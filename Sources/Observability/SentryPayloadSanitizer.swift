import Foundation

enum SentryPayloadSanitizer {
    private static let maxValueLength = 240
    private static let sensitiveKeyFragments = [
        "audio",
        "authorization",
        "bearer",
        "bundle",
        "context",
        "credential",
        "dsn",
        "email",
        "error",
        "file",
        "name",
        "password",
        "path",
        "speaker",
        "source_app",
        "secret",
        "text",
        "title",
        "token",
        "transcript",
        "url",
    ]

    // Security: compile-time regex patterns are built via this helper instead of try! so that a
    // future malformed pattern triggers an assertionFailure in debug builds and falls back to a
    // no-op regex in release builds — keeping the crash-scrubbing path alive rather than crashing it.
    private static func makeRegex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        if let regex = try? NSRegularExpression(pattern: pattern, options: options) {
            return regex
        }
        assertionFailure("Sanitizer regex failed to compile — pattern will be skipped: \(pattern)")
        // "(?!)" is a negative lookahead that never matches, so substitution is a no-op.
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

    static func sanitizeTags(_ tags: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]

        for (key, value) in tags {
            guard !shouldDrop(key: key) else { continue }
            let cleaned = sanitizeText(value)
            guard !cleaned.isEmpty else { continue }
            sanitized[key] = cleaned
        }

        return sanitized
    }

    static func sanitizeContext(_ context: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]

        for (key, value) in context {
            guard !shouldDrop(key: key) else { continue }
            let cleaned = sanitizeText(value)
            guard !cleaned.isEmpty else { continue }
            sanitized[key] = cleaned
        }

        return sanitized
    }

    static func sanitizeAnyDictionary(_ dictionary: [String: Any]) -> [String: Any] {
        var sanitized: [String: Any] = [:]

        for (key, value) in dictionary {
            guard !shouldDrop(key: key) else { continue }
            guard let cleaned = sanitizeAnyValue(value) else { continue }
            sanitized[key] = cleaned
        }

        return sanitized
    }

    static func sanitizeEventContexts(_ contexts: [String: [String: Any]]) -> [String: [String: Any]] {
        var sanitized: [String: [String: Any]] = [:]

        for (key, value) in contexts {
            guard !shouldDrop(key: key) else { continue }
            let cleaned = sanitizeAnyDictionary(value)
            guard !cleaned.isEmpty else { continue }
            sanitized[key] = cleaned
        }

        return sanitized
    }

    static func sanitizeText(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var result = trimmed
        var range = NSRange(result.startIndex..., in: result)
        result = appSupportPathRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted-path]")
        range = NSRange(result.startIndex..., in: result)
        result = userPathRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "/Users/****/")
        range = NSRange(result.startIndex..., in: result)
        result = absolutePathRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted-path]")
        range = NSRange(result.startIndex..., in: result)
        result = rawURLRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted-url]")
        range = NSRange(result.startIndex..., in: result)
        result = apiKeyRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "sk-****")
        range = NSRange(result.startIndex..., in: result)
        result = commonSecretRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted-secret]")
        range = NSRange(result.startIndex..., in: result)
        result = authorizationAssignmentRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1=[redacted-secret]")
        range = NSRange(result.startIndex..., in: result)
        result = authSchemeRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1 ****")
        range = NSRange(result.startIndex..., in: result)
        result = privateKeyBlockRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted-secret]")
        range = NSRange(result.startIndex..., in: result)
        result = privateKeyMarkerRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted-secret]")
        range = NSRange(result.startIndex..., in: result)
        result = secretAssignmentRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1=[redacted-secret]")
        range = NSRange(result.startIndex..., in: result)
        result = emailRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted-email]")
        range = NSRange(result.startIndex..., in: result)
        result = localHostnameRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted-host]")

        if result.count > maxValueLength {
            return String(result.prefix(maxValueLength)) + "..."
        }

        return result
    }

    private static func sanitizeAnyValue(_ value: Any) -> Any? {
        switch value {
        case let string as String:
            let cleaned = sanitizeText(string)
            return cleaned.isEmpty ? nil : cleaned
        case let number as NSNumber:
            return number
        case let array as [Any]:
            let cleaned = array.compactMap(sanitizeAnyValue)
            return cleaned.isEmpty ? nil : cleaned
        case let dictionary as [String: Any]:
            let cleaned = sanitizeAnyDictionary(dictionary)
            return cleaned.isEmpty ? nil : cleaned
        default:
            let cleaned = sanitizeText(String(describing: value))
            return cleaned.isEmpty ? nil : cleaned
        }
    }

    private static func shouldDrop(key: String) -> Bool {
        let normalized = key.lowercased()
        return sensitiveKeyFragments.contains(where: { normalized.contains($0) })
    }
}
