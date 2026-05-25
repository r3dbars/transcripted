import Foundation

/// Shared building blocks for `SentryPayloadSanitizer` and `AnalyticsPayloadSanitizer`.
///
/// Both sanitizers historically duplicated `shouldDrop` and the
/// "redact then truncate to max length" pipeline. Centralizing those keeps
/// the two destinations from drifting when redaction rules change — each
/// sanitizer still owns its own sensitive-key list and length cap, but the
/// mechanics live in one place.
enum PayloadSanitizationCore {
    /// Apply `ObservabilityTextRedactor.redact` and then cap the result at
    /// `maxValueLength`, appending an ellipsis when truncated. Returns an
    /// empty string when the input redacts to empty so callers can drop
    /// the value cleanly.
    static func redactAndCap(_ text: String, maxValueLength: Int) -> String {
        let redacted = ObservabilityTextRedactor.redact(text)
        guard !redacted.isEmpty else { return "" }

        if redacted.count > maxValueLength {
            return String(redacted.prefix(maxValueLength)) + "..."
        }

        return redacted
    }

    /// Drop the value if any sensitive-key fragment appears as a substring
    /// of the lowercased key. Each sanitizer passes its own fragment list
    /// because the Sentry and Analytics destinations have slightly different
    /// risk profiles.
    static func shouldDrop(key: String, sensitiveFragments: [String]) -> Bool {
        let normalized = key.lowercased()
        return sensitiveFragments.contains(where: { normalized.contains($0) })
    }
}
