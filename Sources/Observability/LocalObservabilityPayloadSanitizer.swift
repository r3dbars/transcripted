import Foundation

enum LocalObservabilityPayloadSanitizer {
    private static let sensitiveContextKeys: Set<String> = [
        "audio_device",
        "audio_path",
        "bundle_id",
        "default_input_device",
        "default_input_name",
        "default_output_device",
        "default_output_name",
        "device_name",
        "download_url",
        "file_path",
        "input_device",
        "input_device_name",
        "input_name",
        "meeting_name",
        "meeting_title",
        "meeting_url",
        "microphone_name",
        "output_device",
        "output_device_name",
        "output_name",
        "prompt_text",
        "raw_url",
        "selected_input_device",
        "source_app",
        "source_app_bundle",
        "source_app_bundle_id",
        "source_app_name",
        "speaker_name",
        "title",
        "transcript",
        "transcript_path",
        "transcript_text",
        "transcript_title",
        "url",
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
