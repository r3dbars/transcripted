import Foundation

/// Destination-agnostic payload mechanics shared by the observability
/// sanitizers.
///
/// Sentry and Analytics historically duplicated `shouldDrop` and the "redact
/// then truncate to max length" pipeline. Centralizing those keeps the
/// off-device destinations from drifting when redaction rules change; each
/// destination still owns its sensitive-key list and length cap. The local
/// sanitizer also uses the shared key-matching mechanics with its own list.
/// Generic free-text patterns live in `PrivacyTextRedactor`; the app-specific
/// path profile stays behind `ObservabilityTextRedactor`.
enum PayloadSanitizationCore {
    static let commonTelemetryKeys: Set<String> = [
        "session_id", "correlation_id", "failure_kind", "failure_stage", "start_failure_stage",
        "app_version", "build_revision", "os_major", "input_device_class", "output_device_class",
        "selection_reason", "mic_permission_granted", "screen_permission_granted",
        "accessibility_permission_granted", "trigger", "quality_reason", "capture_outcome",
    ]
    static func uuid(_ value: String?) -> String? {
        guard let value, UUID(uuidString: value) != nil else { return nil }
        return value
    }

    static func category(_ value: String?) -> String? {
        guard let value, !value.isEmpty, value.count <= 80,
              isCategoryShaped(value),
              redactAndCap(value, maxValueLength: 80) == value else { return nil }
        return value
    }

    /// Byte-level `^[a-zA-Z0-9][a-zA-Z0-9_.-]*$`. The regex's `$` also allowed
    /// one trailing line terminator, but `redactAndCap` trims it, so the
    /// equality check above rejected those values anyway. Non-ASCII never matched.
    private static func isCategoryShaped(_ value: String) -> Bool {
        var isFirst = true
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "A")...UInt8(ascii: "Z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"):
                break
            case UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "-"):
                if isFirst { return false }
            default:
                return false
            }
            isFirst = false
        }
        return !isFirst
    }

    /// Sensitive-key fragments shared by every off-device destination. A value
    /// is dropped when its lowercased key contains any of these as a substring.
    /// The Sentry, Analytics, and local sanitizers start from this list and
    /// layer their own destination-specific fragments on top.
    static let baseSensitiveKeyFragments: [String] = [
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

    /// Apply the app observability text profile and then cap the result at
    /// `maxValueLength`, appending an ellipsis when truncated. Returns an empty
    /// string when the input redacts to empty so callers can drop the value
    /// cleanly.
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
    /// because the destinations have slightly different risk profiles.
    static func shouldDrop(key: String, sensitiveFragments: [String]) -> Bool {
        if let asciiResult = asciiShouldDrop(key: key, sensitiveFragments: sensitiveFragments) {
            return asciiResult
        }
        let normalized = key.lowercased()
        return sensitiveFragments.contains(where: { normalized.contains($0) })
    }

    /// Same answer as the lowercase + substring check for printable-ASCII keys
    /// and fragments, without allocating a lowercased String per key. Returns
    /// nil (take the general path) for anything else.
    private static func asciiShouldDrop(key: String, sensitiveFragments: [String]) -> Bool? {
        var lowered: [UInt8] = []
        lowered.reserveCapacity(key.utf8.count)
        for byte in key.utf8 {
            guard byte >= 0x20, byte <= 0x7E else { return nil }
            lowered.append(byte >= 0x41 && byte <= 0x5A ? byte | 0x20 : byte)
        }
        for fragment in sensitiveFragments {
            guard !fragment.isEmpty,
                  fragment.utf8.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }) else { return nil }
            if bytes(lowered, contain: fragment.utf8) { return true }
        }
        return false
    }

    private static func bytes(_ haystack: [UInt8], contain needle: String.UTF8View) -> Bool {
        let needleCount = needle.count
        guard needleCount <= haystack.count else { return false }
        var start = 0
        while start <= haystack.count - needleCount {
            var position = start
            var index = needle.startIndex
            while index != needle.endIndex, haystack[position] == needle[index] {
                position += 1
                index = needle.index(after: index)
            }
            if index == needle.endIndex { return true }
            start += 1
        }
        return false
    }
}
