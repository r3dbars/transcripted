import Foundation

enum SentryPayloadSanitizer {
    private static let maxValueLength = 240
    private static let sensitiveKeyFragments = [
        "audio",
        "authorization",
        "bearer",
        "bundle",
        "email",
        "error",
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

    private static let userPathRegex = try! NSRegularExpression(pattern: #"/Users/[^/\s]+/"#)
    private static let absolutePathRegex = try! NSRegularExpression(pattern: #"(?<!https:)(?<!http:)/(?:Users|private|var|tmp|Volumes|Applications)[^\s"]*"#)
    private static let apiKeyRegex = try! NSRegularExpression(pattern: #"sk-[A-Za-z0-9_-]+"#)
    private static let bearerRegex = try! NSRegularExpression(pattern: #"Bearer [A-Za-z0-9._-]+"#)
    private static let emailRegex = try! NSRegularExpression(pattern: #"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: [.caseInsensitive])
    private static let localHostnameRegex = try! NSRegularExpression(pattern: #"\b[a-zA-Z0-9._-]+\.local\b"#)

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

    static func sanitizeAnyDictionary(_ dictionary: [String: Any]) -> [String: Any] {
        var sanitized: [String: Any] = [:]

        for (key, value) in dictionary.sorted(by: { $0.key < $1.key }) {
            guard !shouldDrop(key: key) else { continue }
            guard let cleaned = sanitizeAnyValue(value) else { continue }
            sanitized[key] = cleaned
        }

        return sanitized
    }

    static func sanitizeEventContexts(_ contexts: [String: [String: Any]]) -> [String: [String: Any]] {
        var sanitized: [String: [String: Any]] = [:]

        for (key, value) in contexts.sorted(by: { $0.key < $1.key }) {
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
        result = userPathRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "/Users/****/")
        range = NSRange(result.startIndex..., in: result)
        result = absolutePathRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted-path]")
        range = NSRange(result.startIndex..., in: result)
        result = apiKeyRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "sk-****")
        range = NSRange(result.startIndex..., in: result)
        result = bearerRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "Bearer ****")
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
