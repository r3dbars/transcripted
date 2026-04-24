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
        let dismissed = AnalyticsEventPolicy.policy(forEvent: "onboarding_dismissed")

        assertEqual(shown?.allowedProperties.contains("meeting_recording_ready"), true, "onboarding shown should preserve meeting-readiness attribution")
        assertEqual(stepViewed?.allowedProperties.contains("flow_elapsed_bucket"), true, "step views should preserve coarse elapsed time")
        assertEqual(stepViewed?.allowedProperties.contains("step_id"), true, "step views should preserve funnel step")
        assertEqual(permissionClicked?.allowedProperties.contains("permission_kind"), true, "permission clicks should preserve the clicked permission")
        assertEqual(permissionChanged?.allowedProperties.contains("to_status"), true, "permission status changes should preserve the new status")
        assertEqual(firstSaved?.allowedProperties.contains("word_count_bucket"), true, "first saved dictation should keep coarse word count")
        assertEqual(meetingDryRun?.allowedProperties.contains("meeting_recording_ready"), true, "meeting dry runs should keep setup readiness")
        assertEqual(agentClicked?.allowedProperties.contains("agent_cta"), true, "agent CTAs should preserve the action id")
        assertEqual(completed?.allowedProperties.contains("first_dictation_saved"), true, "completion should preserve whether first value happened")
        assertEqual(completed?.allowedProperties.contains("flow_elapsed_bucket"), true, "completion should preserve coarse time to finish")
        assertEqual(dismissed?.allowedProperties.contains("step_index"), true, "dismissal should preserve where users dropped")

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "meeting_recording_ready": "true",
                "permission_kind": "system_recording",
                "flow_elapsed_bucket": "30_119s",
                "step_id": "meeting_setup",
            ],
            allowedKeys: [
                "flow_elapsed_bucket",
                "meeting_recording_ready",
                "permission_kind",
                "step_id",
            ]
        )
        assertEqual(sanitized["meeting_recording_ready"], "true", "meeting_recording_ready should avoid the audio-key sanitizer drop")
        assertEqual(sanitized["permission_kind"], "system_recording", "permission kind should survive as a coarse enum")
        assertEqual(sanitized["flow_elapsed_bucket"], "30_119s", "coarse elapsed buckets should survive sanitization")
        assertEqual(sanitized["step_id"], "meeting_setup", "step id should survive sanitization")
    }

    runSuite("AnalyticsEventPolicy allows menu and settings behavior events") {
        let menuOpened = AnalyticsEventPolicy.policy(forEvent: "menu_bar_opened")
        let menuAction = AnalyticsEventPolicy.policy(forEvent: "menu_bar_action_clicked")
        let settingsOpened = AnalyticsEventPolicy.policy(forEvent: "settings_opened")
        let settingsPage = AnalyticsEventPolicy.policy(forEvent: "settings_page_viewed")
        let settingsAction = AnalyticsEventPolicy.policy(forEvent: "settings_action_clicked")
        let settingsToggle = AnalyticsEventPolicy.policy(forEvent: "settings_toggle_changed")
        let settingsPermission = AnalyticsEventPolicy.policy(forEvent: "settings_permission_cta_clicked")
        let captureLibrary = AnalyticsEventPolicy.policy(forEvent: "settings_capture_library_changed")
        let updateAction = AnalyticsEventPolicy.policy(forEvent: "update_action_clicked")
        let updateSetting = AnalyticsEventPolicy.policy(forEvent: "update_setting_changed")
        let updateCheckFinished = AnalyticsEventPolicy.policy(forEvent: "update_check_finished")

        assertEqual(menuOpened?.allowedProperties.contains("paste_available"), true, "menu opens should preserve whether paste has value")
        assertEqual(menuAction?.allowedProperties.contains("action_id"), true, "menu clicks should preserve the clicked action")
        assertEqual(settingsOpened?.allowedProperties.contains("source"), true, "settings opens should preserve entry source")
        assertEqual(settingsPage?.allowedProperties.contains("page_id"), true, "settings page views should preserve page id")
        assertEqual(settingsAction?.allowedProperties.contains("action_id"), true, "settings actions should preserve action id")
        assertEqual(settingsToggle?.allowedProperties.contains("setting_id"), true, "settings toggles should preserve setting id")
        assertEqual(settingsPermission?.allowedProperties.contains("permission_kind"), true, "settings permission CTAs should preserve permission kind")
        assertEqual(captureLibrary?.allowedProperties.contains("location_type"), true, "capture library changes should preserve default-vs-custom only")
        assertEqual(updateAction?.allowedProperties.contains("surface"), true, "update clicks should preserve whether menu or settings drove the action")
        assertEqual(updateAction?.allowedProperties.contains("automatic_downloads_enabled"), true, "update clicks should preserve auto-download state")
        assertEqual(updateSetting?.allowedProperties.contains("setting_id"), true, "update settings should preserve the changed toggle")
        assertEqual(updateCheckFinished?.allowedProperties.contains("result"), true, "update checks should preserve the coarse outcome")

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "action_id": "start_dictation",
                "automatic_downloads_enabled": "true",
                "page_id": "home",
                "setting_id": "menu_bar_start_dictation",
                "source": "menu_bar",
                "state": "ready_to_install",
                "surface": "settings_about",
            ],
            allowedKeys: ["action_id", "automatic_downloads_enabled", "page_id", "setting_id", "source", "state", "surface"]
        )
        assertEqual(sanitized["action_id"], "start_dictation", "action ids should survive sanitization")
        assertEqual(sanitized["automatic_downloads_enabled"], "true", "automatic update download state should survive sanitization")
        assertEqual(sanitized["page_id"], "home", "page ids should survive sanitization")
        assertEqual(sanitized["setting_id"], "menu_bar_start_dictation", "setting ids should survive sanitization")
        assertEqual(sanitized["source"], "menu_bar", "source enums should survive sanitization")
        assertEqual(sanitized["state"], "ready_to_install", "update state should survive sanitization")
        assertEqual(sanitized["surface"], "settings_about", "update surface should survive sanitization")
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
        assertEqual(saved?.allowedProperties.contains("duration_bucket"), true, "meeting saves should preserve coarse duration")
        assertEqual(saved?.allowedProperties.contains("word_count_bucket"), true, "meeting saves should preserve coarse word output")
        assertEqual(saved?.allowedProperties.contains("participant_count_bucket"), true, "meeting saves should preserve coarse participant count")
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
