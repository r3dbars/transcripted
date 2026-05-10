import Foundation

func testMeetingQueuedAudioAvailability() {
    let micURL = URL(fileURLWithPath: "/tmp/meeting-mic.wav")
    let systemURL = URL(fileURLWithPath: "/tmp/meeting-system.wav")

    runSuite("MeetingQueuedAudioAvailability returns nil when queued audio exists") {
        let missing = MeetingQueuedAudioAvailability.missingFiles(
            micURL: micURL,
            systemURL: systemURL,
            fileExists: { _ in true }
        )

        assertNil(missing, "all-present queued audio should continue to transcription")
    }

    runSuite("MeetingQueuedAudioAvailability reports missing mic audio") {
        let missing = MeetingQueuedAudioAvailability.missingFiles(
            micURL: micURL,
            systemURL: systemURL,
            fileExists: { url in url == systemURL }
        )

        assertEqual(
            missing,
            MeetingQueuedAudioAvailability.MissingFiles(micMissing: true, systemMissing: false),
            "missing mic audio should fail the queued job before the pipeline starts"
        )
    }

    runSuite("MeetingQueuedAudioAvailability reports missing system audio") {
        let missing = MeetingQueuedAudioAvailability.missingFiles(
            micURL: micURL,
            systemURL: systemURL,
            fileExists: { url in url == micURL }
        )

        assertEqual(
            missing,
            MeetingQueuedAudioAvailability.MissingFiles(micMissing: false, systemMissing: true),
            "missing system audio should fail the queued job before the pipeline starts"
        )
    }
}
