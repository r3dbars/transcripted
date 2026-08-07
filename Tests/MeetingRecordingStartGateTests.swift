import Foundation

func testMeetingRecordingStartGate() {
    let systemAudioRecordingError = "Turn on System Audio Recording before recording a meeting."
    let combinedPermissionsError = "Turn on Microphone and System Audio Recording before recording a meeting."
    let quickStartCopy = "Transcripted will ask for System Audio Recording the first time you record a meeting so it can capture the other side of Zoom, Meet, and similar apps."
    let optionalPermissionsCopy = "System Audio Recording is requested when you record your first meeting. Calendar is optional if you want Transcripted to spot upcoming meetings and offer a record prompt."

    runSuite("MeetingRecordingStartGate.evaluate — allows meeting capture when required permissions exist") {
        let decision = MeetingRecordingStartGate.evaluate(
            microphoneGranted: true,
            systemAudioRecordingGranted: true
        )

        assertEqual(decision, .allowed, "meeting capture should start normally when both permissions are granted")
        assertFalse(
            decision.systemAudioPermissionCheckWasInconclusive,
            "the ordinary granted path should not carry an inconclusive probe marker"
        )
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

    runSuite("MeetingRecordingStartGate.evaluate — blocks meeting capture when Microphone is missing") {
        let decision = MeetingRecordingStartGate.evaluate(
            microphoneGranted: false,
            systemAudioRecordingGranted: true
        )

        assertFalse(decision.canStart, "meeting capture should fail fast when Microphone is missing")
        assertEqual(
            decision.errorMessage,
            "Turn on Microphone access in System Settings before recording a meeting.",
            "microphone failures should tell the user exactly what to fix"
        )
        assertEqual(decision.failureReason, "microphone", "microphone failures should stay classified for diagnostics")
        assertEqual(decision.missingPermissions, ["microphone"], "missing permission list should stay explicit")
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

    runSuite("MeetingRecordingStartGate.systemAudioVerificationUnavailable — does not claim permission was denied") {
        let decision = MeetingRecordingStartGate.systemAudioVerificationUnavailable()

        assertFalse(decision.canStart, "an unverified first-run permission state should not claim capture is ready")
        assertEqual(
            decision.failureReason,
            "system_audio_recording_check_unavailable",
            "probe transport failures should stay distinct from a missing permission"
        )
        assertEqual(
            decision.missingPermissions,
            [],
            "an inconclusive probe must not report a permission as missing"
        )
        assertTrue(
            decision.errorMessage?.contains("couldn't verify System Audio Recording") == true,
            "user copy should describe an inconclusive macOS check rather than telling them access is off"
        )
        assertTrue(
            decision.systemAudioPermissionCheckWasInconclusive,
            "the blocked decision should retain the probe classification for diagnostics and later copy mapping"
        )
    }

    runSuite("MeetingRecordingStartGate.captureFailureMessage — removes false permission blame after an inconclusive cached-grant check") {
        let permissionLooking = "System audio unavailable — can only record your microphone. Go to System Settings and enable System Audio Recording."
        let mapped = MeetingRecordingStartGate.captureFailureMessage(
            permissionLooking,
            systemAudioPermissionCheckWasInconclusive: true
        )

        assertTrue(mapped.contains("inconclusive access check"), "capture copy should explain what was actually observed")
        assertFalse(mapped.contains("enable System Audio Recording"), "capture copy must not claim access is off")
        assertEqual(
            MeetingStartFailureClassifier.kind(from: mapped),
            "system_stream_unavailable",
            "the mapped failure should stay a stream failure rather than becoming a permission denial"
        )
    }

    runSuite("MeetingRecordingStartGate.captureFailureMessage — preserves precise failures") {
        let timeout = "System audio capture did not become ready in time."
        assertEqual(
            MeetingRecordingStartGate.captureFailureMessage(
                timeout,
                systemAudioPermissionCheckWasInconclusive: true
            ),
            timeout,
            "an accurate readiness timeout should not be rewritten"
        )
        let explicitDenial = "Turn on System Audio Recording before recording a meeting."
        assertEqual(
            MeetingRecordingStartGate.captureFailureMessage(
                explicitDenial,
                systemAudioPermissionCheckWasInconclusive: false
            ),
            explicitDenial,
            "an explicitly denied preflight should keep its direct recovery copy"
        )
        assertEqual(
            MeetingRecordingStartGate.captureFailureMessage(
                explicitDenial,
                systemAudioPermissionCheckWasInconclusive: true,
                explicitSystemAudioPermissionDenialObserved: true
            ),
            explicitDenial,
            "a typed denial from capture must outrank an earlier inconclusive probe"
        )
    }

    runSuite("MeetingPermissionCopy — keeps system-audio copy aligned with the meeting gate") {
        assertEqual(
            MeetingRecordingStartGate.systemAudioRecordingSummary,
            "For the other side of calls, videos, and meetings.",
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
