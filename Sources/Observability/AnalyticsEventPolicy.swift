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
        "onboarding_completed": .init(
            name: "onboarding_completed",
            allowedProperties: [
                "anonymous_usage_enabled",
                "crash_reporting_enabled",
                "system_audio_recording_enabled",
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
