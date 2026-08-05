import Foundation

func testMeetingLiveViewAffordancePolicy() {
    runSuite("MeetingLiveViewAffordancePolicy — no affordance outside active recording") {
        assertNil(
            MeetingLiveViewAffordancePolicy.affordance(isRecording: false, isTranscriptVisible: false)
        )
    }

    runSuite("MeetingLiveViewAffordancePolicy — toggles the drawer") {
        let collapsed = MeetingLiveViewAffordancePolicy.affordance(
            isRecording: true,
            isTranscriptVisible: false
        )
        assertEqual(collapsed?.tooltip, "View live transcript")

        let expanded = MeetingLiveViewAffordancePolicy.affordance(
            isRecording: true,
            isTranscriptVisible: true
        )
        assertEqual(expanded?.tooltip, "Hide live transcript")
    }

    runSuite("MeetingLiveViewAffordancePolicy — context menu copy follows state") {
        assertEqual(
            MeetingLiveViewAffordancePolicy.transcriptToggleMenuTitle(isTranscriptVisible: false),
            "View Live Transcript"
        )
        assertEqual(
            MeetingLiveViewAffordancePolicy.transcriptToggleMenuTitle(isTranscriptVisible: true),
            "Hide Live Transcript"
        )
        assertEqual(MeetingLiveViewAffordancePolicy.keepControlsVisibleMenuTitle, "Keep Controls Visible")
        assertEqual(MeetingLiveViewAffordancePolicy.discardRecordingMenuTitle, "Discard Recording…")
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
        assertNil(MeetingLiveViewAffordancePolicy.drawerStatus(phase: .live, hasEntries: true))
        assertEqual(
            MeetingLiveViewAffordancePolicy.drawerStatus(phase: .deferred("late join"), hasEntries: false),
            "late join"
        )
        assertEqual(
            MeetingLiveViewAffordancePolicy.drawerStatus(phase: .failed("asr died"), hasEntries: true),
            "asr died"
        )
        assertNil(MeetingLiveViewAffordancePolicy.drawerStatus(phase: .stopped, hasEntries: true))
    }

    runSuite("MeetingLiveViewAffordancePolicy — stable automation identifiers") {
        assertEqual(MeetingLiveViewAffordancePolicy.automationIdentifier, "transcripted.meeting-overlay.live-view")
        assertEqual(MeetingLiveViewAffordancePolicy.copyAutomationIdentifier, "transcripted.meeting-overlay.live-view.copy")
    }
}
