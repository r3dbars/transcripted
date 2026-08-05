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
            ) {
                result[pair.key] = "[redacted-sensitive-value]"
            } else {
                result[pair.key] = ObservabilityTextRedactor.redact(pair.value)
            }
        }

        return sanitized.isEmpty ? nil : sanitized
    }
}
