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
        let audioFormatReadTimeout = SentryEventPolicy.policy(
            forEngine: "parakeet",
            event: "audio_format_read_timeout"
        )
        let audioEngineStartTimeout = SentryEventPolicy.policy(
            forEngine: "parakeet",
            event: "audio_engine_start_timeout"
        )
        let zombieEngineRecoveryFailed = SentryEventPolicy.policy(
            forEngine: "parakeet",
            event: "zombie_engine_recovery_failed"
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
        let meetingTranscriptFailed = SentryEventPolicy.policy(
            forEngine: "meeting",
            event: "meeting_transcript_failed"
        )
        let meetingTranscriptSkipped = SentryEventPolicy.policy(
            forEngine: "meeting",
            event: "meeting_transcript_skipped"
        )
        let speakerFinalizationFailed = SentryEventPolicy.policy(
            forEngine: "meeting",
            event: "speaker_finalization_failed"
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
        let importFailed = SentryEventPolicy.policy(
            forEngine: "meeting",
            event: "meeting_file_import_failed"
        )

        assertEqual(transcriptionFailure?.summary, "Speech transcription failed.", "transcription failure should use the normalized summary")
        assertNil(uncleanShutdown, "unclean shutdown markers should stay local and analytics-only")
        assertEqual(sessionStall?.summary, "Transcripted detected a stalled runtime session.", "session stalls should be visible in Sentry")
        assertEqual(hotkeyFailure?.summary, "Transcripted could not register a keyboard shortcut.", "capture failure should stay allowlisted")
        assertEqual(audioStartFailure?.summary, "Speech audio engine failed to start.", "audio-start failures should stay allowlisted with a privacy-safe summary")
        assertEqual(audioFormatReadTimeout?.summary, "Speech audio format readiness timed out.", "audio-format readiness timeouts should be visible in Sentry")
        assertEqual(audioEngineStartTimeout?.summary, "Speech audio engine start timed out.", "audio start timeouts should be visible in Sentry")
        assertEqual(zombieEngineRecoveryFailed?.summary, "Speech engine zombie-state recovery failed.", "zombie recovery failures should be visible in Sentry")
        assertEqual(microphoneStartTimeout?.summary, "Dictation microphone start timed out.", "microphone start timeouts should be visible in Sentry without raw device names")
        assertEqual(deviceRecoveryTimeout?.summary, "Speech engine device-change recovery timed out.", "device recovery timeouts should be visible in Sentry with privacy-safe route context")
        assertEqual(recordingInterrupted?.summary, "Dictation recording was interrupted by audio device recovery.", "recording interruptions should be visible in Sentry with privacy-safe route context")
        assertEqual(meetingStartFailed?.summary, "Meeting recording could not start.", "meeting start failures should be visible without raw device names")
        assertEqual(meetingCaptureDegraded?.summary, "Meeting capture health degraded.", "degraded meeting capture should be visible without raw device names")
        assertEqual(meetingStopTimeout?.summary, "Meeting recording stop timed out.", "stop timeouts should be visible without raw device names")
        assertEqual(meetingTranscriptFailed?.summary, "Meeting transcription failed.", "meeting transcript failures should be visible with sanitized context")
        assertNil(meetingTranscriptSkipped, "expected empty/no-speech meeting outcomes should stay out of Sentry")
        assertEqual(speakerFinalizationFailed?.summary, "Meeting speaker naming finalization failed.", "speaker finalization failures should not masquerade as full transcript failures")
        assertEqual(modelInitFailure?.summary, "Speech model initialization failed.", "model-init failures should stay allowlisted with a privacy-safe summary")
        assertEqual(onboardingStartFailure?.summary, "Onboarding could not start first dictation.", "onboarding start wiring failures should be visible without clickstream data")
        assertEqual(onboardingStopFailure?.summary, "Onboarding could not stop first dictation.", "onboarding stop wiring failures should be visible without clickstream data")
        assertNil(unknown, "unknown events should stay local-only by default")
        assertNil(importFailed, "file import preparation failures should stay local/analytics-only unless explicitly allowlisted")
    }

    runSuite("SentryEventPolicy diagnosticTags keeps timeout triage searchable and safe") {
        let tags = SentryEventPolicy.diagnosticTags(
            forEngine: "dictation",
            event: "microphone_start_timeout",
            context: [
                "audio_device": "Justin's AirPods",
                "default_input_class": "bluetooth",
                "default_output_class": "bluetooth",
                "failure_kind": "microphone_start_timeout",
                "forced_readiness_recoveries": "2",
                "format_ready": "false",
                "hfp_suspected": "false",
                "input_device_class": "bluetooth",
                "output_device_class": "bluetooth",
                "readiness_refreshes": "8",
                "recovering": "false",
                "recovery_start_attempts": "2",
                "route_shape": "bluetooth_input_to_built_in_output",
                "sample_flow_started": "false",
                "selected_input_class": "built_in",
                "selection_overrode_default": "true",
                "selection_reason": "preferredBuiltInForBluetoothHeadset",
                "start_attempts": "4",
                "stt_model": "parakeet-tdt-v3",
                "transcript_text": "private words",
                "trigger": "physical_key",
                "wait_ms": "6000",
            ]
        )

        assertEqual(tags["default_input_class"], "bluetooth", "default input class should be queryable")
        assertEqual(tags["default_output_class"], "bluetooth", "default output class should be queryable")
        assertEqual(tags["failure_kind"], "microphone_start_timeout", "failure kind should be queryable")
        assertEqual(tags["format_ready"], "false", "format readiness should be queryable")
        assertEqual(tags["hfp_suspected"], "false", "HFP suspicion should be queryable")
        assertEqual(tags["recovering"], "false", "recovery state should be queryable")
        assertEqual(tags["input_device_class"], "bluetooth", "coarse device class should be queryable")
        assertEqual(tags["output_device_class"], "bluetooth", "coarse output class should be queryable")
        assertEqual(tags["route_shape"], "bluetooth_input_to_built_in_output", "coarse route shape should be queryable")
        assertEqual(tags["sample_flow_started"], "false", "sample-flow state should be queryable")
        assertEqual(tags["selected_input_class"], "built_in", "selected input class should be queryable")
        assertEqual(tags["selection_overrode_default"], "true", "input override state should be queryable")
        assertEqual(tags["selection_reason"], "preferredBuiltInForBluetoothHeadset", "selection reason should be queryable")
        assertEqual(tags["start_attempts"], "4", "bounded retry count should be queryable")
        assertEqual(tags["stt_model"], "parakeet-tdt-v3", "selected STT model should be queryable")
        assertEqual(tags["readiness_refreshes"], "8", "readiness refresh count should be queryable")
        assertEqual(tags["recovery_start_attempts"], "2", "recovery start count should be queryable")
        assertEqual(tags["forced_readiness_recoveries"], "2", "forced recovery count should be queryable")
        assertEqual(tags["trigger"], "physical_key", "coarse trigger should be queryable")
        assertEqual(tags["wait_bucket"], "lt_10s", "raw wait time should be bucketed")
        assertNil(tags["audio_device"], "raw device names should stay out of Sentry tags")
        assertNil(tags["transcript_text"], "transcript text should stay out of Sentry tags")
    }

    runSuite("SentryEventPolicy diagnosticTags keeps meeting failure triage searchable") {
        let tags = SentryEventPolicy.diagnosticTags(
            forEngine: "meeting",
            event: "meeting_transcript_failed",
            context: [
                "failure_kind": "transcription_inference_failed",
                "input_device_class": "usb",
                "queue_depth_bucket": "zero",
                "system_status": "healthy",
                "trigger": "hotkey",
            ]
        )

        assertEqual(tags["failure_kind"], "transcription_inference_failed", "meeting failure kind should be searchable")
        assertEqual(tags["input_device_class"], "usb", "coarse input class should be searchable")
        assertEqual(tags["queue_depth_bucket"], "zero", "queue depth should stay bucketed")
        assertEqual(tags["system_status"], "healthy", "system capture status should be queryable")
        assertEqual(tags["trigger"], "hotkey", "trigger should be queryable")
    }

    runSuite("SentryEventPolicy diagnosticTags ignores skipped meeting transcripts") {
        let tags = SentryEventPolicy.diagnosticTags(
            forEngine: "meeting",
            event: "meeting_transcript_skipped",
            context: [
                "failure_kind": "no_speech_detected",
                "trigger": "menu",
            ]
        )

        assertTrue(tags.isEmpty, "skipped empty/no-speech meeting outcomes should not create Sentry tags")
    }

    runSuite("SentryEventPolicy diagnosticTags keeps speaker finalization failure separate") {
        let tags = SentryEventPolicy.diagnosticTags(
            forEngine: "meeting",
            event: "speaker_finalization_failed",
            context: [
                "failure_kind": "speaker_finalization_failed",
                "queue_depth_bucket": "zero",
                "session_stage": "save",
                "speaker_name": "Private Person",
                "trigger": "unknown",
            ]
        )

        assertEqual(tags["failure_kind"], "speaker_finalization_failed", "speaker finalization should keep its stable failure kind")
        assertEqual(tags["queue_depth_bucket"], "zero", "queue depth should stay bucketed")
        assertEqual(tags["session_stage"], "save", "save-stage failures should be queryable separately from transcription failures")
        assertEqual(tags["trigger"], "unknown", "trigger should stay queryable")
        assertNil(tags["speaker_name"], "speaker names must stay out of Sentry tags")
    }

    runSuite("SentryEventPolicy diagnosticTags keeps issue 500 volume-drop flags searchable") {
        let tags = SentryEventPolicy.diagnosticTags(
            forEngine: "meeting",
            event: "recording_capture_degraded",
            context: [
                "default_output_volume_dropped": "true",
                "default_system_output_volume_dropped": "true",
                "default_input_volume_dropped": "false",
                "output_ducking_detected": "true",
                "quiet_mic_recovered": "false",
                "quiet_mic_unrecovered": "true",
                "system_status": "failed",
            ]
        )

        assertEqual(tags["default_output_volume_dropped"], "true", "output volume drops should be queryable in APPLE-MACOS-1B")
        assertEqual(tags["default_system_output_volume_dropped"], "true", "system output drops should be queryable in APPLE-MACOS-1B")
        assertEqual(tags["default_input_volume_dropped"], "false", "input volume state should stay available as a control")
        assertEqual(tags["output_ducking_detected"], "true", "ducking classification should stay queryable")
        assertEqual(tags["quiet_mic_recovered"], "false", "quiet mic recovery state should stay queryable")
        assertEqual(tags["quiet_mic_unrecovered"], "true", "unrecovered quiet mic state should stay queryable")
        assertEqual(tags["system_status"], "failed", "existing meeting health tags should still survive")
    }

    runSuite("SentryEventPolicy diagnosticTags ignores non-allowlisted events") {
        let tags = SentryEventPolicy.diagnosticTags(
            forEngine: "dictation",
            event: "dictation_export_failed",
            context: ["format_ready": "false"]
        )

        assertTrue(tags.isEmpty, "local-only events should not get Sentry diagnostic tags")
    }
}
