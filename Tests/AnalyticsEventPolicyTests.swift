import Foundation

func testAnalyticsEventPolicy() {
    runSuite("AnalyticsEventPolicy allows explicit onboarding funnel events") {
        let shown = AnalyticsEventPolicy.policy(forEvent: "onboarding_shown")
        let stepViewed = AnalyticsEventPolicy.policy(forEvent: "onboarding_step_viewed")
        let permissionClicked = AnalyticsEventPolicy.policy(forEvent: "onboarding_permission_cta_clicked")
        let permissionChanged = AnalyticsEventPolicy.policy(forEvent: "onboarding_permission_status_changed")
        let firstSaved = AnalyticsEventPolicy.policy(forEvent: "onboarding_first_dictation_saved")
        let meetingDryRun = AnalyticsEventPolicy.policy(forEvent: "onboarding_meeting_dry_run_clicked")
        let agentClicked = AnalyticsEventPolicy.policy(forEvent: "onboarding_agent_cta_clicked")
        let completed = AnalyticsEventPolicy.policy(forEvent: "onboarding_completed")

        assertEqual(shown?.allowedProperties.contains("meeting_recording_ready"), true, "onboarding shown should preserve meeting-readiness attribution")
        assertEqual(stepViewed?.allowedProperties.contains("step_id"), true, "step views should preserve funnel step")
        assertEqual(permissionClicked?.allowedProperties.contains("permission_kind"), true, "permission clicks should preserve the clicked permission")
        assertEqual(permissionChanged?.allowedProperties.contains("to_status"), true, "permission status changes should preserve the new status")
        assertEqual(firstSaved?.allowedProperties.contains("word_count_bucket"), true, "first saved dictation should keep coarse word count")
        assertEqual(meetingDryRun?.allowedProperties.contains("meeting_recording_ready"), true, "meeting dry runs should keep setup readiness")
        assertEqual(agentClicked?.allowedProperties.contains("agent_cta"), true, "agent CTAs should preserve the action id")
        assertEqual(completed?.allowedProperties.contains("first_dictation_saved"), true, "completion should preserve whether first value happened")

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "meeting_recording_ready": "true",
                "permission_kind": "system_recording",
                "step_id": "meeting_setup",
            ],
            allowedKeys: [
                "meeting_recording_ready",
                "permission_kind",
                "step_id",
            ]
        )
        assertEqual(sanitized["meeting_recording_ready"], "true", "meeting_recording_ready should avoid the audio-key sanitizer drop")
        assertEqual(sanitized["permission_kind"], "system_recording", "permission kind should survive as a coarse enum")
        assertEqual(sanitized["step_id"], "meeting_setup", "step id should survive sanitization")
    }

    runSuite("AnalyticsEventPolicy preserves dictation auto-send attribution") {
        let dictationCompleted = AnalyticsEventPolicy.policy(forEvent: "dictation_completed")
        assertEqual(dictationCompleted?.allowedProperties.contains("auto_send"), true, "dictation completion should allow the existing auto_send property")
    }

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
