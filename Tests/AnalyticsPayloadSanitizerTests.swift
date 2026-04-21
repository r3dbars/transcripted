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
                "failure_kind": "Saved to /Users/redbars/Library/Application Support/Transcripted/logs/app.jsonl by person@example.com",
            ],
            allowedKeys: ["failure_kind"]
        )

        let value = sanitized["failure_kind"] ?? ""
        assertFalse(value.contains("/Users/redbars/"), "user paths should be redacted")
        assertFalse(value.contains("Application Support/Transcripted/logs/app.jsonl"), "app support paths should be fully redacted")
        assertFalse(value.contains("person@example.com"), "emails should be redacted")
        assertTrue(value.contains("[redacted-path]"), "path marker should remain")
        assertTrue(value.contains("[redacted-email]"), "email marker should remain")
    }

    runSuite("AnalyticsPayloadSanitizer redacts raw URLs and common secret values") {
        let sanitized = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "failure_kind": "Upload failed at https://example.com/path?token=abc123 with github_pat_abcdefghijklmnopqrstuvwxyz_1234567890 AKIAIOSFODNN7EXAMPLE AIzaSyA-BCDEFGHIJKLMNOPQRSTUVWXYZ123456 and api_key=secret-value password=hunter2 client_secret:supersecret credential=temp-pass",
            ],
            allowedKeys: ["failure_kind"]
        )

        let value = sanitized["failure_kind"] ?? ""
        assertFalse(value.contains("https://example.com/path?token=abc123"), "raw URLs should be redacted")
        assertFalse(value.contains("github_pat_abcdefghijklmnopqrstuvwxyz_1234567890"), "GitHub fine-grained tokens should be redacted")
        assertFalse(value.contains("AKIAIOSFODNN7EXAMPLE"), "AWS access key IDs should be redacted")
        assertFalse(value.contains("AIzaSyA-BCDEFGHIJKLMNOPQRSTUVWXYZ123456"), "Google API keys should be redacted")
        assertFalse(value.contains("api_key=secret-value"), "inline secret assignments should be redacted")
        assertFalse(value.contains("hunter2"), "password assignment values should be redacted")
        assertFalse(value.contains("supersecret"), "client secret assignment values should be redacted")
        assertFalse(value.contains("temp-pass"), "credential assignment values should be redacted")
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

    runSuite("AnalyticsPayloadSanitizer redacts case-insensitive bearer variants with tabs and multi-space") {
        for raw in ["bearer\ttokenabc", "BEARER   abc.def_ghi", "Bearer\t token-123", "beArEr  mixed_case_token"] {
            let sanitized = AnalyticsPayloadSanitizer.sanitizeText(raw)
            assertFalse(sanitized.lowercased().contains("tokenabc"), "case-insensitive bearer should still redact token part in '\(raw)'")
            assertFalse(sanitized.contains("abc.def_ghi"), "bearer with whitespace variants should redact token in '\(raw)'")
            assertFalse(sanitized.contains("mixed_case_token"), "mixed-case bearer should redact in '\(raw)'")
        }
    }

    runSuite("AnalyticsPayloadSanitizer.redact scrubs without the analytics length cap") {
        // Build a multi-line log blob longer than maxValueLength (80 chars) so
        // the feedback path can verify redaction happens but length is preserved.
        let rawLines = [
            "2026-04-15 User signed in from /Users/redbars/Documents/session.log",
            "Request used Bearer abc123.def456_ghi to contact https://api.example.com/v1/resource",
            "Error reported to person@example.com — see api_key=supersecret for correlation",
            "Final handoff: github_pat_abcdefghijklmnopqrstuvwxyz_1234567890 recorded",
        ]
        let raw = rawLines.joined(separator: "\n")
        let redacted = AnalyticsPayloadSanitizer.redact(raw)

        assertTrue(redacted.count > 80, "redact must not truncate; expected output longer than analytics cap, got \(redacted.count) chars")
        assertTrue(redacted.contains("\n"), "redact must preserve newlines so multi-line log blobs stay readable")
        assertFalse(redacted.contains("/Users/redbars/"), "redact must scrub user paths in multi-line input")
        assertFalse(redacted.contains("person@example.com"), "redact must scrub emails")
        assertFalse(redacted.contains("Bearer abc123.def456_ghi"), "redact must scrub bearer headers")
        assertFalse(redacted.contains("api_key=supersecret"), "redact must scrub inline secret assignments")
        assertFalse(redacted.contains("github_pat_abcdefghijklmnopqrstuvwxyz_1234567890"), "redact must scrub GitHub PAT")
        assertFalse(redacted.contains("https://api.example.com/v1/resource"), "redact must scrub URLs")
    }

    runSuite("AnalyticsPayloadSanitizer.sanitizeText still truncates single-value input") {
        let long = String(repeating: "a", count: 200)
        let sanitized = AnalyticsPayloadSanitizer.sanitizeText(long)
        assertTrue(sanitized.count <= 83, "sanitizeText should still enforce the 80-char cap + \"...\" marker; got \(sanitized.count)")
        assertTrue(sanitized.hasSuffix("..."), "sanitizeText should append the truncation marker")
    }
}
