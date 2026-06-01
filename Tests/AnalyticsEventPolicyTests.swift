import Foundation

func testAnalyticsEventPolicy() {
    runSuite("AnalyticsEventPolicy docs list matches the source allowlist") {
        let documentedEvents = documentedAnalyticsEvents().sorted()
        let policyEvents = sourceAnalyticsPolicyEvents().sorted()

        assertFalse(documentedEvents.isEmpty, "privacy observability doc should list analytics events")
        assertFalse(policyEvents.isEmpty, "analytics event policy source should expose parseable policy events")
        assertEqual(
            documentedEvents,
            policyEvents,
            "docs/privacy-first-observability.md should list the same analytics events as AnalyticsEventPolicy.swift"
        )
    }

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
        assertEqual(updateCheckFinished?.allowedProperties.contains("failure_kind"), true, "update failures should preserve the normalized failure kind")
        assertEqual(updateCheckFinished?.allowedProperties.contains("failure_code"), true, "update failures should preserve coarse error-code buckets")

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "action_id": "start_dictation",
                "automatic_downloads_enabled": "true",
                "failure_code": "sparkle_2003",
                "failure_kind": "feed_unreachable",
                "page_id": "home",
                "setting_id": "menu_bar_start_dictation",
                "source": "menu_bar",
                "state": "ready_to_install",
                "surface": "settings_about",
            ],
            allowedKeys: ["action_id", "automatic_downloads_enabled", "failure_code", "failure_kind", "page_id", "setting_id", "source", "state", "surface"]
        )
        assertEqual(sanitized["action_id"], "start_dictation", "action ids should survive sanitization")
        assertEqual(sanitized["automatic_downloads_enabled"], "true", "automatic update download state should survive sanitization")
        assertEqual(sanitized["failure_code"], "sparkle_2003", "coarse update failure codes should survive sanitization")
        assertEqual(sanitized["failure_kind"], "feed_unreachable", "update failure kind should survive sanitization")
        assertEqual(sanitized["page_id"], "home", "page ids should survive sanitization")
        assertEqual(sanitized["setting_id"], "menu_bar_start_dictation", "setting ids should survive sanitization")
        assertEqual(sanitized["source"], "menu_bar", "source enums should survive sanitization")
        assertEqual(sanitized["state"], "ready_to_install", "update state should survive sanitization")
        assertEqual(sanitized["surface"], "settings_about", "update surface should survive sanitization")
    }

    runSuite("AnalyticsEventPolicy allows update download lifecycle attribution") {
        let started = AnalyticsEventPolicy.policy(forEvent: "update_download_started")
        let finished = AnalyticsEventPolicy.policy(forEvent: "update_download_finished")

        assertEqual(started?.allowedProperties.contains("automatic_downloads_enabled"), true, "download starts should preserve automatic-download state")
        assertEqual(started?.allowedProperties.contains("state"), true, "download starts should preserve update state")
        assertEqual(started?.allowedProperties.contains("version"), true, "download starts should preserve the public app version")
        assertEqual(finished?.allowedProperties.contains("failure_kind"), true, "download finishes should preserve normalized failure kind")

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "automatic_downloads_enabled": "true",
                "state": "downloading",
                "version": "1.2.3",
            ],
            allowedKeys: started?.allowedProperties ?? []
        )
        assertEqual(sanitized["automatic_downloads_enabled"], "true", "automatic-download state should survive sanitization")
        assertEqual(sanitized["state"], "downloading", "download state should survive sanitization")
        assertEqual(sanitized["version"], "1.2.3", "public update version should survive sanitization")
    }

    runSuite("AnalyticsEventPolicy preserves failed update download classification") {
        let finished = AnalyticsEventPolicy.policy(forEvent: "update_download_finished")

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "automatic_downloads_enabled": "false",
                "failure_kind": "download_failed",
                "state": "available",
                "version": "1.2.3",
            ],
            allowedKeys: finished?.allowedProperties ?? []
        )

        assertEqual(sanitized["automatic_downloads_enabled"], "false", "manual downloads should remain distinguishable from automatic downloads")
        assertEqual(sanitized["failure_kind"], "download_failed", "normalized download failure kind should survive")
        assertEqual(sanitized["state"], "available", "failed downloads should keep their post-failure state")
        assertEqual(sanitized["version"], "1.2.3", "failed downloads should keep the public app version")
    }

    runSuite("AnalyticsEventPolicy preserves ready-to-install update state") {
        let ready = AnalyticsEventPolicy.policy(forEvent: "update_ready_to_install")

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "automatic_downloads_enabled": "true",
                "state": "ready_to_install",
                "version": "1.2.3",
            ],
            allowedKeys: ready?.allowedProperties ?? []
        )

        assertEqual(sanitized["automatic_downloads_enabled"], "true", "ready-to-install telemetry should preserve automatic-download state")
        assertEqual(sanitized["state"], "ready_to_install", "ready-to-install state should survive sanitization")
        assertEqual(sanitized["version"], "1.2.3", "ready-to-install telemetry should preserve the public app version")
    }

    runSuite("AnalyticsEventPolicy keeps relaunch update telemetry narrow") {
        let relaunching = AnalyticsEventPolicy.policy(forEvent: "update_relaunching")

        assertEqual(relaunching?.allowedProperties.contains("version"), true, "relaunch telemetry should preserve the public app version")
        assertEqual(relaunching?.allowedProperties.contains("state"), false, "relaunch telemetry should not add redundant update state")
        assertEqual(relaunching?.allowedProperties.contains("automatic_downloads_enabled"), false, "relaunch telemetry should not add settings state")

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "automatic_downloads_enabled": "true",
                "download_url": "redacted",
                "error_message": "redacted",
                "state": "ready_to_install",
                "version": "1.2.3",
            ],
            allowedKeys: relaunching?.allowedProperties ?? []
        )

        assertEqual(sanitized["version"], "1.2.3", "relaunch telemetry should keep the public app version")
        assertNil(sanitized["automatic_downloads_enabled"], "relaunch telemetry should stay narrow")
        assertNil(sanitized["download_url"], "raw download locations should stay out of analytics")
        assertNil(sanitized["error_message"], "raw update errors should stay out of analytics")
        assertNil(sanitized["state"], "relaunch telemetry should not duplicate lifecycle state")
    }

    runSuite("AnalyticsEventPolicy allows runtime diagnostic events") {
        let unclean = AnalyticsEventPolicy.policy(forEvent: "app_unclean_shutdown_detected")
        let stall = AnalyticsEventPolicy.policy(forEvent: "app_session_stall_detected")
        let copied = AnalyticsEventPolicy.policy(forEvent: "support_diagnostics_copied")
        let sent = AnalyticsEventPolicy.policy(forEvent: "support_diagnostic_event_sent")

        assertEqual(unclean?.allowedProperties.contains("session_stage"), true, "unclean shutdown should preserve last session stage")
        assertEqual(unclean?.allowedProperties.contains("heartbeat_age_bucket"), true, "unclean shutdown should preserve heartbeat age bucket")
        assertEqual(unclean?.allowedProperties.contains("session_duration_bucket"), true, "unclean shutdown should preserve coarse session duration")
        assertEqual(stall?.allowedProperties.contains("stall_stage"), true, "session stall should preserve stall stage")
        assertEqual(stall?.allowedProperties.contains("duration_bucket"), true, "session stall should preserve duration bucket")
        assertNotNil(copied, "copy diagnostics event should be allowlisted")
        assertNotNil(sent, "send diagnostic event should be allowlisted")

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "duration_bucket": "30_119s",
                "heartbeat_age_bucket": "1_4m",
                "session_duration_bucket": "5_14m",
                "session_kind": "dictation",
                "session_stage": "recording",
                "stall_stage": "microphone_start_timeout",
            ],
            allowedKeys: stall?.allowedProperties ?? []
        )
        assertEqual(sanitized["session_duration_bucket"], "5_14m", "session duration bucket should survive sanitization")
        assertEqual(sanitized["session_stage"], "recording", "session stage should survive sanitization")
        assertEqual(sanitized["stall_stage"], "microphone_start_timeout", "stall stage should survive sanitization")
    }

    runSuite("AnalyticsEventPolicy preserves dictation auto-send attribution") {
        let dictationCompleted = AnalyticsEventPolicy.policy(forEvent: "dictation_completed")
        assertEqual(dictationCompleted?.allowedProperties.contains("auto_send"), true, "dictation completion should allow the existing auto_send property")
        assertEqual(dictationCompleted?.allowedProperties.contains("input_device_class"), true, "dictation completion should preserve coarse input device class")
        assertEqual(dictationCompleted?.allowedProperties.contains("hfp_suspected"), true, "dictation completion should preserve Bluetooth HFP suspicion only as a boolean")
        assertEqual(dictationCompleted?.allowedProperties.contains("sample_flow_started"), true, "dictation completion should preserve whether audio samples ever flowed")
    }

    runSuite("AnalyticsEventPolicy allows dictation start failures with coarse attribution") {
        let dictationStartFailed = AnalyticsEventPolicy.policy(forEvent: "dictation_start_failed")

        assertEqual(dictationStartFailed?.allowedProperties.contains("failure_kind"), true, "dictation start failures should preserve normalized failure kinds")
        assertEqual(dictationStartFailed?.allowedProperties.contains("trigger"), true, "dictation start failures should preserve trigger attribution")
        assertEqual(dictationStartFailed?.allowedProperties.contains("route_shape"), true, "dictation start failures should preserve safe route shape")
        assertEqual(dictationStartFailed?.allowedProperties.contains("selection_reason"), true, "dictation start failures should preserve coarse device-selection reason")
        assertEqual(dictationStartFailed?.allowedProperties.contains("start_attempt_bucket"), true, "dictation start failures should bucket retry-loop attempts")

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "default_input_class": "bluetooth",
                "default_output_class": "bluetooth",
                "failure_kind": "microphone_start_timeout",
                "format_ready": "false",
                "hfp_suspected": "true",
                "input_channels": "1",
                "input_device_class": "bluetooth",
                "input_rate_hz": "24000",
                "output_channels": "1",
                "output_device_class": "bluetooth",
                "output_rate_hz": "48000",
                "recovering": "true",
                "route_shape": "bluetooth_input_to_bluetooth_output",
                "sample_flow_started": "false",
                "selection_reason": "noBuiltInFallbackAvailable",
                "start_attempt_bucket": "10_plus",
                "start_attempts": "12",
                "trigger": "hotkey",
            ],
            allowedKeys: dictationStartFailed?.allowedProperties ?? []
        )
        assertEqual(sanitized["failure_kind"], "microphone_start_timeout", "dictation start failure kind should survive sanitization")
        assertEqual(sanitized["input_device_class"], "bluetooth", "coarse dictation input class should survive sanitization")
        assertEqual(sanitized["input_rate_hz"], "24000", "safe dictation input rate should survive sanitization")
        assertEqual(sanitized["route_shape"], "bluetooth_input_to_bluetooth_output", "safe route shape should survive sanitization")
        assertEqual(sanitized["hfp_suspected"], "true", "Bluetooth HFP suspicion should survive as a boolean")
        assertEqual(sanitized["sample_flow_started"], "false", "sample flow state should survive as a boolean")
        assertEqual(sanitized["start_attempt_bucket"], "10_plus", "retry count bucket should survive sanitization")
        assertNil(sanitized["start_attempts"], "raw retry count should stay out of analytics")
        assertEqual(sanitized["trigger"], "hotkey", "dictation start trigger should survive sanitization")
    }

    runSuite("AnalyticsEventPolicy preserves zero-attempt start failure buckets") {
        let dictationStartFailed = AnalyticsEventPolicy.policy(forEvent: "dictation_start_failed")

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "failure_kind": "microphone_permission_denied",
                "start_attempt_bucket": "0",
                "trigger": "menu",
            ],
            allowedKeys: dictationStartFailed?.allowedProperties ?? []
        )

        assertEqual(sanitized["failure_kind"], "microphone_permission_denied", "permission failures should keep their normalized failure kind")
        assertEqual(sanitized["start_attempt_bucket"], "0", "immediate failures should preserve the zero-attempt bucket")
        assertEqual(sanitized["trigger"], "menu", "non-hotkey triggers should remain attributable")
    }

    runSuite("AnalyticsEventPolicy drops raw dictation timeout counters") {
        let dictationStartFailed = AnalyticsEventPolicy.policy(forEvent: "dictation_start_failed")

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "failure_kind": "microphone_start_timeout",
                "forced_readiness_recoveries": "2",
                "readiness_refreshes": "4",
                "recovery_start_attempts": "3",
                "start_attempt_bucket": "4_9",
                "start_attempts": "7",
                "trigger": "hotkey",
                "wait_ms": "12000",
            ],
            allowedKeys: dictationStartFailed?.allowedProperties ?? []
        )

        assertEqual(sanitized["start_attempt_bucket"], "4_9", "only the coarse retry bucket should survive")
        assertNil(sanitized["forced_readiness_recoveries"], "raw recovery counts should stay out of analytics")
        assertNil(sanitized["readiness_refreshes"], "raw readiness refresh counts should stay out of analytics")
        assertNil(sanitized["recovery_start_attempts"], "raw recovery start counts should stay out of analytics")
        assertNil(sanitized["start_attempts"], "raw retry counts should stay out of analytics")
        assertNil(sanitized["wait_ms"], "raw wait durations should stay out of analytics")
    }

    runSuite("AnalyticsEventPolicy drops raw dictation device labels") {
        let dictationStartFailed = AnalyticsEventPolicy.policy(forEvent: "dictation_start_failed")

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "audio_device": "Desk microphone",
                "default_input_name": "Desk microphone",
                "failure_kind": "microphone_start_timeout",
                "input_device_class": "built_in",
                "output_device_name": "Desk speakers",
                "route_shape": "built_in_input_to_built_in_output",
                "start_attempt_bucket": "2_3",
                "trigger": "hotkey",
            ],
            allowedKeys: dictationStartFailed?.allowedProperties ?? []
        )

        assertEqual(sanitized["input_device_class"], "built_in", "coarse input class should survive")
        assertEqual(sanitized["route_shape"], "built_in_input_to_built_in_output", "coarse route shape should survive")
        assertNil(sanitized["audio_device"], "raw audio device names should stay out of analytics")
        assertNil(sanitized["default_input_name"], "raw input names should stay out of analytics")
        assertNil(sanitized["output_device_name"], "raw output names should stay out of analytics")
    }

    runSuite("AnalyticsEventPolicy allows dictation audio route lifecycle events") {
        let changed = AnalyticsEventPolicy.policy(forEvent: "dictation_audio_route_changed")
        let finished = AnalyticsEventPolicy.policy(forEvent: "dictation_audio_route_recovery_finished")
        let timeout = AnalyticsEventPolicy.policy(forEvent: "dictation_audio_route_recovery_timeout")

        assertEqual(changed?.allowedProperties.contains("was_recording"), true, "route change should preserve whether an active recording was interrupted")
        assertEqual(changed?.allowedProperties.contains("selected_input_class"), true, "route change should preserve selected input class")
        assertEqual(finished?.allowedProperties.contains("outcome"), true, "route recovery should preserve success/failure")
        assertEqual(finished?.allowedProperties.contains("recovery_latency_bucket"), true, "route recovery should preserve latency as a bucket")
        assertEqual(timeout?.allowedProperties.contains("hfp_suspected"), true, "route timeout should preserve Bluetooth HFP suspicion only as a boolean")

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "outcome": "failed",
                "recovery_latency_bucket": "2_9m",
                "selected_input_class": "built_in",
                "was_recording": "true",
            ],
            allowedKeys: finished?.allowedProperties ?? []
        )
        assertEqual(sanitized["outcome"], "failed", "route recovery outcome should survive sanitization")
        assertEqual(sanitized["recovery_latency_bucket"], "2_9m", "route recovery latency bucket should survive sanitization")
        assertEqual(sanitized["selected_input_class"], "built_in", "selected input class should survive sanitization")
        assertEqual(sanitized["was_recording"], "true", "recording interruption state should survive sanitization")
    }

    runSuite("AnalyticsEventPolicy only permits reviewed analytics events") {
        let dictationStartFailed = AnalyticsEventPolicy.policy(forEvent: "dictation_start_failed")
        let dictationCompleted = AnalyticsEventPolicy.policy(forEvent: "dictation_completed")
        let dictationNoSpeech = AnalyticsEventPolicy.policy(forEvent: "dictation_no_speech")
        let meetingFailed = AnalyticsEventPolicy.policy(forEvent: "meeting_transcript_failed")
        let speakerFinalizationFailed = AnalyticsEventPolicy.policy(forEvent: "meeting_speaker_finalization_failed")
        let meetingSkipped = AnalyticsEventPolicy.policy(forEvent: "meeting_transcript_skipped")
        let unknown = AnalyticsEventPolicy.policy(forEvent: "raw_transcript_uploaded")

        assertEqual(dictationStartFailed?.allowedProperties.contains("failure_kind"), true, "dictation start failures should allow normalized failure kinds")
        assertEqual(dictationCompleted?.allowedProperties.contains("word_count_bucket"), true, "dictation completion should allow bucketed word counts")
        assertEqual(dictationNoSpeech?.allowedProperties.contains("duration_bucket"), true, "dictation no-speech should keep a coarse duration bucket")
        assertEqual(dictationNoSpeech?.allowedProperties.contains("trigger"), true, "dictation no-speech should preserve trigger attribution")
        assertEqual(meetingFailed?.allowedProperties.contains("failure_kind"), true, "meeting failures should allow normalized failure kinds")
        assertEqual(speakerFinalizationFailed?.allowedProperties.contains("failure_kind"), true, "speaker finalization failures should allow normalized failure kinds")
        assertEqual(meetingSkipped?.allowedProperties.contains("failure_kind"), true, "skipped meeting transcripts should allow normalized reasons")
        assertNil(unknown, "unreviewed analytics events should not be allowed")
    }

    runSuite("AnalyticsEventPolicy meeting_recording_stopped system_stream_present key is not silently filtered") {
        let policy = AnalyticsEventPolicy.policy(forEvent: "meeting_recording_stopped")
        let healthPolicy = AnalyticsEventPolicy.policy(forEvent: "meeting_capture_health_snapshot")
        let startFailedPolicy = AnalyticsEventPolicy.policy(forEvent: "meeting_recording_start_failed")
        assertEqual(policy?.allowedProperties.contains("system_stream_present"), true, "system_stream_present should be in the allowlist")
        assertEqual(policy?.allowedProperties.contains("trigger"), true, "meeting stop events should preserve start trigger attribution")
        assertEqual(policy?.allowedProperties.contains("buffer_success_bucket"), true, "meeting stop events should preserve coarse buffer success")
        assertEqual(policy?.allowedProperties.contains("gap_count_bucket"), true, "meeting stop events should preserve coarse gap counts")
        assertEqual(policy?.allowedProperties.contains("input_device_class"), true, "meeting stop events should preserve coarse input device class")
        assertEqual(policy?.allowedProperties.contains("input_rate_hz"), true, "meeting stop events should preserve safe input rate")
        assertEqual(policy?.allowedProperties.contains("route_change_count_bucket"), true, "meeting stop events should preserve coarse route-change counts")
        assertEqual(policy?.allowedProperties.contains("mic_processing"), true, "meeting stop events should preserve the coarse mic processing mode")
        assertEqual(policy?.allowedProperties.contains("output_device_class"), true, "meeting stop events should preserve coarse output device class")
        assertEqual(policy?.allowedProperties.contains("recovery_attempt_bucket"), true, "meeting stop events should preserve recovery attempt buckets")
        assertEqual(policy?.allowedProperties.contains("system_backend"), true, "meeting stop events should preserve system capture backend")
        assertEqual(policy?.allowedProperties.contains("system_status"), true, "meeting stop events should preserve system capture status")
        assertEqual(policy?.allowedProperties.contains("voice_processing"), true, "meeting stop events should preserve whether VPIO was requested")
        assertEqual(healthPolicy?.allowedProperties.contains("stop_timed_out"), true, "health snapshot should preserve stop timeout state")
        assertEqual(startFailedPolicy?.allowedProperties.contains("failure_kind"), true, "meeting start failures should preserve normalized failure kinds")
        assertEqual(policy?.allowedProperties.contains("mic_raw_peak"), true, "meeting stop events should preserve raw mic peak for issue 500 diagnostics")
        assertEqual(policy?.allowedProperties.contains("mic_processed_peak"), true, "meeting stop events should preserve processed mic peak for issue 500 diagnostics")
        assertEqual(policy?.allowedProperties.contains("quiet_mic_recovered"), true, "meeting stop events should preserve quiet-mic recovery classification")
        assertEqual(policy?.allowedProperties.contains("quiet_mic_unrecovered"), true, "meeting stop events should preserve unrecovered quiet-mic classification")
        assertEqual(policy?.allowedProperties.contains("output_ducking_detected"), true, "meeting stop events should preserve output-ducking classification")
        assertEqual(policy?.allowedProperties.contains("system_peak"), true, "meeting stop events should preserve system audio peak for issue 500 diagnostics")
        assertEqual(policy?.allowedProperties.contains("default_input_volume_before"), true, "meeting stop events should preserve input volume before recording")
        assertEqual(policy?.allowedProperties.contains("default_output_volume_during"), true, "meeting stop events should preserve output volume during recording")
        assertEqual(policy?.allowedProperties.contains("default_output_volume_after"), true, "meeting stop events should preserve output volume after recording")
        assertEqual(policy?.allowedProperties.contains("default_output_volume_dropped"), true, "meeting stop events should preserve issue 500 output-drop flags")
        assertEqual(healthPolicy?.allowedProperties.contains("default_system_output_volume_dropped"), true, "health snapshots should preserve system-output drop flags")

        // Verify the key passes sanitization — it must not contain a sensitive fragment
        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "buffer_success_bucket": "90_97",
                "default_input_volume_before": "0.650",
                "default_input_volume_during": "0.650",
                "default_output_volume_before": "0.750",
                "default_output_volume_during": "0.750",
                "default_output_volume_after": "0.500",
                "default_output_volume_dropped": "true",
                "default_system_output_volume_before": "0.750",
                "default_system_output_volume_during": "0.750",
                "default_system_output_volume_after": "0.500",
                "default_system_output_volume_dropped": "true",
                "gap_count_bucket": "1",
                "input_device_class": "bluetooth",
                "input_rate_hz": "48000",
                "mic_processing": "software_agc",
                "mic_processed_peak": "0.36000",
                "mic_raw_peak": "0.03000",
                "output_ducking_detected": "true",
                "output_device_class": "built_in",
                "quiet_mic_recovered": "true",
                "quiet_mic_unrecovered": "false",
                "recovery_attempt_bucket": "0",
                "route_change_count_bucket": "2_3",
                "system_peak": "0.25000",
                "system_backend": "screen_capture_kit",
                "system_stream_present": "true",
                "system_status": "healthy",
                "trigger": "detected_prompt",
                "voice_processing": "false",
            ],
            allowedKeys: [
                "buffer_success_bucket",
                "default_input_volume_before",
                "default_input_volume_during",
                "default_output_volume_before",
                "default_output_volume_during",
                "default_output_volume_after",
                "default_output_volume_dropped",
                "default_system_output_volume_before",
                "default_system_output_volume_during",
                "default_system_output_volume_after",
                "default_system_output_volume_dropped",
                "gap_count_bucket",
                "input_device_class",
                "input_rate_hz",
                "mic_processing",
                "mic_processed_peak",
                "mic_raw_peak",
                "output_ducking_detected",
                "output_device_class",
                "quiet_mic_recovered",
                "quiet_mic_unrecovered",
                "recovery_attempt_bucket",
                "route_change_count_bucket",
                "system_peak",
                "system_backend",
                "system_stream_present",
                "system_status",
                "trigger",
                "voice_processing",
            ]
        )
        assertEqual(sanitized["buffer_success_bucket"], "90_97", "buffer success buckets should survive sanitization")
        assertEqual(sanitized["default_input_volume_before"], "0.650", "input volume before should survive sanitization")
        assertEqual(sanitized["default_output_volume_during"], "0.750", "output volume during should survive sanitization")
        assertEqual(sanitized["default_output_volume_after"], "0.500", "output volume after should survive sanitization")
        assertEqual(sanitized["default_output_volume_dropped"], "true", "output volume drop flags should survive sanitization")
        assertEqual(sanitized["gap_count_bucket"], "1", "gap count buckets should survive sanitization")
        assertEqual(sanitized["input_device_class"], "bluetooth", "coarse input device class should survive sanitization")
        assertEqual(sanitized["input_rate_hz"], "48000", "input sample rate should survive sanitization")
        assertEqual(sanitized["mic_processing"], "software_agc", "coarse mic processing mode should survive sanitization")
        assertEqual(sanitized["mic_raw_peak"], "0.03000", "raw mic peak should survive sanitization")
        assertEqual(sanitized["mic_processed_peak"], "0.36000", "processed mic peak should survive sanitization")
        assertEqual(sanitized["quiet_mic_recovered"], "true", "quiet-mic recovery classification should survive sanitization")
        assertEqual(sanitized["quiet_mic_unrecovered"], "false", "quiet-mic failure classification should survive sanitization")
        assertEqual(sanitized["output_ducking_detected"], "true", "output-ducking classification should survive sanitization")
        assertEqual(sanitized["output_device_class"], "built_in", "coarse output device class should survive sanitization")
        assertEqual(sanitized["recovery_attempt_bucket"], "0", "recovery attempt buckets should survive sanitization")
        assertEqual(sanitized["route_change_count_bucket"], "2_3", "route-change buckets should survive sanitization")
        assertEqual(sanitized["system_peak"], "0.25000", "system audio peak should survive sanitization")
        assertEqual(sanitized["system_backend"], "screen_capture_kit", "capture backend should survive sanitization")
        assertEqual(sanitized["system_stream_present"], "true", "system_stream_present must survive sanitization — if empty the metric is always missing")
        assertEqual(sanitized["system_status"], "healthy", "system capture status should survive sanitization")
        assertEqual(sanitized["trigger"], "detected_prompt", "meeting trigger attribution must survive sanitization")
        assertEqual(sanitized["voice_processing"], "false", "voice processing state should survive sanitization")
    }

    runSuite("AnalyticsEventPolicy meeting_recording_cancelled stays coarse and allowlisted") {
        let policy = AnalyticsEventPolicy.policy(forEvent: "meeting_recording_cancelled")

        assertEqual(policy?.allowedProperties.contains("duration_bucket"), true, "meeting cancellation should only keep bucketed duration")
        assertEqual(policy?.allowedProperties.contains("mic_processing"), true, "meeting cancellation should preserve the coarse mic processing mode")
        assertEqual(policy?.allowedProperties.contains("reason"), true, "meeting cancellation should preserve coarse reason")
        assertEqual(policy?.allowedProperties.contains("stop_timed_out"), true, "meeting cancellation should preserve stop timeout state")
        assertEqual(policy?.allowedProperties.contains("system_stream_present"), true, "meeting cancellation should preserve system stream presence")
        assertEqual(policy?.allowedProperties.contains("trigger"), true, "meeting cancellation should preserve trigger attribution")
        assertEqual(policy?.allowedProperties.contains("voice_processing"), true, "meeting cancellation should preserve whether VPIO was requested")
    }

    runSuite("AnalyticsEventPolicy allows meeting outcome trigger attribution") {
        let saved = AnalyticsEventPolicy.policy(forEvent: "meeting_transcript_saved")
        let failed = AnalyticsEventPolicy.policy(forEvent: "meeting_transcript_failed")
        let speakerFinalizationFailed = AnalyticsEventPolicy.policy(forEvent: "meeting_speaker_finalization_failed")
        let skipped = AnalyticsEventPolicy.policy(forEvent: "meeting_transcript_skipped")

        assertEqual(saved?.allowedProperties.contains("trigger"), true, "meeting saves should preserve trigger attribution")
        assertEqual(saved?.allowedProperties.contains("duration_bucket"), true, "meeting saves should preserve coarse duration")
        assertEqual(saved?.allowedProperties.contains("word_count_bucket"), true, "meeting saves should preserve coarse word output")
        assertEqual(saved?.allowedProperties.contains("participant_count_bucket"), true, "meeting saves should preserve coarse participant count")
        assertEqual(failed?.allowedProperties.contains("trigger"), true, "meeting failures should preserve trigger attribution")
        assertEqual(speakerFinalizationFailed?.allowedProperties.contains("trigger"), true, "speaker finalization failures should preserve trigger attribution")
        assertEqual(speakerFinalizationFailed?.allowedProperties.contains("queue_depth_bucket"), true, "speaker finalization failures should preserve bucketed queue depth")
        assertEqual(speakerFinalizationFailed?.allowedProperties.contains("session_stage"), true, "speaker finalization failures should keep save-stage attribution")
        assertEqual(skipped?.allowedProperties.contains("trigger"), true, "skipped meeting transcripts should preserve trigger attribution")
    }

    runSuite("AnalyticsEventPolicy allows saved-audio retranscription request attribution") {
        let requested = AnalyticsEventPolicy.policy(forEvent: "meeting_saved_audio_retranscription_requested")

        assertEqual(requested?.allowedProperties.contains("mic_stream_present"), true, "saved-audio retranscription requests should preserve whether a local mic stream is present")
        assertEqual(requested?.allowedProperties.contains("trigger"), true, "saved-audio retranscription requests should preserve trigger attribution")
        assertEqual(requested?.allowedProperties.contains("meeting_title"), false, "saved-audio retranscription requests should not preserve meeting titles")

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "mic_stream_present": "true",
                "trigger": "saved_meeting_retranscription",
            ],
            allowedKeys: requested?.allowedProperties ?? []
        )
        assertEqual(sanitized["mic_stream_present"], "true", "mic stream presence should survive the analytics sanitizer")
        assertEqual(sanitized["trigger"], "saved_meeting_retranscription", "saved-meeting trigger should survive the analytics sanitizer")
    }

    runSuite("AnalyticsEventPolicy allows meeting_file_imported with queue depth") {
        let fileImported = AnalyticsEventPolicy.policy(forEvent: "meeting_file_imported")
        assertEqual(fileImported?.allowedProperties.contains("queue_depth_bucket"), true, "file import should allow bucketed queue depth")
    }

    runSuite("AnalyticsEventPolicy allows only stable imported-audio failure fields") {
        let fileImportFailed = AnalyticsEventPolicy.policy(forEvent: "meeting_file_import_failed")
        assertEqual(fileImportFailed?.allowedProperties.contains("failure_kind"), true, "file import failures should preserve normalized failure kind")
        assertEqual(fileImportFailed?.allowedProperties.contains("import_stage"), true, "file import failures should preserve the coarse failure stage")
        assertEqual(fileImportFailed?.allowedProperties.contains("error"), false, "file import failures should not allow raw error text")
        assertEqual(fileImportFailed?.allowedProperties.contains("file"), false, "file import failures should not allow filenames")
        assertEqual(fileImportFailed?.allowedProperties.contains("title"), false, "file import failures should not allow source-derived titles")
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

private func documentedAnalyticsEvents() -> [String] {
    let text = loadRepoText("docs/privacy-first-observability.md")
    let section = markdownSection(
        named: "## Allowlisted analytics events",
        in: text
    )

    return section.split(separator: "\n").compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- `"), trimmed.hasSuffix("`") else {
            return nil
        }

        return String(trimmed.dropFirst(3).dropLast())
    }
}

private func sourceAnalyticsPolicyEvents() -> [String] {
    let text = loadRepoText("Sources/Observability/AnalyticsEventPolicy.swift")
    guard let start = text.range(of: "private static let allowedPolicies: [String: AnalyticsEventPolicy] = [") else {
        return []
    }

    let sourceAfterStart = String(text[start.upperBound...])
    guard let end = sourceAfterStart.range(of: "\n    ]") else {
        return []
    }

    let policyBody = String(sourceAfterStart[..<end.lowerBound])
    return policyBody.split(separator: "\n").compactMap { line in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("\""), trimmed.contains("\": .init(") else {
            return nil
        }

        let withoutLeadingQuote = trimmed.dropFirst()
        guard let closingQuote = withoutLeadingQuote.firstIndex(of: "\"") else {
            return nil
        }

        return String(withoutLeadingQuote[..<closingQuote])
    }
}

private func markdownSection(named heading: String, in text: String) -> String {
    guard let start = text.range(of: heading) else {
        return ""
    }

    let sourceAfterHeading = String(text[start.upperBound...])
    guard let end = sourceAfterHeading.range(of: "\n## ") else {
        return sourceAfterHeading
    }

    return String(sourceAfterHeading[..<end.lowerBound])
}

private func loadRepoText(_ relativePath: String, file: String = #file, line: Int = #line) -> String {
    let url = repoFixtureURL(relativePath)

    do {
        return try String(contentsOf: url, encoding: .utf8)
    } catch {
        failedTests += 1
        totalTests += 1
        let loc = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        print("  FAIL [\(loc)] could not load \(relativePath): \(error)")
        return ""
    }
}
