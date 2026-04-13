import Foundation

func testMeetingRecordingStartGate() {
    let screenRecordingError: String
    let combinedPermissionsError: String
    let quickStartCopy: String
    let optionalPermissionsCopy: String

    if #available(macOS 26.0, *) {
        screenRecordingError = "Turn on System Audio Recording in System Settings before recording a meeting."
        combinedPermissionsError = "Turn on Microphone and System Audio Recording in System Settings before recording a meeting."
        quickStartCopy = "Turn on System Audio Recording before you record meetings so Transcripted can capture the other side of Zoom, Meet, and similar apps."
        optionalPermissionsCopy = "You can start dictating without these. Turn on System Audio Recording before you record meetings, and add Calendar later if you want meeting prompts."
    } else {
        screenRecordingError = "Turn on Screen Recording in System Settings, then quit and reopen Transcripted before recording a meeting."
        combinedPermissionsError = "Turn on Microphone and Screen Recording in System Settings, then quit and reopen Transcripted before recording a meeting."
        quickStartCopy = "Turn on Screen Recording before you record meetings. After you enable it, quit and reopen Transcripted so macOS can hand over system audio."
        optionalPermissionsCopy = "You can start dictating without these. Turn on Screen Recording before you record meetings, then reopen Transcripted. Add Calendar later if you want meeting prompts."
    }

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
            screenRecordingError,
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
            combinedPermissionsError,
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
            quickStartCopy,
            "quick-start copy should reflect the current meeting-audio permission path"
        )
        assertEqual(
            MeetingRecordingStartGate.optionalPermissionsFootnote,
            optionalPermissionsCopy,
            "onboarding footnote should match the current meeting recording requirement"
        )
    }
}
