import Foundation

enum LocalObservabilityPayloadSanitizer {
    private static let sensitiveContextKeys: Set<String> = [
        "audio_device",
        "bundle_id",
        "default_input_device",
        "default_output_device",
        "device_name",
        "file_path",
        "input_device_name",
        "meeting_name",
        "meeting_title",
        "microphone_name",
        "output_device_name",
        "raw_url",
        "selected_input_device",
        "source_app",
        "source_app_bundle_id",
        "source_app_name",
        "speaker_name",
        "transcript_text",
        "transcript_title",
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
            if sensitiveContextKeys.contains(pair.key.lowercased()) {
                result[pair.key] = "[redacted-sensitive-value]"
            } else {
                result[pair.key] = ObservabilityTextRedactor.redact(pair.value)
            }
        }

        return sanitized.isEmpty ? nil : sanitized
    }
}
