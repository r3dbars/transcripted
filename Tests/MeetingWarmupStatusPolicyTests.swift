import Foundation

func testMeetingWarmupStatusPolicy() {
    runSuite("MeetingWarmupStatusPolicy.status — keeps background meeting warmup failures quiet") {
        let status = MeetingWarmupStatusPolicy.status(
            dictationState: .ready,
            meetingState: .failed("Could not establish a secure connection to the download server."),
            isMeetingWarmupInFlight: false,
            shouldSurfaceMeetingWarmupFailure: false
        )

        assertEqual(status.subtitle, "Meetings load when started", "background startup failures should not become visible meeting errors")
        assertEqual(status.meetingsStatus, "On demand", "quiet meeting warmup failures should fall back to lazy meeting copy")
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

    runSuite("MeetingWarmupStatusPolicy.status — explains lazy meeting loading") {
        let status = MeetingWarmupStatusPolicy.status(
            dictationState: .ready,
            meetingState: .notLoaded,
            isMeetingWarmupInFlight: false,
            shouldSurfaceMeetingWarmupFailure: false
        )

        assertEqual(status.title, "Dictation is ready", "dictation-ready startup should not claim meeting models are resident")
        assertEqual(status.subtitle, "Meetings load when started", "lazy meeting startup should be explicit")
        assertEqual(status.meetingsStatus, "On demand", "meeting status should show the lazy model policy")
    }

    runSuite("MeetingWarmupStatusPolicy.status — explains lazy dictation loading") {
        let status = MeetingWarmupStatusPolicy.status(
            dictationState: .notLoaded,
            meetingState: .notLoaded,
            isMeetingWarmupInFlight: false,
            shouldSurfaceMeetingWarmupFailure: false
        )

        assertEqual(status.title, "Transcripted is ready", "lazy default launch should not look like stuck startup work")
        assertEqual(status.subtitle, "Dictation and meetings load when started", "lazy model loading should be explicit")
        assertTrue(status.isReadyForMenuHeader, "lazy model loading should not make the menu header look stuck")
        assertTrue(
            status.detail.contains("outside app updates"),
            "lazy model copy should explain the one-time cache survives normal app updates"
        )
        assertEqual(status.dictationStatus, "On demand", "dictation status should show the lazy model policy")
        assertEqual(status.meetingsStatus, "On demand", "meeting status should show the lazy model policy")
    }

    runSuite("MeetingWarmupStatusPolicy.status — explains one-time dictation download") {
        let status = MeetingWarmupStatusPolicy.status(
            dictationState: .downloading(progress: 0),
            meetingState: .notLoaded,
            isMeetingWarmupInFlight: false,
            shouldSurfaceMeetingWarmupFailure: false
        )

        assertEqual(status.dictationStatus, "Downloading", "zero-progress Parakeet downloads should not pretend to have exact percent progress")
        assertFalse(status.isReadyForMenuHeader, "real downloads should still surface as in-progress work")
        assertTrue(
            status.detail.contains("future app updates should reuse the cached model"),
            "download copy should explain update-safe model caching"
        )
    }

    runSuite("MeetingWarmupStatusPolicy.status — shows cached dictation files without fake readiness") {
        let status = MeetingWarmupStatusPolicy.status(
            dictationState: .cached,
            meetingState: .notLoaded,
            isMeetingWarmupInFlight: false,
            shouldSurfaceMeetingWarmupFailure: false
        )

        assertEqual(status.dictationStatus, "Cached", "cached dictation files should have their own status")
        assertTrue(status.isReadyForMenuHeader, "cached files should not make the menu header look stuck or not ready")
        assertTrue(
            status.detail.contains("load them into memory on first use"),
            "cached copy should not claim the speech model is already loaded"
        )
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
