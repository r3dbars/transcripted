import Foundation

func testPayloadSanitizationCore() {
    runSuite("PayloadSanitizationCore.redactAndCap handles empty input") {
        assertEqual(PayloadSanitizationCore.redactAndCap("", maxValueLength: 80), "", "empty input should redact to empty")
    }

    runSuite("PayloadSanitizationCore.redactAndCap returns empty string when input redacts to empty") {
        assertEqual(PayloadSanitizationCore.redactAndCap("   \n\t  ", maxValueLength: 80), "", "whitespace-only input trims to empty and should redact to empty")
    }

    runSuite("PayloadSanitizationCore.redactAndCap leaves short input under the cap untouched") {
        let result = PayloadSanitizationCore.redactAndCap("hello world", maxValueLength: 80)
        assertEqual(result, "hello world", "input under the cap with nothing to redact should pass through unchanged")
    }

    runSuite("PayloadSanitizationCore.redactAndCap truncates input over the cap with an ellipsis") {
        let long = String(repeating: "a", count: 15)
        let result = PayloadSanitizationCore.redactAndCap(long, maxValueLength: 10)
        assertEqual(result, String(repeating: "a", count: 10) + "...", "over-cap input should be truncated to maxValueLength and suffixed with ...")
        assertTrue(result.hasSuffix("..."), "truncated result should end with the ellipsis marker")
    }

    runSuite("PayloadSanitizationCore.shouldDrop matches case-insensitively") {
        assertTrue(
            PayloadSanitizationCore.shouldDrop(key: "PASSWORD", sensitiveFragments: ["password"]),
            "uppercase keys should still match lowercase fragments"
        )
        assertTrue(
            PayloadSanitizationCore.shouldDrop(key: "Auth_Token", sensitiveFragments: ["token"]),
            "mixed-case keys should still match lowercase fragments"
        )
    }

    runSuite("PayloadSanitizationCore.shouldDrop matches any fragment as a substring") {
        assertTrue(
            PayloadSanitizationCore.shouldDrop(key: "user_auth_token_value", sensitiveFragments: ["password", "token", "email"]),
            "a key containing any one of several fragments should be dropped"
        )
    }

    runSuite("PayloadSanitizationCore.shouldDrop returns false when no fragment matches") {
        assertFalse(
            PayloadSanitizationCore.shouldDrop(key: "duration_bucket", sensitiveFragments: ["password", "token", "email"]),
            "a key matching none of the fragments should not be dropped"
        )
    }

    runSuite("PayloadSanitizationCore.baseSensitiveKeyFragments includes known-sensitive fragments") {
        assertTrue(PayloadSanitizationCore.baseSensitiveKeyFragments.contains("password"), "password should be a base sensitive fragment")
        assertTrue(PayloadSanitizationCore.baseSensitiveKeyFragments.contains("token"), "token should be a base sensitive fragment")
        assertTrue(PayloadSanitizationCore.baseSensitiveKeyFragments.contains("path"), "path should be a base sensitive fragment")
        assertTrue(PayloadSanitizationCore.baseSensitiveKeyFragments.contains("email"), "email should be a base sensitive fragment")
    }
}
