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
}
