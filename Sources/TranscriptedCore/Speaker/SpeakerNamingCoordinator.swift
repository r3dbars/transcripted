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

    /// Adds the people a Save is about to write to (picked, same-name and coalesced
    /// targets) to a review that is still registered, so another meeting's cleanup
    /// cannot merge or prune them before the save lands. Never registers a review that
    /// was already released.
    func extend(requestId: UUID?, transcriptId: UUID, with ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for (key, entry) in entriesByRequestId
        where requestId.map({ $0 == key }) ?? (entry.transcriptId == transcriptId) {
            entriesByRequestId[key] = Entry(
                transcriptId: entry.transcriptId,
                profileIds: entry.profileIds.union(ids)
            )
        }
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
        /// Rows whose name is saved in the transcript only, with no saved person behind
        /// it. They get no review clip and no match outcome.
        var transcriptOnlySpeakerKeys: Set<String> = []
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

    /// Internal (not private) so tests can run the apply step against a database that
    /// changed after planning.
    enum PlannedSpeakerMutation {
        case merge(sourceId: UUID, into: UUID)
        case setDisplayName(id: UUID, name: String)
        case restoreProfile(SpeakerProfile)
        case addOrUpdateEmbedding(embedding: [Float], existingId: UUID?)
        /// Adds a voice sample to a saved person who existed at Save. Unlike
        /// `addOrUpdateEmbedding`, it never creates the person: if they were removed
        /// before the batch ran, the voice follows whoever absorbed them, or is dropped.
        case teachVoice(embedding: [Float], profileId: UUID)
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
        let noDialogSpeakerKeys = Set(noDialogUpdates.map {
            $0.channel.speakerKey(diarizerSpeakerId: $0.diarizerSpeakerId)
        })
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
                noDialogSpeakerKeys: noDialogSpeakerKeys,
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

            self.speakerReviewProfileProtection.extend(
                requestId: requestId,
                transcriptId: transcriptId,
                with: Set(plannedChanges.resolvedUpdates.compactMap(\.resolvedPersistentSpeakerId))
            )

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
                                Self.liveProfileConfirmations(
                                    Self.plannedUserConfirmations(
                                        for: plannedChanges.resolvedUpdates.filter {
                                            !plannedChanges.transcriptOnlySpeakerKeys.contains(
                                                $0.channel.speakerKey(diarizerSpeakerId: $0.diarizerSpeakerId)
                                            )
                                        },
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
                    for: plannedChanges.resolvedUpdates.filter { update in
                        let key = update.channel.speakerKey(diarizerSpeakerId: update.diarizerSpeakerId)
                        guard plannedChanges.transcriptOnlySpeakerKeys.contains(key) else { return true }
                        // A correction's verdict belongs to the wrongly suggested person,
                        // who still exists even when no new person was created for the row.
                        if case .corrected = update.action {
                            return clipsBySpeakerId[key]?.matchedProfileSnapshot != nil
                        }
                        return false
                    },
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
                    excludingSpeakerKeys: plannedChanges.transcriptOnlySpeakerKeys,
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
        /// The name each kept person ends up with, when this plan decided it.
        var plannedNames: [UUID: String] = [:]
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

        /// The person's name after the rows planned so far: the name an earlier row
        /// gave them, else their saved name. Nil when they have neither.
        func displayName(of id: UUID) -> String? {
            for name in [plannedNames[id], profilesById[id]?.displayName] {
                if let name, !TranscriptionTaskManager.normalizeSpeakerName(name).isEmpty {
                    return name
                }
            }
            return nil
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
                        && TranscriptionTaskManager.normalizeSpeakerName(displayName(of: profile.id) ?? "") == targetName
                }
                .sorted { $0.callCount > $1.callCount }
                .first
        }

        /// Records that `id` stays, under `name`, unless an earlier row already decided it.
        /// `writesName` is true only when the row also emits `setDisplayName`, so a
        /// later row never sees a planned name that nothing writes.
        mutating func claimKept(_ id: UUID, name: String, writesName: Bool = false) {
            if writesName {
                plannedNames[id] = name
            }
            guard fates[id] == nil else { return }
            fates[id] = .kept(nameKey: TranscriptionTaskManager.normalizeSpeakerName(name))
        }

        private mutating func keep(_ id: UUID, name: String) {
            fates[id] = .kept(nameKey: TranscriptionTaskManager.normalizeSpeakerName(name))
            plannedNames[id] = name
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
                return [.teachVoice(embedding: embedding, profileId: targetId)]
            }
        }

        /// Gives `profileId` the name when this review has not already committed it to
        /// something else. Otherwise the voice becomes a new saved person with that name.
        /// With no voice to build a person from, the name is saved in the transcript only
        /// and the returned id is not in the database (`willExist` is false for it).
        /// `allowNewProfile` is false for rows with no dialog: a speaker who never spoke
        /// in the transcript does not become a new saved person.
        mutating func claimNamedIdentity(
            _ profileId: UUID,
            name: String,
            embedding: [Float]?,
            allowNewProfile: Bool = true
        ) -> (profileId: UUID, mutations: [PlannedSpeakerMutation]) {
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
                    keep(profileId, name: name)
                    return (profileId, [
                        .setDisplayName(id: profileId, name: name),
                        .resetDisputeCount(profileId),
                    ])
                }
            } else if !isInDatabase(profileId) {
                // Deleted outside this review (for example pruned while the review sat
                // open). Re-create it under the same id so the transcript link stays valid.
                guard allowNewProfile, let embedding else {
                    AppLogger.speakers.warning("Speaker profile is gone and has no voice sample; saving the name in the transcript only", [
                        "speakerId": profileId.uuidString
                    ])
                    return (profileId, [])
                }
                createdIds.insert(profileId)
                keep(profileId, name: name)
                return (profileId, [
                    .addOrUpdateEmbedding(embedding: embedding, existingId: profileId),
                    .setDisplayName(id: profileId, name: name),
                    .resetDisputeCount(profileId),
                ])
            }

            guard allowNewProfile, let embedding else {
                // Another row already decided who this profile is. Linking this name to it
                // would put the wrong person in the transcript, and failing would lose every
                // name in the review, so the name goes in the transcript only.
                AppLogger.speakers.warning("Speaker row conflicts with another row for the same profile and has no voice sample; saving the name in the transcript only", [
                    "speakerId": profileId.uuidString
                ])
                return (UUID(), [])
            }
            let newProfileId = UUID()
            createdIds.insert(newProfileId)
            keep(newProfileId, name: name)
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
        noDialogSpeakerKeys: Set<String> = [],
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
            let speakerKey = update.channel.speakerKey(diarizerSpeakerId: update.diarizerSpeakerId)
            guard let row = planNamingRow(
                update,
                entry: clipsBySpeakerId[speakerKey],
                hasDialog: !noDialogSpeakerKeys.contains(speakerKey),
                state: &state
            ) else {
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

        // A name saved in the transcript only joins the saved person another row of
        // this review created or picked under the same typed name, so one name never
        // ends up with two links in one transcript.
        var transcriptOnlySpeakerKeys = Set<String>()
        for index in resolvedUpdates.indices {
            let update = resolvedUpdates[index]
            guard let resolvedId = update.resolvedPersistentSpeakerId,
                  !state.willExist(resolvedId) else {
                continue
            }
            let speakerKey = update.channel.speakerKey(diarizerSpeakerId: update.diarizerSpeakerId)
            // Rows with no dialog have nothing in the transcript to link, and repointing
            // them would record their verdicts and clips against someone else.
            if !noDialogSpeakerKeys.contains(speakerKey),
               let target = state.manualNameTargets[normalizeSpeakerName(update.newName)],
               state.willExist(target.id) {
                resolvedUpdates[index] = resolvedUpdate(
                    update,
                    name: target.displayName,
                    action: update.action,
                    profileId: target.id
                )
            } else {
                transcriptOnlySpeakerKeys.insert(speakerKey)
            }
        }

        return PlannedNamingChanges(
            resolvedUpdates: resolvedUpdates,
            mutations: mutations,
            transcriptOnlySpeakerKeys: transcriptOnlySpeakerKeys
        )
    }

    nonisolated private static func planNamingRow(
        _ update: SpeakerNameUpdate,
        entry: SpeakerNamingEntry?,
        hasDialog: Bool,
        state: inout NamingPlanState
    ) -> PlannedNamingRow? {
        switch update.action {
        case .merged(let requestedTargetId):
            if isMatchedPersonRelabel(update, entry: entry, targetProfileId: requestedTargetId) {
                // The row was recognized as one saved person and the user picked a
                // different saved person. Merging would fold the recognized person's
                // whole history into the pick and delete them. Treat it as the
                // correction it is: undo the match and teach the voice to the pick.
                return planCorrection(
                    update,
                    entry: entry,
                    explicitTargetId: requestedTargetId,
                    hasDialog: hasDialog,
                    state: &state
                )
            }
            guard let targetId = state.survivingProfile(for: requestedTargetId) else {
                guard hasDialog else {
                    // Nothing in the transcript to name, and naming the row's own profile
                    // would give a speaker who never spoke the picked person's name.
                    AppLogger.speakers.warning("Picked speaker profile no longer exists and the row has no dialog; skipping it", [
                        "targetId": requestedTargetId.uuidString
                    ])
                    return PlannedNamingRow(
                        update: resolvedUpdate(update, name: update.newName, action: update.action, profileId: requestedTargetId),
                        mutations: []
                    )
                }
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
            // A merge does not rename the target, so it stays under the name it has.
            state.claimKept(targetId, name: state.displayName(of: targetId) ?? resolvedName)
            return PlannedNamingRow(
                update: resolvedUpdate(update, name: resolvedName, action: .merged(targetProfileId: targetId), profileId: targetId),
                mutations: mutations
            )

        case .confirmed:
            return planConfirmed(update, entry: entry, hasDialog: hasDialog, state: &state)

        case .named:
            return planNamed(update, entry: entry, state: &state)

        case .corrected:
            return planCorrection(update, entry: entry, explicitTargetId: nil, hasDialog: hasDialog, state: &state)

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
        hasDialog: Bool,
        state: inout NamingPlanState
    ) -> PlannedNamingRow? {
        let profileId = update.persistentSpeakerId
        if !state.willExist(profileId), let survivorId = state.survivingProfile(for: profileId) {
            let survivorName = state.displayName(of: survivorId)
            // Another meeting's cleanup (or a merge in Speakers) absorbed the confirmed
            // person before Save: confirm whoever holds them now, keeping that name.
            // An earlier row of this review merging the shared profile away only
            // carries this row along when it went to someone with the same name (or no
            // name); otherwise this voice is someone else and gets its own person below.
            let absorbedBeforeSave = !state.isInDatabase(profileId)
            let survivorHasSameName = survivorName.map {
                normalizeSpeakerName($0) == normalizeSpeakerName(update.newName)
            } ?? true
            if absorbedBeforeSave || survivorHasSameName {
                var mutations: [PlannedSpeakerMutation] = []
                if survivorName == nil {
                    mutations.append(.setDisplayName(id: survivorId, name: update.newName))
                }
                mutations.append(.resetDisputeCount(survivorId))
                let resolvedName = survivorName ?? update.newName
                state.claimKept(survivorId, name: resolvedName, writesName: survivorName == nil)
                return PlannedNamingRow(
                    update: resolvedUpdate(update, name: resolvedName, action: .confirmed, profileId: survivorId),
                    mutations: mutations
                )
            }
        }

        let identity = state.claimNamedIdentity(
            profileId,
            name: update.newName,
            embedding: entry?.sessionEmbedding ?? entry?.matchedProfileSnapshot?.embedding,
            allowNewProfile: hasDialog
        )
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
            state.claimKept(target.id, name: state.displayName(of: target.id) ?? update.newName)
            state.registerManualName(nameKey, id: target.id, displayName: update.newName)
            return PlannedNamingRow(
                update: resolvedUpdate(update, name: update.newName, action: .named, profileId: target.id),
                mutations: mutations
            )
        }

        let identity = state.claimNamedIdentity(sourceId, name: update.newName, embedding: embedding)
        if state.willExist(identity.profileId) {
            // A transcript-only name has no saved person for later rows to join.
            state.registerManualName(nameKey, id: identity.profileId, displayName: update.newName)
        }
        return PlannedNamingRow(
            update: resolvedUpdate(update, name: update.newName, action: .named, profileId: identity.profileId),
            mutations: identity.mutations
        )
    }

    nonisolated private static func planCorrection(
        _ update: SpeakerNameUpdate,
        entry: SpeakerNamingEntry?,
        explicitTargetId: UUID?,
        hasDialog: Bool,
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
                // Keep the rejected person as they are for the rest of this review, so a
                // later row sharing the profile cannot merge them away (and drop the
                // exemplar just written) or rename them.
                if let rejectedName = state.displayName(of: rejectedProfile.id) {
                    state.claimKept(rejectedProfile.id, name: rejectedName)
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
        var writesName = true

        if let explicitTargetId,
           let survivorId = state.survivingProfile(for: explicitTargetId),
           !excludedIds.contains(survivorId) {
            // A saved person the user picked: teach them the voice, keep their name.
            targetId = survivorId
            resolvedName = explicitTargetId == survivorId
                ? update.newName
                : (state.displayName(of: survivorId) ?? update.newName)
            writesName = false
            if let embedding {
                mutations.append(.teachVoice(embedding: embedding, profileId: targetId))
            }
            mutations.append(.resetDisputeCount(targetId))
        } else if let existing = state.manualNameTargets[nameKey], !excludedIds.contains(existing.id) {
            targetId = existing.id
            resolvedName = existing.displayName
            if let embedding {
                mutations.append(.teachVoice(embedding: embedding, profileId: targetId))
            }
            mutations.append(.setDisplayName(id: targetId, name: resolvedName))
            mutations.append(.resetDisputeCount(targetId))
        } else if let target = state.exactNamedTarget(named: update.newName, excluding: excludedIds) {
            targetId = target.id
            resolvedName = update.newName
            if let embedding {
                mutations.append(.teachVoice(embedding: embedding, profileId: targetId))
            }
            mutations.append(.setDisplayName(id: targetId, name: resolvedName))
            mutations.append(.resetDisputeCount(targetId))
        } else if !hasDialog {
            // No saved person to teach and this speaker never spoke in the transcript:
            // keep the rejection, but do not turn a silent voice into a new saved person.
            AppLogger.speakers.warning("Correction row has no dialog and no existing person to teach; not creating a person", [
                "speakerId": update.persistentSpeakerId.uuidString
            ])
            return PlannedNamingRow(
                update: resolvedUpdate(update, name: update.newName, action: .corrected, profileId: explicitTargetId ?? UUID()),
                mutations: mutations
            )
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

        // A picked person is not renamed, so they stay under the name they have.
        let keptName = writesName
            ? resolvedName
            : (state.displayName(of: targetId) ?? resolvedName)
        state.claimKept(targetId, name: keptName, writesName: writesName)
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

    /// Points each confirmation at the person who holds that profile after the planned
    /// mutations (following a merge another meeting made after Save), and drops the
    /// ones whose person no longer exists (for example a name saved only in the
    /// transcript). A confirmation is a maturity signal; losing one is harmless, while
    /// a missing row used to fail the entire save.
    nonisolated private static func liveProfileConfirmations(
        _ confirmations: [SpeakerUserConfirmation],
        speakerDB: any SpeakerStore
    ) -> [SpeakerUserConfirmation] {
        confirmations.compactMap { confirmation in
            guard let liveId = liveProfileId(for: confirmation.profileId, speakerDB: speakerDB) else {
                AppLogger.speakers.warning("Skipped speaker confirmation for a profile that no longer exists", [
                    "profileId": confirmation.profileId.uuidString
                ])
                return nil
            }
            guard liveId != confirmation.profileId else { return confirmation }
            return SpeakerUserConfirmation(
                profileId: liveId,
                transcriptId: confirmation.transcriptId,
                kind: confirmation.kind,
                confirmedAt: confirmation.confirmedAt
            )
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

    nonisolated static func applyPlannedNamingMutations(
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
                // The same goes for the person it merges into: follow them to whoever
                // absorbed them, and leave the source alone if they were deleted.
                guard let liveTargetId = liveProfileId(for: targetId, speakerDB: speakerDB),
                      liveTargetId != sourceId else {
                    AppLogger.speakers.warning("Skipped merging into a speaker profile that no longer exists", [
                        "sourceId": sourceId.uuidString,
                        "targetId": targetId.uuidString
                    ])
                    continue
                }
                do {
                    try speakerDB.mergeProfiles(sourceId: sourceId, into: liveTargetId)
                } catch {
                    throw SpeakerFinalizationFailureReason.mergeError(
                        from: error,
                        sourceId: sourceId,
                        targetId: liveTargetId
                    )
                }
            case .setDisplayName(let id, let name):
                speakerDB.setDisplayName(id: id, name: name, source: NameSource.userManual)
            case .restoreProfile(let profile):
                speakerDB.restoreProfile(profile)
            case .addOrUpdateEmbedding(let embedding, let existingId):
                _ = speakerDB.addOrUpdateSpeaker(embedding: embedding, existingId: existingId)
            case .teachVoice(let embedding, let profileId):
                // Never re-create a person the user or another meeting removed after Save.
                guard let liveId = liveProfileId(for: profileId, speakerDB: speakerDB) else {
                    AppLogger.speakers.warning("Skipped teaching a voice to a speaker profile that no longer exists", [
                        "profileId": profileId.uuidString
                    ])
                    continue
                }
                _ = speakerDB.addOrUpdateSpeaker(embedding: embedding, existingId: liveId)
            // Verdicts about a person follow them if another meeting merged them after
            // Save. A display name does not: renaming whoever absorbed them would
            // override that merge's choice of name.
            case .incrementDisputeCount(let id):
                if let liveId = liveProfileId(for: id, speakerDB: speakerDB) {
                    speakerDB.incrementDisputeCount(id: liveId)
                }
            case .resetDisputeCount(let id):
                if let liveId = liveProfileId(for: id, speakerDB: speakerDB) {
                    speakerDB.resetDisputeCount(id: liveId)
                }
            case .recordNegativeExemplar(let profileId, let embedding):
                if let liveId = liveProfileId(for: profileId, speakerDB: speakerDB) {
                    speakerDB.recordNegativeExemplar(profileId: liveId, embedding: embedding)
                }
            }
        }
    }

    /// The id that holds this person right now: the id itself when it still exists,
    /// else whoever the merge log says absorbed it. Nil when the person was deleted.
    nonisolated private static func liveProfileId(for id: UUID, speakerDB: any SpeakerStore) -> UUID? {
        if speakerDB.getSpeaker(id: id) != nil { return id }
        return speakerDB.mergeSurvivorId(of: id)
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
        excludingSpeakerKeys excludedSpeakerKeys: Set<String> = [],
        clipsDirectory: URL
    ) {
        for clip in clips where !excludedSpeakerIds.contains(clip.id) {
            let key = clip.channel.speakerKey(diarizerSpeakerId: clip.diarizerSpeakerId)
            guard !excludedSpeakerKeys.contains(key) else { continue }
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
                publishSpeakerNamesSaved()
                scheduleStatusReset(delay: 8)
            } else {
                clearSpeakerFinalizationFailure()
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
            splitLocalSpeakers: splitLocalSpeakers,
            micOnlyByChoice: values["mic_only"] == "true"
        )
    }
}
