import Foundation

func testAnalyticsEventPolicy() {
    runSuite("AnalyticsEventPolicy only permits reviewed analytics events") {
        let dictationCompleted = AnalyticsEventPolicy.policy(forEvent: "dictation_completed")
        let dictationNoSpeech = AnalyticsEventPolicy.policy(forEvent: "dictation_no_speech")
        let meetingFailed = AnalyticsEventPolicy.policy(forEvent: "meeting_transcript_failed")
        let unknown = AnalyticsEventPolicy.policy(forEvent: "raw_transcript_uploaded")

        assertEqual(dictationCompleted?.allowedProperties.contains("word_count_bucket"), true, "dictation completion should allow bucketed word counts")
        assertEqual(dictationNoSpeech?.allowedProperties.contains("duration_bucket"), true, "dictation no-speech should keep a coarse duration bucket")
        assertEqual(dictationNoSpeech?.allowedProperties.contains("trigger"), true, "dictation no-speech should preserve trigger attribution")
        assertEqual(meetingFailed?.allowedProperties.contains("failure_kind"), true, "meeting failures should allow normalized failure kinds")
        assertNil(unknown, "unreviewed analytics events should not be allowed")
    }

    runSuite("AnalyticsEventPolicy meeting_recording_stopped system_stream_present key is not silently filtered") {
        let policy = AnalyticsEventPolicy.policy(forEvent: "meeting_recording_stopped")
        assertEqual(policy?.allowedProperties.contains("system_stream_present"), true, "system_stream_present should be in the allowlist")
        assertEqual(policy?.allowedProperties.contains("trigger"), true, "meeting stop events should preserve start trigger attribution")

        // Verify the key passes sanitization — it must not contain a sensitive fragment
        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "system_stream_present": "true",
                "trigger": "detected_prompt",
            ],
            allowedKeys: ["system_stream_present", "trigger"]
        )
        assertEqual(sanitized["system_stream_present"], "true", "system_stream_present must survive sanitization — if empty the metric is always missing")
        assertEqual(sanitized["trigger"], "detected_prompt", "meeting trigger attribution must survive sanitization")
    }

    runSuite("AnalyticsEventPolicy meeting_recording_cancelled stays coarse and allowlisted") {
        let policy = AnalyticsEventPolicy.policy(forEvent: "meeting_recording_cancelled")

        assertEqual(policy?.allowedProperties.contains("duration_bucket"), true, "meeting cancellation should only keep bucketed duration")
        assertEqual(policy?.allowedProperties.contains("reason"), true, "meeting cancellation should preserve coarse reason")
        assertEqual(policy?.allowedProperties.contains("system_stream_present"), true, "meeting cancellation should preserve system stream presence")
        assertEqual(policy?.allowedProperties.contains("trigger"), true, "meeting cancellation should preserve trigger attribution")
    }

    runSuite("AnalyticsEventPolicy allows meeting outcome trigger attribution") {
        let saved = AnalyticsEventPolicy.policy(forEvent: "meeting_transcript_saved")
        let failed = AnalyticsEventPolicy.policy(forEvent: "meeting_transcript_failed")

        assertEqual(saved?.allowedProperties.contains("trigger"), true, "meeting saves should preserve trigger attribution")
        assertEqual(failed?.allowedProperties.contains("trigger"), true, "meeting failures should preserve trigger attribution")
    }

    runSuite("AnalyticsEventPolicy allows meeting_file_imported with queue depth") {
        let fileImported = AnalyticsEventPolicy.policy(forEvent: "meeting_file_imported")
        assertEqual(fileImported?.allowedProperties.contains("queue_depth_bucket"), true, "file import should allow bucketed queue depth")
    }

    runSuite("AnalyticsEventPolicy allows coarse meeting prompt telemetry") {
        let shown = AnalyticsEventPolicy.policy(forEvent: "meeting_prompt_shown")
        let dismissed = AnalyticsEventPolicy.policy(forEvent: "meeting_prompt_dismissed")
        let recorded = AnalyticsEventPolicy.policy(forEvent: "meeting_prompt_record_selected")

        assertEqual(shown?.allowedProperties.contains("provider"), true, "prompt shown should allow provider attribution")
        assertEqual(shown?.allowedProperties.contains("prompt_reason"), true, "prompt shown should preserve why it appeared")
        assertEqual(dismissed?.allowedProperties.contains("source"), true, "prompt dismiss should allow source attribution")
        assertEqual(dismissed?.allowedProperties.contains("backoff_kind"), true, "prompt dismiss should preserve which backoff rule fired")
        assertEqual(recorded?.allowedProperties.contains("provider"), true, "prompt accept should allow provider attribution")

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "prompt_reason": "calendar_plus_runtime_match",
                "backoff_kind": "calendar_teams_extended",
            ],
            allowedKeys: ["prompt_reason", "backoff_kind"]
        )
        assertEqual(sanitized["prompt_reason"], "calendar_plus_runtime_match", "prompt reason should survive sanitization")
        assertEqual(sanitized["backoff_kind"], "calendar_teams_extended", "dismiss backoff kind should survive sanitization")
    }
}
