import Foundation

func testMeetingRecordingStartGate() {
    runSuite("MeetingRecordingStartGate.evaluate — allows meeting capture when required permissions exist") {
        let decision = MeetingRecordingStartGate.evaluate(
            microphoneGranted: true,
            screenRecordingGranted: true
        )

        assertEqual(decision, .allowed, "meeting capture should start normally when both permissions are granted")
    }

    runSuite("MeetingRecordingStartGate.evaluate — blocks meeting capture when Screen Recording is missing") {
        let decision = MeetingRecordingStartGate.evaluate(
            microphoneGranted: true,
            screenRecordingGranted: false
        )

        assertFalse(decision.canStart, "meeting capture should fail fast when Screen Recording is missing")
        assertEqual(
            decision.errorMessage,
            "Turn on Screen Recording in System Settings, then quit and reopen Transcripted before recording a meeting.",
            "screen recording failures should tell the user exactly what to fix"
        )
        assertEqual(decision.failureReason, "screen_recording", "screen recording failures should stay classified for diagnostics")
        assertEqual(decision.missingPermissions, ["screen_recording"], "missing permission list should stay explicit")
    }

    runSuite("MeetingRecordingStartGate.evaluate — blocks meeting capture when both permissions are missing") {
        let decision = MeetingRecordingStartGate.evaluate(
            microphoneGranted: false,
            screenRecordingGranted: false
        )

        assertFalse(decision.canStart, "meeting capture should not start when both required permissions are missing")
        assertEqual(
            decision.errorMessage,
            "Turn on Microphone and Screen Recording in System Settings, then quit and reopen Transcripted before recording a meeting.",
            "combined permission failures should mention both missing requirements"
        )
        assertEqual(
            decision.missingPermissions,
            ["microphone", "screen_recording"],
            "combined permission failures should preserve a stable missing-permission list"
        )
    }

    runSuite("MeetingPermissionCopy — keeps screen recording copy aligned with the meeting gate") {
        assertEqual(
            MeetingRecordingStartGate.screenRecordingSummary,
            "Optional on first launch. Required before Transcripted can capture meeting audio from other apps.",
            "shared summary copy should explain that screen recording is optional for dictation setup but required for meetings"
        )
        assertEqual(
            MeetingRecordingStartGate.screenRecordingQuickStart,
            "Turn on Screen Recording before you record meetings. After you enable it, quit and reopen Transcripted so macOS can hand over system audio.",
            "quick-start copy should explain that screen recording changes need a relaunch before meeting capture works"
        )
        assertEqual(
            MeetingRecordingStartGate.optionalPermissionsFootnote,
            "You can start dictating without these. Turn on Screen Recording before you record meetings, then reopen Transcripted. Add Calendar later if you want meeting prompts.",
            "onboarding footnote should match the current meeting recording requirement and relaunch guidance"
        )
    }
}
