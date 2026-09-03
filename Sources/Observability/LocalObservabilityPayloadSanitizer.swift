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

    /// Exact keys whose values are coarse enums, booleans, or numbers that the
    /// app emits next to raw device labels. The substring rule blanks them
    /// for containing "device" or "audio", which left `input_device_class`
    /// as "[redacted-sensitive-value]" on every dictation record while the
    /// sibling keys `default_input_class` and `route_shape` carried the same
    /// coarse fact. The escape only applies when the value still looks
    /// categorical (see `isCategoricalValue`), so a raw label written under
    /// one of these keys stays redacted.
    static let categoricalSafeKeys: Set<String> = [
        "input_device_class",
        "output_device_class",
        "system_output_device_class",
        "audio_has_signal",
        "audio_gaps",
        "device_switches",
        "mic_file_present",
        "system_file_present",
        "audio_duration_s",
        "audio_active_duration_s",
        "retry_audio_duration_s",
        "audio_active_ratio",
        "audio_peak",
        "audio_rms",
    ]

    private static func sanitizeContext(_ context: [String: String]?) -> [String: String]? {
        guard let context else { return nil }

        let sanitized = context.reduce(into: [String: String]()) { result, pair in
            if PayloadSanitizationCore.shouldDrop(
                key: pair.key,
                sensitiveFragments: sensitiveKeyFragments
            ), !isCategoricalSafe(key: pair.key, value: pair.value) {
                result[pair.key] = "[redacted-sensitive-value]"
            } else {
                result[pair.key] = ObservabilityTextRedactor.redact(pair.value)
            }
        }

        return sanitized.isEmpty ? nil : sanitized
    }

    static func isCategoricalSafe(key: String, value: String) -> Bool {
        categoricalSafeKeys.contains(key.lowercased()) && isCategoricalValue(value)
    }

    /// A bare number, `true`/`false`, or a short snake_case token. Device
    /// names, paths, and titles all carry spaces, uppercase, slashes, or
    /// punctuation and fail this test.
    private static func isCategoricalValue(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 40 else { return false }
        return value.allSatisfy { character in
            character.isASCII
                && (character.isNumber
                    || (character.isLetter && character.isLowercase)
                    || character == "_"
                    || character == "."
                    || character == "-")
        }
    }
}
