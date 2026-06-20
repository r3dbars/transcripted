import Foundation

func testSentryPayloadSanitizer() {
    let corpus = loadJSONFixture("Tests/Fixtures/ObservabilitySanitizerCorpus.json", as: ObservabilitySanitizerCorpus.self)

    runSuite("SentryPayloadSanitizer.sanitizeText redacts paths and secrets") {
        let input = "Saved to /Users/redbars/Private/notes.md with token sk-ant-secret and header Bearer abc123"
        let sanitized = SentryPayloadSanitizer.sanitizeText(input)

        assertFalse(sanitized.contains("/Users/redbars/"), "username should be redacted")
        assertFalse(sanitized.contains("sk-ant-secret"), "API keys should be redacted")
        assertFalse(sanitized.contains("Bearer abc123"), "bearer tokens should be redacted")
        assertTrue(sanitized.contains("[redacted-path]"), "sanitized path marker should remain")
        assertTrue(sanitized.contains("sk-****"), "sanitized API key marker should remain")
        assertTrue(sanitized.contains("Bearer ****"), "sanitized bearer marker should remain")
    }

    runSuite("SentryPayloadSanitizer.sanitizeContext drops obviously sensitive keys") {
        let sanitized = SentryPayloadSanitizer.sanitizeContext([
            "client_secret": "plain-secret",
            "context": "Customer transcript line that should stay local",
            "dsn": "https://example@sentry.invalid/1",
            "duration_ms": "123",
            "meeting_state": "transcribing",
            "meeting_name": "Weekly roadmap call",
            "name": "Customer name",
            "password": "hunter2",
            "title": "Private customer call",
            "transcript_url": "/Users/redbars/Library/Application Support/Draft/meetings/demo.md",
            "error": "meeting title leaked",
            "source_app_bundle_id": "com.apple.Safari",
        ])

        assertEqual(sanitized["duration_ms"], "123", "coarse numeric values should remain")
        assertEqual(sanitized["meeting_state"], "transcribing", "non-sensitive state should remain")
        assertNil(sanitized["client_secret"], "client secrets should be dropped")
        assertNil(sanitized["context"], "free-form context strings should be dropped")
        assertNil(sanitized["dsn"], "DSNs should be dropped")
        assertNil(sanitized["meeting_name"], "meeting names should be dropped")
        assertNil(sanitized["name"], "generic names should be dropped")
        assertNil(sanitized["password"], "password fields should be dropped")
        assertNil(sanitized["title"], "title should be dropped")
        assertNil(sanitized["transcript_url"], "transcript path should be dropped")
        assertNil(sanitized["error"], "free-form error payloads should be dropped")
        assertNil(sanitized["source_app_bundle_id"], "source app bundle IDs should be dropped")
    }

    runSuite("SentryPayloadSanitizer.sanitizeTags keeps reviewed boolean file-presence flags") {
        let sanitized = SentryPayloadSanitizer.sanitizeTags([
            "mic_file_available": "true",
            "system_file_available": "false",
            "transcript_file_path": "/Users/redbars/Library/Application Support/Transcripted/captures/meetings/private.md",
        ])

        assertEqual(sanitized["mic_file_available"], "true", "coarse file-presence flags should stay queryable")
        assertEqual(sanitized["system_file_available"], "false", "coarse system file-presence flags should stay queryable")
        assertNil(sanitized["transcript_file_path"], "raw file path keys should still be dropped")
    }

    runSuite("SentryPayloadSanitizer.sanitizeContext keeps audio-start recovery diagnostics coarse") {
        let sanitized = SentryPayloadSanitizer.sanitizeContext([
            "attempt": "2",
            "start_mode": "normal",
            "recovering": "false",
            "format_ready": "true",
            "generation": "4",
            "gap_count": "1",
            "input_rate_hz": "48000",
            "output_device_class": "built_in",
            "output_rate_hz": "48000",
            "recovery_attempt_count": "0",
            "route_change_count": "2",
            "hw_channels": "1",
            "system_backend": "screen_capture_kit",
            "system_status": "healthy",
            "start_attempts": "3",
            "readiness_refreshes": "2",
            "status_domain": "com.apple.coreaudio.avfaudio",
            "status_code": "-10868",
            "input_device_class": "bluetooth",
            "audio_device": "Private AirPods",
            "error": "Failed to initialize active nodes",
            "source_app": "com.example.private",
        ])

        assertEqual(sanitized["attempt"], "2", "retry attempt should remain")
        assertEqual(sanitized["start_mode"], "normal", "start mode should remain")
        assertEqual(sanitized["recovering"], "false", "recovery flag should remain")
        assertEqual(sanitized["format_ready"], "true", "format readiness should remain")
        assertEqual(sanitized["generation"], "4", "recovery generation should remain")
        assertEqual(sanitized["gap_count"], "1", "gap counts should remain")
        assertEqual(sanitized["input_rate_hz"], "48000", "input rate should remain")
        assertEqual(sanitized["output_device_class"], "built_in", "coarse output device class should remain")
        assertEqual(sanitized["output_rate_hz"], "48000", "output rate should remain")
        assertEqual(sanitized["recovery_attempt_count"], "0", "recovery attempt count should remain")
        assertEqual(sanitized["route_change_count"], "2", "route change count should remain")
        assertEqual(sanitized["hw_channels"], "1", "hardware channel count should remain")
        assertEqual(sanitized["system_backend"], "screen_capture_kit", "capture backend should remain")
        assertEqual(sanitized["system_status"], "healthy", "system status should remain")
        assertEqual(sanitized["start_attempts"], "3", "start attempt count should remain")
        assertEqual(sanitized["readiness_refreshes"], "2", "readiness refresh count should remain")
        assertEqual(sanitized["status_domain"], "com.apple.coreaudio.avfaudio", "status domain should remain")
        assertEqual(sanitized["status_code"], "-10868", "status code should remain")
        assertEqual(sanitized["input_device_class"], "bluetooth", "coarse input device classes should remain")
        assertNil(sanitized["audio_device"], "raw audio device names should be dropped")
        assertNil(sanitized["error"], "free-form errors should be dropped")
        assertNil(sanitized["source_app"], "source app identifiers should be dropped")
    }

    runSuite("SentryPayloadSanitizer.sanitizeContext keeps runtime crash context coarse") {
        let sanitized = SentryPayloadSanitizer.sanitizeContext([
            "app_version": "1.2.5",
            "build_version": "458",
            "heartbeat_age_bucket": "15_59s",
            "last_event": "clean_shutdown",
            "os_major": "26",
            "previous_clean_shutdown": "true",
            "session_active": "false",
            "session_duration_bucket": "5_14m",
            "session_kind": "none",
            "session_stage": "idle",
            "transcript_path": "/Users/redbars/Library/Application Support/Transcripted/captures/meetings/private.md",
            "error": "private raw failure",
        ])

        assertEqual(sanitized["app_version"], "1.2.5", "app version should remain")
        assertEqual(sanitized["build_version"], "458", "build version should remain")
        assertEqual(sanitized["heartbeat_age_bucket"], "15_59s", "heartbeat bucket should remain")
        assertEqual(sanitized["last_event"], "clean_shutdown", "last event should remain")
        assertEqual(sanitized["os_major"], "26", "OS major should remain")
        assertEqual(sanitized["previous_clean_shutdown"], "true", "clean shutdown state should remain")
        assertEqual(sanitized["session_active"], "false", "session activity should remain")
        assertEqual(sanitized["session_duration_bucket"], "5_14m", "session duration bucket should remain")
        assertEqual(sanitized["session_kind"], "none", "session kind should remain")
        assertEqual(sanitized["session_stage"], "idle", "session stage should remain")
        assertNil(sanitized["transcript_path"], "transcript paths should still be dropped")
        assertNil(sanitized["error"], "free-form runtime errors should still be dropped")
    }

    runSuite("SentryPayloadSanitizer.sanitizeCrashRuntimeTags exposes only reviewed workflow state") {
        let sanitized = SentryPayloadSanitizer.sanitizeCrashRuntimeTags([
            "last_event": "dictation_transcribing",
            "session_kind": "dictation",
            "session_stage": "transcribing",
            "transcript_path": "/Users/redbars/Library/Application Support/Transcripted/captures/meetings/private.md",
            "error": "private raw failure",
        ])

        assertEqual(sanitized["last_event"], "dictation_transcribing", "last runtime event should be queryable as a crash tag")
        assertEqual(Set(sanitized.keys), ["last_event"], "crash runtime tags should stay limited to one reviewed workflow dimension")
    }

    runSuite("SentryPayloadSanitizer.sanitizeTags still scrubs selector-enrichment values") {
        let sanitized = SentryPayloadSanitizer.sanitizeTags([
            "unrecognized_selector": "openURL:https://example.com/private?token=abc123",
            "unrecognized_selector_class": "/Users/redbars/PrivateWidget",
        ])

        assertFalse(
            sanitized["unrecognized_selector"]?.contains("https://example.com") ?? true,
            "selector crash tags should not retain raw URLs"
        )
        assertFalse(
            sanitized["unrecognized_selector_class"]?.contains("/Users/redbars") ?? true,
            "selector class crash tags should not retain absolute paths"
        )
    }

    runSuite("SentryPayloadSanitizer.sanitizeText redacts emails hostnames and non-home paths") {
        let input = "Contact me at person@example.com from Redbarss-MacBook-Pro.local and inspect /private/var/folders/demo/file.txt"
        let sanitized = SentryPayloadSanitizer.sanitizeText(input)

        assertFalse(sanitized.contains("person@example.com"), "emails should be redacted")
        assertFalse(sanitized.contains("Redbarss-MacBook-Pro.local"), "hostnames should be redacted")
        assertFalse(sanitized.contains("/private/var/folders/demo/file.txt"), "absolute private paths should be redacted")
        assertTrue(sanitized.contains("[redacted-email]"), "redacted email marker should remain")
        assertTrue(sanitized.contains("[redacted-host]"), "redacted hostname marker should remain")
        assertTrue(sanitized.contains("[redacted-path]"), "redacted path marker should remain")
    }

    runSuite("SentryPayloadSanitizer.sanitizeText redacts Transcripted app support paths with spaces") {
        let input = "Read /Users/redbars/Library/Application Support/Transcripted/logs/app.jsonl before retry"
        let sanitized = SentryPayloadSanitizer.sanitizeText(input)

        assertFalse(sanitized.contains("/Users/redbars/"), "username should be redacted")
        assertFalse(sanitized.contains("Application Support/Transcripted/logs/app.jsonl"), "app support path should be fully redacted")
        assertTrue(sanitized.contains("[redacted-path]"), "redacted path marker should remain")
    }

    runSuite("SentryPayloadSanitizer.sanitizeText redacts synthetic-root macOS paths") {
        let input = "Retry after checking /System/Volumes/Data/Users/redbars/Library/Application Support/Transcripted/logs/app.jsonl"
        let sanitized = SentryPayloadSanitizer.sanitizeText(input)

        assertFalse(sanitized.contains("/System/Volumes/Data/Users/redbars/"), "synthetic-root home paths should be redacted")
        assertFalse(sanitized.contains("Application Support/Transcripted/logs/app.jsonl"), "synthetic-root app support path should be fully redacted")
        assertTrue(sanitized.contains("[redacted-path]"), "redacted path marker should remain")
    }

    runSuite("SentryPayloadSanitizer.sanitizeText redacts raw URLs and common token formats") {
        let input = "Download failed at https://example.com/private?token=abc123 with ghp_123456789012345678901234567890123456 phc_abcdefghijklmnopqrstuvwxyz123456 AKIAIOSFODNN7EXAMPLE AIzaSyA-BCDEFGHIJKLMNOPQRSTUVWXYZ123456"
        let sanitized = SentryPayloadSanitizer.sanitizeText(input)

        assertFalse(sanitized.contains("https://example.com/private?token=abc123"), "raw URLs should be redacted")
        assertFalse(sanitized.contains("ghp_123456789012345678901234567890123456"), "GitHub tokens should be redacted")
        assertFalse(sanitized.contains("phc_abcdefghijklmnopqrstuvwxyz123456"), "PostHog keys should be redacted")
        assertFalse(sanitized.contains("AKIAIOSFODNN7EXAMPLE"), "AWS access key IDs should be redacted")
        assertFalse(sanitized.contains("AIzaSyA-BCDEFGHIJKLMNOPQRSTUVWXYZ123456"), "Google API keys should be redacted")
        assertTrue(sanitized.contains("[redacted-url]"), "redacted URL marker should remain")
        assertTrue(sanitized.contains("[redacted-secret]"), "redacted secret marker should remain")
    }

    runSuite("SentryPayloadSanitizer.sanitizeText redacts password and secret assignments") {
        let input = "Sync failed with password=hunter2 client_secret:supersecret credential=temp-pass dsn=https://example@sentry.invalid/1"
        let sanitized = SentryPayloadSanitizer.sanitizeText(input)

        assertFalse(sanitized.contains("hunter2"), "password assignment values should be redacted")
        assertFalse(sanitized.contains("supersecret"), "client secret assignment values should be redacted")
        assertFalse(sanitized.contains("temp-pass"), "credential assignment values should be redacted")
        assertFalse(sanitized.contains("https://example@sentry.invalid/1"), "DSN URLs should be redacted")
        assertTrue(sanitized.contains("password=[redacted-secret]"), "password marker should remain")
        assertTrue(sanitized.contains("client_secret=[redacted-secret]"), "client secret marker should remain")
        assertTrue(sanitized.contains("credential=[redacted-secret]"), "credential marker should remain")
    }

    runSuite("SentryPayloadSanitizer redacts case-insensitive bearer variants with tabs and multi-space") {
        for raw in ["bearer\ttokenabc", "BEARER   abc.def_ghi", "Bearer\t token-123", "beArEr  mixed_case_token"] {
            let sanitized = SentryPayloadSanitizer.sanitizeText(raw)
            assertFalse(sanitized.lowercased().contains("tokenabc"), "case-insensitive bearer should still redact token part in '\(raw)'")
            assertFalse(sanitized.contains("abc.def_ghi"), "bearer with whitespace variants should redact token in '\(raw)'")
            assertFalse(sanitized.contains("mixed_case_token"), "mixed-case bearer should redact in '\(raw)'")
            assertTrue(sanitized.contains("****"), "sanitized auth marker should remain in '\(raw)'")
        }
    }

    runSuite("SentryPayloadSanitizer redacts basic auth headers and authorization assignments") {
        let input = "Authorization: Basic dXNlcjpwYXNz Proxy-Authorization=Bearer abc123 fallback Basic ZGVtbzpwYXNz"
        let sanitized = SentryPayloadSanitizer.sanitizeText(input)

        assertFalse(sanitized.contains("dXNlcjpwYXNz"), "basic auth payloads should be redacted")
        assertFalse(sanitized.contains("abc123"), "authorization assignment bearer tokens should be redacted")
        assertFalse(sanitized.contains("ZGVtbzpwYXNz"), "standalone basic auth values should be redacted")
        assertTrue(sanitized.contains("Authorization=[redacted-secret]"), "authorization assignments should collapse to a redacted marker")
        assertTrue(sanitized.contains("Proxy-Authorization=[redacted-secret]"), "proxy authorization assignments should collapse to a redacted marker")
        assertTrue(sanitized.contains("Basic ****"), "standalone basic auth marker should remain")
    }

    runSuite("SentryPayloadSanitizer redacts PEM private key material") {
        let input = """
        Failed to parse key:
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAlwAAAAdzc2gtcn
        -----END OPENSSH PRIVATE KEY-----
        """
        let sanitized = SentryPayloadSanitizer.sanitizeText(input)

        assertFalse(sanitized.contains("BEGIN OPENSSH PRIVATE KEY"), "private key header should be redacted")
        assertFalse(sanitized.contains("b3BlbnNzaC1rZXkt"), "private key body should be redacted")
        assertFalse(sanitized.contains("END OPENSSH PRIVATE KEY"), "private key footer should be redacted")
        assertTrue(sanitized.contains("[redacted-secret]"), "private key content should collapse to a secret marker")
    }

    runSuite("SentryPayloadSanitizer.sanitizeAnyDictionary redacts nested free-form values") {
        let sanitized = SentryPayloadSanitizer.sanitizeAnyDictionary([
            "safe_count": 3,
            "title": "Private meeting",
            "nested": [
                "path": "/Users/redbars/Library/Application Support/Draft/demo.md",
                "state": "recording",
            ],
        ])

        assertEqual(sanitized["safe_count"] as? NSNumber, 3, "numeric values should remain")
        assertNil(sanitized["title"], "sensitive top-level keys should be dropped")
        let nested = sanitized["nested"] as? [String: Any]
        assertNil(nested?["path"], "nested sensitive keys should be dropped")
        assertEqual(nested?["state"] as? String, "recording", "safe nested values should remain")
    }

    runSuite("SentryPayloadSanitizer drops automatic app identifiers") {
        let sanitized = SentryPayloadSanitizer.sanitizeEventContexts([
            "app": [
                "app_identifier": "com.private.customer-app",
                "app_name": "Private Customer App",
                "app_version": "1.1.44",
            ],
            "device": [
                "name": "Justin's MacBook Pro",
                "model": "Mac15,6",
            ],
        ])

        let app = sanitized["app"]
        assertNil(app?["app_identifier"], "bundle-like app identifiers should not leave the app")
        assertNil(app?["app_name"], "app names should not leave the app")
        assertEqual(app?["app_version"] as? String, "1.1.44", "coarse app version should remain")

        let device = sanitized["device"]
        assertNil(device?["name"], "raw device names should not leave the app")
        assertEqual(device?["model"] as? String, "Mac15,6", "coarse hardware model should remain")
    }

    runSuite("SentryPayloadSanitizer matches the shared regression corpus") {
        for testCase in corpus.cases {
            let sanitized = SentryPayloadSanitizer.sanitizeText(testCase.input)
            for forbidden in testCase.mustNotContain {
                assertFalse(
                    sanitized.contains(forbidden),
                    "shared case \(testCase.id) should redact \(forbidden)"
                )
            }
            for required in testCase.mustContain {
                assertTrue(
                    sanitized.contains(required),
                    "shared case \(testCase.id) should keep marker \(required)"
                )
            }
        }
    }
}
