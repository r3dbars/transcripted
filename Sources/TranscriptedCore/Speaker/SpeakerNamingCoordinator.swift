import Foundation

// MARK: - Speaker Naming Flow Coordination

extension TranscriptionTaskManager {

    private struct PlannedNamingChanges {
        let resolvedUpdates: [SpeakerNameUpdate]
        let mutations: [PlannedSpeakerMutation]
    }

    private enum PlannedSpeakerMutation {
        case merge(sourceId: UUID, into: UUID)
        case setDisplayName(id: UUID, name: String)
        case restoreProfile(SpeakerProfile)
        case addOrUpdateEmbedding(embedding: [Float], existingId: UUID?)
        case incrementDisputeCount(UUID)
        case resetDisputeCount(UUID)
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
        micURL: URL,
        systemURL: URL,
        clips: [SpeakerNamingEntry]
    ) {
        let speakerDB = transcription.speakerDB
        let clipsBySpeakerId = Dictionary(uniqueKeysWithValues: clips.map { ($0.diarizerSpeakerId, $0) })

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let resolvedURL = TranscriptSaver.resolveTranscriptURL(
                transcriptURL,
                transcriptId: transcriptId
            ) else {
                SpeakerClipExtractor.cleanupClips(clips)
                Self.removeTemporaryAudioFile(micURL, label: "mic audio")
                Self.removeTemporaryAudioFile(systemURL, label: "system audio")

                Task { @MainActor in
                    self?.finishNamingFlow(
                        didFinalizeTranscript: false,
                        updatesCount: updates.count,
                        transcriptId: transcriptId,
                        resolvedURL: transcriptURL
                    )
                }
                return
            }

            guard let plannedChanges = Self.planNamingUpdates(
                updates,
                clipsBySpeakerId: clipsBySpeakerId,
                speakerDB: speakerDB
            ) else {
                SpeakerClipExtractor.cleanupClips(clips)
                Self.removeTemporaryAudioFile(micURL, label: "mic audio")
                Self.removeTemporaryAudioFile(systemURL, label: "system audio")

                Task { @MainActor in
                    self?.finishNamingFlow(
                        didFinalizeTranscript: false,
                        updatesCount: updates.count,
                        transcriptId: transcriptId,
                        resolvedURL: resolvedURL
                    )
                }
                return
            }

            let didFinalizeTranscript = updates.isEmpty || TranscriptSaver.updateSpeakerNames(
                transcriptURL: resolvedURL,
                updates: plannedChanges.resolvedUpdates,
                transcriptionResult: transcriptionResult,
                speakerStore: speakerDB
            )

            if didFinalizeTranscript {
                Self.applyPlannedNamingMutations(plannedChanges.mutations, speakerDB: speakerDB)
            }

            SpeakerClipExtractor.cleanupClips(clips)
            Self.removeTemporaryAudioFile(micURL, label: "mic audio")
            Self.removeTemporaryAudioFile(systemURL, label: "system audio")

            Task { @MainActor in
                self?.finishNamingFlow(
                    didFinalizeTranscript: didFinalizeTranscript,
                    updatesCount: updates.count,
                    transcriptId: transcriptId,
                    resolvedURL: resolvedURL
                )
            }
        }
    }

    /// Clean up any tasks stuck in pendingNaming state.
    /// Called from applicationWillTerminate to prevent orphaned audio files.
    public func cleanupPendingNaming() {
        if let request = speakerNamingRequest {
            Self.removeTemporaryAudioFile(request.micAudioURL, label: "pending mic audio")
            Self.removeTemporaryAudioFile(request.systemAudioURL, label: "pending system audio")
            SpeakerClipExtractor.cleanupClips(request.speakers)
            speakerNamingRequest = nil
            AppLogger.pipeline.info("Cleaned up pending naming on shutdown")
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

        for update in updates {
            let entry = clipsBySpeakerId[update.diarizerSpeakerId]
            guard let plan = planPersistentSpeakerResolution(
                for: update,
                entry: entry,
                speakerDB: speakerDB
            ) else {
                return nil
            }

            AppLogger.speakers.info("Speaker named", [
                "originalId": update.persistentSpeakerId.uuidString,
                "resolvedId": plan.resolvedPersistentSpeakerId.uuidString,
                "name": update.newName,
                "action": "\(update.action)"
            ])

            resolvedUpdates.append(SpeakerNameUpdate(
                persistentSpeakerId: update.persistentSpeakerId,
                diarizerSpeakerId: update.diarizerSpeakerId,
                newName: update.newName,
                previousName: update.previousName,
                action: update.action,
                resolvedPersistentSpeakerId: plan.resolvedPersistentSpeakerId
            ))
            mutations.append(contentsOf: plan.mutations)
        }

        return PlannedNamingChanges(
            resolvedUpdates: resolvedUpdates,
            mutations: mutations
        )
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
            // The user clicked "Keep as You" for this mic speaker. Wiring lands in the
            // follow-up PR that enables mic diarization end-to-end; for now, skip silently
            // so the DB isn't mutated and the transcript rewrite path doesn't see this
            // update. Default (off) behavior never produces this action.
            return (update.persistentSpeakerId, [])
        }
    }

    nonisolated private static func applyPlannedNamingMutations(
        _ mutations: [PlannedSpeakerMutation],
        speakerDB: any SpeakerStore
    ) {
        for mutation in mutations {
            switch mutation {
            case .merge(let sourceId, let targetId):
                speakerDB.mergeProfiles(sourceId: sourceId, into: targetId)
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
            }
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

    nonisolated private static func removeTemporaryAudioFile(_ url: URL?, label: String) {
        guard let url else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            AppLogger.pipeline.warning("Failed to remove temporary audio file", [
                "label": label,
                "file": url.lastPathComponent,
                "error": error.localizedDescription
            ])
        }
    }

    nonisolated private static func normalizeSpeakerName(_ name: String?) -> String {
        (name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    @MainActor private func finishNamingFlow(
        didFinalizeTranscript: Bool,
        updatesCount: Int,
        transcriptId: UUID,
        resolvedURL: URL
    ) {
        if didFinalizeTranscript {
            AppLogger.pipeline.info("Speaker naming complete", [
                "named": "\(updatesCount)",
                "transcript": resolvedURL.lastPathComponent
            ])
            populateSavedMetadata(from: resolvedURL)
            displayStatus = .transcriptSaved
        } else {
            AppLogger.pipeline.error("Speaker naming finalization failed", [
                "transcriptId": transcriptId.uuidString,
                "transcript": resolvedURL.lastPathComponent
            ])
            displayStatus = .failed(message: "Failed to finalize speaker names")
        }

        scheduleStatusReset(delay: 8)
        speakerNamingRequest = nil
    }
}
