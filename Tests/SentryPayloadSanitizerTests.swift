import Foundation

func testSentryPayloadSanitizer() {
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

    runSuite("SentryPayloadSanitizer.sanitizeContext keeps audio-start recovery diagnostics coarse") {
        let sanitized = SentryPayloadSanitizer.sanitizeContext([
            "attempt": "2",
            "start_mode": "normal",
            "recovering": "false",
            "format_ready": "true",
            "generation": "4",
            "input_rate_hz": "48000",
            "output_rate_hz": "48000",
            "hw_channels": "1",
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
        assertEqual(sanitized["input_rate_hz"], "48000", "input rate should remain")
        assertEqual(sanitized["output_rate_hz"], "48000", "output rate should remain")
        assertEqual(sanitized["hw_channels"], "1", "hardware channel count should remain")
        assertEqual(sanitized["start_attempts"], "3", "start attempt count should remain")
        assertEqual(sanitized["readiness_refreshes"], "2", "readiness refresh count should remain")
        assertEqual(sanitized["status_domain"], "com.apple.coreaudio.avfaudio", "status domain should remain")
        assertEqual(sanitized["status_code"], "-10868", "status code should remain")
        assertEqual(sanitized["input_device_class"], "bluetooth", "coarse input device classes should remain")
        assertNil(sanitized["audio_device"], "raw audio device names should be dropped")
        assertNil(sanitized["error"], "free-form errors should be dropped")
        assertNil(sanitized["source_app"], "source app identifiers should be dropped")
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
}
