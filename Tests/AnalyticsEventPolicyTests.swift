import Foundation

func testAnalyticsEventPolicy() {
    runSuite("AnalyticsEventPolicy docs list matches the source allowlist") {
        let documentedEvents = documentedAnalyticsEvents().sorted()
        let policyEvents = AnalyticsEventPolicy.allEventNames.sorted()

        assertFalse(documentedEvents.isEmpty, "privacy observability doc should list analytics events")
        assertFalse(policyEvents.isEmpty, "analytics event policy should expose its allowlisted event names")
        assertEqual(
            documentedEvents,
            policyEvents,
            "docs/privacy-first-observability.md should list the same analytics events as Resources/analytics-events.psv"
        )
    }

    runSuite("AnalyticsEventPolicy taxonomy file stays union-merge clean") {
        let fileEvents = taxonomyFileEventNames()
        let uniqueFileEvents = Set(fileEvents)

        assertFalse(fileEvents.isEmpty, "Resources/analytics-events.psv should list analytics events")
        assertEqual(
            fileEvents.count,
            uniqueFileEvents.count,
            "Resources/analytics-events.psv must keep one line per event; run scripts/ops/normalize-analytics-taxonomy.py after a union merge"
        )
        assertEqual(
            uniqueFileEvents.sorted(),
            AnalyticsEventPolicy.allEventNames.sorted(),
            "the compiled allowlist should reflect exactly the events in Resources/analytics-events.psv"
        )
    }

    runSuite("AnalyticsEventPolicy taxonomy blocks sensitive property names") {
        let forbiddenFragments = [
            "audio_path",
            "audio_ref",
            "authorization",
            "bundle",
            "credential",
            "device_id",
            "distinct_id",
            "email",
            "file",
            "filename",
            "identity",
            "invitee",
            "meeting_title",
            "person_id",
            "raw_url",
            "referrer",
            "speaker",
            "source_app",
            "text",
            "title",
            "token",
            "transcript",
            "url",
            "user_id",
        ]
        let properties = allAllowedAnalyticsPropertyNames()

        for property in properties {
            let normalized = property.lowercased()
            for fragment in forbiddenFragments {
                assertFalse(
                    normalized.contains(fragment),
                    "\(property) should not include forbidden analytics fragment \(fragment)"
                )
            }
        }
    }

    runSuite("AnalyticsEventPolicy taxonomy requires reviewed non-bucket property shapes") {
        let reviewedNonBucketProperties = reviewedNonBucketAnalyticsProperties()
        let properties = allAllowedAnalyticsPropertyNames()

        for property in properties where !property.hasSuffix("_bucket") {
            assertTrue(
                reviewedNonBucketProperties.contains(property),
                "\(property) must be explicitly reviewed as an enum, boolean, public version, count, or coarse numeric diagnostic"
            )
        }
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

    runSuite("AnalyticsEventPolicy pins active onboarding activation events") {
        let expected: [(String, Set<String>)] = [
            ("onboarding_model_state_changed", ["from_status", "step_id", "to_status"]),
            ("onboarding_primary_cta_clicked", ["cta", "cta_type", "flow_elapsed_bucket", "model_state", "step_elapsed_bucket", "step_id"]),
            ("onboarding_first_dictation_started", ["model_state", "step_id"]),
            ("onboarding_first_dictation_saved", ["delivery", "step_id", "word_count_bucket"]),
            ("onboarding_first_dictation_stop_clicked", ["step_id"]),
            ("onboarding_first_dictation_empty", ["step_id"]),
            ("onboarding_agent_cta_clicked", ["agent_cta", "step_id"]),
            ("onboarding_reporting_toggle_changed", ["available", "enabled", "reporting_kind", "step_id"]),
        ]

        for (event, properties) in expected {
            assertEqual(
                AnalyticsEventPolicy.policy(forEvent: event)?.allowedProperties ?? Set<String>(),
                properties,
                "\(event) should keep a narrow activation payload"
            )
        }
    }

    runSuite("AnalyticsEventPolicy allows post-artifact activation events") {
        let artifact = AnalyticsEventPolicy.policy(forEvent: "activation_artifact_action_clicked")
        let firstArtifact = AnalyticsEventPolicy.policy(forEvent: "activation_first_artifact_saved")
        let dictationArtifact = AnalyticsEventPolicy.policy(forEvent: "dictation_artifact_saved")
        let secondArtifact = AnalyticsEventPolicy.policy(forEvent: "activation_second_artifact_saved")
        let prompt = AnalyticsEventPolicy.policy(forEvent: "activation_agent_prompt_action_clicked")
        let setup = AnalyticsEventPolicy.policy(forEvent: "activation_agent_setup_cta_clicked")
        let agentQuery = AnalyticsEventPolicy.policy(forEvent: "agent_capture_query_observed")
        let returnProxy = AnalyticsEventPolicy.policy(forEvent: "activation_return_proxy_observed")

        assertEqual(artifact?.allowedProperties ?? Set<String>(), ["action_kind", "artifact_age_bucket", "artifact_kind", "duration_bucket", "result", "surface", "trigger", "word_count_bucket"], "artifact actions should stay bucketed")
        assertEqual(firstArtifact?.allowedProperties ?? Set<String>(), ["artifact_kind", "duration_bucket", "surface", "trigger", "word_count_bucket"], "first artifact saves should stay bucketed")
        assertEqual(dictationArtifact?.allowedProperties ?? Set<String>(), ["delivery", "duration_bucket", "save_outcome", "surface", "trigger", "word_count_bucket"], "dictation saved-artifact events should stay bucketed and enum-only")
        assertEqual(secondArtifact?.allowedProperties ?? Set<String>(), ["days_since_first_bucket", "first_artifact_kind", "second_artifact_kind", "surface", "trigger"], "second artifact saves should stay bucketed")
        assertEqual(prompt?.allowedProperties ?? Set<String>(), ["action_kind", "agent_target", "artifact_kind", "prompt_kind", "result", "surface"], "agent prompt actions should stay enum-only")
        assertEqual(setup?.allowedProperties ?? Set<String>(), ["agent_target", "prior_status", "result", "setup_kind", "surface"], "setup CTAs should stay enum-only")
        assertEqual(returnProxy?.allowedProperties ?? Set<String>(), ["prior_artifact_kind", "proxy_kind", "return_window_bucket", "surface"], "return proxy should not include paths or titles")
        assertEqual(agentQuery?.allowedProperties ?? Set<String>(), ["client_family", "capture_kind", "result", "source_count_bucket", "tool_kind"], "agent query observation should stay enum and bucket only")
        assertEqual(
            agentQuery?.allowedProperties ?? Set<String>(),
            mcpAgentCaptureQueryAllowedProperties(),
            "MCP agent capture telemetry must mirror the app analytics allowlist"
        )

        let activationAllowedProperties = (prompt?.allowedProperties ?? Set<String>())
            .union(artifact?.allowedProperties ?? Set<String>())
            .union(firstArtifact?.allowedProperties ?? Set<String>())
            .union(dictationArtifact?.allowedProperties ?? Set<String>())
            .union(secondArtifact?.allowedProperties ?? Set<String>())
            .union(agentQuery?.allowedProperties ?? Set<String>())
        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "action_kind": "open_markdown",
                "agent_target": "mcp_client",
                "artifact_age_bucket": "24_48h",
                "artifact_kind": "meeting",
                "capture_age_bucket": "2_7d",
                "capture_kind": "meeting",
                "client_family": "mcp",
                "days_since_first_bucket": "2_7d",
                "duration_bucket": "10_29m",
                "first_artifact_kind": "dictation",
                "prompt_kind": "meeting_bundle",
                "query_kind": "search",
                "result": "success",
                "return_window_bucket": "3_7d",
                "save_outcome": "success",
                "second_artifact_kind": "meeting",
                "source_count_bucket": "2_3",
                "surface": "home_preview",
                "tool_kind": "search",
                "trigger": "detected_prompt",
                "word_count_bucket": "300_plus",
                "first_artifact_saved_at": "2026-06-19T12:00:00Z",
                "transcript": "private words",
                "meeting_title": "Customer call",
                "speaker_name": "Alice",
                "audio_path": "/Users/redbars/private.wav",
                "file_path": "/Users/redbars/private.md",
                "meeting_url": "https://example.com/private",
                "prompt_text": "Read my transcript",
                "query_text": "customer roadmap objection",
                "raw_capture_id": "cap_private",
                "source_app_name": "Slack",
                "word_count": "4217",
            ],
            allowedKeys: activationAllowedProperties
        )

        assertEqual(sanitized["action_kind"], "open_markdown", "action kind should survive")
        assertEqual(sanitized["agent_target"], "mcp_client", "agent target should survive")
        assertEqual(sanitized["artifact_age_bucket"], "24_48h", "artifact age bucket should survive")
        assertEqual(sanitized["artifact_kind"], "meeting", "artifact kind should survive")
        assertNil(sanitized["capture_age_bucket"], "agent query observation no longer sends capture age buckets")
        assertEqual(sanitized["capture_kind"], "meeting", "capture kind should survive")
        assertEqual(sanitized["client_family"], "mcp", "client family should survive")
        assertEqual(sanitized["days_since_first_bucket"], "2_7d", "days since first bucket should survive")
        assertEqual(sanitized["duration_bucket"], "10_29m", "duration bucket should survive")
        assertEqual(sanitized["first_artifact_kind"], "dictation", "first artifact kind should survive")
        assertEqual(sanitized["prompt_kind"], "meeting_bundle", "prompt kind should survive")
        assertNil(sanitized["query_kind"], "agent query observation no longer sends query kind")
        assertEqual(sanitized["result"], "success", "coarse action result should survive")
        assertNil(sanitized["return_window_bucket"], "agent query observation no longer sends return window buckets")
        assertEqual(sanitized["save_outcome"], "success", "coarse save result should survive")
        assertEqual(sanitized["second_artifact_kind"], "meeting", "second artifact kind should survive")
        assertEqual(sanitized["source_count_bucket"], "2_3", "source count bucket should survive")
        assertEqual(sanitized["surface"], "home_preview", "surface should survive")
        assertEqual(sanitized["tool_kind"], "search", "tool kind should survive")
        assertEqual(sanitized["trigger"], "detected_prompt", "trigger should survive")
        assertEqual(sanitized["word_count_bucket"], "300_plus", "word count bucket should survive")
        assertNil(sanitized["first_artifact_saved_at"], "raw first-save timestamps must not be sent")
        assertNil(sanitized["transcript"], "raw transcript text must not be sent")
        assertNil(sanitized["meeting_title"], "meeting titles must not be sent")
        assertNil(sanitized["speaker_name"], "speaker names must not be sent")
        assertNil(sanitized["audio_path"], "audio paths must not be sent")
        assertNil(sanitized["file_path"], "file paths must not be sent")
        assertNil(sanitized["meeting_url"], "meeting URLs must not be sent")
        assertNil(sanitized["prompt_text"], "raw prompt text must not be sent")
        assertNil(sanitized["query_text"], "raw query text must not be sent")
        assertNil(sanitized["raw_capture_id"], "raw capture IDs must not be sent")
        assertNil(sanitized["source_app_name"], "source app names must not be sent")
        assertNil(sanitized["word_count"], "raw counts should stay out of activation analytics")
    }

    runSuite("AnalyticsEventPolicy allows Dayflow timeline scaffold events without screen content") {
        let expected: [(String, Set<String>)] = [
            ("timeline_enabled", ["permission_state", "provider_kind", "result", "surface"]),
            ("timeline_screen_permission_ready", ["permission_state", "result", "surface"]),
            ("timeline_screen_permission_denied", ["permission_state", "result", "surface"]),
            ("timeline_capture_paused", ["pause_reason", "result", "surface"]),
            ("timeline_capture_resumed", ["pause_reason", "result", "surface"]),
            ("timeline_card_generated", ["card_kind", "count_bucket", "duration_bucket", "provider_kind", "result", "surface"]),
            ("timeline_card_opened", ["card_kind", "result", "surface"]),
            ("timeline_daily_markdown_written", ["count_bucket", "duration_bucket", "result", "surface"]),
            ("timeline_used_again", ["return_window_bucket", "surface"]),
        ]

        for (event, properties) in expected {
            assertEqual(
                AnalyticsEventPolicy.policy(forEvent: event)?.allowedProperties ?? Set<String>(),
                properties,
                "\(event) should stay coarse and privacy-reviewed"
            )
        }

        let generatedProperties: [String: String] = [
            "surface": TimelineAnalyticsTelemetry.Surface.timelineHome.rawValue,
            "result": TimelineAnalyticsTelemetry.Result.success.rawValue,
            "provider_kind": TimelineAnalyticsTelemetry.ProviderKind.localLLM.rawValue,
            "card_kind": TimelineAnalyticsTelemetry.CardKind.activity.rawValue,
            "duration_bucket": AnalyticsReporter.durationBucket(seconds: 42),
            "count_bucket": AnalyticsReporter.countBucket(5),
            "ocr_text": "private screen words",
            "screenshot_path": "/Users/redbars/private.png",
            "app_name": "Safari",
            "window_title": "Customer dashboard",
            "url": "https://example.com/private",
            "bundle_id": "com.private.app",
            "person_id": "person_123",
        ]
        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            generatedProperties,
            allowedKeys: AnalyticsEventPolicy.policy(forEvent: "timeline_card_generated")?.allowedProperties ?? Set<String>()
        )

        assertEqual(sanitized["surface"], "timeline_home", "timeline surface should survive as an enum")
        assertEqual(sanitized["result"], "success", "timeline result should survive as an enum")
        assertEqual(sanitized["provider_kind"], "local_llm", "provider kind should stay coarse")
        assertEqual(sanitized["card_kind"], "activity", "card kind should stay coarse")
        assertEqual(sanitized["duration_bucket"], "30_119s", "duration should stay bucketed")
        assertEqual(sanitized["count_bucket"], "4_9", "counts should stay bucketed")
        assertNil(sanitized["ocr_text"], "OCR text must not be sent")
        assertNil(sanitized["screenshot_path"], "screenshot paths must not be sent")
        assertNil(sanitized["app_name"], "app names must not be sent")
        assertNil(sanitized["window_title"], "window titles must not be sent")
        assertNil(sanitized["url"], "URLs must not be sent")
        assertNil(sanitized["bundle_id"], "raw bundle IDs must not be sent")
        assertNil(sanitized["person_id"], "personal identifiers must not be sent")

        let now = Date(timeIntervalSinceReferenceDate: 5_000_000)
        assertNil(
            TimelineAnalyticsTelemetry.returnWindowBucket(since: now.addingTimeInterval(-2 * 3_600), now: now),
            "immediate same-session timeline reuse should not emit a return bucket"
        )
        assertEqual(
            TimelineAnalyticsTelemetry.returnWindowBucket(since: now.addingTimeInterval(-24 * 3_600), now: now),
            "18_36h",
            "next-day timeline reuse should use a coarse return bucket"
        )
    }

    runSuite("ActivationTelemetry buckets artifact age, first-artifact saves, dictation artifacts, and next-day return proxy") {
        let now = Date(timeIntervalSinceReferenceDate: 1_000_000)
        let suiteName = "ActivationTelemetryTests.first-artifact.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(
            ActivationTelemetry.artifactAgeBucket(since: now.addingTimeInterval(-3 * 3_600), now: now),
            "lt_12h",
            "same-session artifacts should stay in the shortest age bucket"
        )
        assertEqual(
            ActivationTelemetry.artifactAgeBucket(since: now.addingTimeInterval(-30 * 3_600), now: now),
            "24_48h",
            "next-day artifacts should use a stable age bucket"
        )
        assertNil(
            ActivationTelemetry.returnWindowBucket(since: now.addingTimeInterval(-2 * 3_600), now: now),
            "return proxy should not fire for immediate same-session refreshes"
        )
        assertEqual(
            ActivationTelemetry.returnWindowBucket(since: now.addingTimeInterval(-24 * 3_600), now: now),
            "18_36h",
            "next-day return proxy should capture the 18-36h window"
        )
        assertEqual(
            ActivationTelemetry.returnWindowBucket(since: now.addingTimeInterval(-96 * 3_600), now: now),
            "3_7d",
            "late return proxy should stay bucketed"
        )
        assertTrue(
            ActivationTelemetry.markFirstArtifactSavedTrackedIfNeeded(userDefaults: defaults),
            "first saved artifact should be marked once per install"
        )
        assertFalse(
            ActivationTelemetry.markFirstArtifactSavedTrackedIfNeeded(userDefaults: defaults),
            "first saved artifact should not be marked twice"
        )
        let dictationProperties = ActivationTelemetry.dictationArtifactSavedProperties(
            delivery: "pasted",
            durationBucket: "30_119s",
            saveOutcome: "success",
            surface: .dictationSave,
            trigger: "hotkey",
            wordCountBucket: "10_49"
        )
        assertEqual(
            Set(dictationProperties.keys),
            ["delivery", "duration_bucket", "save_outcome", "surface", "trigger", "word_count_bucket"],
            "dictation artifact save telemetry should not include raw text, paths, filenames, app names, titles, or counts"
        )
        assertEqual(dictationProperties["surface"], "dictation_save", "saved dictation surface should stay coarse")

        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(
            "ActivationTelemetryTests.saved-dictation.\(UUID().uuidString)",
            isDirectory: true
        )
        let outputDir = tempRoot.appendingPathComponent("dictations", isDirectory: true)
        try? fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        let saved = try? DictationTranscriptStore.save(
            text: "saved artifact proof",
            sourceApp: nil,
            delivery: .pasted,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            directory: outputDir
        )
        assertEqual(
            saved.map { ActivationTelemetry.savedDictationArtifactExists($0) },
            true,
            "dictation_artifact_saved may fire only after a regular Markdown file exists on disk"
        )

        if let saved {
            try? fm.removeItem(at: saved.url)
            assertFalse(
                ActivationTelemetry.trackDictationArtifactSaved(
                    saved: saved,
                    delivery: "pasted",
                    durationBucket: "10_29s",
                    trigger: "hotkey",
                    wordCountBucket: "10_49"
                ),
                "missing saved Markdown must block dictation_artifact_saved even if a stale save result exists"
            )
        }
    }

    runSuite("ActivationTelemetry tracks first and second artifact saves once per install") {
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000)
        let suiteName = "ActivationTelemetryTests.second-artifact.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = ActivationTelemetry.recordArtifactSave(
            artifactKind: .dictation,
            savedAt: now,
            userDefaults: defaults
        )
        assertTrue(first.firstArtifact, "first durable artifact should be recognized")
        assertNil(first.secondArtifact, "first durable artifact should not also be second")

        let second = ActivationTelemetry.recordArtifactSave(
            artifactKind: .meeting,
            savedAt: now.addingTimeInterval(3 * 86_400),
            userDefaults: defaults
        )
        assertFalse(second.firstArtifact, "second durable artifact should not retrigger first")
        assertEqual(second.secondArtifact?.firstKind.rawValue, "dictation", "second event should preserve the first artifact kind enum")
        assertEqual(second.secondArtifact?.daysSinceFirstBucket, "2_7d", "second event should bucket days since first")

        let third = ActivationTelemetry.recordArtifactSave(
            artifactKind: .meeting,
            savedAt: now.addingTimeInterval(4 * 86_400),
            userDefaults: defaults
        )
        assertFalse(third.firstArtifact, "later durable artifacts should not retrigger first")
        assertNil(third.secondArtifact, "second durable artifact should only be tracked once")

        assertEqual(
            ActivationTelemetry.daysSinceFirstBucket(since: now.addingTimeInterval(-6 * 3_600), now: now),
            "same_day",
            "same-day second artifacts should stay coarse"
        )
        assertEqual(
            ActivationTelemetry.daysSinceFirstBucket(since: now.addingTimeInterval(-20 * 86_400), now: now),
            "8_30d",
            "longer second-artifact gaps should stay bucketed"
        )
        assertEqual(
            ActivationTelemetry.daysSinceFirstBucket(since: nil, now: now),
            "unknown",
            "legacy installs without first-save date should not invent a raw timestamp"
        )
        assertEqual(
            ActivationTelemetry.artifactCountBucket(0),
            "0",
            "empty artifact counts should stay bucketed"
        )
        assertEqual(
            ActivationTelemetry.artifactCountBucket(4),
            "3_5",
            "mid-sized artifact counts should stay bucketed"
        )
        assertEqual(
            ActivationTelemetry.artifactCountBucket(9),
            "6_plus",
            "large artifact counts should stay capped"
        )
        let habitPolicy = AnalyticsEventPolicy.policy(forEvent: "activation_habit_loop_actioned")
        assertEqual(
            habitPolicy?.allowedProperties ?? Set<String>(),
            ["action_kind", "artifact_count_bucket", "artifact_kind", "result", "return_window_bucket", "surface"],
            "habit loop telemetry should stay enum and bucket only"
        )
    }

    runSuite("ActivationTelemetry emits second artifact for legacy first-artifact installs") {
        let suiteName = "ActivationTelemetryTests.legacy-second-artifact.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: ActivationTelemetry.firstArtifactSavedTrackedKey)

        let legacySecond = ActivationTelemetry.recordArtifactSave(
            artifactKind: .meeting,
            savedAt: Date(timeIntervalSinceReferenceDate: 3_000_000),
            userDefaults: defaults
        )
        assertFalse(legacySecond.firstArtifact, "legacy installs should not retrigger first artifact")
        assertEqual(legacySecond.secondArtifact?.firstKind.rawValue, "unknown", "legacy second-artifact event should avoid inventing first kind")
        assertEqual(legacySecond.secondArtifact?.daysSinceFirstBucket, "unknown", "legacy second-artifact event should avoid inventing first date")
    }

    runSuite("ActivationTelemetry does not retain opted-out first artifact metadata") {
        let suiteName = "ActivationTelemetryTests.opt-out-first-artifact.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AnalyticsPreferences.setEnabled(false, userDefaults: defaults)
        let disabledResult = ActivationTelemetry.trackFirstArtifactSavedIfNeeded(
            artifactKind: .dictation,
            surface: .dictationSave,
            trigger: "hotkey",
            savedAt: Date(timeIntervalSinceReferenceDate: 4_000_000),
            userDefaults: defaults
        )
        assertFalse(disabledResult, "opted-out first artifact should not report")
        assertFalse(defaults.bool(forKey: ActivationTelemetry.firstArtifactSavedTrackedKey), "opted-out first artifact should not mark first-save telemetry state")
        assertNil(defaults.string(forKey: ActivationTelemetry.firstArtifactKindKey), "opted-out first artifact should not store kind for later reporting")
        assertNil(defaults.object(forKey: ActivationTelemetry.firstArtifactSavedAtKey), "opted-out first artifact should not store date for later reporting")

        AnalyticsPreferences.setEnabled(true, userDefaults: defaults)
        let enabledResult = ActivationTelemetry.trackFirstArtifactSavedIfNeeded(
            artifactKind: .meeting,
            surface: .meetingSave,
            trigger: "manual",
            savedAt: Date(timeIntervalSinceReferenceDate: 4_100_000),
            userDefaults: defaults
        )
        assertTrue(enabledResult, "first artifact after analytics opt-in should be treated as the first observable artifact")
        assertEqual(defaults.string(forKey: ActivationTelemetry.firstArtifactKindKey), "meeting", "only opted-in artifact kind should be retained")
    }

    runSuite("AnalyticsEventPolicy allows workflow abandonment taxonomy") {
        let abandoned = AnalyticsEventPolicy.policy(forEvent: "workflow_abandoned")
        assertEqual(
            abandoned?.allowedProperties ?? Set<String>(),
            ["elapsed_bucket", "prior_ready_state", "reason_kind", "stage", "surface", "workflow_kind"],
            "workflow abandonment should stay coarse and enum-only"
        )

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "workflow_kind": "failed_meeting_retry",
                "stage": "retry_available",
                "reason_kind": "dismissed",
                "elapsed_bucket": "unknown",
                "surface": "home",
                "prior_ready_state": "retry_ready",
                "meeting_title": "Customer call",
                "file_path": "/Users/redbars/private.md",
                "raw_duration": "472.221",
                "raw_error": "private stack",
                "source_app": "Zoom",
                "url": "https://example.com/meeting",
            ],
            allowedKeys: abandoned?.allowedProperties ?? []
        )

        assertEqual(sanitized["workflow_kind"], "failed_meeting_retry", "workflow kind should survive")
        assertEqual(sanitized["stage"], "retry_available", "stage should survive")
        assertEqual(sanitized["reason_kind"], "dismissed", "reason kind should survive")
        assertEqual(sanitized["elapsed_bucket"], "unknown", "elapsed bucket should survive")
        assertEqual(sanitized["surface"], "home", "surface should survive")
        assertEqual(sanitized["prior_ready_state"], "retry_ready", "prior ready state should survive")
        assertNil(sanitized["meeting_title"], "meeting titles must not be sent")
        assertNil(sanitized["file_path"], "file paths must not be sent")
        assertNil(sanitized["raw_duration"], "raw durations must not be sent")
        assertNil(sanitized["raw_error"], "raw errors must not be sent")
        assertNil(sanitized["source_app"], "source apps must not be sent")
        assertNil(sanitized["url"], "raw URLs must not be sent")
    }

    runSuite("AnalyticsEventPolicy allows workflow recovery taxonomy") {
        let attempted = AnalyticsEventPolicy.policy(forEvent: "workflow_recovery_attempted")
        assertEqual(
            attempted?.allowedProperties ?? Set<String>(),
            ["artifact_retained", "failure_kind", "recovery_attempt_bucket", "retry_source", "surface", "workflow_kind"],
            "workflow recovery attempts should stay coarse and enum-only"
        )

        let finished = AnalyticsEventPolicy.policy(forEvent: "workflow_recovery_finished")
        assertEqual(
            finished?.allowedProperties ?? Set<String>(),
            ["artifact_retained", "elapsed_bucket", "failure_kind", "recovery_attempt_bucket", "result", "retry_source", "surface", "workflow_kind"],
            "workflow recovery terminal events should preserve only buckets and terminal result"
        )

        let failed = AnalyticsEventPolicy.policy(forEvent: "workflow_recovery_failed")
        assertEqual(
            failed?.allowedProperties ?? Set<String>(),
            ["artifact_retained", "elapsed_bucket", "failure_kind", "recovery_attempt_bucket", "result", "retry_source", "surface", "workflow_kind"],
            "workflow recovery failed events should match the terminal payload without adding raw failure details"
        )

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "workflow_kind": "local_summary",
                "failure_kind": "timeout",
                "retry_source": "summary_failure_notice",
                "recovery_attempt_bucket": "1",
                "elapsed_bucket": "30_59s",
                "result": "success",
                "surface": "home",
                "artifact_retained": "true",
                "attempt_bucket": "1",
                "meeting_title": "Customer call",
                "audio_path": "/Users/redbars/private.wav",
                "transcript_text": "private transcript",
                "raw_error": "stack trace",
            ],
            allowedKeys: finished?.allowedProperties ?? []
        )

        assertEqual(sanitized["workflow_kind"], "local_summary", "workflow kind should survive")
        assertEqual(sanitized["failure_kind"], "timeout", "failure kind should survive")
        assertEqual(sanitized["retry_source"], "summary_failure_notice", "retry source should survive")
        assertEqual(sanitized["recovery_attempt_bucket"], "1", "recovery attempt bucket should survive")
        assertEqual(sanitized["elapsed_bucket"], "30_59s", "elapsed bucket should survive")
        assertEqual(sanitized["result"], "success", "terminal result should survive")
        assertEqual(sanitized["surface"], "home", "surface should survive")
        assertEqual(sanitized["artifact_retained"], "true", "artifact retention should survive as a boolean string")
        assertNil(sanitized["attempt_bucket"], "legacy attempt bucket should not be allowlisted")
        assertNil(sanitized["meeting_title"], "meeting titles must not be sent")
        assertNil(sanitized["audio_path"], "audio paths must not be sent")
        assertNil(sanitized["transcript_text"], "transcript text must not be sent")
        assertNil(sanitized["raw_error"], "raw errors must not be sent")
    }

    runSuite("WorkflowRecoveryTelemetry emits the allowlisted recovery attempt bucket") {
        let source = readAnalyticsPolicyRepoTextFile("Sources/Observability/WorkflowRecoveryTelemetry.swift")
        assertTrue(
            source.contains("\"recovery_attempt_bucket\": AnalyticsReporter.countBucket(attempt)"),
            "workflow recovery helper should emit the allowlisted recovery attempt bucket key"
        )
        assertFalse(
            source.contains("\"attempt_bucket\""),
            "workflow recovery helper should not emit the legacy attempt bucket key"
        )
        assertTrue(
            source.contains("\"workflow_recovery_failed\""),
            "workflow recovery helper should emit a dedicated failed terminal event for failure drill-down"
        )
    }

    runSuite("AnalyticsEventPolicy allows product friction only as coarse enums and buckets") {
        let friction = AnalyticsEventPolicy.policy(forEvent: "product_friction_observed")
        assertEqual(
            friction?.allowedProperties ?? Set<String>(),
            ["elapsed_bucket", "failure_kind", "model_state", "result", "route_shape", "stage", "surface"],
            "product friction should stay narrowly scoped"
        )

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "elapsed_bucket": "10_29s",
                "failure_kind": "pasteback_failed",
                "model_state": "ready",
                "result": "failed",
                "route_shape": "built_in_input_to_bluetooth_output",
                "stage": "pasteback",
                "surface": "dictation",
                "error_message": "private raw error",
                "audio_path": "/Users/jane/private.wav",
                "file_path": "/Users/jane/private.md",
                "meeting_title": "Customer roadmap",
                "source_app_bundle": "com.example.Private",
                "transcript_text": "private transcript",
                "retry_count": "7",
            ],
            allowedKeys: friction?.allowedProperties ?? []
        )

        assertEqual(sanitized["elapsed_bucket"], "10_29s", "elapsed time should survive only as a bucket")
        assertEqual(sanitized["failure_kind"], "pasteback_failed", "failure kind should survive as a normalized enum")
        assertEqual(sanitized["model_state"], "ready", "model state should survive as a coarse enum")
        assertEqual(sanitized["result"], "failed", "result should survive as a coarse enum")
        assertEqual(sanitized["route_shape"], "built_in_input_to_bluetooth_output", "route shape should survive as a coarse enum")
        assertEqual(sanitized["stage"], "pasteback", "stage should survive as a coarse enum")
        assertEqual(sanitized["surface"], "dictation", "surface should survive as a coarse enum")
        assertNil(sanitized["error_message"], "raw error strings should stay out of friction analytics")
        assertNil(sanitized["audio_path"], "audio paths should stay out of friction analytics")
        assertNil(sanitized["file_path"], "file paths should stay out of friction analytics")
        assertNil(sanitized["meeting_title"], "meeting titles should stay out of friction analytics")
        assertNil(sanitized["source_app_bundle"], "source app bundle IDs should stay out of friction analytics")
        assertNil(sanitized["transcript_text"], "transcript text should stay out of friction analytics")
        assertNil(sanitized["retry_count"], "raw retry counts should stay out of friction analytics")
    }

    runSuite("AnalyticsEventPolicy allows menu and settings behavior events") {
        let menuOpened = AnalyticsEventPolicy.policy(forEvent: "menu_bar_opened")
        let menuAction = AnalyticsEventPolicy.policy(forEvent: "menu_bar_action_clicked")
        let settingsOpened = AnalyticsEventPolicy.policy(forEvent: "settings_opened")
        let settingsPage = AnalyticsEventPolicy.policy(forEvent: "settings_page_viewed")
        let settingsFeature = AnalyticsEventPolicy.policy(forEvent: "settings_feature_discovered")
        let settingsAction = AnalyticsEventPolicy.policy(forEvent: "settings_action_clicked")
        let settingsToggle = AnalyticsEventPolicy.policy(forEvent: "settings_toggle_changed")
        let settingsPermission = AnalyticsEventPolicy.policy(forEvent: "settings_permission_cta_clicked")
        let captureLibrary = AnalyticsEventPolicy.policy(forEvent: "settings_capture_library_changed")
        let updateAction = AnalyticsEventPolicy.policy(forEvent: "update_action_clicked")
        let updateSetting = AnalyticsEventPolicy.policy(forEvent: "update_setting_changed")
        let updateCheckFinished = AnalyticsEventPolicy.policy(forEvent: "update_check_finished")
        let liveTranscriptDrawer = AnalyticsEventPolicy.policy(forEvent: "meeting_live_transcript_drawer_actioned")

        assertEqual(menuOpened?.allowedProperties.contains("paste_available"), true, "menu opens should preserve whether paste has value")
        assertEqual(menuAction?.allowedProperties.contains("action_id"), true, "menu clicks should preserve the clicked action")
        assertEqual(settingsOpened?.allowedProperties.contains("source"), true, "settings opens should preserve entry source")
        assertEqual(settingsPage?.allowedProperties.contains("page_id"), true, "settings page views should preserve page id")
        assertEqual(settingsFeature?.allowedProperties ?? Set<String>(), ["feature_area", "page_id", "source"], "feature discovery should preserve only the area, page, and source")
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
        assertEqual(liveTranscriptDrawer?.allowedProperties ?? Set<String>(), ["action_kind", "result", "surface", "trigger"], "live transcript drawer adoption should stay enum-only")

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "action_id": "start_dictation",
                "action_kind": "open",
                "automatic_downloads_enabled": "true",
                "failure_code": "sparkle_2003",
                "failure_kind": "feed_unreachable",
                "feature_area": "agent_setup",
                "page_id": "home",
                "setting_id": "menu_bar_start_dictation",
                "source": "menu_bar",
                "state": "ready_to_install",
                "surface": "settings_about",
                "trigger": "overlay_button",
                "transcript_text": "private live transcript",
            ],
            allowedKeys: ["action_id", "action_kind", "automatic_downloads_enabled", "failure_code", "failure_kind", "feature_area", "page_id", "setting_id", "source", "state", "surface", "trigger"]
        )
        assertEqual(sanitized["action_id"], "start_dictation", "action ids should survive sanitization")
        assertEqual(sanitized["action_kind"], "open", "drawer actions should survive as coarse enums")
        assertEqual(sanitized["automatic_downloads_enabled"], "true", "automatic update download state should survive sanitization")
        assertEqual(sanitized["failure_code"], "sparkle_2003", "coarse update failure codes should survive sanitization")
        assertEqual(sanitized["failure_kind"], "feed_unreachable", "update failure kind should survive sanitization")
        assertEqual(sanitized["feature_area"], "agent_setup", "feature-area enums should survive sanitization")
        assertEqual(sanitized["page_id"], "home", "page ids should survive sanitization")
        assertEqual(sanitized["setting_id"], "menu_bar_start_dictation", "setting ids should survive sanitization")
        assertEqual(sanitized["source"], "menu_bar", "source enums should survive sanitization")
        assertEqual(sanitized["state"], "ready_to_install", "update state should survive sanitization")
        assertEqual(sanitized["surface"], "settings_about", "update surface should survive sanitization")
        assertEqual(sanitized["trigger"], "overlay_button", "drawer triggers should survive as coarse enums")
        assertNil(sanitized["transcript_text"], "live transcript text must not be sent")
    }

    runSuite("FeatureDiscoveryTelemetry tracks each high-leverage feature once") {
        let suiteName = "FeatureDiscoveryTelemetryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertTrue(
            FeatureDiscoveryTelemetry.markDiscoveredIfNeeded(featureArea: .agentSetup, userDefaults: defaults),
            "first discovery should be recorded"
        )
        assertFalse(
            FeatureDiscoveryTelemetry.markDiscoveredIfNeeded(featureArea: .agentSetup, userDefaults: defaults),
            "same feature discovery should not be recorded twice"
        )
        assertTrue(
            FeatureDiscoveryTelemetry.markDiscoveredIfNeeded(featureArea: .captureLibrary, userDefaults: defaults),
            "a different feature area should still be recorded"
        )
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
        let installed = AnalyticsEventPolicy.policy(forEvent: "update_installed")

        assertEqual(relaunching?.allowedProperties.contains("version"), true, "relaunch telemetry should preserve the public app version")
        assertEqual(relaunching?.allowedProperties.contains("state"), false, "relaunch telemetry should not add redundant update state")
        assertEqual(relaunching?.allowedProperties.contains("automatic_downloads_enabled"), false, "relaunch telemetry should not add settings state")
        assertEqual(installed?.allowedProperties.contains("version"), true, "installed update telemetry should preserve the public app version")
        assertEqual(installed?.allowedProperties.contains("previous_version"), true, "installed update telemetry should preserve the previous public app version")

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

        let installedSanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "previous_version": "1.2.2",
                "state": "ready_to_install",
                "version": "1.2.3",
            ],
            allowedKeys: installed?.allowedProperties ?? []
        )

        assertEqual(installedSanitized["version"], "1.2.3", "installed update telemetry should keep the target version")
        assertEqual(installedSanitized["previous_version"], "1.2.2", "installed update telemetry should keep the public previous version")
        assertNil(installedSanitized["state"], "installed update telemetry should stay lifecycle-specific")
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

    runSuite("AnalyticsEventPolicy allows dictation stop latency only as coarse buckets") {
        let stopLatency = AnalyticsEventPolicy.policy(forEvent: "dictation_stop_latency_measured")

        assertEqual(stopLatency?.allowedProperties.contains("trigger"), true, "dictation stop latency should preserve stop trigger attribution")
        assertEqual(stopLatency?.allowedProperties.contains("delivery"), true, "dictation stop latency should preserve delivery outcome")
        assertEqual(stopLatency?.allowedProperties.contains("word_count_bucket"), true, "dictation stop latency should preserve coarse text size")
        assertEqual(stopLatency?.allowedProperties.contains("stop_to_paste_bucket"), true, "dictation stop latency should bucket stop-to-paste time")
        assertEqual(stopLatency?.allowedProperties.contains("stop_to_done_bucket"), true, "dictation stop latency should bucket total stop pipeline time")
        assertEqual(stopLatency?.allowedProperties.contains("decode_bucket"), true, "dictation stop latency should bucket local model work without raw timings")

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "auto_enter_bucket": "lt_100ms",
                "auto_send": "disabled",
                "chars": "512",
                "cleanup_bucket": "lt_100ms",
                "cleanup_changed": "true",
                "cleanup_enabled": "true",
                "copy_reason": "focus_changed",
                "decode_bucket": "250_499ms",
                "delivery": "pasted",
                "mic_stop_bucket": "lt_100ms",
                "model_wait_bucket": "lt_100ms",
                "outcome": "completed",
                "paste_bucket": "100_249ms",
                "raw_text": "hello private words",
                "save_bucket": "lt_100ms",
                "save_outcome": "saved",
                "source_app_bundle": "com.example.PrivateApp",
                "stop_to_done_bucket": "500_999ms",
                "stop_to_done_ms": "742",
                "stop_to_paste_bucket": "500_999ms",
                "stop_to_paste_ms": "621",
                "trigger": "physical_key",
                "word_count_bucket": "10_49",
            ],
            allowedKeys: stopLatency?.allowedProperties ?? []
        )

        assertEqual(sanitized["stop_to_paste_bucket"], "500_999ms", "bucketed stop-to-paste timing should survive")
        assertEqual(sanitized["stop_to_done_bucket"], "500_999ms", "bucketed total stop timing should survive")
        assertEqual(sanitized["decode_bucket"], "250_499ms", "bucketed model work should survive")
        assertEqual(sanitized["copy_reason"], "focus_changed", "normalized copy reason should survive")
        assertEqual(sanitized["word_count_bucket"], "10_49", "coarse word count should survive")
        assertNil(sanitized["stop_to_paste_ms"], "raw stop-to-paste milliseconds should stay local")
        assertNil(sanitized["stop_to_done_ms"], "raw stop pipeline milliseconds should stay local")
        assertNil(sanitized["chars"], "raw character counts should stay local")
        assertNil(sanitized["raw_text"], "transcript text should stay out of analytics")
        assertNil(sanitized["source_app_bundle"], "source app bundle IDs should stay out of analytics")
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
        let dictationArtifactSaved = AnalyticsEventPolicy.policy(forEvent: "dictation_artifact_saved")
        let dictationStopLatency = AnalyticsEventPolicy.policy(forEvent: "dictation_stop_latency_measured")
        let dictationNoSpeech = AnalyticsEventPolicy.policy(forEvent: "dictation_no_speech")
        let dictationRecordingTooShort = AnalyticsEventPolicy.policy(forEvent: "dictation_recording_too_short")
        let meetingFailed = AnalyticsEventPolicy.policy(forEvent: "meeting_transcript_failed")
        let speakerFinalizationFailed = AnalyticsEventPolicy.policy(forEvent: "meeting_speaker_finalization_failed")
        let meetingSkipped = AnalyticsEventPolicy.policy(forEvent: "meeting_transcript_skipped")
        let unknown = AnalyticsEventPolicy.policy(forEvent: "raw_transcript_uploaded")

        assertEqual(dictationStartFailed?.allowedProperties.contains("failure_kind"), true, "dictation start failures should allow normalized failure kinds")
        assertEqual(dictationCompleted?.allowedProperties.contains("word_count_bucket"), true, "dictation completion should allow bucketed word counts")
        assertEqual(dictationArtifactSaved?.allowedProperties.contains("save_outcome"), true, "strict dictation saved-artifact proof should allow only a reviewed save outcome enum")
        assertEqual(dictationStopLatency?.allowedProperties.contains("stop_to_paste_bucket"), true, "dictation stop latency should allow only bucketed stop-to-paste timing")
        assertEqual(dictationNoSpeech?.allowedProperties.contains("duration_bucket"), true, "dictation no-speech should keep a coarse duration bucket")
        assertEqual(dictationNoSpeech?.allowedProperties.contains("trigger"), true, "dictation no-speech should preserve trigger attribution")
        assertEqual(dictationRecordingTooShort?.allowedProperties.contains("duration_bucket"), true, "dictation too-short should keep a coarse duration bucket")
        assertEqual(dictationRecordingTooShort?.allowedProperties.contains("trigger"), true, "dictation too-short should preserve trigger attribution")
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
        assertEqual(policy?.allowedProperties.contains("mic_boost_prompt"), true, "meeting stop events should preserve the issue 500 mic-boost prompt outcome")
        assertEqual(healthPolicy?.allowedProperties.contains("mic_boost_prompt"), true, "health snapshots should preserve the issue 500 mic-boost prompt outcome")

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

    runSuite("AnalyticsEventPolicy allows speaker review funnel events without names") {
        let shown = AnalyticsEventPolicy.policy(forEvent: "meeting_speaker_review_shown")
        let submitted = AnalyticsEventPolicy.policy(forEvent: "meeting_speaker_review_submitted")

        assertEqual(
            shown?.allowedProperties ?? Set<String>(),
            [
                "known_people_bucket",
                "local_voice_bucket",
                "match_suggestion_bucket",
                "remote_voice_bucket",
                "review_item_bucket",
                "review_reason",
                "surface",
            ],
            "speaker review shown should keep only inventory buckets and enums"
        )
        assertEqual(
            submitted?.allowedProperties ?? Set<String>(),
            [
                "completion_kind",
                "known_people_bucket",
                "local_voice_bucket",
                "match_suggestion_bucket",
                "remote_voice_bucket",
                "result",
                "review_item_bucket",
                "review_reason",
                "surface",
                "updates_submitted_bucket",
            ],
            "speaker review submitted should keep only outcome enums and buckets"
        )

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "completion_kind": "save",
                "known_people_bucket": "4_9",
                "local_voice_bucket": "1",
                "match_suggestion_bucket": "2_3",
                "remote_voice_bucket": "2_3",
                "result": "updates_submitted",
                "review_item_bucket": "4_9",
                "review_reason": "mixed",
                "surface": "speaker_review_sheet",
                "updates_submitted_bucket": "2_3",
                "audio_path": "/Users/jane/Private/customer.wav",
                "meeting_title": "Customer Roadmap",
                "speaker_id": "private-id",
                "speaker_name": "Alice Customer",
                "transcript_text": "private transcript words",
            ],
            allowedKeys: (shown?.allowedProperties ?? []).union(submitted?.allowedProperties ?? [])
        )

        assertEqual(sanitized["completion_kind"], "save", "completion kind should survive")
        assertEqual(sanitized["known_people_bucket"], "4_9", "known people bucket should survive")
        assertEqual(sanitized["local_voice_bucket"], "1", "local voice bucket should survive")
        assertEqual(sanitized["match_suggestion_bucket"], "2_3", "suggestion bucket should survive")
        assertEqual(sanitized["remote_voice_bucket"], "2_3", "remote voice bucket should survive")
        assertEqual(sanitized["result"], "updates_submitted", "coarse result should survive")
        assertEqual(sanitized["review_item_bucket"], "4_9", "review item bucket should survive")
        assertEqual(sanitized["review_reason"], "mixed", "review reason should survive")
        assertEqual(sanitized["surface"], "speaker_review_sheet", "surface should survive")
        assertEqual(sanitized["updates_submitted_bucket"], "2_3", "submitted update bucket should survive")
        assertNil(sanitized["audio_path"], "audio paths must not be sent")
        assertNil(sanitized["meeting_title"], "meeting titles must not be sent")
        assertNil(sanitized["speaker_id"], "speaker ids must not be sent")
        assertNil(sanitized["speaker_name"], "speaker names must not be sent")
        assertNil(sanitized["transcript_text"], "transcript text must not be sent")
    }

    runSuite("AnalyticsEventPolicy meeting outcomes drop adversarial private fields") {
        let privateFields = [
            "audio_device": "Jane's AirPods Pro",
            "audio_path": "/Users/jane/Private/customer.wav",
            "email": "person@example.com",
            "file_path": "/Users/jane/Private/customer.md",
            "meeting_title": "Customer Roadmap",
            "raw_url": "https://meet.example.com/private-room",
            "speaker_name": "Alice Customer",
            "token": "sk-private",
            "transcript_text": "private transcript words",
        ]

        let saved = AnalyticsPayloadSanitizer.sanitizeProperties(
            privateFields.merging(
                [
                    "duration_bucket": "10_29m",
                    "participant_count_bucket": "2_3",
                    "queue_depth_bucket": "1",
                    "trigger": "hotkey",
                    "word_count_bucket": "300_plus",
                ],
                uniquingKeysWith: { _, new in new }
            ),
            allowedKeys: AnalyticsEventPolicy.policy(forEvent: "meeting_transcript_saved")?.allowedProperties ?? []
        )
        assertEqual(saved["duration_bucket"], "10_29m", "saved meetings should keep duration bucket")
        assertEqual(saved["participant_count_bucket"], "2_3", "saved meetings should keep participant bucket")
        assertEqual(saved["trigger"], "hotkey", "saved meetings should keep trigger")
        assertEqual(saved["word_count_bucket"], "300_plus", "saved meetings should keep word bucket")

        let failed = AnalyticsPayloadSanitizer.sanitizeProperties(
            privateFields.merging(
                [
                    "failure_kind": "transcription_inference_failed",
                    "queue_depth_bucket": "1",
                    "trigger": "hotkey",
                ],
                uniquingKeysWith: { _, new in new }
            ),
            allowedKeys: AnalyticsEventPolicy.policy(forEvent: "meeting_transcript_failed")?.allowedProperties ?? []
        )
        assertEqual(failed["failure_kind"], "transcription_inference_failed", "meeting failures should keep normalized failure kind")
        assertEqual(failed["queue_depth_bucket"], "1", "meeting failures should keep queue bucket")

        let skipped = AnalyticsPayloadSanitizer.sanitizeProperties(
            privateFields.merging(
                [
                    "failure_kind": "no_speech_detected",
                    "queue_depth_bucket": "0",
                    "trigger": "hotkey",
                ],
                uniquingKeysWith: { _, new in new }
            ),
            allowedKeys: AnalyticsEventPolicy.policy(forEvent: "meeting_transcript_skipped")?.allowedProperties ?? []
        )
        assertEqual(skipped["failure_kind"], "no_speech_detected", "skipped meetings should keep normalized reason")

        let importFailed = AnalyticsPayloadSanitizer.sanitizeProperties(
            privateFields.merging(
                [
                    "failure_kind": "unsupported_format",
                    "import_stage": "preparation",
                ],
                uniquingKeysWith: { _, new in new }
            ),
            allowedKeys: AnalyticsEventPolicy.policy(forEvent: "meeting_file_import_failed")?.allowedProperties ?? []
        )
        assertEqual(importFailed["failure_kind"], "unsupported_format", "import failures should keep normalized kind")
        assertEqual(importFailed["import_stage"], "preparation", "import failures should keep coarse stage")

        for sanitized in [saved, failed, skipped, importFailed] {
            for key in privateFields.keys {
                assertNil(sanitized[key], "\(key) should not be emitted for meeting outcome analytics")
            }
        }
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
        let choice = AnalyticsEventPolicy.policy(forEvent: "meeting_prompt_choice_made")
        let dismissed = AnalyticsEventPolicy.policy(forEvent: "meeting_prompt_dismissed")
        let outcome = AnalyticsEventPolicy.policy(forEvent: "meeting_prompt_outcome_recorded")
        let recorded = AnalyticsEventPolicy.policy(forEvent: "meeting_prompt_record_selected")
        let suppressed = AnalyticsEventPolicy.policy(forEvent: "meeting_prompt_suppressed")

        assertEqual(shown?.allowedProperties.contains("provider"), true, "prompt shown should allow provider attribution")
        assertEqual(shown?.allowedProperties.contains("prompt_reason"), true, "prompt shown should preserve why it appeared")
        assertEqual(shown?.allowedProperties.contains("calendar_confidence"), true, "prompt shown should keep coarse calendar confidence")
        assertEqual(shown?.allowedProperties.contains("call_state"), true, "prompt shown should keep coarse in-call state")
        assertEqual(shown?.allowedProperties.contains("app_signal"), true, "prompt shown should keep coarse app signal")
        assertEqual(shown?.allowedProperties.contains("route_ready"), true, "prompt shown should preserve route readiness")
        assertEqual(shown?.allowedProperties.contains("missing_permission"), true, "prompt shown should preserve missing-permission buckets")
        assertEqual(dismissed?.allowedProperties.contains("source"), true, "prompt dismiss should allow source attribution")
        assertEqual(dismissed?.allowedProperties.contains("backoff_kind"), true, "prompt dismiss should preserve which backoff rule fired")
        assertEqual(dismissed?.allowedProperties.contains("cooldown_reason"), true, "prompt dismiss should preserve cooldown reason")
        assertEqual(choice?.allowedProperties ?? Set<String>(), [
            "calendar_confidence",
            "call_state",
            "choice_kind",
            "elapsed_bucket",
            "prompt_reason",
            "provider",
            "route_ready",
            "source",
        ], "prompt choices should keep only prompt buckets, the selected choice, and elapsed bucket")
        assertEqual(outcome?.allowedProperties ?? Set<String>(), [
            "calendar_confidence",
            "call_state",
            "elapsed_bucket",
            "outcome_kind",
            "prompt_reason",
            "provider",
            "route_ready",
            "source",
            "suppression_reason",
        ], "prompt outcomes should keep only prompt buckets, outcome, elapsed bucket, and optional suppression reason")
        assertEqual(recorded?.allowedProperties.contains("provider"), true, "prompt accept should allow provider attribution")
        assertEqual(suppressed?.allowedProperties.contains("suppression_reason"), true, "prompt suppression should preserve why nothing appeared")
        assertEqual(suppressed?.allowedProperties.contains("capture_activity"), true, "prompt suppression should preserve already-recording state")
        assertEqual(suppressed?.allowedProperties.contains("cooldown_reason"), true, "prompt suppression should preserve duplicate/cooldown reason")

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "app_signal": "browser_mic",
                "calendar_confidence": "linked_event_runtime_match",
                "call_state": "mic_active",
                "capture_activity": "meeting_recording",
                "cooldown_reason": "runtime_default_fallback",
                "missing_permission": "system_audio_recording",
                "prompt_reason": "calendar_plus_runtime_match",
                "provider": "googleMeet",
                "route_ready": "false",
                "source": "runtime_app",
                "suppression_reason": "pending_candidate",
                "backoff_kind": "calendar_teams_extended",
            ],
            allowedKeys: suppressed?.allowedProperties.union(dismissed?.allowedProperties ?? []) ?? []
        )
        assertEqual(sanitized["app_signal"], "browser_mic", "coarse app signal should survive sanitization")
        assertEqual(sanitized["calendar_confidence"], "linked_event_runtime_match", "calendar confidence should survive sanitization")
        assertEqual(sanitized["call_state"], "mic_active", "in-call state should survive sanitization")
        assertEqual(sanitized["capture_activity"], "meeting_recording", "already-recording state should survive sanitization")
        assertEqual(sanitized["cooldown_reason"], "runtime_default_fallback", "cooldown reason should survive sanitization")
        assertEqual(sanitized["missing_permission"], "system_audio_recording", "missing permission bucket should survive sanitization")
        assertEqual(sanitized["prompt_reason"], "calendar_plus_runtime_match", "prompt reason should survive sanitization")
        assertEqual(sanitized["provider"], "googleMeet", "provider enum should survive sanitization")
        assertEqual(sanitized["route_ready"], "false", "route readiness should survive sanitization")
        assertEqual(sanitized["source"], "runtime_app", "prompt source should survive sanitization")
        assertEqual(sanitized["suppression_reason"], "pending_candidate", "suppression reason should survive sanitization")
        assertEqual(sanitized["backoff_kind"], "calendar_teams_extended", "dismiss backoff kind should survive sanitization")

        let decisionOutcome = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "calendar_confidence": "linked_event_runtime_match",
                "call_state": "mic_active",
                "choice_kind": "record",
                "elapsed_bucket": "10_29s",
                "outcome_kind": "transcript_saved",
                "prompt_reason": "calendar_plus_runtime_match",
                "provider": "googleMeet",
                "route_ready": "true",
                "source": "runtime_app",
                "suppression_reason": "own_capture_active",
                "source_app_name": "Private Browser",
                "meeting_title": "Customer Roadmap",
                "meeting_url": "https://meet.example.com/private",
                "transcript_text": "private words",
            ],
            allowedKeys: (choice?.allowedProperties ?? []).union(outcome?.allowedProperties ?? [])
        )
        assertEqual(decisionOutcome["choice_kind"], "record", "choice kind should survive as an enum")
        assertEqual(decisionOutcome["elapsed_bucket"], "10_29s", "elapsed time should survive only as a bucket")
        assertEqual(decisionOutcome["outcome_kind"], "transcript_saved", "outcome kind should survive as an enum")
        assertEqual(decisionOutcome["suppression_reason"], "own_capture_active", "suppression reason should survive when outcome is suppressed")
        assertNil(decisionOutcome["source_app_name"], "source app names must not be sent")
        assertNil(decisionOutcome["meeting_title"], "meeting titles must not be sent")
        assertNil(decisionOutcome["meeting_url"], "meeting URLs must not be sent")
        assertNil(decisionOutcome["transcript_text"], "transcript text must not be sent")

        let privatePromptFields = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "app_signal": "native_mic",
                "calendar_confidence": "linked_event",
                "call_state": "scheduled",
                "provider": "zoom",
                "source": "calendar_event",
                "source_app_name": "Private Browser",
                "source_app_bundle_id": "com.example.private",
                "meeting_title": "Customer Roadmap",
                "invitee_name": "Alice Customer",
                "speaker_name": "Bob Customer",
                "meeting_url": "https://meet.example.com/private",
                "prompt_text": "Record Customer Roadmap?",
                "audio_ref": "/Users/redbars/private.wav",
                "file_path": "/Users/redbars/private.md",
                "transcript_text": "private words",
            ],
            allowedKeys: (shown?.allowedProperties ?? [])
                .union([
                    "source_app_name",
                    "source_app_bundle_id",
                    "meeting_title",
                    "invitee_name",
                    "speaker_name",
                    "meeting_url",
                    "prompt_text",
                    "audio_ref",
                    "file_path",
                    "transcript_text",
                ])
        )
        assertEqual(privatePromptFields["app_signal"], "native_mic", "safe prompt context should survive beside private inputs")
        assertEqual(privatePromptFields["calendar_confidence"], "linked_event", "safe calendar confidence should survive beside private inputs")
        assertEqual(privatePromptFields["provider"], "zoom", "safe provider enum should survive beside private inputs")
        assertNil(privatePromptFields["source_app_name"], "source app names must not be sent")
        assertNil(privatePromptFields["source_app_bundle_id"], "source app bundle IDs must not be sent")
        assertNil(privatePromptFields["meeting_title"], "meeting titles must not be sent")
        assertNil(privatePromptFields["invitee_name"], "invitee names must not be sent")
        assertNil(privatePromptFields["speaker_name"], "speaker names must not be sent")
        assertNil(privatePromptFields["meeting_url"], "meeting URLs must not be sent")
        assertNil(privatePromptFields["prompt_text"], "raw prompt text must not be sent")
        assertNil(privatePromptFields["audio_ref"], "audio references must not be sent")
        assertNil(privatePromptFields["file_path"], "file paths must not be sent")
        assertNil(privatePromptFields["transcript_text"], "transcript text must not be sent")
    }

    runSuite("AnalyticsEventPolicy pins meeting prompt telemetry firing paths") {
        let appSource = readAnalyticsPolicyRepoTextFile("Sources/TranscriptedApp.swift")
        let meetingSessionSource = readAnalyticsPolicyRepoTextFile("Sources/Meeting/MeetingSessionController.swift")

        assertEqual(
            analyticsPolicyOccurrenceCount(of: "\"meeting_prompt_shown\"", in: appSource),
            1,
            "shown telemetry should fire once, only after the detected prompt is actually presented"
        )
        assertEqual(
            analyticsPolicyOccurrenceCount(of: "\"meeting_prompt_record_selected\"", in: appSource),
            1,
            "selected telemetry should fire once on the explicit record choice"
        )
        assertEqual(
            analyticsPolicyOccurrenceCount(of: "\"meeting_prompt_suppressed\"", in: appSource),
            1,
            "suppression telemetry should fire once from the detector suppression hook"
        )
        assertEqual(
            analyticsPolicyOccurrenceCount(of: "\"meeting_prompt_choice_made\"", in: appSource),
            4,
            "choice telemetry should cover record, dismiss, remind-later, and expiry actions without counting shown inventory"
        )
        assertEqual(
            analyticsPolicyOccurrenceCount(of: "\"meeting_prompt_outcome_recorded\"", in: appSource),
            2,
            "app-level outcomes should cover ignored expiry and pre-prompt suppression only"
        )
        assertEqual(
            analyticsPolicyOccurrenceCount(of: "\"meeting_prompt_outcome_recorded\"", in: meetingSessionSource),
            2,
            "session-level outcomes should stay centralized for start/save/fail terminal recording results"
        )
        assertTrue(
            meetingSessionSource.contains("guard let properties = promptProperties else { return }"),
            "manual and hotkey meetings must not inherit stale detected-prompt properties"
        )
    }

    runSuite("AnalyticsEventPolicy keeps mic boost prompt events narrow") {
        let shown = AnalyticsEventPolicy.policy(forEvent: "meeting_mic_boost_prompt_shown")
        let actioned = AnalyticsEventPolicy.policy(forEvent: "meeting_mic_boost_prompt_actioned")

        assertEqual(
            shown?.allowedProperties ?? Set<String>(),
            ["duration_bucket", "trigger"],
            "mic boost prompt shown should carry only coarse duration and trigger"
        )
        assertEqual(
            actioned?.allowedProperties ?? Set<String>(),
            ["action", "duration_bucket", "trigger"],
            "mic boost prompt actioned should carry only the accept/decline enum plus coarse attribution"
        )
        assertEqual(
            actioned?.allowedProperties.contains("app_name"),
            false,
            "the foreign app holding the mic must never be named in analytics"
        )

        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "action": "accepted",
                "duration_bucket": "10_29s",
                "trigger": "hotkey",
                "app_name": "Safari",
            ],
            allowedKeys: actioned?.allowedProperties ?? Set<String>()
        )
        assertEqual(sanitized["action"], "accepted", "accept/decline enum should survive sanitization")
        assertEqual(sanitized["duration_bucket"], "10_29s", "coarse duration bucket should survive sanitization")
        assertEqual(sanitized["trigger"], "hotkey", "trigger enum should survive sanitization")
        assertNil(sanitized["app_name"], "unallowlisted properties must be dropped")
    }
}

private func analyticsPolicyOccurrenceCount(of needle: String, in haystack: String) -> Int {
    guard !needle.isEmpty else { return 0 }
    var count = 0
    var searchRange = haystack.startIndex..<haystack.endIndex
    while let range = haystack.range(of: needle, range: searchRange) {
        count += 1
        searchRange = range.upperBound..<haystack.endIndex
    }
    return count
}

private func readAnalyticsPolicyRepoTextFile(_ relativePath: String) -> String {
    let path = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(relativePath)
        .path
    return (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
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

private func allAllowedAnalyticsPropertyNames() -> [String] {
    Set(AnalyticsEventPolicy.allPolicies.flatMap { $0.allowedProperties }).sorted()
}

private func taxonomyFileEventNames() -> [String] {
    taxonomyDataLines(relativePath: "Resources/analytics-events.psv").compactMap { line in
        let pieces = line.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard let first = pieces.first else {
            return nil
        }
        return String(first)
    }
}

private func reviewedNonBucketAnalyticsProperties() -> Set<String> {
    Set(taxonomyDataLines(relativePath: "Resources/analytics-reviewed-properties.psv"))
}

private func taxonomyDataLines(relativePath: String) -> [String] {
    loadRepoText(relativePath)
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
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

private func mcpAgentCaptureQueryAllowedProperties() -> Set<String> {
    let source = loadRepoText("Tools/TranscriptedMCP/Sources/TranscriptedMCP/AgentCaptureQueryTelemetry.swift")
    guard let declaration = source.range(of: "static let allowedProperties: Set<String> = [") else {
        return []
    }

    let afterDeclaration = String(source[declaration.upperBound...])
    guard let closingBracket = afterDeclaration.range(of: "]") else {
        return []
    }

    let literalBody = String(afterDeclaration[..<closingBracket.lowerBound])
    return Set(
        literalBody
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { line -> String? in
                let trimmed = line.trimmingCharacters(in: CharacterSet(charactersIn: "\","))
                return trimmed.isEmpty ? nil : trimmed
            }
    )
}
