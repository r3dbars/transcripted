import Foundation

enum PayloadRedactor {
    // Security: compile-time regex patterns are built via this helper instead
    // of try! so a future malformed pattern skips that rule instead of
    // crashing the reporting path.
    private static func makeRegex(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        if let regex = try? NSRegularExpression(pattern: pattern, options: options) {
            return regex
        }
        assertionFailure("Sanitizer regex failed to compile: \(pattern)")
        // "(?!)" is a negative lookahead that never matches.
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: "(?!)")
    }

    private static let appSupportPathRegex = makeRegex(#"/Users/[^/\s]+/Library/Application Support/(?:Transcripted|Draft)(?:/[^\s"]*)?"#)
    private static let userPathRegex = makeRegex(#"/Users/[^/\s]+/"#)
    private static let absolutePathRegex = makeRegex(
        #"(?<!https:)(?<!http:)/(?:System/Volumes/Data/)?(?:Users|private|var|tmp|Volumes|Applications|Library|opt)[^\s"]*"#
    )
    private static let rawURLRegex = makeRegex(#"https?://[^\s"]+"#, options: [.caseInsensitive])
    private static let apiKeyRegex = makeRegex(#"sk-[A-Za-z0-9_-]+"#)
    private static let commonSecretRegex = makeRegex(
        #"\b(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|phc_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|AIza[0-9A-Za-z\-_]{35}|xox[baprs]-[A-Za-z0-9-]{10,}|xoxx-[A-Za-z0-9-]{10,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9._-]{10,}\.[A-Za-z0-9._-]{10,})\b"#
    )
    private static let authSchemeRegex = makeRegex(#"(Bearer|Basic)\s+[A-Za-z0-9._~+\/=-]+"#, options: [.caseInsensitive])
    private static let authorizationAssignmentRegex = makeRegex(
        #"(?i)\b((?:proxy-)?authorization)\s*[:=]\s*(?:basic|bearer)\s+[^\s,;]+"#
    )
    private static let privateKeyBlockRegex = makeRegex(
        #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#,
        options: [.caseInsensitive]
    )
    private static let privateKeyMarkerRegex = makeRegex(
        #"-----((?:BEGIN|END)) [A-Z0-9 ]*PRIVATE KEY-----"#,
        options: [.caseInsensitive]
    )
    private static let secretAssignmentRegex = makeRegex(
        #"(?i)\b((?:access_)?token|refresh_token|api[_-]?key|x-api-key|signature|x-amz-signature|password|passphrase|secret|client[_-]?secret|credential|dsn)\s*[:=]\s*([^\s,;]+)"#
    )
    private static let emailRegex = makeRegex(#"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: [.caseInsensitive])
    private static let localHostnameRegex = makeRegex(#"\b[a-zA-Z0-9._-]+\.local\b"#)

    static func redact(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var result = trimmed
        for (regex, replacement) in redactionRules {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
        }
        return result
    }

    static func shouldDrop(key: String, fragments: [String]) -> Bool {
        let normalized = key.lowercased()
        return fragments.contains(where: { normalized.contains($0) })
    }

    private static let redactionRules: [(NSRegularExpression, String)] = [
        (appSupportPathRegex, "[redacted-path]"),
        (userPathRegex, "/Users/****/"),
        (absolutePathRegex, "[redacted-path]"),
        (rawURLRegex, "[redacted-url]"),
        (apiKeyRegex, "sk-****"),
        (commonSecretRegex, "[redacted-secret]"),
        (authorizationAssignmentRegex, "$1=[redacted-secret]"),
        (authSchemeRegex, "$1 ****"),
        (privateKeyBlockRegex, "[redacted-secret]"),
        (privateKeyMarkerRegex, "[redacted-secret]"),
        (secretAssignmentRegex, "$1=[redacted-secret]"),
        (emailRegex, "[redacted-email]"),
        (localHostnameRegex, "[redacted-host]")
    ]
}
