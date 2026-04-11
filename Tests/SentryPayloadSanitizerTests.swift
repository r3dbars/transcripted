import Foundation

func testSentryPayloadSanitizer() {
    runSuite("SentryPayloadSanitizer.sanitizeText redacts paths and secrets") {
        let input = "Saved to /Users/redbars/Private/notes.md with token sk-ant-secret and header Bearer abc123"
        let sanitized = SentryPayloadSanitizer.sanitizeText(input)

        assertFalse(sanitized.contains("/Users/redbars/"), "username should be redacted")
        assertFalse(sanitized.contains("sk-ant-secret"), "API keys should be redacted")
        assertFalse(sanitized.contains("Bearer abc123"), "bearer tokens should be redacted")
        assertTrue(sanitized.contains("/Users/****/"), "sanitized path marker should remain")
        assertTrue(sanitized.contains("sk-****"), "sanitized API key marker should remain")
        assertTrue(sanitized.contains("Bearer ****"), "sanitized bearer marker should remain")
    }

    runSuite("SentryPayloadSanitizer.sanitizeContext drops obviously sensitive keys") {
        let sanitized = SentryPayloadSanitizer.sanitizeContext([
            "duration_ms": "123",
            "meeting_state": "transcribing",
            "title": "Private customer call",
            "transcript_url": "/Users/redbars/Library/Application Support/Draft/meetings/demo.md",
            "source_app_bundle_id": "com.apple.Safari",
        ])

        assertEqual(sanitized["duration_ms"], "123", "coarse numeric values should remain")
        assertEqual(sanitized["meeting_state"], "transcribing", "non-sensitive state should remain")
        assertNil(sanitized["title"], "title should be dropped")
        assertNil(sanitized["transcript_url"], "transcript path should be dropped")
        assertNil(sanitized["source_app_bundle_id"], "source app bundle IDs should be dropped")
    }
}
