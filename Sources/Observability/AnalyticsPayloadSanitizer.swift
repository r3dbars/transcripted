import Foundation

enum AnalyticsPayloadSanitizer {
    private static let maxValueLength = 80
    private static let sensitiveKeyFragments = [
        "audio",
        "bundle",
        "email",
        "error",
        "file",
        "name",
        "path",
        "speaker",
        "source_app",
        "text",
        "title",
        "token",
        "transcript",
        "url",
    ]

    private static let userPathRegex = try! NSRegularExpression(pattern: #"/Users/[^/\s]+/"#)
    private static let absolutePathRegex = try! NSRegularExpression(pattern: #"(?<!https:)(?<!http:)/(?:Users|private|var|tmp|Volumes|Applications)[^\s"]*"#)
    private static let rawURLRegex = try! NSRegularExpression(pattern: #"https?://[^\s"]+"#, options: [.caseInsensitive])
    private static let commonSecretRegex = try! NSRegularExpression(
        pattern: #"\b(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|phc_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|xoxx-[A-Za-z0-9-]{10,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9._-]{10,}\.[A-Za-z0-9._-]{10,})\b"#
    )
    private static let secretAssignmentRegex = try! NSRegularExpression(
        pattern: #"(?i)\b((?:access_)?token|refresh_token|api[_-]?key|x-api-key|signature|x-amz-signature)\s*[:=]\s*([^\s,;]+)"#
    )
    private static let emailRegex = try! NSRegularExpression(pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: [.caseInsensitive])

    static func sanitizeProperties(
        _ properties: [String: String],
        allowedKeys: Set<String>
    ) -> [String: String] {
        var sanitized: [String: String] = [:]

        for (key, value) in properties.sorted(by: { $0.key < $1.key }) {
            guard allowedKeys.contains(key) else { continue }
            guard !shouldDrop(key: key) else { continue }

            let cleaned = sanitizeText(value)
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
        result = userPathRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "/Users/****/")
        range = NSRange(result.startIndex..., in: result)
        result = absolutePathRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted-path]")
        range = NSRange(result.startIndex..., in: result)
        result = rawURLRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted-url]")
        range = NSRange(result.startIndex..., in: result)
        result = commonSecretRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted-secret]")
        range = NSRange(result.startIndex..., in: result)
        result = secretAssignmentRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1=[redacted-secret]")
        range = NSRange(result.startIndex..., in: result)
        result = emailRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted-email]")

        if result.count > maxValueLength {
            return String(result.prefix(maxValueLength)) + "..."
        }

        return result
    }

    private static func shouldDrop(key: String) -> Bool {
        let normalized = key.lowercased()
        return sensitiveKeyFragments.contains(where: { normalized.contains($0) })
    }
}
