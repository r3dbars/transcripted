import Foundation

enum AnalyticsPayloadSanitizer {
    private static let maxValueLength = 80
    // Analytics drops exactly the shared base fragments; see
    // `PayloadSanitizationCore.baseSensitiveKeyFragments`.
    private static let sensitiveKeyFragments = PayloadSanitizationCore.baseSensitiveKeyFragments

    static func sanitizeProperties(
        _ properties: [String: String],
        allowedKeys: Set<String>
    ) -> [String: String] {
        var sanitized: [String: String] = [:]

        for (key, value) in properties {
            guard allowedKeys.contains(key) else { continue }
            guard !shouldDrop(key: key) else { continue }

            let cleaned = sanitizeText(value)
            guard !cleaned.isEmpty else { continue }
            sanitized[key] = cleaned
        }

        return sanitized
    }

    static func sanitizeDiagnosticContextForDisplay(_ context: [String: String]) -> [String: String] {
        var sanitized: [String: String] = [:]

        for (key, value) in context {
            guard !shouldDrop(key: key) else { continue }

            let cleaned = sanitizeText(value)
            guard !cleaned.isEmpty else { continue }
            sanitized[key] = cleaned
        }

        return sanitized
    }

    static func sanitizeText(_ text: String) -> String {
        PayloadSanitizationCore.redactAndCap(text, maxValueLength: maxValueLength)
    }

    /// Apply regex-based redaction without the analytics length cap.
    /// Use this for feedback / diagnostic contexts where multi-line log
    /// blobs must be scrubbed but not truncated. `sanitizeText` calls
    /// this and then applies the `maxValueLength` cap.
    static func redact(_ text: String) -> String {
        ObservabilityTextRedactor.redact(text)
    }

    private static func shouldDrop(key: String) -> Bool {
        PayloadSanitizationCore.shouldDrop(key: key, sensitiveFragments: sensitiveKeyFragments)
    }
}
