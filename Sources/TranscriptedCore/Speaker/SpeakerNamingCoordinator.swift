import Foundation

// MARK: - Speaker Naming Flow Coordination

extension TranscriptionTaskManager {

    /// Internal (not private) only so the naming flow can span files.
    struct PlannedNamingChanges {
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
                        try TranscriptFileRewrite.write(originalTranscriptData, to: resolvedURL)
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
}
