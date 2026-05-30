import Foundation

struct SentryEventPolicy: Equatable {
    let engine: String
    let event: String
    let summary: String

    static func policy(forEngine engine: String, event: String) -> SentryEventPolicy? {
        allowedPolicies["\(engine).\(event)"]
    }

    static func diagnosticTags(
        forEngine engine: String,
        event: String,
        context: [String: String]
    ) -> [String: String] {
        guard policy(forEngine: engine, event: event) != nil else { return [:] }

        var tags = context.filter { allowedDiagnosticTagKeys.contains($0.key) }
        if let waitBucket = durationBucket(fromMilliseconds: context["wait_ms"]) {
            tags["wait_bucket"] = waitBucket
        }

        return SentryPayloadSanitizer.sanitizeTags(tags)
    }

    private static let allowedDiagnosticTagKeys: Set<String> = [
        "attenuation_kind",
        "capture_quality",
        "captured_input_volume_changed",
        "captured_input_volume_dropped",
        "default_input_class",
        "default_input_volume_changed",
        "default_input_volume_dropped",
        "default_output_class",
        "default_output_volume_changed",
        "default_output_volume_dropped",
        "default_system_output_volume_changed",
        "default_system_output_volume_dropped",
        "duration_bucket",
        "failure_kind",
        "forced_readiness_recoveries",
        "format_ready",
        "gap_count_bucket",
        "hfp_suspected",
        "input_channels",
        "input_device_class",
        "input_rate_hz",
        "input_volume_scalar_available",
        "output_ducking_detected",
        "output_channels",
        "output_device_class",
        "output_rate_hz",
        "quiet_mic_recovered",
        "quiet_mic_unrecovered",
        "queue_depth_bucket",
        "readiness_refreshes",
        "recovering",
        "recovery_start_attempts",
        "route_change_count_bucket",
        "route_shape",
        "sample_flow_started",
        "selected_input_class",
        "selection_overrode_default",
        "selection_reason",
        "session_active",
        "session_kind",
        "session_stage",
        "stall_kind",
        "stall_stage",
        "start_attempts",
        "stt_model",
        "system_status",
        "trigger",
        "was_recording",
    ]

    private static func durationBucket(fromMilliseconds value: String?) -> String? {
        guard let value,
              let milliseconds = Double(value) else {
            return nil
        }
        return AnalyticsReporter.durationBucket(seconds: milliseconds / 1000)
    }

    private static let allowedPolicies: [String: SentryEventPolicy] = [
        "app.session_stall_detected": .init(
            engine: "app",
            event: "session_stall_detected",
            summary: "Transcripted detected a stalled runtime session."
        ),
        "parakeet.model_init_failed": .init(
            engine: "parakeet",
            event: "model_init_failed",
            summary: "Speech model initialization failed."
        ),
        "parakeet.prewarm_failed": .init(
            engine: "parakeet",
            event: "prewarm_failed",
            summary: "Speech engine prewarm failed."
        ),
        "parakeet.device_change_rewarm_failed": .init(
            engine: "parakeet",
            event: "device_change_rewarm_failed",
            summary: "Speech engine failed to rewarm after an audio device change."
        ),
        "parakeet.mic_not_authorized": .init(
            engine: "parakeet",
            event: "mic_not_authorized",
            summary: "Microphone permission was not authorized."
        ),
        "parakeet.resync_engine_failed": .init(
            engine: "parakeet",
            event: "resync_engine_failed",
            summary: "Speech engine failed while resyncing the audio graph."
        ),
        "parakeet.zero_sample_rate": .init(
            engine: "parakeet",
            event: "zero_sample_rate",
            summary: "Audio hardware reported an invalid sample rate."
        ),
        "parakeet.audio_format_failed": .init(
            engine: "parakeet",
            event: "audio_format_failed",
            summary: "Transcripted could not create the expected audio format."
        ),
        "parakeet.audio_format_read_timeout": .init(
            engine: "parakeet",
            event: "audio_format_read_timeout",
            summary: "Speech audio format readiness timed out."
        ),
        "parakeet.audio_engine_start_failed": .init(
            engine: "parakeet",
            event: "audio_engine_start_failed",
            summary: "Speech audio engine failed to start."
        ),
        "parakeet.audio_engine_start_timeout": .init(
            engine: "parakeet",
            event: "audio_engine_start_timeout",
            summary: "Speech audio engine start timed out."
        ),
        "parakeet.zombie_engine_recovery_failed": .init(
            engine: "parakeet",
            event: "zombie_engine_recovery_failed",
            summary: "Speech engine zombie-state recovery failed."
        ),
        "parakeet.asr_manager_unavailable": .init(
            engine: "parakeet",
            event: "asr_manager_unavailable",
            summary: "Speech transcription manager was unavailable."
        ),
        "parakeet.transcription_failed": .init(
            engine: "parakeet",
            event: "transcription_failed",
            summary: "Speech transcription failed."
        ),
        "dictation.microphone_start_timeout": .init(
            engine: "dictation",
            event: "microphone_start_timeout",
            summary: "Dictation microphone start timed out."
        ),
        "parakeet.device_change_recovery_timeout": .init(
            engine: "parakeet",
            event: "device_change_recovery_timeout",
            summary: "Speech engine device-change recovery timed out."
        ),
        "parakeet.recording_interrupted": .init(
            engine: "parakeet",
            event: "recording_interrupted",
            summary: "Dictation recording was interrupted by audio device recovery."
        ),
        "meeting.meeting_start_failed": .init(
            engine: "meeting",
            event: "meeting_start_failed",
            summary: "Meeting recording could not start."
        ),
        "meeting.recording_capture_degraded": .init(
            engine: "meeting",
            event: "recording_capture_degraded",
            summary: "Meeting capture health degraded."
        ),
        "meeting.recording_stop_timeout": .init(
            engine: "meeting",
            event: "recording_stop_timeout",
            summary: "Meeting recording stop timed out."
        ),
        "meeting.meeting_transcript_failed": .init(
            engine: "meeting",
            event: "meeting_transcript_failed",
            summary: "Meeting transcription failed."
        ),
        "meeting.speaker_finalization_failed": .init(
            engine: "meeting",
            event: "speaker_finalization_failed",
            summary: "Meeting speaker naming finalization failed."
        ),
        "onboarding.first_dictation_start_failed": .init(
            engine: "onboarding",
            event: "first_dictation_start_failed",
            summary: "Onboarding could not start first dictation."
        ),
        "onboarding.first_dictation_stop_failed": .init(
            engine: "onboarding",
            event: "first_dictation_stop_failed",
            summary: "Onboarding could not stop first dictation."
        ),
        "capture.hotkey_register_failed": .init(
            engine: "capture",
            event: "hotkey_register_failed",
            summary: "Transcripted could not register a keyboard shortcut."
        ),
        "overlay.cgevent_create_failed": .init(
            engine: "overlay",
            event: "cgevent_create_failed",
            summary: "Transcripted could not create the paste event."
        ),
    ]
}
