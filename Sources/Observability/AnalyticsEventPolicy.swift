import Foundation

struct AnalyticsEventPolicy: Equatable {
    let name: String
    let allowedProperties: Set<String>

    static func policy(forEvent event: String) -> AnalyticsEventPolicy? {
        allowedPolicies[event]
    }

    private static let allowedPolicies: [String: AnalyticsEventPolicy] = [
        "app_launched": .init(
            name: "app_launched",
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
                "model_state",
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
                "completion_path",
                "crash_reporting_enabled",
                "first_dictation_saved",
                "meeting_recording_ready",
                "model_state",
                "step_id",
            ]
        ),
        "dictation_started": .init(
            name: "dictation_started",
            allowedProperties: [
                "trigger",
            ]
        ),
        "dictation_completed": .init(
            name: "dictation_completed",
            allowedProperties: [
                "auto_send",
                "delivery",
                "duration_bucket",
                "trigger",
                "word_count_bucket",
            ]
        ),
        "dictation_cancelled": .init(
            name: "dictation_cancelled",
            allowedProperties: [
                "duration_bucket",
                "trigger",
            ]
        ),
        "dictation_no_speech": .init(
            name: "dictation_no_speech",
            allowedProperties: [
                "duration_bucket",
                "trigger",
            ]
        ),
        "meeting_recording_started": .init(
            name: "meeting_recording_started",
            allowedProperties: [
                "trigger",
            ]
        ),
        "meeting_prompt_shown": .init(
            name: "meeting_prompt_shown",
            allowedProperties: [
                "prompt_reason",
                "provider",
                "source",
            ]
        ),
        "meeting_prompt_dismissed": .init(
            name: "meeting_prompt_dismissed",
            allowedProperties: [
                "backoff_kind",
                "prompt_reason",
                "provider",
                "source",
            ]
        ),
        "meeting_prompt_record_selected": .init(
            name: "meeting_prompt_record_selected",
            allowedProperties: [
                "prompt_reason",
                "provider",
                "source",
            ]
        ),
        "meeting_recording_stopped": .init(
            name: "meeting_recording_stopped",
            allowedProperties: [
                "capture_quality",
                "duration_bucket",
                "reason",
                "system_stream_present",
                "trigger",
            ]
        ),
        "meeting_recording_cancelled": .init(
            name: "meeting_recording_cancelled",
            allowedProperties: [
                "duration_bucket",
                "reason",
                "system_stream_present",
                "trigger",
            ]
        ),
        "meeting_transcript_saved": .init(
            name: "meeting_transcript_saved",
            allowedProperties: [
                "queue_depth_bucket",
                "trigger",
            ]
        ),
        "meeting_transcript_failed": .init(
            name: "meeting_transcript_failed",
            allowedProperties: [
                "failure_kind",
                "queue_depth_bucket",
                "trigger",
            ]
        ),
        "meeting_file_imported": .init(
            name: "meeting_file_imported",
            allowedProperties: [
                "queue_depth_bucket",
            ]
        ),
    ]
}
