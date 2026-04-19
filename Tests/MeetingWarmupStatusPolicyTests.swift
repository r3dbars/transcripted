import Foundation

func testMeetingWarmupStatusPolicy() {
    runSuite("MeetingWarmupStatusPolicy.status — keeps background meeting warmup failures quiet") {
        let status = MeetingWarmupStatusPolicy.status(
            dictationState: .ready,
            meetingState: .failed("Could not establish a secure connection to the download server."),
            isMeetingWarmupInFlight: false,
            shouldSurfaceMeetingWarmupFailure: false
        )

        assertEqual(status, .ready, "background startup failures should not become visible meeting errors")
    }

    runSuite("MeetingWarmupStatusPolicy.status — surfaces user-requested meeting warmup failures") {
        let status = MeetingWarmupStatusPolicy.status(
            dictationState: .ready,
            meetingState: .failed("Could not establish a secure connection to the download server."),
            isMeetingWarmupInFlight: false,
            shouldSurfaceMeetingWarmupFailure: true
        )

        assertEqual(status.subtitle, "Meeting transcription models failed to load", "explicit meeting setup should show the failure")
        assertEqual(status.meetingsStatus, "Failed", "the meeting action should offer retry copy after visible failure")
    }

    runSuite("MeetingWarmupStatusPolicy.status — shows meeting loading while warmup is visible") {
        let status = MeetingWarmupStatusPolicy.status(
            dictationState: .ready,
            meetingState: .loading,
            isMeetingWarmupInFlight: true,
            shouldSurfaceMeetingWarmupFailure: false
        )

        assertEqual(status.subtitle, "Loading meeting transcription", "visible warmup should still show loading copy")
        assertEqual(status.meetingsStatus, "Loading", "meeting status should track visible loading")
    }

    runSuite("MeetingWarmupStatusPolicy.status — dictation failures still take priority") {
        let status = MeetingWarmupStatusPolicy.status(
            dictationState: .failed("Model load failed"),
            meetingState: .failed("Meeting load failed"),
            isMeetingWarmupInFlight: false,
            shouldSurfaceMeetingWarmupFailure: false
        )

        assertEqual(status.subtitle, "The local dictation model failed to load", "dictation failure copy should remain unchanged")
        assertEqual(status.meetingsStatus, "Waiting", "meeting setup should wait until dictation is available")
    }
}
