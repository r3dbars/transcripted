import Foundation

// MARK: - Speaker Naming Flow Coordination

@available(macOS 26.0, *)
extension TranscriptionTaskManager {

    /// Handle completion of the speaker naming flow.
    /// Applies names to the database, updates the transcript, and cleans up.
    ///
    /// DB operations (mergeProfiles, setDisplayName, mergeDuplicates) run on a
    /// background task to avoid blocking the main thread with cascading queue.sync
    /// calls — each DB method synchronously locks a utility queue, and with 7+
    /// speakers this totals 15-20 blocking calls that freeze the UI.
    func handleNamingComplete(
        updates: [SpeakerNameUpdate],
        transcriptURL: URL,
        micURL: URL,
        systemURL: URL,
        clips: [SpeakerNamingEntry]
    ) {
        let speakerDB = transcription.speakerDB

        // Immediately dismiss the naming tray so the UI is responsive
        self.speakerNamingRequest = nil

        // All DB writes, file updates, and cleanup run off the main thread
        Task.detached { [weak self] in
            // Apply name updates to speaker database
            for update in updates {
                switch update.action {
                case .merged(let targetId):
                    speakerDB.mergeProfiles(sourceId: update.persistentSpeakerId, into: targetId)

                case .named, .corrected:
                    speakerDB.setDisplayName(
                        id: update.persistentSpeakerId,
                        name: update.newName,
                        source: NameSource.userManual
                    )

                case .confirmed:
                    speakerDB.setDisplayName(
                        id: update.persistentSpeakerId,
                        name: update.newName,
                        source: NameSource.userManual
                    )
                    speakerDB.resetDisputeCount(id: update.persistentSpeakerId)
                }

                AppLogger.speakers.info("Speaker named", [
                    "id": "\(update.persistentSpeakerId)",
                    "name": update.newName,
                    "action": "\(update.action)"
                ])
            }

            // Merge profiles that ended up with the same name
            speakerDB.mergeProfilesByName()
            // Re-run duplicate detection now that profiles have been updated
            speakerDB.mergeDuplicates()

            // Update the saved transcript file with real names
            if !updates.isEmpty {
                TranscriptSaver.updateSpeakerNames(transcriptURL: transcriptURL, updates: updates)
            }

            // Clean up clips and audio files
            SpeakerClipExtractor.cleanupClips(clips)
            try? FileManager.default.removeItem(at: micURL)
            try? FileManager.default.removeItem(at: systemURL)

            AppLogger.pipeline.info("Speaker naming complete", [
                "named": "\(updates.count)",
                "transcript": transcriptURL.lastPathComponent
            ])

            // Only UI state updates on the main thread
            await MainActor.run {
                self?.populateSavedMetadata(from: transcriptURL)
                self?.displayStatus = .transcriptSaved
                self?.scheduleStatusReset(delay: 8)
            }
        }
    }

    /// Clean up any tasks stuck in pendingNaming state.
    /// Called from applicationWillTerminate to prevent orphaned audio files.
    func cleanupPendingNaming() {
        if let request = speakerNamingRequest {
            try? FileManager.default.removeItem(at: request.micAudioURL)
            try? FileManager.default.removeItem(at: request.systemAudioURL)
            SpeakerClipExtractor.cleanupClips(request.speakers)
            speakerNamingRequest = nil
            AppLogger.pipeline.info("Cleaned up pending naming on shutdown")
        }
    }
}
