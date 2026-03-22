import Foundation

// MARK: - Speaker Naming Flow Coordination

@available(macOS 26.0, *)
extension TranscriptionTaskManager {

    /// Handle completion of the speaker naming flow.
    /// Applies names to the database, updates the transcript, and cleans up.
    func handleNamingComplete(
        updates: [SpeakerNameUpdate],
        transcriptURL: URL,
        micURL: URL,
        systemURL: URL,
        clips: [SpeakerNamingEntry]
    ) {
        let speakerDB = transcription.speakerDB

        // Apply name updates to speaker database
        for update in updates {
            switch update.action {
            case .merged(let targetId):
                speakerDB.mergeProfiles(sourceId: update.persistentSpeakerId, into: targetId)

            case .named, .corrected:
                speakerDB.setDisplayName(
                    id: update.persistentSpeakerId,
                    name: update.newName,
                    source: "user_manual"
                )

            case .confirmed:
                speakerDB.setDisplayName(
                    id: update.persistentSpeakerId,
                    name: update.newName,
                    source: "user_manual"
                )
                speakerDB.resetDisputeCount(id: update.persistentSpeakerId)
            }

            AppLogger.speakers.info("Speaker named", [
                "id": "\(update.persistentSpeakerId)",
                "name": update.newName,
                "action": "\(update.action)"
            ])
        }

        // Merge profiles that ended up with the same name (e.g., user named 4 profiles "Jenny Wen")
        speakerDB.mergeProfilesByName()
        // Also re-run duplicate detection now that profiles have been updated
        speakerDB.mergeDuplicates()

        // Update the saved transcript file with real names
        if !updates.isEmpty {
            TranscriptSaver.updateSpeakerNames(transcriptURL: transcriptURL, updates: updates)
        }

        // Clean up clips and audio files
        SpeakerClipExtractor.cleanupClips(clips)
        try? FileManager.default.removeItem(at: micURL)
        try? FileManager.default.removeItem(at: systemURL)

        // Clear the naming request
        self.speakerNamingRequest = nil

        // Re-show success view after naming so user can Copy/Open the transcript
        self.lastSavedTranscriptURL = transcriptURL
        self.displayStatus = .transcriptSaved
        self.scheduleStatusReset(delay: 8)

        AppLogger.pipeline.info("Speaker naming complete", [
            "named": "\(updates.count)",
            "transcript": transcriptURL.lastPathComponent
        ])
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
