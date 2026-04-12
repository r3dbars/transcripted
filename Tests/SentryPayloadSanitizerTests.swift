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
            "duration_ms": "123",
            "meeting_state": "transcribing",
            "title": "Private customer call",
            "transcript_url": "/Users/redbars/Library/Application Support/Draft/meetings/demo.md",
            "error": "meeting title leaked",
            "source_app_bundle_id": "com.apple.Safari",
        ])

        assertEqual(sanitized["duration_ms"], "123", "coarse numeric values should remain")
        assertEqual(sanitized["meeting_state"], "transcribing", "non-sensitive state should remain")
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
