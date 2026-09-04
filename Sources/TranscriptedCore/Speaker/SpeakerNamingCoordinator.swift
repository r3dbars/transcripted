import Foundation

/// Tracks which review generation owns each stable transcript identity.
///
/// Callers deliberately consult and mutate this registry while holding
/// `TranscriptSaver`'s file-update serializer. That makes ownership changes
/// atomic with transcript replacement/finalization ordering: a stale callback
/// either finishes before supersession (and is then overwritten by the new
/// transcript) or observes that it no longer owns the file and does nothing.
final class SpeakerNamingRequestOwnership: @unchecked Sendable {
    private struct Entry {
        let requestId: UUID
        let transcriptURL: URL
    }

    private let lock = NSLock()
    private var entriesByTranscriptId: [UUID: [Entry]] = [:]

    func install(requestId: UUID, transcriptId: UUID, transcriptURL: URL) {
        lock.lock()
        var entries = entriesByTranscriptId[transcriptId, default: []]
        entries.removeAll { $0.requestId == requestId }
        entries.append(Entry(
            requestId: requestId,
            transcriptURL: transcriptURL.standardizedFileURL
        ))
        entriesByTranscriptId[transcriptId] = entries
        lock.unlock()
    }

    func isCurrent(requestId: UUID, transcriptId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entriesByTranscriptId[transcriptId]?.last?.requestId == requestId
    }

    func requestId(transcriptId: UUID) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return entriesByTranscriptId[transcriptId]?.last?.requestId
    }

    func requests(transcriptURL: URL) -> [UUID: Set<UUID>] {
        let targetURL = transcriptURL.standardizedFileURL
        lock.lock()
        defer { lock.unlock() }
        return entriesByTranscriptId.compactMapValues { entries in
            let requestIds = Set(entries.compactMap { entry in
                entry.transcriptURL == targetURL ? entry.requestId : nil
            })
            return requestIds.isEmpty ? nil : requestIds
        }
    }

    func invalidate(transcriptId: UUID, requestId: UUID? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let requestId {
            entriesByTranscriptId[transcriptId]?.removeAll { $0.requestId == requestId }
            if entriesByTranscriptId[transcriptId]?.isEmpty == true {
                entriesByTranscriptId.removeValue(forKey: transcriptId)
            }
        } else {
            entriesByTranscriptId.removeValue(forKey: transcriptId)
        }
    }
}

// MARK: - Speaker Naming Flow Coordination

extension TranscriptionTaskManager {

    private struct PlannedNamingChanges {
        let resolvedUpdates: [SpeakerNameUpdate]
        let mutations: [PlannedSpeakerMutation]
    }

    private struct DeferredReviewPlan {
        let redirectedSpeakerIdsByKey: [String: UUID]
        let reviewClipSpeakerIdsByKey: [String: UUID]
        let mutations: [PlannedSpeakerMutation]
    }

    enum NamingFlowFinishOutcome {
        case completed
        case transcriptFinalizationFailed
        case metadataPublicationFailed
        case superseded
    }

    private enum PlannedSpeakerMutation {
        case merge(sourceId: UUID, into: UUID)
        case setDisplayName(id: UUID, name: String)
        case restoreProfile(SpeakerProfile)
        case addOrUpdateEmbedding(embedding: [Float], existingId: UUID?)
        case incrementDisputeCount(UUID)
        case resetDisputeCount(UUID)
        case recordNegativeExemplar(profileId: UUID, embedding: [Float])
    }

    /// Handle completion of the speaker naming flow.
    /// Applies names to the database, updates the transcript, and cleans up.
    ///
    /// DB operations (mergeProfiles, setDisplayName, mergeDuplicates) run on a
    /// background task to avoid blocking the main thread with cascading queue.sync
    /// calls — each DB method synchronously locks a utility queue, and with 7+
    /// speakers this totals 15-20 blocking calls that freeze the UI.
    public func handleNamingComplete(
        updates: [SpeakerNameUpdate],
        transcriptURL: URL,
        transcriptId: UUID,
        transcriptionResult: TranscriptionResult,
        micURL: URL?,
        systemURL: URL,
        splitLocalSpeakers: Bool = false,
        shouldRemoveTemporaryAudio: Bool = true,
        shouldRemoveMicAudio: Bool? = nil,
        shouldRemoveSystemAudio: Bool? = nil,
        sourceFailedTranscriptionId: UUID? = nil,
        clips: [SpeakerNamingEntry],
        importedRecoverySession: (any ImportedTranscriptionRecoverySession)? = nil,
        requestId: UUID? = nil
    ) {
        let removeMicAudio = shouldRemoveMicAudio ?? shouldRemoveTemporaryAudio
        let removeSystemAudio = shouldRemoveSystemAudio ?? shouldRemoveTemporaryAudio
        let speakerDB = transcription.speakerDB
        let clipsDirectory = transcription.speakerClipsDirectory
        let clipsBySpeakerId = Dictionary(uniqueKeysWithValues: clips.map {
            ($0.channel.speakerKey(diarizerSpeakerId: $0.diarizerSpeakerId), $0)
        })

        // Partition updates: special actions follow different paths than regular
        // name/merge/confirm updates. We process all of them during naming completion.
        var collapsedUpdates: [SpeakerNameUpdate] = []
        var discardedUpdates: [SpeakerNameUpdate] = []
        var regularUpdates: [SpeakerNameUpdate] = []
        for update in updates {
            if case .collapsedToMe = update.action { collapsedUpdates.append(update) }
            else if case .discardedFromDatabase = update.action { discardedUpdates.append(update) }
            else { regularUpdates.append(update) }
        }
        let visibleRegularUpdates = regularUpdates.filter {
            Self.visibleTranscriptUtteranceCount(for: $0, in: transcriptionResult) > 0
        }
        let noDialogUpdates = regularUpdates.filter {
            Self.visibleTranscriptUtteranceCount(for: $0, in: transcriptionResult) == 0
        }
        if !noDialogUpdates.isEmpty {
            AppLogger.speakers.warning("Skipping transcript rewrites for speaker updates with no dialog", [
                "count": "\(noDialogUpdates.count)"
            ])
        }
        regularUpdates = regularUpdates.filter {
            Self.visibleTranscriptUtteranceCount(for: $0, in: transcriptionResult) > 0
                || Self.shouldApplyNoDialogDatabaseMutation($0.action)
        }
        let newlyCreatedMicProfileIds = transcriptionResult.newlyCreatedMicProfileIds

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let requestIsCurrent = {
                guard let requestId else { return true }
                return TranscriptSaver.serializeTranscriptFileUpdate {
                    self.speakerNamingRequestOwnership.isCurrent(
                        requestId: requestId,
                        transcriptId: transcriptId
                    )
                }
            }
            let replacementIsInProgress = {
                TranscriptSaver.hasReplacementReservation(at: transcriptURL)
                    || TranscriptSaver.hasReplacementReservation(transcriptId: transcriptId)
            }
            let waitForCurrentRequestAfterReplacement = {
                while !requestIsCurrent() && replacementIsInProgress() {
                    // The review UI has already consumed this one-shot callback.
                    // A replacement failure can restore this generation, so keep
                    // it alive until ownership reaches a permanent outcome.
                    Thread.sleep(forTimeInterval: 0.1)
                }
                return requestIsCurrent()
            }
            guard waitForCurrentRequestAfterReplacement() else {
                AppLogger.pipeline.info("Ignored superseded speaker naming callback", [
                    "transcriptId": transcriptId.uuidString
                ])
                return
            }

            guard let plannedChanges = Self.planNamingUpdates(
                regularUpdates,
                clipsBySpeakerId: clipsBySpeakerId,
                speakerDB: speakerDB
            ) else {
                guard requestIsCurrent() else { return }
                self.cleanupNamingArtifacts(
                    clips: clips,
                    micURL: micURL,
                    systemURL: systemURL,
                    shouldRemoveMicAudio: false,
                    shouldRemoveSystemAudio: false,
                    importedRecoverySession: importedRecoverySession
                )

                Task { @MainActor in
                    _ = self.finishNamingFlow(
                        didFinalizeTranscript: false,
                        updatesCount: updates.count,
                        transcriptId: transcriptId,
                        resolvedURL: transcriptURL,
                        micURL: micURL,
                        systemURL: systemURL,
                        sourceFailedTranscriptionId: sourceFailedTranscriptionId,
                        splitLocalSpeakers: splitLocalSpeakers,
                        importedRecoverySession: importedRecoverySession,
                        requestId: requestId
                    )
                    self.clearCompletedSpeakerNamingRequest(
                        transcriptId: transcriptId,
                        requestId: requestId
                    )
                }
                return
            }

            let deferredReviewPlan = updates.isEmpty
                ? Self.planDeferredReview(clips)
                : nil

            let transcriptUpdates = plannedChanges.resolvedUpdates.filter {
                Self.visibleTranscriptUtteranceCount(for: $0, in: transcriptionResult) > 0
            }
            // Resolve and mutate under the same serializer used by transcript styling/title
            // renames. Otherwise the styler can move the canonical file after resolution but
            // before the first speaker rewrite, leaving finalization pointed at a stale path.
            let finalizeTranscript = {
                TranscriptSaver.serializeTranscriptFileUpdate {
                    if let requestId,
                       !self.speakerNamingRequestOwnership.isCurrent(
                        requestId: requestId,
                        transcriptId: transcriptId
                       ) {
                        let replacementInProgress = TranscriptSaver.hasReplacementReservation(
                            at: transcriptURL
                        ) || TranscriptSaver.hasReplacementReservation(
                            transcriptId: transcriptId
                        )
                        return (
                            didFinalize: false,
                            resolvedURL: transcriptURL,
                            superseded: !replacementInProgress,
                            replacementInProgress: replacementInProgress
                        )
                    }
                    guard !TranscriptSaver.isReplacingTranscript(at: transcriptURL),
                          !TranscriptSaver.isReplacingTranscript(transcriptId: transcriptId) else {
                        return (
                            didFinalize: false,
                            resolvedURL: transcriptURL,
                            superseded: false,
                            replacementInProgress: true
                        )
                    }
                    guard let resolvedURL = TranscriptSaver.resolveTranscriptURL(
                        transcriptURL,
                        transcriptId: transcriptId
                    ) else {
                        return (
                            didFinalize: false,
                            resolvedURL: transcriptURL,
                            superseded: false,
                            replacementInProgress: false
                        )
                    }
                    guard let originalTranscriptData = try? Data(contentsOf: resolvedURL) else {
                        AppLogger.speakers.error("Speaker naming could not snapshot the transcript before update")
                        return (
                            didFinalize: false,
                            resolvedURL: resolvedURL,
                            superseded: false,
                            replacementInProgress: false
                        )
                    }

                var didFinalize = visibleRegularUpdates.isEmpty || TranscriptSaver.updateSpeakerNames(
                    transcriptURL: resolvedURL,
                    updates: transcriptUpdates,
                    transcriptionResult: transcriptionResult
                )

                if didFinalize, let deferredReviewPlan {
                    didFinalize = TranscriptSaver.markSpeakerReviewDeferred(
                        transcriptURL: resolvedURL,
                        entries: clips,
                        redirectedSpeakerIdsByKey: deferredReviewPlan.redirectedSpeakerIdsByKey
                    )
                }

                if didFinalize && !collapsedUpdates.isEmpty {
                    didFinalize = TranscriptSaver.collapseMicSpeakersToYou(
                        transcriptURL: resolvedURL,
                        collapsedUpdates: collapsedUpdates
                    )
                }

                if didFinalize && !discardedUpdates.isEmpty {
                    didFinalize = TranscriptSaver.discardSpeakerDatabaseLinks(
                        transcriptURL: resolvedURL,
                        discardedUpdates: discardedUpdates
                    )
                }

                if didFinalize {
                    do {
                        try speakerDB.performMutationBatch {
                            try Self.applyPlannedNamingMutations(plannedChanges.mutations, speakerDB: speakerDB)
                            try speakerDB.recordUserConfirmations(
                                Self.plannedUserConfirmations(
                                    for: plannedChanges.resolvedUpdates,
                                    transcriptId: transcriptId
                                )
                            )
                            if let deferredReviewPlan {
                                try Self.applyPlannedNamingMutations(deferredReviewPlan.mutations, speakerDB: speakerDB)
                            }
                        }
                    } catch {
                        AppLogger.speakers.error("Speaker naming persistence failed", ["error": error.localizedDescription])
                        didFinalize = false
                    }
                }

                if !didFinalize {
                    do {
                        try originalTranscriptData.write(to: resolvedURL, options: .atomic)
                        FileManager.default.restrictToOwnerOnly(atPath: resolvedURL.path)
                    } catch {
                        AppLogger.speakers.error("Speaker naming transcript rollback failed", [
                            "error": error.localizedDescription
                        ])
                    }
                }

                    return (
                        didFinalize: didFinalize,
                        resolvedURL: resolvedURL,
                        superseded: false,
                        replacementInProgress: false
                    )
                }
            }
            var finalization = finalizeTranscript()
            while finalization.replacementInProgress {
                // A replacement reservation can span model preparation and a
                // full transcription. The review sheet has already handed us
                // its one completion callback, so returning here would strand
                // an invisible request forever. Wait off the main actor and
                // retry only the serialized file-finalization step; speaker DB
                // mutations above are intentionally not repeated.
                Thread.sleep(forTimeInterval: 0.1)
                guard waitForCurrentRequestAfterReplacement() else { return }
                finalization = finalizeTranscript()
            }
            guard !finalization.superseded else {
                AppLogger.pipeline.info("Stopped stale speaker finalization after supersession", [
                    "transcriptId": transcriptId.uuidString
                ])
                return
            }
            let didFinalizeTranscript = finalization.didFinalize
            let resolvedURL = finalization.resolvedURL

            if didFinalizeTranscript {
                speakerDB.recordMatchOutcomes(Self.plannedMatchOutcomes(
                    for: plannedChanges.resolvedUpdates,
                    clipsBySpeakerId: clipsBySpeakerId,
                    transcriptId: transcriptId
                ))
                for update in collapsedUpdates where newlyCreatedMicProfileIds.contains(update.persistentSpeakerId) {
                    speakerDB.deleteSpeaker(id: update.persistentSpeakerId)
                    SpeakerClipExtractor.deletePersistedClip(
                        for: update.persistentSpeakerId,
                        clipsDirectory: clipsDirectory
                    )
                    AppLogger.speakers.info("Collapsed mic speaker — deleted newly-created profile", [
                        "profileId": update.persistentSpeakerId.uuidString,
                        "diarizerSpeakerId": update.diarizerSpeakerId
                    ])
                }
                Self.restoreCollapsedMatchedSpeakers(
                    collapsedUpdates,
                    clipsBySpeakerId: clipsBySpeakerId,
                    speakerDB: speakerDB
                )
                Self.applyDiscardedSpeakerActions(
                    discardedUpdates,
                    clipsBySpeakerId: clipsBySpeakerId,
                    speakerDB: speakerDB,
                    clipsDirectory: clipsDirectory
                )
                Self.persistReviewClips(
                    clips,
                    speakerIdsByKey: deferredReviewPlan?.reviewClipSpeakerIdsByKey
                        ?? Self.reviewClipSpeakerIdsByKey(from: plannedChanges.resolvedUpdates),
                    excludingSpeakerIds: Self.nonRetainedReviewSpeakerIds(from: collapsedUpdates + discardedUpdates),
                    clipsDirectory: clipsDirectory
                )
            }

            if !didFinalizeTranscript {
                self.cleanupNamingArtifacts(
                    clips: clips,
                    micURL: micURL,
                    systemURL: systemURL,
                    shouldRemoveMicAudio: false,
                    shouldRemoveSystemAudio: false,
                    importedRecoverySession: importedRecoverySession
                )
            }

            Task { @MainActor in
                let outcome = self.finishNamingFlow(
                    didFinalizeTranscript: didFinalizeTranscript,
                    updatesCount: updates.count,
                    transcriptId: transcriptId,
                    resolvedURL: resolvedURL,
                    micURL: micURL,
                    systemURL: systemURL,
                    sourceFailedTranscriptionId: sourceFailedTranscriptionId,
                    splitLocalSpeakers: splitLocalSpeakers,
                    importedRecoverySession: importedRecoverySession,
                    shouldDeleteSourceFailedAudio: shouldRemoveTemporaryAudio,
                    requestId: requestId
                )
                switch outcome {
                case .completed:
                    self.cleanupNamingArtifacts(
                        clips: clips,
                        micURL: micURL,
                        systemURL: systemURL,
                        shouldRemoveMicAudio: removeMicAudio,
                        shouldRemoveSystemAudio: removeSystemAudio,
                        importedRecoverySession: importedRecoverySession
                    )
                case .metadataPublicationFailed:
                    // The speaker clips are no longer needed, but retry audio must remain
                    // available through the failed-transcription queue.
                    self.cleanupNamingArtifacts(
                        clips: clips,
                        micURL: micURL,
                        systemURL: systemURL,
                        shouldRemoveMicAudio: false,
                        shouldRemoveSystemAudio: false
                    )
                case .transcriptFinalizationFailed:
                    break
                case .superseded:
                    return
                }
                self.clearCompletedSpeakerNamingRequest(
                    transcriptId: transcriptId,
                    requestId: requestId
                )
            }
        }
    }

    /// Clean up any tasks stuck in pendingNaming state.
    /// Called from applicationWillTerminate to prevent orphaned audio files.
    public func cleanupPendingNaming() {
        let requests = [speakerNamingRequest].compactMap { $0 }
            + pendingSpeakerNamingRequests
            + Array(deferredSpeakerNamingRequests.values)
        guard !requests.isEmpty else { return }

        TranscriptSaver.serializeTranscriptFileUpdate {
            for request in requests {
                speakerNamingRequestOwnership.invalidate(
                    transcriptId: request.transcriptId,
                    requestId: request.id
                )
            }
        }
        for request in requests {
            cleanupSpeakerNamingRequest(request)
        }
        speakerNamingRequest = nil
        pendingSpeakerNamingRequests.removeAll()
        deferredSpeakerNamingRequests.removeAll()
        AppLogger.pipeline.info("Cleaned up pending naming on shutdown", [
            "count": "\(requests.count)"
        ])
    }

    func enqueueSpeakerNamingRequest(_ request: SpeakerNamingRequest) {
        let duplicateRequests = [speakerNamingRequest].compactMap { $0 }
            .filter { $0.transcriptId == request.transcriptId }
            + pendingSpeakerNamingRequests.filter { $0.transcriptId == request.transcriptId }
            + deferredSpeakerNamingRequests.values.filter {
                $0.transcriptId == request.transcriptId
            }
        if !duplicateRequests.isEmpty {
            let isReplacementGeneration = TranscriptSaver.hasReplacementReservation(
                at: request.transcriptURL
            ) || TranscriptSaver.hasReplacementReservation(
                transcriptId: request.transcriptId
            )
            guard isReplacementGeneration else {
                AppLogger.pipeline.warning("Ignoring duplicate speaker naming request", [
                    "transcriptId": request.transcriptId.uuidString
                ])
                return
            }

            // Keep the previous generation until the replacement task commits.
            // This request becomes the current owner immediately, so an old
            // callback cannot edit the replacement file. If the task rolls back,
            // removing this request reveals the prior owner and review.
        }

        speakerNamingRequestOwnership.install(
            requestId: request.id,
            transcriptId: request.transcriptId,
            transcriptURL: request.transcriptURL
        )

        if !duplicateRequests.isEmpty {
            AppLogger.pipeline.info("Superseded speaker review with replacement generation", [
                "transcriptId": request.transcriptId.uuidString
            ])
        }

        guard speakerNamingRequest != nil else {
            speakerNamingRequest = request
            return
        }

        pendingSpeakerNamingRequests.append(request)
        AppLogger.pipeline.info("Queued speaker naming request behind active review", [
            "pending": "\(pendingSpeakerNamingRequests.count)"
        ])
    }

    @discardableResult
    public func deferPendingSpeakerNamingReview(reason: String) -> Bool {
        guard let request = speakerNamingRequest else { return false }
        speakerNamingRequest = nil
        deferredSpeakerNamingRequests[request.id] = request

        AppLogger.pipeline.info("Deferring pending speaker review", [
            "reason": reason,
            "speakers": "\(request.speakers.count)"
        ])
        request.onComplete([])
        return true
    }

    public func hasPendingSpeakerNamingReviewForLastSavedTranscript() -> Bool {
        if let transcriptId = lastSavedTranscriptId,
           hasPendingSpeakerNamingReview(transcriptId: transcriptId) {
            return true
        }

        guard let transcriptURL = lastSavedTranscriptURL else { return false }
        return hasPendingSpeakerNamingReview(transcriptURL: transcriptURL)
    }

    public func hasPendingSpeakerNamingReview(transcriptId: UUID) -> Bool {
        speakerNamingRequest?.transcriptId == transcriptId
            || pendingSpeakerNamingRequests.contains { $0.transcriptId == transcriptId }
    }

    public func hasPendingSpeakerNamingReview(transcriptURL: URL) -> Bool {
        let standardizedURL = transcriptURL.standardizedFileURL
        return speakerNamingRequest?.transcriptURL.standardizedFileURL == standardizedURL
            || pendingSpeakerNamingRequests.contains { request in
                request.transcriptURL.standardizedFileURL == standardizedURL
            }
    }

    private func cleanupSpeakerNamingRequest(
        _ request: SpeakerNamingRequest,
        preservingSourceAudio: Bool = false
    ) {
        if !preservingSourceAudio
            && (request.shouldRemoveMicAudioOnCleanup || request.shouldRemoveSystemAudioOnCleanup) {
            if request.importedRecoverySession?.prepareForScratchCleanup() != false {
                let removedMic = !request.shouldRemoveMicAudioOnCleanup
                    || removeManagedCleanupFile(request.micAudioURL, label: "pending mic audio")
                let removedSystem = !request.shouldRemoveSystemAudioOnCleanup
                    || removeManagedCleanupFile(request.systemAudioURL, label: "pending system audio")
                if removedMic && removedSystem {
                    request.importedRecoverySession?.scratchCleanupConfirmed()
                }
            }
        }
        cleanupSpeakerClips(request.speakers)
    }

    func clearCompletedSpeakerNamingRequest(
        transcriptId: UUID,
        requestId: UUID? = nil
    ) {
        TranscriptSaver.serializeTranscriptFileUpdate {
            speakerNamingRequestOwnership.invalidate(
                transcriptId: transcriptId,
                requestId: requestId
            )
        }
        if speakerNamingRequest?.transcriptId == transcriptId
            && (requestId == nil || speakerNamingRequest?.id == requestId) {
            speakerNamingRequest = nil
        }
        pendingSpeakerNamingRequests.removeAll {
            $0.transcriptId == transcriptId && (requestId == nil || $0.id == requestId)
        }
        if let requestId {
            deferredSpeakerNamingRequests.removeValue(forKey: requestId)
        } else {
            deferredSpeakerNamingRequests = deferredSpeakerNamingRequests.filter {
                $0.value.transcriptId != transcriptId
            }
        }
        promoteNextSpeakerNamingRequestIfNeeded()
    }

    func cancelSpeakerNamingRequest(transcriptId: UUID) {
        removeSpeakerNamingRequests(
            transcriptId: transcriptId,
            requestIds: nil,
            preservingSourceAudio: false
        )
    }

    func cancelSpeakerNamingRequest(transcriptId: UUID, requestId: UUID) {
        removeSpeakerNamingRequests(
            transcriptId: transcriptId,
            requestIds: [requestId],
            preservingSourceAudio: false
        )
    }

    func speakerNamingRequestIds(transcriptId: UUID) -> Set<UUID> {
        var requestIds = Set(([speakerNamingRequest].compactMap { $0 } + pendingSpeakerNamingRequests)
            .filter { $0.transcriptId == transcriptId }
            .map(\.id))
        if let ownedRequestId = speakerNamingRequestOwnership.requestId(transcriptId: transcriptId) {
            requestIds.insert(ownedRequestId)
        }
        return requestIds
    }

    func speakerNamingRequestIds(transcriptURL: URL) -> [UUID: Set<UUID>] {
        let targetURL = transcriptURL.standardizedFileURL
        let matching = ([speakerNamingRequest].compactMap { $0 } + pendingSpeakerNamingRequests)
            .filter { $0.transcriptURL.standardizedFileURL == targetURL }
        var requestIds = Dictionary(grouping: matching, by: \.transcriptId)
            .mapValues { Set($0.map(\.id)) }
        for (transcriptId, ownedRequestIds) in speakerNamingRequestOwnership.requests(
            transcriptURL: transcriptURL
        ) {
            requestIds[transcriptId, default: []].formUnion(ownedRequestIds)
        }
        return requestIds
    }

    func supersedeSpeakerNamingRequests(
        transcriptId: UUID,
        requestIds: Set<UUID>
    ) {
        guard !requestIds.isEmpty else { return }
        removeSpeakerNamingRequests(
            transcriptId: transcriptId,
            requestIds: requestIds,
            preservingSourceAudio: false
        )
    }

    private func removeSpeakerNamingRequests(
        transcriptId: UUID,
        requestIds: Set<UUID>?,
        preservingSourceAudio: Bool
    ) {
        let matchesTarget: (SpeakerNamingRequest) -> Bool = { request in
            request.transcriptId == transcriptId
                && (requestIds.map { $0.contains(request.id) } ?? true)
        }
        let cancelledRequests = [speakerNamingRequest].compactMap { $0 }
            .filter(matchesTarget)
            + pendingSpeakerNamingRequests.filter(matchesTarget)
            + deferredSpeakerNamingRequests.values.filter(matchesTarget)

        TranscriptSaver.serializeTranscriptFileUpdate {
            if let requestIds {
                for requestId in requestIds {
                    speakerNamingRequestOwnership.invalidate(
                        transcriptId: transcriptId,
                        requestId: requestId
                    )
                }
            } else {
                speakerNamingRequestOwnership.invalidate(transcriptId: transcriptId)
            }
        }
        if let activeRequest = speakerNamingRequest,
           matchesTarget(activeRequest) {
            speakerNamingRequest = nil
        }
        pendingSpeakerNamingRequests.removeAll(where: matchesTarget)
        deferredSpeakerNamingRequests = deferredSpeakerNamingRequests.filter {
            !matchesTarget($0.value)
        }
        for request in cancelledRequests {
            cleanupSpeakerNamingRequest(
                request,
                preservingSourceAudio: preservingSourceAudio
            )
        }
        promoteNextSpeakerNamingRequestIfNeeded()
    }

    private func promoteNextSpeakerNamingRequestIfNeeded() {
        guard speakerNamingRequest == nil, !pendingSpeakerNamingRequests.isEmpty else { return }
        speakerNamingRequest = pendingSpeakerNamingRequests.removeFirst()
    }

    nonisolated private func cleanupNamingArtifacts(
        clips: [SpeakerNamingEntry],
        micURL: URL?,
        systemURL: URL,
        shouldRemoveMicAudio: Bool,
        shouldRemoveSystemAudio: Bool,
        importedRecoverySession: (any ImportedTranscriptionRecoverySession)? = nil
    ) {
        cleanupSpeakerClips(clips)
        guard shouldRemoveMicAudio || shouldRemoveSystemAudio else { return }
        guard importedRecoverySession?.prepareForScratchCleanup() != false else { return }
        let removedMic = !shouldRemoveMicAudio
            || removeManagedCleanupFile(micURL, label: "mic audio")
        let removedSystem = !shouldRemoveSystemAudio
            || removeManagedCleanupFile(systemURL, label: "system audio")
        if removedMic && removedSystem {
            importedRecoverySession?.scratchCleanupConfirmed()
        }
    }

    nonisolated private func cleanupSpeakerClips(_ clips: [SpeakerNamingEntry]) {
        for clip in clips {
            removeManagedCleanupFile(clip.clipURL, label: "speaker naming clip")
        }
    }

    nonisolated private static func planNamingUpdates(
        _ updates: [SpeakerNameUpdate],
        clipsBySpeakerId: [String: SpeakerNamingEntry],
        speakerDB: any SpeakerStore
    ) -> PlannedNamingChanges? {
        var resolvedUpdates: [SpeakerNameUpdate] = []
        resolvedUpdates.reserveCapacity(updates.count)
        var mutations: [PlannedSpeakerMutation] = []
        var manualNameTargets: [String: (id: UUID, displayName: String)] = [:]
        var mergeTargets: [UUID: UUID] = [:]

        for update in updates {
            let entry = clipsBySpeakerId[update.channel.speakerKey(diarizerSpeakerId: update.diarizerSpeakerId)]
            guard let plan = planPersistentSpeakerResolution(
                for: update,
                entry: entry,
                speakerDB: speakerDB
            ) else {
                return nil
            }

            var resolvedPersistentSpeakerId = plan.resolvedPersistentSpeakerId
            var plannedMutations = plan.mutations
            var resolvedName = update.newName
            if Self.shouldCoalesceManualName(update.action) {
                let nameKey = normalizeSpeakerName(update.newName)
                if !nameKey.isEmpty, let existingTarget = manualNameTargets[nameKey] {
                    resolvedPersistentSpeakerId = existingTarget.id
                    resolvedName = existingTarget.displayName
                    plannedMutations = Self.coalescedManualNameMutations(
                        for: update,
                        entry: entry,
                        existingTarget: existingTarget.id,
                        canonicalName: existingTarget.displayName,
                        plannedMutations: plannedMutations
                    )
                } else if !nameKey.isEmpty {
                    manualNameTargets[nameKey] = (plan.resolvedPersistentSpeakerId, update.newName)
                }
            }

            AppLogger.speakers.info("Speaker named", [
                "originalId": update.persistentSpeakerId.uuidString,
                "resolvedId": resolvedPersistentSpeakerId.uuidString,
                "name": resolvedName,
                "action": "\(update.action)"
            ])

            resolvedUpdates.append(SpeakerNameUpdate(
                persistentSpeakerId: update.persistentSpeakerId,
                diarizerSpeakerId: update.diarizerSpeakerId,
                channel: update.channel,
                newName: resolvedName,
                previousName: update.previousName,
                action: update.action,
                resolvedPersistentSpeakerId: resolvedPersistentSpeakerId
            ))
            for mutation in plannedMutations {
                if case .merge(let sourceId, let targetId) = mutation {
                    // Diarizer rows can share one database profile. Merge that profile
                    // once, while still rewriting and confirming every transcript row.
                    guard sourceId != targetId else { continue }
                    if let previousTarget = mergeTargets[sourceId] {
                        guard previousTarget == targetId else { return nil }
                        continue
                    }
                    mergeTargets[sourceId] = targetId
                }
                mutations.append(mutation)
            }
        }

        return PlannedNamingChanges(
            resolvedUpdates: resolvedUpdates,
            mutations: mutations
        )
    }

    /// Map submitted review verdicts onto the recognition lifeline.
    ///
    /// Corrections attribute to the profile that was wrongly suggested (the
    /// pre-meeting matched snapshot) so the mistake lands on the profile that
    /// made it; everything else attributes to the resolved profile. Collapse
    /// and discard rows are user bookkeeping, not match verdicts, and are
    /// intentionally not recorded.
    nonisolated static func plannedMatchOutcomes(
        for updates: [SpeakerNameUpdate],
        clipsBySpeakerId: [String: SpeakerNamingEntry],
        transcriptId: UUID
    ) -> [SpeakerMatchOutcome] {
        updates.compactMap { update in
            guard let kind = SpeakerMatchOutcomeKind(reviewAction: update.action) else {
                return nil
            }

            let entry = clipsBySpeakerId[update.channel.speakerKey(diarizerSpeakerId: update.diarizerSpeakerId)]
            let profileId: UUID
            switch update.action {
            case .corrected:
                profileId = entry?.matchedProfileSnapshot?.id ?? update.persistentSpeakerId
            case .merged(let targetProfileId):
                profileId = targetProfileId
            default:
                profileId = update.resolvedPersistentSpeakerId ?? update.persistentSpeakerId
            }

            return SpeakerMatchOutcome(
                profileId: profileId,
                kind: kind,
                similarity: entry?.matchSimilarity,
                secondSimilarity: entry?.matchSecondSimilarity,
                callCountAtMatch: entry?.matchedProfileSnapshot?.callCount,
                channel: update.channel.rawValue,
                transcriptId: transcriptId
            )
        }
    }

    /// Canonical identity-learning proof. Unlike the recognition lifeline,
    /// corrections are attributed to the corrected-to profile. A unique
    /// profile/transcript constraint means multiple rows for one person in one
    /// meeting still count as exactly one confirmation.
    nonisolated static func plannedUserConfirmations(
        for updates: [SpeakerNameUpdate],
        transcriptId: UUID
    ) -> [SpeakerUserConfirmation] {
        updates.compactMap { update in
            guard let kind = SpeakerUserConfirmationKind(reviewAction: update.action) else {
                return nil
            }

            let profileId: UUID
            switch update.action {
            case .merged(let targetProfileId):
                profileId = targetProfileId
            case .named, .confirmed, .corrected:
                profileId = update.resolvedPersistentSpeakerId ?? update.persistentSpeakerId
            case .collapsedToMe, .discardedFromDatabase:
                return nil
            }
            return SpeakerUserConfirmation(
                profileId: profileId,
                transcriptId: transcriptId,
                kind: kind
            )
        }
    }

    nonisolated private static func shouldCoalesceManualName(_ action: SpeakerNameUpdate.NamingAction) -> Bool {
        switch action {
        case .named, .corrected:
            return true
        case .confirmed, .merged, .collapsedToMe, .discardedFromDatabase:
            return false
        }
    }

    nonisolated private static func shouldApplyNoDialogDatabaseMutation(_ action: SpeakerNameUpdate.NamingAction) -> Bool {
        switch action {
        case .confirmed, .corrected, .merged:
            return true
        case .named, .collapsedToMe, .discardedFromDatabase:
            return false
        }
    }

    nonisolated private static func coalescedManualNameMutations(
        for update: SpeakerNameUpdate,
        entry: SpeakerNamingEntry?,
        existingTarget: UUID,
        canonicalName: String,
        plannedMutations: [PlannedSpeakerMutation]
    ) -> [PlannedSpeakerMutation] {
        switch update.action {
        case .named:
            var mutations: [PlannedSpeakerMutation] = []
            if update.persistentSpeakerId != existingTarget {
                mutations.append(.merge(sourceId: update.persistentSpeakerId, into: existingTarget))
            }
            mutations.append(.resetDisputeCount(existingTarget))
            return mutations

        case .corrected:
            var mutations = plannedMutations.compactMap { mutation -> PlannedSpeakerMutation? in
                switch mutation {
                case .restoreProfile, .incrementDisputeCount, .recordNegativeExemplar:
                    return mutation
                case .merge, .setDisplayName, .addOrUpdateEmbedding, .resetDisputeCount:
                    return nil
                }
            }
            if let embedding = entry?.sessionEmbedding {
                mutations.append(.addOrUpdateEmbedding(embedding: embedding, existingId: existingTarget))
            }
            mutations.append(.setDisplayName(id: existingTarget, name: canonicalName))
            mutations.append(.resetDisputeCount(existingTarget))
            return mutations

        case .confirmed, .merged, .collapsedToMe, .discardedFromDatabase:
            return plannedMutations
        }
    }

    nonisolated private static func planPersistentSpeakerResolution(
        for update: SpeakerNameUpdate,
        entry: SpeakerNamingEntry?,
        speakerDB: any SpeakerStore
    ) -> (resolvedPersistentSpeakerId: UUID, mutations: [PlannedSpeakerMutation])? {
        switch update.action {
        case .merged(let targetProfileId):
            return (
                targetProfileId,
                [
                    .merge(sourceId: update.persistentSpeakerId, into: targetProfileId),
                    .resetDisputeCount(targetProfileId),
                ]
            )

        case .confirmed:
            return (
                update.persistentSpeakerId,
                [
                    .setDisplayName(id: update.persistentSpeakerId, name: update.newName),
                    .resetDisputeCount(update.persistentSpeakerId),
                ]
            )

        case .named:
            if let targetProfile = exactNamedTarget(
                named: update.newName,
                excluding: update.persistentSpeakerId,
                speakerDB: speakerDB
            ) {
                return (
                    targetProfile.id,
                    [
                        .merge(sourceId: update.persistentSpeakerId, into: targetProfile.id),
                        .resetDisputeCount(targetProfile.id),
                    ]
                )
            }

            return (
                update.persistentSpeakerId,
                [
                    .setDisplayName(id: update.persistentSpeakerId, name: update.newName),
                    .resetDisputeCount(update.persistentSpeakerId),
                ]
            )

        case .corrected:
            var mutations: [PlannedSpeakerMutation] = []
            if let matchedProfile = entry?.matchedProfileSnapshot {
                mutations.append(.restoreProfile(matchedProfile))
                mutations.append(.incrementDisputeCount(matchedProfile.id))
                // The rejected embedding becomes a negative exemplar against the wrongly-suggested
                // profile: "this voice is explicitly not this person", used to veto future matches.
                // The corrected-to target (below) is resolved via `exactNamedTarget(excluding:
                // update.persistentSpeakerId)`, and on a match `persistentSpeakerId == matchedProfile.id`,
                // so the target can never be the matched profile — the same id is never written a
                // positive embedding and a negative exemplar for one correction.
                if let embedding = entry?.sessionEmbedding {
                    mutations.append(.recordNegativeExemplar(profileId: matchedProfile.id, embedding: embedding))
                }
            }

            if let targetProfile = exactNamedTarget(
                named: update.newName,
                excluding: update.persistentSpeakerId,
                speakerDB: speakerDB
            ) {
                if let embedding = entry?.sessionEmbedding {
                    mutations.append(.addOrUpdateEmbedding(embedding: embedding, existingId: targetProfile.id))
                }
                mutations.append(.setDisplayName(id: targetProfile.id, name: update.newName))
                mutations.append(.resetDisputeCount(targetProfile.id))
                return (targetProfile.id, mutations)
            }

            if let embedding = entry?.sessionEmbedding {
                let newProfileId = UUID()
                mutations.append(.addOrUpdateEmbedding(embedding: embedding, existingId: newProfileId))
                mutations.append(.setDisplayName(id: newProfileId, name: update.newName))
                mutations.append(.resetDisputeCount(newProfileId))
                return (newProfileId, mutations)
            }

            AppLogger.speakers.error("Correction missing session embedding; refusing unsafe profile rewrite", [
                "speakerId": update.persistentSpeakerId.uuidString,
                "name": update.newName
            ])
            return nil

        case .collapsedToMe:
            // Collapsed updates are handled upstream in handleNamingComplete because they
            // rewrite transcript text and delete only newly-created mic profiles.
            return (update.persistentSpeakerId, [])

        case .discardedFromDatabase:
            // Discarded updates are handled upstream because they remove transcript DB links
            // and either delete a new profile or restore an existing matched profile snapshot.
            return (update.persistentSpeakerId, [])
        }
    }

    nonisolated private static func applyPlannedNamingMutations(
        _ mutations: [PlannedSpeakerMutation],
        speakerDB: any SpeakerStore
    ) throws {
        for mutation in mutations {
            switch mutation {
            case .merge(let sourceId, let targetId):
                try speakerDB.mergeProfiles(sourceId: sourceId, into: targetId)
            case .setDisplayName(let id, let name):
                speakerDB.setDisplayName(id: id, name: name, source: NameSource.userManual)
            case .restoreProfile(let profile):
                speakerDB.restoreProfile(profile)
            case .addOrUpdateEmbedding(let embedding, let existingId):
                _ = speakerDB.addOrUpdateSpeaker(embedding: embedding, existingId: existingId)
            case .incrementDisputeCount(let id):
                speakerDB.incrementDisputeCount(id: id)
            case .resetDisputeCount(let id):
                speakerDB.resetDisputeCount(id: id)
            case .recordNegativeExemplar(let profileId, let embedding):
                speakerDB.recordNegativeExemplar(profileId: profileId, embedding: embedding)
            }
        }
    }

    nonisolated private static func planDeferredReview(_ clips: [SpeakerNamingEntry]) -> DeferredReviewPlan {
        var redirectedSpeakerIdsByKey: [String: UUID] = [:]
        var reviewClipSpeakerIdsByKey: [String: UUID] = [:]
        var mutations: [PlannedSpeakerMutation] = []

        for clip in clips {
            let key = clip.channel.speakerKey(diarizerSpeakerId: clip.diarizerSpeakerId)
            guard let matchedProfile = clip.matchedProfileSnapshot,
                  let embedding = clip.sessionEmbedding else {
                reviewClipSpeakerIdsByKey[key] = clip.id
                continue
            }

            let deferredProfileId = UUID()
            redirectedSpeakerIdsByKey[key] = deferredProfileId
            reviewClipSpeakerIdsByKey[key] = deferredProfileId
            mutations.append(.restoreProfile(matchedProfile))
            mutations.append(.addOrUpdateEmbedding(embedding: embedding, existingId: deferredProfileId))
        }

        return DeferredReviewPlan(
            redirectedSpeakerIdsByKey: redirectedSpeakerIdsByKey,
            reviewClipSpeakerIdsByKey: reviewClipSpeakerIdsByKey,
            mutations: mutations
        )
    }

    nonisolated private static func reviewClipSpeakerIdsByKey(from updates: [SpeakerNameUpdate]) -> [String: UUID] {
        Dictionary(uniqueKeysWithValues: updates.map { update in
            (
                update.channel.speakerKey(diarizerSpeakerId: update.diarizerSpeakerId),
                update.resolvedPersistentSpeakerId ?? update.persistentSpeakerId
            )
        })
    }

    nonisolated private static func restoreCollapsedMatchedSpeakers(
        _ updates: [SpeakerNameUpdate],
        clipsBySpeakerId: [String: SpeakerNamingEntry],
        speakerDB: any SpeakerStore
    ) {
        for update in updates {
            let key = update.channel.speakerKey(diarizerSpeakerId: update.diarizerSpeakerId)
            guard let snapshot = clipsBySpeakerId[key]?.matchedProfileSnapshot else { continue }

            speakerDB.restoreProfile(snapshot)
            speakerDB.incrementDisputeCount(id: snapshot.id)
            AppLogger.speakers.info("Collapsed mic speaker — restored matched profile", [
                "profileId": snapshot.id.uuidString,
                "diarizerSpeakerId": update.diarizerSpeakerId
            ])
        }
    }

    nonisolated private static func applyDiscardedSpeakerActions(
        _ updates: [SpeakerNameUpdate],
        clipsBySpeakerId: [String: SpeakerNamingEntry],
        speakerDB: any SpeakerStore,
        clipsDirectory: URL
    ) {
        for update in updates {
            let key = update.channel.speakerKey(diarizerSpeakerId: update.diarizerSpeakerId)
            guard let entry = clipsBySpeakerId[key] else {
                AppLogger.speakers.warning("Skipped speaker discard because review entry was missing", [
                    "speakerId": update.persistentSpeakerId.uuidString,
                    "diarizerSpeakerId": update.diarizerSpeakerId
                ])
                continue
            }

            if let snapshot = entry.matchedProfileSnapshot {
                // Discard freezes the matched profile (dispute count) but intentionally does NOT
                // record a negative exemplar: unlike an explicit correction, a discard says "don't
                // save this sample", not "this voice is a different known person". Negative
                // exemplars are scoped to the `.corrected` path.
                speakerDB.restoreProfile(snapshot)
                speakerDB.incrementDisputeCount(id: snapshot.id)
                AppLogger.speakers.info("Discarded speaker sample and restored matched profile", [
                    "profileId": snapshot.id.uuidString,
                    "diarizerSpeakerId": update.diarizerSpeakerId
                ])
            } else if entry.currentName == nil && entry.matchSimilarity == nil {
                speakerDB.deleteSpeaker(id: update.persistentSpeakerId)
                SpeakerClipExtractor.deletePersistedClip(
                    for: update.persistentSpeakerId,
                    clipsDirectory: clipsDirectory
                )
                AppLogger.speakers.info("Discarded newly-created speaker profile", [
                    "profileId": update.persistentSpeakerId.uuidString,
                    "diarizerSpeakerId": update.diarizerSpeakerId
                ])
            } else {
                AppLogger.speakers.warning("Skipped speaker discard delete for existing profile without snapshot", [
                    "profileId": update.persistentSpeakerId.uuidString,
                    "diarizerSpeakerId": update.diarizerSpeakerId
                ])
            }
        }
    }

    nonisolated private static func nonRetainedReviewSpeakerIds(from updates: [SpeakerNameUpdate]) -> Set<UUID> {
        Set(updates.map(\.persistentSpeakerId))
    }

    nonisolated private static func persistReviewClips(
        _ clips: [SpeakerNamingEntry],
        speakerIdsByKey: [String: UUID],
        excludingSpeakerIds excludedSpeakerIds: Set<UUID>,
        clipsDirectory: URL
    ) {
        for clip in clips where !excludedSpeakerIds.contains(clip.id) {
            let key = clip.channel.speakerKey(diarizerSpeakerId: clip.diarizerSpeakerId)
            let speakerId = speakerIdsByKey[key] ?? clip.id
            SpeakerClipExtractor.persistClip(
                from: clip.clipURL,
                speakerId: speakerId,
                clipsDirectory: clipsDirectory
            )
        }
    }

    nonisolated private static func exactNamedTarget(
        named rawName: String,
        excluding sourceId: UUID,
        speakerDB: any SpeakerStore
    ) -> SpeakerProfile? {
        let targetName = normalizeSpeakerName(rawName)
        guard !targetName.isEmpty else { return nil }

        return speakerDB.allSpeakers()
            .filter { profile in
                profile.id != sourceId && normalizeSpeakerName(profile.displayName) == targetName
            }
            .sorted { $0.callCount > $1.callCount }
            .first
    }

    nonisolated private static func normalizeSpeakerName(_ name: String?) -> String {
        (name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    nonisolated private static func visibleTranscriptUtteranceCount(
        for update: SpeakerNameUpdate,
        in result: TranscriptionResult
    ) -> Int {
        guard let diarizerSpeakerId = Int(update.diarizerSpeakerId) else { return 0 }
        let utterances = update.channel == .mic
            ? result.micUtterances
            : result.systemUtterances
        return utterances.filter {
            $0.speakerId == diarizerSpeakerId
                && !$0.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    @MainActor func finishNamingFlow(
        didFinalizeTranscript: Bool,
        updatesCount: Int,
        transcriptId: UUID,
        resolvedURL: URL,
        micURL: URL?,
        systemURL: URL,
        sourceFailedTranscriptionId: UUID? = nil,
        splitLocalSpeakers: Bool = false,
        importedRecoverySession: (any ImportedTranscriptionRecoverySession)? = nil,
        shouldDeleteSourceFailedAudio: Bool = true,
        requestId: UUID? = nil
    ) -> NamingFlowFinishOutcome {
        // Failure publication also belongs to the request generation. A replacement
        // can finish between the background attempt and this MainActor handoff.
        if let requestId, !speakerNamingRequestOwnership.isCurrent(
            requestId: requestId, transcriptId: transcriptId
        ) {
            return .superseded
        }
        if didFinalizeTranscript {
            // A title/style rename can queue behind transcript finalization and move the file
            // before this MainActor handoff runs. Resolve and consume metadata in one serialized
            // transaction so UI bookkeeping never publishes the stale pre-rename URL.
            let publicationAttempt = TranscriptSaver.serializeTranscriptFileUpdate {
                    if let requestId,
                       !speakerNamingRequestOwnership.isCurrent(
                        requestId: requestId,
                        transcriptId: transcriptId
                       ) {
                        return (
                            metadata: Optional<(resolvedURL: URL, didAlreadyPublish: Bool)>.none,
                            superseded: true
                        )
                    }
                    guard let currentURL = TranscriptSaver.resolveTranscriptURL(
                        resolvedURL,
                        transcriptId: transcriptId
                    ) else {
                        return (
                            metadata: Optional<(resolvedURL: URL, didAlreadyPublish: Bool)>.none,
                            superseded: false
                        )
                    }

                    let didAlreadyPublish = lastSavedTranscriptId == transcriptId
                        || lastSavedTranscriptURL == currentURL
                    populateSavedMetadata(from: currentURL)
                    return (
                        metadata: Optional.some((
                            resolvedURL: currentURL,
                            didAlreadyPublish: didAlreadyPublish
                        )),
                        superseded: false
                    )
                }

            guard !publicationAttempt.superseded else { return .superseded }
            let metadataPublication = publicationAttempt.metadata

            guard let metadataPublication else {
                AppLogger.pipeline.error("Speaker naming metadata publication failed", [
                    "transcriptId": transcriptId.uuidString,
                    "transcript": resolvedURL.lastPathComponent
                ])
                let retryError = "Speaker names were saved, but the finalized transcript could not be found. Retry audio was preserved."
                let retryId = sourceFailedTranscriptionId ?? transcriptId
                let didPersistRetry = persistNamingFailureRetry(
                    id: retryId,
                    transcriptURL: resolvedURL,
                    micURL: micURL,
                    systemURL: systemURL,
                    splitLocalSpeakers: splitLocalSpeakers,
                    errorMessage: retryError
                )
                if didPersistRetry {
                    importedRecoverySession?.failedQueueHandoffConfirmed()
                    displayStatus = .failed(message: "Final transcript could not be found. Retry audio was kept.")
                } else {
                    AppLogger.pipeline.error("Speaker naming retry queue persistence failed", [
                        "transcriptId": transcriptId.uuidString,
                        "retryId": retryId.uuidString
                    ])
                    displayStatus = .failed(
                        message: "Final transcript could not be found. Retry could not be saved; audio was left in place."
                    )
                }
                scheduleStatusReset(delay: 8)
                return .metadataPublicationFailed
            }

            AppLogger.pipeline.info("Speaker naming complete", [
                "named": "\(updatesCount)",
                "transcript": metadataPublication.resolvedURL.lastPathComponent
            ])
            if let sourceFailedTranscriptionId {
                if shouldDeleteSourceFailedAudio {
                    failedTranscriptionManager.deleteFailedTranscription(id: sourceFailedTranscriptionId)
                } else {
                    failedTranscriptionManager.removeFailedTranscription(id: sourceFailedTranscriptionId)
                }
            }
            if !metadataPublication.didAlreadyPublish {
                displayStatus = .transcriptSaved
                scheduleStatusReset(delay: 8)
            }
            return .completed
        } else {
            AppLogger.pipeline.error("Speaker naming finalization failed", [
                "transcriptId": transcriptId.uuidString,
                "transcript": resolvedURL.lastPathComponent
            ])
            let didPersistRetry = persistNamingFailureRetry(
                id: sourceFailedTranscriptionId ?? transcriptId,
                transcriptURL: resolvedURL,
                micURL: micURL,
                systemURL: systemURL,
                splitLocalSpeakers: splitLocalSpeakers,
                errorMessage: "Speaker names could not be saved. Retry to rebuild the meeting and save the names."
            )
            if didPersistRetry {
                importedRecoverySession?.failedQueueHandoffConfirmed()
            }
            displayStatus = .failed(message: didPersistRetry
                ? "Failed to finalize speaker names"
                : "Speaker names could not be saved. Retry could not be saved; audio was left in place.")
            scheduleStatusReset(delay: 8)
            return .transcriptFinalizationFailed
        }
    }

    @MainActor private func persistNamingFailureRetry(
        id: UUID,
        transcriptURL: URL,
        micURL: URL?,
        systemURL: URL,
        splitLocalSpeakers: Bool,
        errorMessage: String
    ) -> Bool {
        if failedTranscriptionManager.failedTranscriptions.contains(where: { $0.id == id }) {
            let didUpdate = failedTranscriptionManager.updateFailedTranscriptionError(
                id: id,
                errorMessage: errorMessage
            )
            if !didUpdate {
                // The pre-existing durable row remains actionable even if its diagnostic
                // could not be refreshed. Treating it as absent would create duplicates.
                AppLogger.pipeline.warning("Speaker naming retry diagnostic update failed", [
                    "retryId": id.uuidString
                ])
            }
            return true
        }

        let values = TranscriptSaver.serializeTranscriptFileUpdate {
            let currentURL = TranscriptSaver.resolveTranscriptURL(transcriptURL, transcriptId: id)
                ?? transcriptURL
            return (try? TranscriptFrontmatter.readValues(from: currentURL)) ?? [:]
        }
        return addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: errorMessage,
            taskId: id,
            meetingTitle: values["title"],
            recordingDate: TranscriptFrontmatter.recordedAt(values: values),
            archiveAudio: false,
            splitLocalSpeakers: splitLocalSpeakers
        )
    }
}
