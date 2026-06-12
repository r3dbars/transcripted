import Foundation

func testMeetingLiveViewAffordancePolicy() {
    runSuite("MeetingLiveViewAffordancePolicy — hidden outside active recording") {
        assertNil(
            MeetingLiveViewAffordancePolicy.affordance(
                isRecording: false,
                isRecordingMinimized: false,
                isLiveMeetingSidecarEnabled: true,
                isTranscriptVisible: false
            ),
            "the live transcript affordance should only render while a meeting is recording"
        )
        assertNil(
            MeetingLiveViewAffordancePolicy.affordance(
                isRecording: false,
                isRecordingMinimized: false,
                isLiveMeetingSidecarEnabled: false,
                isTranscriptVisible: false
            ),
            "no recording means no live transcript button, regardless of the preference"
        )
    }

    runSuite("MeetingLiveViewAffordancePolicy — hidden in the minimized recording pill") {
        assertNil(
            MeetingLiveViewAffordancePolicy.affordance(
                isRecording: true,
                isRecordingMinimized: true,
                isLiveMeetingSidecarEnabled: true,
                isTranscriptVisible: false
            ),
            "the minimized pill stays stripped down to cancel/timer/stop"
        )
    }

    runSuite("MeetingLiveViewAffordancePolicy — toggles the drawer when live meetings is on") {
        let collapsed = MeetingLiveViewAffordancePolicy.affordance(
            isRecording: true,
            isRecordingMinimized: false,
            isLiveMeetingSidecarEnabled: true,
            isTranscriptVisible: false
        )
        assertEqual(collapsed?.tooltip, "View live transcript")
        assertEqual(
            collapsed?.enablesLiveMeetingsOnClick, false,
            "an already-enabled preference should not be re-enabled on click"
        )

        let expanded = MeetingLiveViewAffordancePolicy.affordance(
            isRecording: true,
            isRecordingMinimized: false,
            isLiveMeetingSidecarEnabled: true,
            isTranscriptVisible: true
        )
        assertEqual(expanded?.tooltip, "Hide live transcript", "open drawer should offer the hide action")
        assertEqual(expanded?.enablesLiveMeetingsOnClick, false)
    }

    runSuite("MeetingLiveViewAffordancePolicy — one-click enable when the preference is off") {
        let affordance = MeetingLiveViewAffordancePolicy.affordance(
            isRecording: true,
            isRecordingMinimized: false,
            isLiveMeetingSidecarEnabled: false,
            isTranscriptVisible: false
        )
        assertNotNil(affordance, "the point-of-use affordance should stay discoverable when the preference is off")
        assertEqual(affordance?.tooltip, "Turn on live transcript")
        assertEqual(
            affordance?.enablesLiveMeetingsOnClick, true,
            "clicking with the preference off should enable live meetings before showing the drawer"
        )
        assertTrue(
            affordance?.accessibilityHelp.contains("next meeting") == true,
            "off-state copy must not promise live text for the current meeting — live ASR cannot join mid-recording"
        )
    }

    runSuite("MeetingLiveViewAffordancePolicy — drawer status copy follows the feed phase") {
        assertEqual(
            MeetingLiveViewAffordancePolicy.drawerStatus(phase: .starting, hasEntries: false),
            "Starting live transcription…"
        )
        assertEqual(
            MeetingLiveViewAffordancePolicy.drawerStatus(phase: .live, hasEntries: false),
            "Listening — the live transcript appears as people talk."
        )
        assertNil(
            MeetingLiveViewAffordancePolicy.drawerStatus(phase: .live, hasEntries: true),
            "entries should render without status copy once live text flows"
        )
        assertEqual(
            MeetingLiveViewAffordancePolicy.drawerStatus(phase: .deferred("late join"), hasEntries: false),
            "late join",
            "deferred phases carry their own user-facing note"
        )
        assertEqual(
            MeetingLiveViewAffordancePolicy.drawerStatus(phase: .failed("asr died"), hasEntries: true),
            "asr died",
            "a failure note should show even when earlier entries exist"
        )
        assertNil(
            MeetingLiveViewAffordancePolicy.drawerStatus(phase: .stopped, hasEntries: true),
            "stopping keeps the captured entries readable without extra copy"
        )
    }

    runSuite("MeetingLiveViewAffordancePolicy — stable automation identifiers") {
        assertEqual(
            MeetingLiveViewAffordancePolicy.automationIdentifier,
            "transcripted.meeting-overlay.live-view",
            "external UI automation pins this identifier"
        )
        assertEqual(
            MeetingLiveViewAffordancePolicy.browserAutomationIdentifier,
            "transcripted.meeting-overlay.live-view.open-browser",
            "the drawer's browser action keeps its own stable identifier"
        )
    }
}
