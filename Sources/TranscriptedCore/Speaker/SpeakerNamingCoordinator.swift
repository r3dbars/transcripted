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
        micURL: URL,
        systemURL: URL,
        clips: [SpeakerNamingEntry]
    ) {
        let speakerDB = transcription.speakerDB
        let speakerClipsDirectory = transcription.speakerClipsDirectory
        let suggestedProvisionalIds = Set(
            clips
                .filter { $0.suggestedProfileId != nil }
                .map(\.id)
        )

        // Immediately dismiss the naming tray so the UI is responsive
        self.speakerNamingRequest = nil

        // All DB writes, file updates, and cleanup run off the main thread
        Task.detached { [weak self] in
            func canonicalProfileId(for update: SpeakerNameUpdate) -> UUID {
                switch update.action {
                case .merged(let targetId):
                    if speakerDB.getSpeaker(id: targetId) != nil {
                        return targetId
                    }
                    return speakerDB.findProfilesByName(update.newName).first?.id ?? targetId
                case .named, .corrected, .confirmed:
                    if speakerDB.getSpeaker(id: update.persistentSpeakerId) != nil {
                        return update.persistentSpeakerId
                    }
                    return speakerDB.findProfilesByName(update.newName).first?.id ?? update.persistentSpeakerId
                }
            }

            var resolvedUpdates: [SpeakerNameUpdate] = []

            // Apply name updates to speaker database
            for update in updates {
                let resolvedUpdate: SpeakerNameUpdate
                switch update.action {
                case .merged(let targetId):
                    guard targetId != update.persistentSpeakerId else { continue }
                    speakerDB.mergeProfiles(sourceId: update.persistentSpeakerId, into: targetId)
                    resolvedUpdate = update

                case .named:
                    speakerDB.setDisplayName(
                        id: update.persistentSpeakerId,
                        name: update.newName,
                        source: NameSource.userManual
                    )
                    resolvedUpdate = update

                case .corrected:
                    if suggestedProvisionalIds.contains(update.persistentSpeakerId) {
                        speakerDB.setDisplayName(
                            id: update.persistentSpeakerId,
                            name: update.newName,
                            source: NameSource.userManual
                        )
                        speakerDB.resetDisputeCount(id: update.persistentSpeakerId)
                        resolvedUpdate = SpeakerNameUpdate(
                            persistentSpeakerId: update.persistentSpeakerId,
                            sortformerSpeakerId: update.sortformerSpeakerId,
                            newName: update.newName,
                            action: .named
                        )
                    } else if let sourceProfile = speakerDB.getSpeaker(id: update.persistentSpeakerId) {
                        let detachedProfile = speakerDB.addOrUpdateSpeaker(
                            embedding: sourceProfile.embedding,
                            existingId: nil
                        )
                        speakerDB.setDisplayName(
                            id: detachedProfile.id,
                            name: update.newName,
                            source: NameSource.userManual
                        )
                        speakerDB.resetDisputeCount(id: detachedProfile.id)
                        if let concreteDB = speakerDB as? SpeakerDatabase {
                            concreteDB.incrementDisputeCount(id: update.persistentSpeakerId)
                        }
                        resolvedUpdate = SpeakerNameUpdate(
                            persistentSpeakerId: update.persistentSpeakerId,
                            sortformerSpeakerId: update.sortformerSpeakerId,
                            newName: update.newName,
                            action: .merged(targetProfileId: detachedProfile.id)
                        )
                    } else {
                        speakerDB.setDisplayName(
                            id: update.persistentSpeakerId,
                            name: update.newName,
                            source: NameSource.userManual
                        )
                        resolvedUpdate = update
                    }

                case .confirmed:
                    speakerDB.setDisplayName(
                        id: update.persistentSpeakerId,
                        name: update.newName,
                        source: NameSource.userManual
                    )
                    speakerDB.resetDisputeCount(id: update.persistentSpeakerId)
                    resolvedUpdate = update
                }

                resolvedUpdates.append(resolvedUpdate)
                AppLogger.speakers.info("Speaker named", [
                    "id": "\(update.persistentSpeakerId)",
                    "name": update.newName,
                    "action": "\(update.action)"
                ])
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

            // Update the saved transcript file with real names
            let canonicalUpdates = resolvedUpdates.map { update -> SpeakerNameUpdate in
                let canonicalId = canonicalProfileId(for: update)
                switch update.action {
                case .merged:
                    return SpeakerNameUpdate(
                        persistentSpeakerId: update.persistentSpeakerId,
                        sortformerSpeakerId: update.sortformerSpeakerId,
                        newName: update.newName,
                        action: .merged(targetProfileId: canonicalId)
                    )
                case .named, .corrected, .confirmed:
                    guard canonicalId != update.persistentSpeakerId else { return update }
                    return SpeakerNameUpdate(
                        persistentSpeakerId: update.persistentSpeakerId,
                        sortformerSpeakerId: update.sortformerSpeakerId,
                        newName: update.newName,
                        action: .merged(targetProfileId: canonicalId)
                    )
                }
            }

            // Resolve the transcript URL — the file may have been renamed by
            // MeetingTranscriptStyler between save and naming completion.
            let resolvedURL = TranscriptSaver.resolveTranscriptURL(
                transcriptURL,
                updates: canonicalUpdates.isEmpty ? resolvedUpdates : canonicalUpdates
            )

            if !canonicalUpdates.isEmpty {
                TranscriptSaver.updateSpeakerNames(
                    transcriptURL: resolvedURL,
                    updates: canonicalUpdates,
                    speakerStoreForIndex: speakerDB
                )
            }

            // Clean up clips and audio files
            SpeakerClipExtractor.cleanupClips(clips)
            try? FileManager.default.removeItem(at: micURL)
            try? FileManager.default.removeItem(at: systemURL)

            AppLogger.pipeline.info("Speaker naming complete", [
                "named": "\(canonicalUpdates.count)",
                "transcript": resolvedURL.lastPathComponent
            ])

            // Only UI state updates on the main thread
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.populateSavedMetadata(from: resolvedURL)
                self.displayStatus = .transcriptSaved
                self.scheduleStatusReset(delay: 8)
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
}
