import Foundation

enum SentryPayloadSanitizer {
    private static let maxValueLength = 240
    private static let crashRuntimeTagKeys: Set<String> = [
        "last_event",
    ]
    private static let explicitlySafeKeys: Set<String> = [
        "mic_file_available",
        "system_file_available",
    ]
    // Sentry layers two extra fragments ("context", "identifier") on top of the
    // shared base in `PayloadSanitizationCore.baseSensitiveKeyFragments`.
    private static let sensitiveKeyFragments = PayloadSanitizationCore.baseSensitiveKeyFragments + [
        "context",
        "identifier",
    ]

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

    static func sanitizeCrashRuntimeTags(_ context: [String: String]) -> [String: String] {
        let tagCandidates = context.filter { crashRuntimeTagKeys.contains($0.key) }
        return sanitizeTags(tagCandidates)
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
        PayloadSanitizationCore.redactAndCap(text, maxValueLength: maxValueLength)
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
        if explicitlySafeKeys.contains(key) {
            return false
        }

        return PayloadSanitizationCore.shouldDrop(key: key, sensitiveFragments: sensitiveKeyFragments)
    }
}
