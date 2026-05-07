import Foundation

enum AnalyticsPayloadSanitizer {
    private static let maxValueLength = 80
    private static let sensitiveKeyFragments = [
        "audio",
        "authorization",
        "bearer",
        "bundle",
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

    static func sanitizeText(_ text: String) -> String {
        let redacted = redact(text)
        guard !redacted.isEmpty else { return "" }

        if redacted.count > maxValueLength {
            return String(redacted.prefix(maxValueLength)) + "..."
        }

        return redacted
    }

    /// Apply regex-based redaction without the analytics length cap.
    /// Use this for feedback / diagnostic contexts where multi-line log
    /// blobs must be scrubbed but not truncated. `sanitizeText` calls
    /// this and then applies the `maxValueLength` cap.
    static func redact(_ text: String) -> String {
        PayloadRedactor.redact(text)
    }

    private static func shouldDrop(key: String) -> Bool {
        PayloadRedactor.shouldDrop(key: key, fragments: sensitiveKeyFragments)
    }
}
