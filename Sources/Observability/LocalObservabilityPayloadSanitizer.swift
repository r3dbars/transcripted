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

    /// Measurement-suffixed keys whose value is a bare number are kept even when
    /// the key matches a sensitive fragment.
    ///
    /// The fragment list matches on substrings, so `audio_engine_start_ms` and
    /// `audio_tap_install_ms` are dropped for containing "audio" — which erased
    /// every stage timing for the dictation start path from the on-disk log and
    /// left the slowest user-visible path undiagnosable. A bare number under a
    /// duration/size/rate key carries no identifying content, so the value is
    /// safe to keep. Both halves of the test matter: the suffix keeps this away
    /// from identifier-shaped keys, and the numeric check keeps it away from any
    /// key whose value is a device or file name.
    ///
    /// Local-sink only. Sentry and Analytics sanitize `mergedContext`
    /// separately and are unaffected by this escape.
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

    /// True for an optionally-signed decimal with no exponent, grouping, or
    /// units. Deliberately stricter than `Double(_:)`, which also accepts
    /// "infinity", "nan", and hex floats.
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
