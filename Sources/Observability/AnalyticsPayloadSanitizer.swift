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
