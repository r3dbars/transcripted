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

/// Saved-person ids that open speaker reviews still point at.
///
/// Every finished transcription runs duplicate cleanup and weak-profile pruning
/// over the whole people database. Those used to protect only the finishing
/// meeting's own review rows, so a review left open (or queued behind another)
/// could have its people merged away or deleted before the user pressed Save,
/// and the save then failed. The pipeline runner reads this off the main actor,
/// so it is lock-protected rather than main-actor state.
final class SpeakerReviewProfileProtection: @unchecked Sendable {
    private struct Entry {
        let transcriptId: UUID
        let profileIds: Set<UUID>
    }

    private let lock = NSLock()
    private var entriesByRequestId: [UUID: Entry] = [:]

    static func profileIds(for request: SpeakerNamingRequest) -> Set<UUID> {
        var ids = Set<UUID>()
        for entry in request.speakers {
            ids.insert(entry.id)
            if let suggestedProfileId = entry.suggestedProfileId {
                ids.insert(suggestedProfileId)
            }
            if let snapshotId = entry.matchedProfileSnapshot?.id {
                ids.insert(snapshotId)
            }
        }
        return ids
    }

    func protect(_ request: SpeakerNamingRequest) {
        let ids = Self.profileIds(for: request)
        lock.lock()
        entriesByRequestId[request.id] = Entry(transcriptId: request.transcriptId, profileIds: ids)
        lock.unlock()
    }

    func release(requestId: UUID) {
        lock.lock()
        entriesByRequestId.removeValue(forKey: requestId)
        lock.unlock()
    }

    func release(transcriptId: UUID) {
        lock.lock()
        entriesByRequestId = entriesByRequestId.filter { $0.value.transcriptId != transcriptId }
        lock.unlock()
    }

    func releaseAll() {
        lock.lock()
        entriesByRequestId.removeAll()
        lock.unlock()
    }

    var protectedProfileIds: Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return entriesByRequestId.values.reduce(into: Set<UUID>()) { $0.formUnion($1.profileIds) }
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

            let finalizationFailure = { (reason: SpeakerFinalizationFailureReason) in
                SpeakerFinalizationFailure(
                    reason: reason,
                    reviewMode: updates.isEmpty ? .reviewLater : .save,
                    isRetry: sourceFailedTranscriptionId != nil
                )
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

                let failure = finalizationFailure(.planMissingEmbedding)
                Task { @MainActor in
                    _ = self.finishNamingFlow(
                        didFinalizeTranscript: false,
                        failure: failure,
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
                            replacementInProgress: replacementInProgress,
                            failureReason: SpeakerFinalizationFailureReason?.none
                        )
                    }
                    guard !TranscriptSaver.isReplacingTranscript(at: transcriptURL),
                          !TranscriptSaver.isReplacingTranscript(transcriptId: transcriptId) else {
                        return (
                            didFinalize: false,
                            resolvedURL: transcriptURL,
                            superseded: false,
                            replacementInProgress: true,
                            failureReason: SpeakerFinalizationFailureReason?.none
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
                            replacementInProgress: false,
                            failureReason: SpeakerFinalizationFailureReason?.some(.transcriptUnresolved)
                        )
                    }
                    guard let originalTranscriptData = try? Data(contentsOf: resolvedURL) else {
                        AppLogger.speakers.error("Speaker naming could not snapshot the transcript before update")
                        return (
                            didFinalize: false,
                            resolvedURL: resolvedURL,
                            superseded: false,
                            replacementInProgress: false,
                            failureReason: SpeakerFinalizationFailureReason?.some(.transcriptUnreadable)
                        )
                    }

                var failureReason: SpeakerFinalizationFailureReason?
                var didFinalize = visibleRegularUpdates.isEmpty || TranscriptSaver.updateSpeakerNames(
                    transcriptURL: resolvedURL,
                    updates: transcriptUpdates,
                    transcriptionResult: transcriptionResult
                )
                if !didFinalize { failureReason = .nameRewriteFailed }

                if didFinalize, let deferredReviewPlan {
                    didFinalize = TranscriptSaver.markSpeakerReviewDeferred(
                        transcriptURL: resolvedURL,
                        entries: clips,
                        redirectedSpeakerIdsByKey: deferredReviewPlan.redirectedSpeakerIdsByKey
                    )
                    if !didFinalize { failureReason = .deferredMarkerFailed }
                }

                if didFinalize && !collapsedUpdates.isEmpty {
                    didFinalize = TranscriptSaver.collapseMicSpeakersToYou(
                        transcriptURL: resolvedURL,
                        collapsedUpdates: collapsedUpdates
                    )
                    if !didFinalize { failureReason = .collapseFailed }
                }

                if didFinalize && !discardedUpdates.isEmpty {
                    didFinalize = TranscriptSaver.discardSpeakerDatabaseLinks(
                        transcriptURL: resolvedURL,
                        discardedUpdates: discardedUpdates
                    )
                    if !didFinalize { failureReason = .discardFailed }
                }

                if didFinalize {
                    do {
                        try speakerDB.performMutationBatch {
                            try Self.applyPlannedNamingMutations(plannedChanges.mutations, speakerDB: speakerDB)
                            try speakerDB.recordUserConfirmations(
                                Self.existingProfileConfirmations(
                                    Self.plannedUserConfirmations(
                                        for: plannedChanges.resolvedUpdates,
                                        transcriptId: transcriptId
                                    ),
                                    speakerDB: speakerDB
                                )
                            )
                            if let deferredReviewPlan {
                                try Self.applyPlannedNamingMutations(deferredReviewPlan.mutations, speakerDB: speakerDB)
                            }
                        }
                    } catch {
                        failureReason = SpeakerFinalizationFailureReason.classify(databaseError: error)
                        AppLogger.speakers.error("Speaker naming persistence failed", [
                            "error": error.localizedDescription,
                            "reason": failureReason?.rawValue ?? "unknown"
                        ])
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
                        replacementInProgress: false,
                        failureReason: didFinalize ? nil : failureReason
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
            let failure = finalization.failureReason.map(finalizationFailure)

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
                    failure: failure,
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
        speakerReviewProfileProtection.releaseAll()
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
        speakerReviewProfileProtection.protect(request)

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
        if let requestId {
            speakerReviewProfileProtection.release(requestId: requestId)
        } else {
            speakerReviewProfileProtection.release(transcriptId: transcriptId)
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
        if let requestIds {
            for requestId in requestIds {
                speakerReviewProfileProtection.release(requestId: requestId)
            }
        } else {
            speakerReviewProfileProtection.release(transcriptId: transcriptId)
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

    /// What a saved person becomes once one review's planned mutations have run.
    private enum PlannedProfileFate: Equatable {
        /// Still exists afterward. Another row may reuse it only under the same name.
        case kept(nameKey: String)
        /// Absorbed into another saved person and deleted.
        case mergedInto(UUID)
    }

    /// Planning state for one review. It is built from one snapshot of the people
    /// database taken at Save, so every row is planned against what actually exists
    /// then, and it records what earlier rows already decided for each person so a
    /// later row can never undo or contradict them.
    private struct NamingPlanState {
        let speakerDB: any SpeakerStore
        /// Saved people when planning started, in `allSpeakers()` order.
        let profiles: [SpeakerProfile]
        let profilesById: [UUID: SpeakerProfile]
        var fates: [UUID: PlannedProfileFate] = [:]
        /// People this plan creates (new ids, or re-created ids that vanished).
        var createdIds: Set<UUID> = []
        var manualNameTargets: [String: (id: UUID, displayName: String)] = [:]
        private var databaseSurvivors: [UUID: UUID?] = [:]

        init(speakerDB: any SpeakerStore) {
            self.speakerDB = speakerDB
            profiles = speakerDB.allSpeakers()
            profilesById = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }

        /// The person is in the database (or created by this plan) before the batch runs.
        func isInDatabase(_ id: UUID) -> Bool {
            profilesById[id] != nil || createdIds.contains(id)
        }

        /// The person will still exist after this plan's merges.
        func willExist(_ id: UUID) -> Bool {
            guard isInDatabase(id) else { return false }
            if case .mergedInto = fates[id] { return false }
            return true
        }

        func displayName(of id: UUID) -> String? {
            guard let name = profilesById[id]?.displayName,
                  !TranscriptionTaskManager.normalizeSpeakerName(name).isEmpty else {
                return nil
            }
            return name
        }

        /// Follows a person who is gone to whoever absorbed them: first through this
        /// plan's own merges, then through the database's merge log (another meeting's
        /// duplicate cleanup, or a merge the user made in Speakers). Nil when the person
        /// was deleted outright.
        mutating func survivingProfile(for id: UUID) -> UUID? {
            var current = id
            var visited: Set<UUID> = []
            while visited.insert(current).inserted {
                if willExist(current) { return current }
                if case .mergedInto(let next)? = fates[current] {
                    current = next
                    continue
                }
                guard !isInDatabase(current), let next = databaseSurvivor(of: current) else {
                    return nil
                }
                current = next
            }
            return nil
        }

        /// Only the database's merge log, never this plan's own merges.
        mutating func databaseSurvivor(of id: UUID) -> UUID? {
            if let cached = databaseSurvivors[id] { return cached }
            let survivor = speakerDB.mergeSurvivorId(of: id)
            databaseSurvivors[id] = survivor
            return survivor
        }

        func exactNamedTarget(named rawName: String, excluding excludedIds: Set<UUID>) -> SpeakerProfile? {
            let targetName = TranscriptionTaskManager.normalizeSpeakerName(rawName)
            guard !targetName.isEmpty else { return nil }

            return profiles
                .filter { profile in
                    !excludedIds.contains(profile.id)
                        && willExist(profile.id)
                        && TranscriptionTaskManager.normalizeSpeakerName(profile.displayName) == targetName
                }
                .sorted { $0.callCount > $1.callCount }
                .first
        }

        mutating func claimKept(_ id: UUID, nameKey: String) {
            if fates[id] == nil {
                fates[id] = .kept(nameKey: nameKey)
            }
        }

        mutating func registerManualName(_ nameKey: String, id: UUID, displayName: String) {
            guard !nameKey.isEmpty, manualNameTargets[nameKey] == nil else { return }
            manualNameTargets[nameKey] = (id, displayName)
        }

        /// Moves a row's own profile into `target`. Only the first row that decides a
        /// profile's fate merges it. When the profile is already gone, or an earlier row
        /// kept it under a name or sent it to a different person (mic and system rows,
        /// or two diarizer rows, can share one profile), the earlier decision stands and
        /// only this row's voice is taught to `target`. Merging it anyway used to delete
        /// a profile an earlier row still needed and fail the whole save.
        mutating func absorb(
            _ sourceId: UUID,
            into targetId: UUID,
            embedding: [Float]?
        ) -> [PlannedSpeakerMutation] {
            guard sourceId != targetId else { return [] }
            switch fates[sourceId] {
            case .mergedInto(let existingTarget)? where existingTarget == targetId:
                return []
            case nil where isInDatabase(sourceId):
                fates[sourceId] = .mergedInto(targetId)
                return [.merge(sourceId: sourceId, into: targetId)]
            default:
                guard let embedding else { return [] }
                return [.addOrUpdateEmbedding(embedding: embedding, existingId: targetId)]
            }
        }

        /// Gives `profileId` the name when this review has not already committed it to
        /// something else. Otherwise the voice becomes a new saved person with that name.
        /// Returns nil only when a new person is needed but there is no voice to build it from.
        mutating func claimNamedIdentity(
            _ profileId: UUID,
            name: String,
            embedding: [Float]?
        ) -> (profileId: UUID, mutations: [PlannedSpeakerMutation])? {
            let nameKey = TranscriptionTaskManager.normalizeSpeakerName(name)
            if willExist(profileId) {
                let isFreeForThisName: Bool
                switch fates[profileId] {
                case nil:
                    isFreeForThisName = true
                case .kept(let claimedNameKey)?:
                    isFreeForThisName = claimedNameKey == nameKey
                case .mergedInto?:
                    isFreeForThisName = false
                }
                if isFreeForThisName {
                    fates[profileId] = .kept(nameKey: nameKey)
                    return (profileId, [
                        .setDisplayName(id: profileId, name: name),
                        .resetDisputeCount(profileId),
                    ])
                }
            } else if !isInDatabase(profileId) {
                // Deleted outside this review (for example pruned while the review sat
                // open). Re-create it under the same id so the transcript link stays valid.
                guard let embedding else {
                    AppLogger.speakers.warning("Speaker profile is gone and has no voice sample; saving the name in the transcript only", [
                        "speakerId": profileId.uuidString
                    ])
                    return (profileId, [])
                }
                createdIds.insert(profileId)
                fates[profileId] = .kept(nameKey: nameKey)
                return (profileId, [
                    .addOrUpdateEmbedding(embedding: embedding, existingId: profileId),
                    .setDisplayName(id: profileId, name: name),
                    .resetDisputeCount(profileId),
                ])
            }

            guard let embedding else {
                AppLogger.speakers.error("Speaker row conflicts with another row for the same profile and has no voice sample", [
                    "speakerId": profileId.uuidString
                ])
                return nil
            }
            let newProfileId = UUID()
            createdIds.insert(newProfileId)
            fates[newProfileId] = .kept(nameKey: nameKey)
            return (newProfileId, [
                .addOrUpdateEmbedding(embedding: embedding, existingId: newProfileId),
                .setDisplayName(id: newProfileId, name: name),
                .resetDisputeCount(newProfileId),
            ])
        }
    }

    private struct PlannedNamingRow {
        let update: SpeakerNameUpdate
        let mutations: [PlannedSpeakerMutation]
    }

    nonisolated private static func planNamingUpdates(
        _ updates: [SpeakerNameUpdate],
        clipsBySpeakerId: [String: SpeakerNamingEntry],
        speakerDB: any SpeakerStore
    ) -> PlannedNamingChanges? {
        guard !updates.isEmpty else {
            return PlannedNamingChanges(resolvedUpdates: [], mutations: [])
        }

        var state = NamingPlanState(speakerDB: speakerDB)
        var resolvedUpdates: [SpeakerNameUpdate] = []
        resolvedUpdates.reserveCapacity(updates.count)
        var mutations: [PlannedSpeakerMutation] = []

        for update in updates {
            let entry = clipsBySpeakerId[update.channel.speakerKey(diarizerSpeakerId: update.diarizerSpeakerId)]
            guard let row = planNamingRow(update, entry: entry, state: &state) else {
                return nil
            }

            AppLogger.speakers.info("Speaker named", [
                "originalId": update.persistentSpeakerId.uuidString,
                "resolvedId": (row.update.resolvedPersistentSpeakerId ?? update.persistentSpeakerId).uuidString,
                "name": row.update.newName,
                "action": "\(row.update.action)"
            ])
            resolvedUpdates.append(row.update)
            mutations.append(contentsOf: row.mutations)
        }

        return PlannedNamingChanges(
            resolvedUpdates: resolvedUpdates,
            mutations: mutations
        )
    }

    nonisolated private static func planNamingRow(
        _ update: SpeakerNameUpdate,
        entry: SpeakerNamingEntry?,
        state: inout NamingPlanState
    ) -> PlannedNamingRow? {
        switch update.action {
        case .merged(let requestedTargetId):
            if isMatchedPersonRelabel(update, entry: entry, targetProfileId: requestedTargetId) {
                // The row was recognized as one saved person and the user picked a
                // different saved person. Merging would fold the recognized person's
                // whole history into the pick and delete them. Treat it as the
                // correction it is: undo the match and teach the voice to the pick.
                return planCorrection(update, entry: entry, explicitTargetId: requestedTargetId, state: &state)
            }
            guard let targetId = state.survivingProfile(for: requestedTargetId) else {
                AppLogger.speakers.warning("Picked speaker profile no longer exists; saving the row as a typed name", [
                    "targetId": requestedTargetId.uuidString
                ])
                return planNamed(update, entry: entry, state: &state)
            }
            let resolvedName = targetId == requestedTargetId
                ? update.newName
                : (state.displayName(of: targetId) ?? update.newName)
            var mutations = state.absorb(
                update.persistentSpeakerId,
                into: targetId,
                embedding: entry?.sessionEmbedding
            )
            mutations.append(.resetDisputeCount(targetId))
            state.claimKept(targetId, nameKey: normalizeSpeakerName(resolvedName))
            return PlannedNamingRow(
                update: resolvedUpdate(update, name: resolvedName, action: .merged(targetProfileId: targetId), profileId: targetId),
                mutations: mutations
            )

        case .confirmed:
            return planConfirmed(update, entry: entry, state: &state)

        case .named:
            return planNamed(update, entry: entry, state: &state)

        case .corrected:
            return planCorrection(update, entry: entry, explicitTargetId: nil, state: &state)

        case .collapsedToMe, .discardedFromDatabase:
            // Handled upstream in handleNamingComplete: collapse rewrites transcript text and
            // deletes only newly-created mic profiles; discard removes transcript DB links and
            // either deletes a new profile or restores an existing matched profile snapshot.
            return PlannedNamingRow(
                update: resolvedUpdate(update, name: update.newName, action: update.action, profileId: update.persistentSpeakerId),
                mutations: []
            )
        }
    }

    /// A recognized, named person relabeled to a different saved person by name.
    /// Picking the same person (or a same-named duplicate) is still a merge.
    nonisolated private static func isMatchedPersonRelabel(
        _ update: SpeakerNameUpdate,
        entry: SpeakerNamingEntry?,
        targetProfileId: UUID
    ) -> Bool {
        guard let snapshot = entry?.matchedProfileSnapshot,
              snapshot.id == update.persistentSpeakerId,
              targetProfileId != snapshot.id else {
            return false
        }
        let recognizedName = normalizeSpeakerName(snapshot.displayName)
        return !recognizedName.isEmpty && recognizedName != normalizeSpeakerName(update.newName)
    }

    nonisolated private static func planConfirmed(
        _ update: SpeakerNameUpdate,
        entry: SpeakerNamingEntry?,
        state: inout NamingPlanState
    ) -> PlannedNamingRow? {
        let profileId = update.persistentSpeakerId
        if !state.isInDatabase(profileId), let survivorId = state.databaseSurvivor(of: profileId),
           state.willExist(survivorId) {
            // Another meeting's cleanup (or a merge in Speakers) absorbed the confirmed
            // person. Confirm the person that holds them now, keeping that person's name.
            var mutations: [PlannedSpeakerMutation] = []
            let survivorName = state.displayName(of: survivorId)
            if survivorName == nil {
                mutations.append(.setDisplayName(id: survivorId, name: update.newName))
            }
            mutations.append(.resetDisputeCount(survivorId))
            let resolvedName = survivorName ?? update.newName
            state.claimKept(survivorId, nameKey: normalizeSpeakerName(resolvedName))
            return PlannedNamingRow(
                update: resolvedUpdate(update, name: resolvedName, action: .confirmed, profileId: survivorId),
                mutations: mutations
            )
        }

        guard let identity = state.claimNamedIdentity(
            profileId,
            name: update.newName,
            embedding: entry?.sessionEmbedding ?? entry?.matchedProfileSnapshot?.embedding
        ) else {
            return nil
        }
        return PlannedNamingRow(
            update: resolvedUpdate(update, name: update.newName, action: .confirmed, profileId: identity.profileId),
            mutations: identity.mutations
        )
    }

    nonisolated private static func planNamed(
        _ update: SpeakerNameUpdate,
        entry: SpeakerNamingEntry?,
        state: inout NamingPlanState
    ) -> PlannedNamingRow? {
        let sourceId = update.persistentSpeakerId
        let embedding = entry?.sessionEmbedding
        let nameKey = normalizeSpeakerName(update.newName)

        // Rows typed with the same name are one person: every row lands on the
        // profile the first of them resolved to.
        if let existing = state.manualNameTargets[nameKey] {
            var mutations = state.absorb(sourceId, into: existing.id, embedding: embedding)
            mutations.append(.resetDisputeCount(existing.id))
            return PlannedNamingRow(
                update: resolvedUpdate(update, name: existing.displayName, action: .named, profileId: existing.id),
                mutations: mutations
            )
        }

        if let target = state.exactNamedTarget(named: update.newName, excluding: [sourceId]) {
            var mutations = state.absorb(sourceId, into: target.id, embedding: embedding)
            mutations.append(.resetDisputeCount(target.id))
            state.claimKept(target.id, nameKey: nameKey)
            state.registerManualName(nameKey, id: target.id, displayName: update.newName)
            return PlannedNamingRow(
                update: resolvedUpdate(update, name: update.newName, action: .named, profileId: target.id),
                mutations: mutations
            )
        }

        guard let identity = state.claimNamedIdentity(sourceId, name: update.newName, embedding: embedding) else {
            return nil
        }
        state.registerManualName(nameKey, id: identity.profileId, displayName: update.newName)
        return PlannedNamingRow(
            update: resolvedUpdate(update, name: update.newName, action: .named, profileId: identity.profileId),
            mutations: identity.mutations
        )
    }

    nonisolated private static func planCorrection(
        _ update: SpeakerNameUpdate,
        entry: SpeakerNamingEntry?,
        explicitTargetId: UUID?,
        state: inout NamingPlanState
    ) -> PlannedNamingRow? {
        let embedding = entry?.sessionEmbedding
        let rejectedProfile = entry?.matchedProfileSnapshot
        var mutations: [PlannedSpeakerMutation] = []
        if let rejectedProfile {
            if state.willExist(rejectedProfile.id) {
                mutations.append(.restoreProfile(rejectedProfile))
                mutations.append(.incrementDisputeCount(rejectedProfile.id))
                // The rejected embedding becomes a negative exemplar against the wrongly-suggested
                // profile: "this voice is explicitly not this person", used to veto future matches.
                // Every target below excludes the rejected profile, so the same id is never
                // written a positive embedding and a negative exemplar for one correction.
                if let embedding {
                    mutations.append(.recordNegativeExemplar(profileId: rejectedProfile.id, embedding: embedding))
                }
            } else {
                AppLogger.speakers.warning("Correction skipped restoring a matched profile that no longer exists", [
                    "profileId": rejectedProfile.id.uuidString
                ])
            }
        }

        let excludedIds = Set([update.persistentSpeakerId, rejectedProfile?.id].compactMap { $0 })
        let nameKey = normalizeSpeakerName(update.newName)
        let resolvedName: String
        let targetId: UUID

        if let explicitTargetId,
           let survivorId = state.survivingProfile(for: explicitTargetId),
           !excludedIds.contains(survivorId) {
            // A saved person the user picked: teach them the voice, keep their name.
            targetId = survivorId
            resolvedName = explicitTargetId == survivorId
                ? update.newName
                : (state.displayName(of: survivorId) ?? update.newName)
            if let embedding {
                mutations.append(.addOrUpdateEmbedding(embedding: embedding, existingId: targetId))
            }
            mutations.append(.resetDisputeCount(targetId))
        } else if let existing = state.manualNameTargets[nameKey], !excludedIds.contains(existing.id) {
            targetId = existing.id
            resolvedName = existing.displayName
            if let embedding {
                mutations.append(.addOrUpdateEmbedding(embedding: embedding, existingId: targetId))
            }
            mutations.append(.setDisplayName(id: targetId, name: resolvedName))
            mutations.append(.resetDisputeCount(targetId))
        } else if let target = state.exactNamedTarget(named: update.newName, excluding: excludedIds) {
            targetId = target.id
            resolvedName = update.newName
            if let embedding {
                mutations.append(.addOrUpdateEmbedding(embedding: embedding, existingId: targetId))
            }
            mutations.append(.setDisplayName(id: targetId, name: resolvedName))
            mutations.append(.resetDisputeCount(targetId))
        } else if let embedding {
            targetId = UUID()
            resolvedName = update.newName
            state.createdIds.insert(targetId)
            mutations.append(.addOrUpdateEmbedding(embedding: embedding, existingId: targetId))
            mutations.append(.setDisplayName(id: targetId, name: resolvedName))
            mutations.append(.resetDisputeCount(targetId))
        } else {
            AppLogger.speakers.error("Correction missing session embedding; refusing unsafe profile rewrite", [
                "speakerId": update.persistentSpeakerId.uuidString,
                "name": update.newName
            ])
            return nil
        }

        state.claimKept(targetId, nameKey: normalizeSpeakerName(resolvedName))
        if explicitTargetId == nil {
            // Typed corrections coalesce with other typed rows of the same name.
            state.registerManualName(nameKey, id: targetId, displayName: resolvedName)
        }
        return PlannedNamingRow(
            update: resolvedUpdate(update, name: resolvedName, action: .corrected, profileId: targetId),
            mutations: mutations
        )
    }

    nonisolated private static func resolvedUpdate(
        _ update: SpeakerNameUpdate,
        name: String,
        action: SpeakerNameUpdate.NamingAction,
        profileId: UUID
    ) -> SpeakerNameUpdate {
        SpeakerNameUpdate(
            persistentSpeakerId: update.persistentSpeakerId,
            diarizerSpeakerId: update.diarizerSpeakerId,
            channel: update.channel,
            newName: name,
            previousName: update.previousName,
            action: action,
            resolvedPersistentSpeakerId: profileId
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

    /// Drops confirmations for people that do not exist after the planned mutations
    /// (for example a name saved only in the transcript because its profile vanished
    /// with no voice sample to rebuild it). A confirmation is a maturity signal; losing
    /// one is harmless, while a missing row used to fail the entire save.
    nonisolated private static func existingProfileConfirmations(
        _ confirmations: [SpeakerUserConfirmation],
        speakerDB: any SpeakerStore
    ) -> [SpeakerUserConfirmation] {
        confirmations.filter { confirmation in
            guard speakerDB.getSpeaker(id: confirmation.profileId) != nil else {
                AppLogger.speakers.warning("Skipped speaker confirmation for a profile that no longer exists", [
                    "profileId": confirmation.profileId.uuidString
                ])
                return false
            }
            return true
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

    nonisolated private static func applyPlannedNamingMutations(
        _ mutations: [PlannedSpeakerMutation],
        speakerDB: any SpeakerStore
    ) throws {
        for mutation in mutations {
            switch mutation {
            case .merge(let sourceId, let targetId):
                // The plan only merges profiles that existed at Save. If another meeting's
                // cleanup removed this one since, its voice already went elsewhere; failing
                // the whole save over it would lose every name the user typed.
                guard speakerDB.getSpeaker(id: sourceId) != nil else {
                    AppLogger.speakers.warning("Skipped merging a speaker profile that no longer exists", [
                        "sourceId": sourceId.uuidString,
                        "targetId": targetId.uuidString
                    ])
                    continue
                }
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
        failure: SpeakerFinalizationFailure? = nil,
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
                    publishSpeakerFinalizationFailure(
                        displayMessage: "Final transcript could not be found. Retry audio was kept.",
                        failure: nil
                    )
                } else {
                    AppLogger.pipeline.error("Speaker naming retry queue persistence failed", [
                        "transcriptId": transcriptId.uuidString,
                        "retryId": retryId.uuidString
                    ])
                    publishSpeakerFinalizationFailure(
                        displayMessage: "Final transcript could not be found. Retry could not be saved; audio was left in place.",
                        failure: nil
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
                "transcript": resolvedURL.lastPathComponent,
                "reason": failure?.reason.rawValue ?? "unknown"
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
            publishSpeakerFinalizationFailure(
                displayMessage: didPersistRetry
                    ? "Failed to finalize speaker names"
                    : "Speaker names could not be saved. Retry could not be saved; audio was left in place.",
                failure: failure
            )
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
