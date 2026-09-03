import Foundation

enum LocalObservabilityPayloadSanitizer {
    // Local logs use the shared privacy floor plus "device" so raw hardware
    // labels cannot bypass redaction under a new key spelling.
    static let sensitiveKeyFragments = PayloadSanitizationCore.baseSensitiveKeyFragments + [
        "device",
    ]

    static func sanitize(_ event: ObservabilityEvent) -> ObservabilityEvent {
        ObservabilityEvent(
            timestamp: event.timestamp,
            level: event.level,
            engine: event.engine,
            event: event.event,
            message: ObservabilityTextRedactor.redact(event.message),
            context: sanitizeContext(event.context),
            appVersion: event.appVersion,
            osVersion: event.osVersion
        )
    }

    private static func sanitizeContext(_ context: [String: String]?) -> [String: String]? {
        guard let context else { return nil }

        let sanitized = context.reduce(into: [String: String]()) { result, pair in
            if PayloadSanitizationCore.shouldDrop(
                key: pair.key,
                sensitiveFragments: sensitiveKeyFragments
            ), !isPlainMeasurement(key: pair.key, value: pair.value) {
                result[pair.key] = "[redacted-sensitive-value]"
            } else {
                result[pair.key] = ObservabilityTextRedactor.redact(pair.value)
            }
        }

        return sanitized.isEmpty ? nil : sanitized
    }

    /// Numeric duration, rate, size, and count values are safe to retain in
    /// the on-device log even when their key contains a sensitive fragment.
    /// This remains local-only and does not weaken Sentry or analytics policy.
    private static let measurementKeySuffixes = [
        "_ms", "_s", "_ns", "_us", "_hz", "_bytes", "_count", "_seconds", "_rtf",
    ]

    static func isPlainMeasurement(key: String, value: String) -> Bool {
        let normalized = key.lowercased()
        guard normalized == "rtf" || measurementKeySuffixes.contains(where: { normalized.hasSuffix($0) }) else {
            return false
        }
        return isBareNumber(value)
    }

    private static func isBareNumber(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 24 else { return false }

        var digits = 0
        var seenSeparator = false
        for (offset, character) in value.enumerated() {
            if character == "-" || character == "+" {
                guard offset == 0 else { return false }
                continue
            }
            if character == "." {
                guard !seenSeparator else { return false }
                seenSeparator = true
                continue
            }
            guard character.isASCII, character.isNumber else { return false }
            digits += 1
        }
        return digits > 0
    }
}
