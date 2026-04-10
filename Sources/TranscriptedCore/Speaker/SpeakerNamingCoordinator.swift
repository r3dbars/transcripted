import Foundation

// MARK: - Speaker Naming Flow Coordination

extension TranscriptionTaskManager {

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
        micURL: URL,
        systemURL: URL,
        clips: [SpeakerNamingEntry]
    ) {
        let speakerDB = transcription.speakerDB
        let speakerClipsDirectory = transcription.speakerClipsDirectory
        let clipsBySpeakerId = Dictionary(uniqueKeysWithValues: clips.map { ($0.sortformerSpeakerId, $0) })

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let resolvedUpdates = Self.applyNamingUpdates(
                updates,
                clipsBySpeakerId: clipsBySpeakerId,
                speakerDB: speakerDB
            ) else {
                SpeakerClipExtractor.cleanupClips(clips)
                try? FileManager.default.removeItem(at: micURL)
                try? FileManager.default.removeItem(at: systemURL)

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

            guard let resolvedURL = TranscriptSaver.resolveTranscriptURL(
                transcriptURL,
                transcriptId: transcriptId
            ) else {
                SpeakerClipExtractor.cleanupClips(clips)
                try? FileManager.default.removeItem(at: micURL)
                try? FileManager.default.removeItem(at: systemURL)

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

            let handledIds = Set(resolvedUpdates.map(\.persistentSpeakerId))
            for entry in clips where entry.suggestedProfileId != nil && !handledIds.contains(entry.id) {
                speakerDB.deleteSpeaker(id: entry.id)
                SpeakerClipExtractor.deletePersistedClip(
                    for: entry.id,
                    clipsDirectory: speakerClipsDirectory
                )
            }

            // Merge profiles that ended up with the same name
            speakerDB.mergeProfilesByName()
            // Re-run duplicate detection now that profiles have been updated
            speakerDB.mergeDuplicates()

            let didFinalizeTranscript = updates.isEmpty || TranscriptSaver.updateSpeakerNames(
                transcriptURL: resolvedURL,
                updates: resolvedUpdates,
                speakerStoreForIndex: speakerDB
            )

            SpeakerClipExtractor.cleanupClips(clips)
            try? FileManager.default.removeItem(at: micURL)
            try? FileManager.default.removeItem(at: systemURL)

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
            try? FileManager.default.removeItem(at: request.micAudioURL)
            try? FileManager.default.removeItem(at: request.systemAudioURL)
            SpeakerClipExtractor.cleanupClips(request.speakers)
            for entry in request.speakers where entry.suggestedProfileId != nil {
                transcription.speakerDB.deleteSpeaker(id: entry.id)
                SpeakerClipExtractor.deletePersistedClip(
                    for: entry.id,
                    clipsDirectory: transcription.speakerClipsDirectory
                )
            }
            speakerNamingRequest = nil
            AppLogger.pipeline.info("Cleaned up pending naming on shutdown")
        }
    }

    nonisolated private static func applyNamingUpdates(
        _ updates: [SpeakerNameUpdate],
        clipsBySpeakerId: [String: SpeakerNamingEntry],
        speakerDB: any SpeakerStore
    ) -> [SpeakerNameUpdate]? {
        var resolvedUpdates: [SpeakerNameUpdate] = []
        resolvedUpdates.reserveCapacity(updates.count)

        for update in updates {
            let entry = clipsBySpeakerId[update.sortformerSpeakerId]
            guard let resolvedPersistentSpeakerId = resolvePersistentSpeakerId(
                for: update,
                entry: entry,
                speakerDB: speakerDB
            ) else {
                return nil
            }

            AppLogger.speakers.info("Speaker named", [
                "originalId": update.persistentSpeakerId.uuidString,
                "resolvedId": resolvedPersistentSpeakerId.uuidString,
                "name": update.newName,
                "action": "\(update.action)"
            ])

            resolvedUpdates.append(SpeakerNameUpdate(
                persistentSpeakerId: update.persistentSpeakerId,
                sortformerSpeakerId: update.sortformerSpeakerId,
                newName: update.newName,
                previousName: update.previousName,
                action: update.action,
                resolvedPersistentSpeakerId: resolvedPersistentSpeakerId
            ))
        }

        return resolvedUpdates
    }

    nonisolated private static func resolvePersistentSpeakerId(
        for update: SpeakerNameUpdate,
        entry: SpeakerNamingEntry?,
        speakerDB: any SpeakerStore
    ) -> UUID? {
        switch update.action {
        case .merged(let targetProfileId):
            speakerDB.mergeProfiles(sourceId: update.persistentSpeakerId, into: targetProfileId)
            speakerDB.resetDisputeCount(id: targetProfileId)
            return targetProfileId

        case .confirmed:
            speakerDB.setDisplayName(
                id: update.persistentSpeakerId,
                name: update.newName,
                source: NameSource.userManual
            )
            speakerDB.resetDisputeCount(id: update.persistentSpeakerId)
            return update.persistentSpeakerId

        case .named:
            if let targetProfile = exactNamedTarget(
                named: update.newName,
                excluding: update.persistentSpeakerId,
                speakerDB: speakerDB
            ) {
                speakerDB.mergeProfiles(sourceId: update.persistentSpeakerId, into: targetProfile.id)
                speakerDB.resetDisputeCount(id: targetProfile.id)
                return targetProfile.id
            }

            speakerDB.setDisplayName(
                id: update.persistentSpeakerId,
                name: update.newName,
                source: NameSource.userManual
            )
            speakerDB.resetDisputeCount(id: update.persistentSpeakerId)
            return update.persistentSpeakerId

        case .corrected:
            if let matchedProfile = entry?.matchedProfileSnapshot {
                speakerDB.restoreProfile(matchedProfile)
                speakerDB.incrementDisputeCount(id: matchedProfile.id)
            }

            if let targetProfile = exactNamedTarget(
                named: update.newName,
                excluding: update.persistentSpeakerId,
                speakerDB: speakerDB
            ) {
                if let embedding = entry?.sessionEmbedding {
                    _ = speakerDB.addOrUpdateSpeaker(embedding: embedding, existingId: targetProfile.id)
                }
                speakerDB.setDisplayName(
                    id: targetProfile.id,
                    name: update.newName,
                    source: NameSource.userManual
                )
                speakerDB.resetDisputeCount(id: targetProfile.id)
                return targetProfile.id
            }

            if let embedding = entry?.sessionEmbedding {
                let newProfile = speakerDB.addOrUpdateSpeaker(embedding: embedding, existingId: nil)
                speakerDB.setDisplayName(
                    id: newProfile.id,
                    name: update.newName,
                    source: NameSource.userManual
                )
                speakerDB.resetDisputeCount(id: newProfile.id)
                return newProfile.id
            }

            AppLogger.speakers.error("Correction missing session embedding; refusing unsafe profile rewrite", [
                "speakerId": update.persistentSpeakerId.uuidString,
                "name": update.newName
            ])
            return nil
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
