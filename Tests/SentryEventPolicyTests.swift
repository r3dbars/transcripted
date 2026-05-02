import Foundation

func testSentryEventPolicy() {
    runSuite("SentryEventPolicy returns policies only for explicitly allowlisted events") {
        let transcriptionFailure = SentryEventPolicy.policy(
            forEngine: "parakeet",
            event: "transcription_failed"
        )
        let uncleanShutdown = SentryEventPolicy.policy(
            forEngine: "app",
            event: "unclean_shutdown_detected"
        )
        let sessionStall = SentryEventPolicy.policy(
            forEngine: "app",
            event: "session_stall_detected"
        )
        let hotkeyFailure = SentryEventPolicy.policy(
            forEngine: "capture",
            event: "hotkey_register_failed"
        )
        let audioStartFailure = SentryEventPolicy.policy(
            forEngine: "parakeet",
            event: "audio_engine_start_failed"
        )
        let microphoneStartTimeout = SentryEventPolicy.policy(
            forEngine: "dictation",
            event: "microphone_start_timeout"
        )
        let deviceRecoveryTimeout = SentryEventPolicy.policy(
            forEngine: "parakeet",
            event: "device_change_recovery_timeout"
        )
        let recordingInterrupted = SentryEventPolicy.policy(
            forEngine: "parakeet",
            event: "recording_interrupted"
        )
        let meetingStartFailed = SentryEventPolicy.policy(
            forEngine: "meeting",
            event: "meeting_start_failed"
        )
        let meetingCaptureDegraded = SentryEventPolicy.policy(
            forEngine: "meeting",
            event: "recording_capture_degraded"
        )
        let meetingStopTimeout = SentryEventPolicy.policy(
            forEngine: "meeting",
            event: "recording_stop_timeout"
        )
        let modelInitFailure = SentryEventPolicy.policy(
            forEngine: "parakeet",
            event: "model_init_failed"
        )
        let onboardingStartFailure = SentryEventPolicy.policy(
            forEngine: "onboarding",
            event: "first_dictation_start_failed"
        )
        let onboardingStopFailure = SentryEventPolicy.policy(
            forEngine: "onboarding",
            event: "first_dictation_stop_failed"
        )
        let unknown = SentryEventPolicy.policy(
            forEngine: "dictation",
            event: "dictation_export_failed"
        )

        assertEqual(transcriptionFailure?.summary, "Speech transcription failed.", "transcription failure should use the normalized summary")
        assertEqual(uncleanShutdown?.summary, "Previous app session did not shut down cleanly.", "unclean shutdown reports should be visible in Sentry")
        assertEqual(sessionStall?.summary, "Transcripted detected a stalled runtime session.", "session stalls should be visible in Sentry")
        assertEqual(hotkeyFailure?.summary, "Transcripted could not register a keyboard shortcut.", "capture failure should stay allowlisted")
        assertEqual(audioStartFailure?.summary, "Speech audio engine failed to start.", "audio-start failures should stay allowlisted with a privacy-safe summary")
        assertEqual(microphoneStartTimeout?.summary, "Dictation microphone start timed out.", "microphone start timeouts should be visible in Sentry without raw device names")
        assertEqual(deviceRecoveryTimeout?.summary, "Speech engine device-change recovery timed out.", "device recovery timeouts should be visible in Sentry with privacy-safe route context")
        assertEqual(recordingInterrupted?.summary, "Dictation recording was interrupted by audio device recovery.", "recording interruptions should be visible in Sentry with privacy-safe route context")
        assertEqual(meetingStartFailed?.summary, "Meeting recording could not start.", "meeting start failures should be visible without raw device names")
        assertEqual(meetingCaptureDegraded?.summary, "Meeting capture health degraded.", "degraded meeting capture should be visible without raw device names")
        assertEqual(meetingStopTimeout?.summary, "Meeting recording stop timed out.", "stop timeouts should be visible without raw device names")
        assertEqual(modelInitFailure?.summary, "Speech model initialization failed.", "model-init failures should stay allowlisted with a privacy-safe summary")
        assertEqual(onboardingStartFailure?.summary, "Onboarding could not start first dictation.", "onboarding start wiring failures should be visible without clickstream data")
        assertEqual(onboardingStopFailure?.summary, "Onboarding could not stop first dictation.", "onboarding stop wiring failures should be visible without clickstream data")
        assertNil(unknown, "unknown events should stay local-only by default")
    }
}
