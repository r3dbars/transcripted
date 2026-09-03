import Foundation

func testRetranscribeLocalSpeakerPreferenceContract() {
    runSuite("Meeting transcription entry points resolve splitLocalSpeakers from the preference") {
        let controller = readSourceFixture("Sources/Meeting/MeetingSessionController.swift")
        let coordinator = readSourceFixture("Sources/Meeting/TranscriptionQueueCoordinator.swift")

        guard let retranscribeStart = controller.range(of: "func retranscribeSavedMeeting("),
              let retranscribeEnd = controller.range(
                  of: "private func handleReplacementTranscriptCommitted(",
                  range: retranscribeStart.upperBound..<controller.endIndex
              ) else {
            assertTrue(false, "test should find retranscribeSavedMeeting")
            return
        }
        let retranscribe = String(controller[retranscribeStart.lowerBound..<retranscribeEnd.lowerBound])

        assertTrue(
            retranscribe.contains("splitLocalSpeakers: LocalSpeakerPreferences.isEnabled()"),
            "saved-audio retranscription should honour the People-in-the-room preference"
        )
        assertTrue(
            !retranscribe.contains("splitLocalSpeakers: true"),
            "saved-audio retranscription should not hard-code local speaker splitting"
        )
        assertTrue(
            coordinator.contains("splitLocalSpeakers: LocalSpeakerPreferences.isEnabled()"),
            "live capture transcription should keep reading the preference"
        )
        assertTrue(
            coordinator.contains("splitLocalSpeakers: splitLocalSpeakers"),
            "queued recorded jobs must persist the snapshot onto the failed-queue row"
        )
        assertTrue(
            controller.contains("preserveFailedMeetingForRetry(")
                && controller.contains("splitLocalSpeakers: LocalSpeakerPreferences.isEnabled()"),
            "live unexpected/no-file preserves must snapshot People-in-the-room"
        )
        assertTrue(
            controller.contains("preserveTimedOutFailedMeetingForRetry(")
                && controller.contains("splitLocalSpeakers: LocalSpeakerPreferences.isEnabled()"),
            "stop-timeout preserves must snapshot People-in-the-room"
        )
    }
}
