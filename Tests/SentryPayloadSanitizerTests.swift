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
            "dsn": "https://example@sentry.invalid/1",
            "duration_ms": "123",
            "meeting_state": "transcribing",
            "password": "hunter2",
            "title": "Private customer call",
            "transcript_url": "/Users/redbars/Library/Application Support/Draft/meetings/demo.md",
            "error": "meeting title leaked",
            "source_app_bundle_id": "com.apple.Safari",
        ])

        assertEqual(sanitized["duration_ms"], "123", "coarse numeric values should remain")
        assertEqual(sanitized["meeting_state"], "transcribing", "non-sensitive state should remain")
        assertNil(sanitized["client_secret"], "client secrets should be dropped")
        assertNil(sanitized["dsn"], "DSNs should be dropped")
        assertNil(sanitized["password"], "password fields should be dropped")
        assertNil(sanitized["title"], "title should be dropped")
        assertNil(sanitized["transcript_url"], "transcript path should be dropped")
        assertNil(sanitized["error"], "free-form error payloads should be dropped")
        assertNil(sanitized["source_app_bundle_id"], "source app bundle IDs should be dropped")
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
            assertTrue(sanitized.contains("Bearer ****"), "sanitized bearer marker should remain in '\(raw)'")
        }
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
