import Foundation

func testMeetingLiveViewAffordancePolicy() {
    runSuite("MeetingLiveViewAffordancePolicy — no affordance outside active recording") {
        assertNil(
            MeetingLiveViewAffordancePolicy.affordance(
                isRecording: false,
                isLiveMeetingSidecarEnabled: true,
                isTranscriptVisible: false
            ),
            "the pill click affordance should only exist while a meeting is recording"
        )
        assertNil(
            MeetingLiveViewAffordancePolicy.affordance(
                isRecording: false,
                isLiveMeetingSidecarEnabled: false,
                isTranscriptVisible: false
            ),
            "no recording means no transcript affordance, regardless of the preference"
        )
    }

    runSuite("MeetingLiveViewAffordancePolicy — toggles the drawer when live meetings is on") {
        let collapsed = MeetingLiveViewAffordancePolicy.affordance(
            isRecording: true,
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
            isLiveMeetingSidecarEnabled: true,
            isTranscriptVisible: true
        )
        assertEqual(expanded?.tooltip, "Hide live transcript", "open drawer should offer the hide action")
        assertEqual(expanded?.enablesLiveMeetingsOnClick, false)
    }

    runSuite("MeetingLiveViewAffordancePolicy — one-click enable when the preference is off") {
        let affordance = MeetingLiveViewAffordancePolicy.affordance(
            isRecording: true,
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

    runSuite("MeetingLiveViewAffordancePolicy — context menu copy follows state") {
        assertEqual(
            MeetingLiveViewAffordancePolicy.transcriptToggleMenuTitle(
                isLiveMeetingSidecarEnabled: false,
                isTranscriptVisible: false
            ),
            "Turn On Live Transcript"
        )
        assertEqual(
            MeetingLiveViewAffordancePolicy.transcriptToggleMenuTitle(
                isLiveMeetingSidecarEnabled: true,
                isTranscriptVisible: false
            ),
            "View Live Transcript"
        )
        assertEqual(
            MeetingLiveViewAffordancePolicy.transcriptToggleMenuTitle(
                isLiveMeetingSidecarEnabled: true,
                isTranscriptVisible: true
            ),
            "Hide Live Transcript"
        )
        assertEqual(MeetingLiveViewAffordancePolicy.keepControlsVisibleMenuTitle, "Keep Controls Visible")
        assertEqual(
            MeetingLiveViewAffordancePolicy.discardRecordingMenuTitle, "Discard Recording…",
            "discard moved off the pill into the menu; the title must keep its confirmation ellipsis"
        )
        assertEqual(MeetingLiveViewAffordancePolicy.openInBrowserMenuTitle, "Open Live View in Browser")
        assertEqual(MeetingLiveViewAffordancePolicy.copyTranscriptMenuTitle, "Copy Transcript")
        assertEqual(
            MeetingLiveViewAffordancePolicy.openInBrowserFailedStatus,
            "Could not open Live View in your browser. Try again from the menu.",
            "browser handoff failures should have visible drawer feedback, not just telemetry"
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
            "external UI automation pins the pill body identifier"
        )
        assertEqual(
            MeetingLiveViewAffordancePolicy.copyAutomationIdentifier,
            "transcripted.meeting-overlay.live-view.copy",
            "the drawer's copy action keeps its own stable identifier"
        )
        assertEqual(
            MeetingLiveViewAffordancePolicy.moreAutomationIdentifier,
            "transcripted.meeting-overlay.live-view.more",
            "the drawer's overflow menu keeps its own stable identifier"
        )
    }
}
