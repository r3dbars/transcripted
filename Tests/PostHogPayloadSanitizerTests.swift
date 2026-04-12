import Foundation

func testPostHogPayloadSanitizer() {
    runSuite("PostHogPayloadSanitizer keeps coarse diagnostics and drops sensitive keys") {
        let sanitized = PostHogPayloadSanitizer.sanitizeProperties([
            "duration_ms": "1234",
            "queue_depth": "2",
            "system_audio_status": "healthy",
            "title": "Private customer sync",
            "source_app_bundle_id": "com.apple.Safari",
            "error": "failed at /Users/redbars/secret.txt",
            "transcript_url": "/Users/redbars/Library/Application Support/Draft/meetings/demo.md",
        ])

        assertEqual(sanitized["duration_ms"], "1234", "coarse numeric diagnostics should remain")
        assertEqual(sanitized["queue_depth"], "2", "queue depth should remain")
        assertEqual(sanitized["system_audio_status"], "healthy", "coarse audio health state should remain")
        assertNil(sanitized["title"], "meeting titles should be dropped")
        assertNil(sanitized["source_app_bundle_id"], "source app identifiers should be dropped")
        assertNil(sanitized["error"], "free-form errors should be dropped")
        assertNil(sanitized["transcript_url"], "transcript paths should be dropped")
    }

    runSuite("PostHogPayloadSanitizer redacts secrets inside values it keeps") {
        let sanitized = PostHogPayloadSanitizer.sanitizeProperties([
            "phase": "Saved near /Users/redbars/Documents/demo.md with Bearer abc123 and sk-secret-token"
        ])

        let value = sanitized["phase"] ?? ""
        assertFalse(value.contains("/Users/redbars/"), "paths should be redacted")
        assertFalse(value.contains("Bearer abc123"), "bearer tokens should be redacted")
        assertFalse(value.contains("sk-secret-token"), "API keys should be redacted")
        assertTrue(value.contains("[redacted-path]"), "path marker should remain")
        assertTrue(value.contains("Bearer ****"), "bearer marker should remain")
        assertTrue(value.contains("sk-****"), "API key marker should remain")
    }
}
