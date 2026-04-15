import Foundation

func testAnalyticsPayloadSanitizer() {
    runSuite("AnalyticsPayloadSanitizer keeps only allowlisted coarse properties") {
        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "duration_bucket": "10_29s",
                "source_app_name": "Safari",
                "title": "Customer call",
                "word_count_bucket": "50_149",
            ],
            allowedKeys: ["duration_bucket", "source_app_name", "word_count_bucket"]
        )

        assertEqual(sanitized["duration_bucket"], "10_29s", "coarse duration buckets should remain")
        assertEqual(sanitized["word_count_bucket"], "50_149", "coarse word count buckets should remain")
        assertNil(sanitized["source_app_name"], "sensitive source app properties should be dropped even if a caller asks for them")
        assertNil(sanitized["title"], "non-allowlisted properties should be dropped")
    }

    runSuite("AnalyticsPayloadSanitizer redacts file paths and emails from values") {
        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "failure_kind": "Saved to /Users/redbars/secret.md by person@example.com",
            ],
            allowedKeys: ["failure_kind"]
        )

        let value = sanitized["failure_kind"] ?? ""
        assertFalse(value.contains("/Users/redbars/"), "user paths should be redacted")
        assertFalse(value.contains("person@example.com"), "emails should be redacted")
        assertTrue(value.contains("[redacted-path]"), "path marker should remain")
        assertTrue(value.contains("[redacted-email]"), "email marker should remain")
    }

    runSuite("AnalyticsPayloadSanitizer redacts raw URLs and common secret values") {
        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "failure_kind": "Upload failed at https://example.com/path?token=abc123 with github_pat_abcdefghijklmnopqrstuvwxyz_1234567890 and api_key=secret-value",
            ],
            allowedKeys: ["failure_kind"]
        )

        let value = sanitized["failure_kind"] ?? ""
        assertFalse(value.contains("https://example.com/path?token=abc123"), "raw URLs should be redacted")
        assertFalse(value.contains("github_pat_abcdefghijklmnopqrstuvwxyz_1234567890"), "GitHub fine-grained tokens should be redacted")
        assertFalse(value.contains("api_key=secret-value"), "inline secret assignments should be redacted")
        assertTrue(value.contains("[redacted-url]"), "URL marker should remain")
        assertTrue(value.contains("[redacted-secret]"), "secret marker should remain")
    }

    runSuite("AnalyticsPayloadSanitizer redacts bearer headers and sk-style keys") {
        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "failure_kind": "Request used Bearer abc123 and sk-proj-secret-value while retrying",
            ],
            allowedKeys: ["failure_kind"]
        )

        let value = sanitized["failure_kind"] ?? ""
        assertFalse(value.contains("Bearer abc123"), "bearer headers should be redacted")
        assertFalse(value.contains("sk-proj-secret-value"), "sk-style API keys should be redacted")
        assertTrue(value.contains("Bearer ****"), "bearer marker should remain")
        assertTrue(value.contains("sk-****"), "sk-style marker should remain")
    }
}
