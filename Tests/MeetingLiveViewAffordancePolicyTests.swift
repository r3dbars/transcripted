import Foundation

func testMeetingLiveViewAffordancePolicy() {
    runSuite("MeetingLiveViewAffordancePolicy — hidden outside active recording") {
        assertNil(
            MeetingLiveViewAffordancePolicy.affordance(
                isRecording: false,
                isRecordingMinimized: false,
                isLiveMeetingSidecarEnabled: true
            ),
            "the live view affordance should only render while a meeting is recording"
        )
        assertNil(
            MeetingLiveViewAffordancePolicy.affordance(
                isRecording: false,
                isRecordingMinimized: false,
                isLiveMeetingSidecarEnabled: false
            ),
            "no recording means no live view button, regardless of the preference"
        )
    }

    runSuite("MeetingLiveViewAffordancePolicy — hidden in the minimized recording pill") {
        assertNil(
            MeetingLiveViewAffordancePolicy.affordance(
                isRecording: true,
                isRecordingMinimized: true,
                isLiveMeetingSidecarEnabled: true
            ),
            "the minimized pill stays stripped down to cancel/timer/stop"
        )
    }

    runSuite("MeetingLiveViewAffordancePolicy — opens directly when live meetings is already on") {
        let affordance = MeetingLiveViewAffordancePolicy.affordance(
            isRecording: true,
            isRecordingMinimized: false,
            isLiveMeetingSidecarEnabled: true
        )
        assertNotNil(affordance, "recording with the preference on should offer the live view")
        assertEqual(affordance?.tooltip, "Open live transcript view")
        assertEqual(affordance?.accessibilityLabel, "Open live transcript view")
        assertEqual(
            affordance?.enablesLiveMeetingsOnClick, false,
            "an already-enabled preference should not be re-enabled on click"
        )
    }

    runSuite("MeetingLiveViewAffordancePolicy — one-click enable when the preference is off") {
        let affordance = MeetingLiveViewAffordancePolicy.affordance(
            isRecording: true,
            isRecordingMinimized: false,
            isLiveMeetingSidecarEnabled: false
        )
        assertNotNil(affordance, "the point-of-use affordance should stay discoverable when the preference is off")
        assertEqual(affordance?.tooltip, "Turn on live transcript view")
        assertEqual(
            affordance?.enablesLiveMeetingsOnClick, true,
            "clicking with the preference off should enable live meetings before opening the view"
        )
        assertTrue(
            affordance?.accessibilityHelp.contains("next meeting") == true,
            "off-state copy must not promise live text for the current meeting — live ASR cannot join mid-recording"
        )
    }

    runSuite("MeetingLiveViewAffordancePolicy — stable automation identifier") {
        assertEqual(
            MeetingLiveViewAffordancePolicy.automationIdentifier,
            "transcripted.meeting-overlay.live-view",
            "external UI automation pins this identifier"
        )
    }
}
