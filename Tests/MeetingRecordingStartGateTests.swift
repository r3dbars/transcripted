import Foundation

func testMeetingRecordingStartGate() {
    let systemAudioRecordingError = "Turn on System Audio Recording before recording a meeting."
    let combinedPermissionsError = "Turn on Microphone and System Audio Recording before recording a meeting."
    let quickStartCopy = "Turn on System Audio Recording so Transcripted can capture the other side of Zoom, Meet, and similar apps."
    let optionalPermissionsCopy = "Calendar is optional. Add it later if you want Transcripted to spot upcoming meetings and offer a record prompt."

    runSuite("MeetingRecordingStartGate.evaluate — allows meeting capture when required permissions exist") {
        let decision = MeetingRecordingStartGate.evaluate(
            microphoneGranted: true,
            systemAudioRecordingGranted: true
        )

        assertEqual(decision, .allowed, "meeting capture should start normally when both permissions are granted")
    }

    runSuite("MeetingRecordingStartGate.evaluate — blocks meeting capture when System Audio Recording is missing") {
        let decision = MeetingRecordingStartGate.evaluate(
            microphoneGranted: true,
            systemAudioRecordingGranted: false
        )

        assertFalse(decision.canStart, "meeting capture should fail fast when System Audio Recording is missing")
        assertEqual(
            decision.errorMessage,
            systemAudioRecordingError,
            "system-audio failures should tell the user exactly what to fix"
        )
        assertEqual(decision.failureReason, "system_audio_recording", "system-audio failures should stay classified for diagnostics")
        assertEqual(decision.missingPermissions, ["system_audio_recording"], "missing permission list should stay explicit")
    }

    runSuite("MeetingRecordingStartGate.evaluate — blocks meeting capture when both permissions are missing") {
        let decision = MeetingRecordingStartGate.evaluate(
            microphoneGranted: false,
            systemAudioRecordingGranted: false
        )

        assertFalse(decision.canStart, "meeting capture should not start when both required permissions are missing")
        assertEqual(
            decision.errorMessage,
            combinedPermissionsError,
            "combined permission failures should mention both missing requirements"
        )
        assertEqual(
            decision.missingPermissions,
            ["microphone", "system_audio_recording"],
            "combined permission failures should preserve a stable missing-permission list"
        )
    }

    runSuite("MeetingPermissionCopy — keeps system-audio copy aligned with the meeting gate") {
        assertEqual(
            MeetingRecordingStartGate.systemAudioRecordingSummary,
            "Needed so Transcripted can capture the other side of calls, videos, and other meeting audio.",
            "shared summary copy should explain why system audio recording matters"
        )
        assertEqual(
            MeetingRecordingStartGate.systemAudioRecordingQuickStart,
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
