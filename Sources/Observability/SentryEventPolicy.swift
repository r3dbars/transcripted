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

        var tags = context.filter { allowedDiagnosticTagKeys.union(TelemetryContext.keys).contains($0.key) }
        if let waitBucket = AnalyticsReporter.durationBucket(fromMilliseconds: context["wait_ms"]) {
            tags["wait_bucket"] = waitBucket
        }
        // Start-path timings use `latencyBucket`, not `durationBucket`. The
        // latter puts everything under ten seconds in one bucket, and the
        // whole question these answer (issue #1743) is whether a pending start
        // had been running for a hundred milliseconds or for seconds.
        if let pendingBucket = AnalyticsReporter.latencyBucket(fromMilliseconds: context["pending_for_ms"]) {
            tags["pending_bucket"] = pendingBucket
        }
        if let stagePendingBucket = AnalyticsReporter.latencyBucket(
            fromMilliseconds: context["stage_pending_for_ms"]
        ) {
            tags["stage_pending_bucket"] = stagePendingBucket
        }

        // Reasons must be codes, never a shortened excerpt of a raw error.
        if let reason = tags["reason"], PayloadSanitizationCore.category(reason) == nil {
            tags["reason"] = "unknown"
        }

        return SentryPayloadSanitizer.sanitizeTags(tags)
    }

    private static let allowedDiagnosticTagKeys: Set<String> = [
        "attenuation_kind",
        "app_active",
        "buffer_success_bucket",
        "capture_outcome",
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
        "delivery",
        "failure_kind",
        "forced_readiness_recoveries",
        "format_ready",
        "gap_count_bucket",
        "hfp_suspected",
        "input_channels",
        "input_device_class",
        "input_rate_hz",
        "input_volume_scalar_available",
        "mic_boost_prompt",
        "mic_file_available",
        "output_ducking_detected",
        "pending_stage",
        "capture_health_scope",
        "cross_app_capture_status",
        "output_ducking_measurement",
        "output_channels",
        "output_device_class",
        "output_rate_hz",
        "quiet_mic_recovered",
        "quiet_mic_unrecovered",
        "quality_reason",
        "queue_depth_bucket",
        "reason",
        "readiness_refreshes",
        "recovering",
        "recovery_start_attempts",
        "result",
        "route_change_count_bucket",
        "route_stability_warning",
        "route_shape",
        "sample_flow_started",
        "selected_input_class",
        "selection_overrode_default",
        "selection_reason",
        "shortcut_mode",
        "stabilization_attempt_bucket",
        "stabilization_outcome",
        "session_active",
        "session_kind",
        "session_stage",
        "stall_kind",
        "stall_stage",
        "stage",
        "start_attempts",
        "start_failure_stage",
        "start_plan",
        "stt_model",
        "stop_timed_out",
        "system_file_available",
        "system_failed",
        "system_stream_present",
        "system_status",
        "trigger",
        "voice_processing",
        "voice_processing_active",
        "voice_processing_start_fallback",
        "was_recording",
    ]

    private static let allowedPolicies: [String: SentryEventPolicy] = [
        "meeting.meeting_capture_stopped_under_controller": .init(
            engine: "meeting",
            event: "meeting_capture_stopped_under_controller",
            summary: "Meeting recording stopped unexpectedly before completion."
        ),
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
        "parakeet.model_download_stalled": .init(
            engine: "parakeet",
            event: "model_download_stalled",
            summary: "Speech model download stopped making progress."
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
        "parakeet.audio_engine_work_circuit_open": .init(
            engine: "parakeet",
            event: "audio_engine_work_circuit_open",
            summary: "Speech audio engine start was blocked by a prior timed operation."
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
        "parakeet.audio_engine_rebuild_churn_detected": .init(
            engine: "parakeet",
            event: "audio_engine_rebuild_churn_detected",
            summary: "Speech audio engine entered a repeated rebuild loop."
        ),
        "parakeet.audio_engine_retirement_limit_reached": .init(
            engine: "parakeet",
            event: "audio_engine_retirement_limit_reached",
            summary: "Speech audio engine recovery reached its safety limit."
        ),
        "dictation.microphone_start_timeout": .init(
            engine: "dictation",
            event: "microphone_start_timeout",
            summary: "Dictation microphone start timed out."
        ),
        // The sibling of the one above, and the one behind the error users
        // actually report (issue #1743): their own hotkey ended a session
        // whose microphone start had not landed. Same user-visible outcome —
        // they asked to dictate and got an error instead — so it is reported
        // off-device on the same terms. Its diagnostic tags are the trigger,
        // the shortcut mode, which start stage was pending, whether the app
        // was frontmost, and two bucketed durations. No transcript, path,
        // device name or title, so `SentryPayloadSanitizer` needs no change.
        "dictation.dictation_cancelled_before_microphone_ready": .init(
            engine: "dictation",
            event: "dictation_cancelled_before_microphone_ready",
            summary: "Dictation ended before the microphone finished opening."
        ),
        "dictation.dictation_stopped_audio_persistence_failed": .init(
            engine: "dictation",
            event: "dictation_stopped_audio_persistence_failed",
            summary: "Stopped dictation audio could not be preserved for recovery."
        ),
        "dictation.dictation_delivery_completed": .init(
            engine: "dictation",
            event: "dictation_delivery_completed",
            summary: "Dictation delivery failed."
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
        "meeting.recording_stop_timeout": .init(
            engine: "meeting",
            event: "recording_stop_timeout",
            summary: "Meeting recording stop timed out."
        ),
        "meeting.meeting_recording_missing_audio": .init(
            engine: "meeting",
            event: "meeting_recording_missing_audio",
            summary: "Meeting recording stopped without usable audio."
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
        "overlay.cgevent_create_failed": .init(
            engine: "overlay",
            event: "cgevent_create_failed",
            summary: "Transcripted could not create the paste event."
        ),
    ]
}
