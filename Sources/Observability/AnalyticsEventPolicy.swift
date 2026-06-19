import Foundation

struct AnalyticsEventPolicy: Equatable {
    let name: String
    let allowedProperties: Set<String>

    static func policy(forEvent event: String) -> AnalyticsEventPolicy? {
        allowedPolicies[event]
    }

    /// All allowlisted analytics event names, sorted. Exposed so tests can assert
    /// source-vs-docs parity against the compiled policy table instead of parsing this file's text.
    static var allEventNames: [String] {
        allowedPolicies.keys.sorted()
    }

    /// All allowlisted analytics policies, sorted by event name. Tests use this
    /// to keep the public taxonomy doc in lockstep with the compiled allowlist.
    static var allPolicies: [AnalyticsEventPolicy] {
        allowedPolicies.keys.sorted().compactMap { allowedPolicies[$0] }
    }

    private static let meetingCaptureDiagnosticProperties: Set<String> = [
        "attenuation_kind",
        "buffer_success_bucket",
        "captured_input_volume_before",
        "captured_input_volume_changed",
        "captured_input_volume_dropped",
        "captured_input_volume_during",
        "default_input_volume_after",
        "default_input_volume_before",
        "default_input_volume_changed",
        "default_input_volume_dropped",
        "default_input_volume_during",
        "default_output_volume_after",
        "default_output_volume_before",
        "default_output_volume_changed",
        "default_output_volume_dropped",
        "default_output_volume_during",
        "default_system_output_volume_after",
        "default_system_output_volume_before",
        "default_system_output_volume_changed",
        "default_system_output_volume_dropped",
        "default_system_output_volume_during",
        "gap_count_bucket",
        "input_channels",
        "input_device_class",
        "input_rate_hz",
        "input_volume_scalar_available",
        "mic_boost_prompt",
        "mic_processing",
        "mic_processed_peak",
        "mic_raw_peak",
        "mic_recovering",
        "output_ducking_detected",
        "output_device_class",
        "output_rate_hz",
        "quiet_mic_recovered",
        "quiet_mic_unrecovered",
        "realtime_agc",
        "recovery_attempt_bucket",
        "route_change_count_bucket",
        "system_backend",
        "system_channels",
        "system_peak",
        "system_failed",
        "system_output_device_class",
        "system_output_rate_hz",
        "system_rate_hz",
        "system_status",
        "voice_processing",
        "voice_processing_active",
    ]

    private static let dictationRouteDiagnosticProperties: Set<String> = [
        "default_input_class",
        "default_output_class",
        "format_ready",
        "hfp_suspected",
        "input_channels",
        "input_device_class",
        "input_rate_hz",
        "output_channels",
        "output_device_class",
        "output_rate_hz",
        "recovery_latency_bucket",
        "recovering",
        "route_shape",
        "sample_flow_started",
        "selection_overrode_default",
        "selection_reason",
        "selected_input_class",
        "was_recording",
    ]

    private static let runtimeDiagnosticProperties: Set<String> = [
        "app_version",
        "build_version",
        "duration_bucket",
        "format_ready",
        "heartbeat_age_bucket",
        "last_event",
        "os_major",
        "previous_clean_shutdown",
        "reason",
        "recovering",
        "session_active",
        "session_duration_bucket",
        "session_kind",
        "session_stage",
        "stall_kind",
        "stall_stage",
        "trigger",
    ]

    private static let activationArtifactActionProperties: Set<String> = [
        "action_kind",
        "artifact_age_bucket",
        "artifact_kind",
        "surface",
    ]

    private static let activationFirstArtifactProperties: Set<String> = [
        "artifact_kind",
        "duration_bucket",
        "surface",
        "trigger",
        "word_count_bucket",
    ]

    private static let activationAgentPromptActionProperties: Set<String> = [
        "action_kind",
        "agent_target",
        "artifact_kind",
        "prompt_kind",
        "result",
        "surface",
    ]

    private static let activationAgentSetupProperties: Set<String> = [
        "agent_target",
        "prior_status",
        "result",
        "setup_kind",
        "surface",
    ]

    private static let activationReturnProxyProperties: Set<String> = [
        "prior_artifact_kind",
        "proxy_kind",
        "return_window_bucket",
        "surface",
    ]

    private static let meetingPromptProperties: Set<String> = [
        "app_signal",
        "calendar_confidence",
        "call_state",
        "missing_permission",
        "prompt_reason",
        "provider",
        "route_ready",
        "source",
    ]

    private static let allowedPolicies: [String: AnalyticsEventPolicy] = [
        "app_launched": .init(
            name: "app_launched",
            allowedProperties: []
        ),
        "app_unclean_shutdown_detected": .init(
            name: "app_unclean_shutdown_detected",
            allowedProperties: runtimeDiagnosticProperties
        ),
        "app_session_stall_detected": .init(
            name: "app_session_stall_detected",
            allowedProperties: runtimeDiagnosticProperties
        ),
        "support_diagnostics_copied": .init(
            name: "support_diagnostics_copied",
            allowedProperties: []
        ),
        "support_diagnostic_event_sent": .init(
            name: "support_diagnostic_event_sent",
            allowedProperties: []
        ),
        "onboarding_shown": .init(
            name: "onboarding_shown",
            allowedProperties: [
                "analytics_available",
                "crash_reporting_available",
                "entrypoint",
                "has_target",
                "meeting_recording_ready",
                "mic_status",
                "model_state",
                "pasteback_status",
            ]
        ),
        "onboarding_step_viewed": .init(
            name: "onboarding_step_viewed",
            allowedProperties: [
                "flow_elapsed_bucket",
                "model_state",
                "step_id",
                "step_index",
            ]
        ),
        "onboarding_permission_cta_clicked": .init(
            name: "onboarding_permission_cta_clicked",
            allowedProperties: [
                "permission_kind",
                "prior_status",
                "required",
                "step_id",
            ]
        ),
        "onboarding_permission_status_changed": .init(
            name: "onboarding_permission_status_changed",
            allowedProperties: [
                "from_status",
                "permission_kind",
                "step_id",
                "to_status",
            ]
        ),
        "onboarding_model_state_changed": .init(
            name: "onboarding_model_state_changed",
            allowedProperties: [
                "from_status",
                "step_id",
                "to_status",
            ]
        ),
        "onboarding_primary_cta_clicked": .init(
            name: "onboarding_primary_cta_clicked",
            allowedProperties: [
                "cta",
                "cta_type",
                "flow_elapsed_bucket",
                "model_state",
                "step_elapsed_bucket",
                "step_id",
            ]
        ),
        "onboarding_first_dictation_started": .init(
            name: "onboarding_first_dictation_started",
            allowedProperties: [
                "model_state",
                "step_id",
            ]
        ),
        "onboarding_first_dictation_saved": .init(
            name: "onboarding_first_dictation_saved",
            allowedProperties: [
                "delivery",
                "step_id",
                "word_count_bucket",
            ]
        ),
        "onboarding_first_dictation_stop_clicked": .init(
            name: "onboarding_first_dictation_stop_clicked",
            allowedProperties: [
                "step_id",
            ]
        ),
        "onboarding_first_dictation_empty": .init(
            name: "onboarding_first_dictation_empty",
            allowedProperties: [
                "step_id",
            ]
        ),
        "onboarding_meeting_dry_run_clicked": .init(
            name: "onboarding_meeting_dry_run_clicked",
            allowedProperties: [
                "meeting_recording_ready",
                "step_id",
            ]
        ),
        "onboarding_agent_cta_clicked": .init(
            name: "onboarding_agent_cta_clicked",
            allowedProperties: [
                "agent_cta",
                "step_id",
            ]
        ),
        "onboarding_reporting_toggle_changed": .init(
            name: "onboarding_reporting_toggle_changed",
            allowedProperties: [
                "available",
                "enabled",
                "reporting_kind",
                "step_id",
            ]
        ),
        "onboarding_completed": .init(
            name: "onboarding_completed",
            allowedProperties: [
                "anonymous_usage_enabled",
                "calendar_status",
                "completion_flow",
                "crash_reporting_enabled",
                "first_dictation_saved",
                "flow_elapsed_bucket",
                "meeting_dry_run_completed",
                "meeting_recording_ready",
                "model_state",
                "step_id",
            ]
        ),
        "onboarding_dismissed": .init(
            name: "onboarding_dismissed",
            allowedProperties: [
                "first_dictation_saved",
                "flow_elapsed_bucket",
                "meeting_dry_run_completed",
                "model_state",
                "step_id",
                "step_index",
            ]
        ),
        "activation_artifact_action_clicked": .init(
            name: "activation_artifact_action_clicked",
            allowedProperties: activationArtifactActionProperties
        ),
        "activation_first_artifact_saved": .init(
            name: "activation_first_artifact_saved",
            allowedProperties: activationFirstArtifactProperties
        ),
        "activation_agent_prompt_action_clicked": .init(
            name: "activation_agent_prompt_action_clicked",
            allowedProperties: activationAgentPromptActionProperties
        ),
        "activation_agent_setup_cta_clicked": .init(
            name: "activation_agent_setup_cta_clicked",
            allowedProperties: activationAgentSetupProperties
        ),
        "activation_return_proxy_observed": .init(
            name: "activation_return_proxy_observed",
            allowedProperties: activationReturnProxyProperties
        ),
        "menu_bar_opened": .init(
            name: "menu_bar_opened",
            allowedProperties: [
                "dictation_ready",
                "entrypoint",
                "meeting_recording_ready",
                "model_state",
                "paste_available",
                "recent_meetings_available",
                "update_state",
            ]
        ),
        "menu_bar_action_clicked": .init(
            name: "menu_bar_action_clicked",
            allowedProperties: [
                "action_id",
                "dictation_ready",
                "meeting_recording_ready",
                "paste_available",
            ]
        ),
        "update_action_clicked": .init(
            name: "update_action_clicked",
            allowedProperties: [
                "action_id",
                "automatic_downloads_enabled",
                "state",
                "surface",
                "version",
            ]
        ),
        "update_setting_changed": .init(
            name: "update_setting_changed",
            allowedProperties: [
                "enabled",
                "setting_id",
            ]
        ),
        "update_check_finished": .init(
            name: "update_check_finished",
            allowedProperties: [
                "automatic_downloads_enabled",
                "failure_code",
                "failure_kind",
                "result",
                "state",
                "version",
            ]
        ),
        "update_download_started": .init(
            name: "update_download_started",
            allowedProperties: [
                "automatic_downloads_enabled",
                "state",
                "version",
            ]
        ),
        "update_download_finished": .init(
            name: "update_download_finished",
            allowedProperties: [
                "automatic_downloads_enabled",
                "failure_kind",
                "state",
                "version",
            ]
        ),
        "update_ready_to_install": .init(
            name: "update_ready_to_install",
            allowedProperties: [
                "automatic_downloads_enabled",
                "state",
                "version",
            ]
        ),
        "update_relaunching": .init(
            name: "update_relaunching",
            allowedProperties: [
                "version",
            ]
        ),
        "update_installed": .init(
            name: "update_installed",
            allowedProperties: [
                "previous_version",
                "version",
            ]
        ),
        "settings_opened": .init(
            name: "settings_opened",
            allowedProperties: [
                "page_id",
                "source",
            ]
        ),
        "settings_page_viewed": .init(
            name: "settings_page_viewed",
            allowedProperties: [
                "page_id",
                "source",
            ]
        ),
        "settings_action_clicked": .init(
            name: "settings_action_clicked",
            allowedProperties: [
                "action_id",
                "page_id",
            ]
        ),
        "settings_toggle_changed": .init(
            name: "settings_toggle_changed",
            allowedProperties: [
                "enabled",
                "page_id",
                "setting_id",
            ]
        ),
        "settings_permission_cta_clicked": .init(
            name: "settings_permission_cta_clicked",
            allowedProperties: [
                "page_id",
                "permission_kind",
                "prior_status",
            ]
        ),
        "settings_capture_library_changed": .init(
            name: "settings_capture_library_changed",
            allowedProperties: [
                "location_type",
                "page_id",
            ]
        ),
        "dictation_started": .init(
            name: "dictation_started",
            allowedProperties: dictationRouteDiagnosticProperties.union(Set([
                "trigger",
            ]))
        ),
        "dictation_start_failed": .init(
            name: "dictation_start_failed",
            allowedProperties: dictationRouteDiagnosticProperties.union(Set([
                "failure_kind",
                "start_attempt_bucket",
                "trigger",
            ]))
        ),
        "dictation_completed": .init(
            name: "dictation_completed",
            allowedProperties: dictationRouteDiagnosticProperties.union(Set([
                "auto_send",
                "delivery",
                "duration_bucket",
                "trigger",
                "word_count_bucket",
            ]))
        ),
        "dictation_artifact_saved": .init(
            name: "dictation_artifact_saved",
            allowedProperties: [
                "delivery",
                "duration_bucket",
                "save_outcome",
                "surface",
                "trigger",
                "word_count_bucket",
            ]
        ),
        "dictation_stop_latency_measured": .init(
            name: "dictation_stop_latency_measured",
            allowedProperties: dictationRouteDiagnosticProperties.union(Set([
                "auto_enter_bucket",
                "auto_send",
                "cleanup_bucket",
                "cleanup_changed",
                "cleanup_enabled",
                "copy_reason",
                "decode_bucket",
                "delivery",
                "mic_stop_bucket",
                "model_wait_bucket",
                "outcome",
                "paste_bucket",
                "save_bucket",
                "save_outcome",
                "stop_to_done_bucket",
                "stop_to_paste_bucket",
                "trigger",
                "word_count_bucket",
            ]))
        ),
        "dictation_cancelled": .init(
            name: "dictation_cancelled",
            allowedProperties: dictationRouteDiagnosticProperties.union(Set([
                "duration_bucket",
                "trigger",
            ]))
        ),
        "dictation_no_speech": .init(
            name: "dictation_no_speech",
            allowedProperties: dictationRouteDiagnosticProperties.union(Set([
                "duration_bucket",
                "trigger",
            ]))
        ),
        "dictation_audio_route_changed": .init(
            name: "dictation_audio_route_changed",
            allowedProperties: dictationRouteDiagnosticProperties
        ),
        "dictation_audio_route_recovery_finished": .init(
            name: "dictation_audio_route_recovery_finished",
            allowedProperties: dictationRouteDiagnosticProperties.union(Set([
                "outcome",
            ]))
        ),
        "dictation_audio_route_recovery_timeout": .init(
            name: "dictation_audio_route_recovery_timeout",
            allowedProperties: dictationRouteDiagnosticProperties
        ),
        "meeting_recording_started": .init(
            name: "meeting_recording_started",
            allowedProperties: meetingCaptureDiagnosticProperties.union(Set([
                "trigger",
            ]))
        ),
        "meeting_recording_start_failed": .init(
            name: "meeting_recording_start_failed",
            allowedProperties: meetingCaptureDiagnosticProperties.union(Set([
                "failure_kind",
                "trigger",
            ]))
        ),
        "meeting_prompt_shown": .init(
            name: "meeting_prompt_shown",
            allowedProperties: meetingPromptProperties
        ),
        "meeting_prompt_dismissed": .init(
            name: "meeting_prompt_dismissed",
            allowedProperties: meetingPromptProperties.union(Set([
                "backoff_kind",
                "cooldown_reason",
            ]))
        ),
        "meeting_prompt_record_selected": .init(
            name: "meeting_prompt_record_selected",
            allowedProperties: meetingPromptProperties
        ),
        "meeting_prompt_suppressed": .init(
            name: "meeting_prompt_suppressed",
            allowedProperties: meetingPromptProperties.union(Set([
                "capture_activity",
                "cooldown_reason",
                "suppression_reason",
            ]))
        ),
        "meeting_mic_boost_prompt_shown": .init(
            name: "meeting_mic_boost_prompt_shown",
            allowedProperties: [
                "duration_bucket",
                "trigger",
            ]
        ),
        "meeting_mic_boost_prompt_actioned": .init(
            name: "meeting_mic_boost_prompt_actioned",
            allowedProperties: [
                "action",
                "duration_bucket",
                "trigger",
            ]
        ),
        "meeting_recording_stopped": .init(
            name: "meeting_recording_stopped",
            allowedProperties: meetingCaptureDiagnosticProperties.union(Set([
                "capture_quality",
                "duration_bucket",
                "gap_count_bucket",
                "reason",
                "route_change_count_bucket",
                "system_stream_present",
                "stop_timed_out",
                "trigger",
            ]))
        ),
        "meeting_capture_health_snapshot": .init(
            name: "meeting_capture_health_snapshot",
            allowedProperties: meetingCaptureDiagnosticProperties.union(Set([
                "capture_quality",
                "duration_bucket",
                "gap_count_bucket",
                "reason",
                "route_change_count_bucket",
                "system_stream_present",
                "stop_timed_out",
                "trigger",
            ]))
        ),
        "meeting_recording_cancelled": .init(
            name: "meeting_recording_cancelled",
            allowedProperties: meetingCaptureDiagnosticProperties.union(Set([
                "duration_bucket",
                "reason",
                "stop_timed_out",
                "system_stream_present",
                "trigger",
            ]))
        ),
        "meeting_transcript_saved": .init(
            name: "meeting_transcript_saved",
            allowedProperties: [
                "duration_bucket",
                "participant_count_bucket",
                "queue_depth_bucket",
                "trigger",
                "word_count_bucket",
            ]
        ),
        "meeting_transcript_failed": .init(
            name: "meeting_transcript_failed",
            allowedProperties: meetingCaptureDiagnosticProperties.union(Set([
                "failure_kind",
                "queue_depth_bucket",
                "trigger",
            ]))
        ),
        "meeting_speaker_finalization_failed": .init(
            name: "meeting_speaker_finalization_failed",
            allowedProperties: [
                "failure_kind",
                "queue_depth_bucket",
                "session_stage",
                "trigger",
            ]
        ),
        "meeting_transcript_skipped": .init(
            name: "meeting_transcript_skipped",
            allowedProperties: meetingCaptureDiagnosticProperties.union(Set([
                "failure_kind",
                "queue_depth_bucket",
                "trigger",
            ]))
        ),
        "meeting_saved_audio_retranscription_requested": .init(
            name: "meeting_saved_audio_retranscription_requested",
            allowedProperties: [
                "mic_stream_present",
                "trigger",
            ]
        ),
        "meeting_file_imported": .init(
            name: "meeting_file_imported",
            allowedProperties: [
                "queue_depth_bucket",
            ]
        ),
        "meeting_file_import_failed": .init(
            name: "meeting_file_import_failed",
            allowedProperties: [
                "failure_kind",
                "import_stage",
            ]
        ),
    ]
}
