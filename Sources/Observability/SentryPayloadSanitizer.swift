import Foundation

enum SentryPayloadSanitizer {
    private static let maxValueLength = 240
    private static let sensitiveKeyFragments = [
        "audio",
        "authorization",
        "bearer",
        "bundle",
        "email",
        "file",
        "path",
        "speaker",
        "source_app",
        "text",
        "title",
        "token",
        "transcript",
        "url",
    ]

    private static let userPathRegex = try! NSRegularExpression(pattern: #"/Users/[^/]+/"#)
    private static let apiKeyRegex = try! NSRegularExpression(pattern: #"sk-[A-Za-z0-9_-]+"#)
    private static let bearerRegex = try! NSRegularExpression(pattern: #"Bearer [A-Za-z0-9._-]+"#)

    static func sanitizeTags(_ tags: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]

        for (key, value) in tags.sorted(by: { $0.key < $1.key }) {
            guard !shouldDrop(key: key) else { continue }
            let cleaned = sanitizeText(value)
            guard !cleaned.isEmpty else { continue }
            sanitized[key] = cleaned
        }

        return sanitized
    }

    static func sanitizeContext(_ context: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]

        for (key, value) in context.sorted(by: { $0.key < $1.key }) {
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
        result = apiKeyRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "sk-****")
        range = NSRange(result.startIndex..., in: result)
        result = bearerRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "Bearer ****")

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
