import Foundation

enum LogPrivacySanitizer {
    private static let redactedSensitiveValue = "[redacted-sensitive-value]"

    private static let sensitiveKeyFragments: [String] = [
        "audio",
        "credential",
        "device",
        "dsn",
        "email",
        "file",
        "filename",
        "name",
        "password",
        "path",
        "profile",
        "secret",
        "token",
        "transcript",
        "url",
    ]

    private static let safeSensitiveLookingKeys: Set<String> = [
        "audiodurations",
        "audioactivecoeff",
        "audioactivedurations",
        "audioactiveratio",
        "audiogaps",
        "audiographgeneration",
        "audiohassignal",
        "audioinputselectionloadms",
        "audiopeak",
        "audiorms",
        "deviceswitches",
        "inputchannels",
        "inputdeviceclass",
        "inputratehz",
        "newprofiles",
        "outputchannels",
        "outputdeviceclass",
        "outputratehz",
        "profilecallcount",
        "profileid",
        "routechangecount",
        "routechangecountbucket",
        "speakerid",
        "speakerids",
        "speakers",
        "systembackend",
        "systemchannels",
        "systemoutputdeviceclass",
        "systemoutputratehz",
        "systemratehz",
        "systemstatus",
        "transcriptionengine",
        "transcriptid",
    ]

    // Core log messages historically use a narrower set of trailing
    // diagnostic keys than the app observability layer. Keep that profile here
    // so sharing the generic redactor does not change existing log output.
    private static let pathDiagnosticMetadataKeys: Set<String> = [
        "attempt",
        "code",
        "duration",
        "error",
        "event",
        "operation",
        "reason",
        "stage",
        "status",
    ]

    static func sanitizeText(_ text: String) -> String {
        PrivacyTextRedactor.redact(
            text,
            pathDiagnosticMetadataKeys: pathDiagnosticMetadataKeys
        )
    }

    static func sanitizeMetadata(_ metadata: [String: String]?) -> [String: String]? {
        guard let metadata else { return nil }

        let sanitized = metadata.reduce(into: [String: String]()) { result, pair in
            if shouldRedactValue(forKey: pair.key) {
                result[pair.key] = redactedSensitiveValue
            } else {
                let value = sanitizeText(pair.value)
                if !value.isEmpty {
                    result[pair.key] = value
                }
            }
        }

        return sanitized.isEmpty ? nil : sanitized
    }

    private static func shouldRedactValue(forKey key: String) -> Bool {
        let normalized = normalize(key)
        guard !safeSensitiveLookingKeys.contains(normalized) else { return false }
        return sensitiveKeyFragments.contains(where: { normalized.contains($0) })
    }

    private static func normalize(_ key: String) -> String {
        String(key.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
