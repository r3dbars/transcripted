import Foundation

enum SentryRuntimeConfiguration {
    static let dsnInfoKey = "TranscriptedSentryDSN"
    static let environmentInfoKey = "TranscriptedSentryEnvironment"
    static let releasePrefixInfoKey = "TranscriptedSentryReleasePrefix"
    static let appHangTrackingInfoKey = "TranscriptedSentryAppHangTrackingEnabled"
    static let dsnEnvironmentKey = "SENTRY_DSN"
    static let environmentEnvironmentKey = "SENTRY_ENVIRONMENT"
    static let releaseEnvironmentKey = "SENTRY_RELEASE"
    static let distEnvironmentKey = "SENTRY_DIST"
    static let appHangTrackingEnvironmentKey = "SENTRY_ENABLE_APP_HANG_TRACKING"
    static let defaultReleasePrefix = "transcripted"

    static func dsn(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> String? {
        firstValidHTTPSValue(
            environment[dsnEnvironmentKey],
            infoDictionary?[dsnInfoKey] as? String
        )
    }

    static func environment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> String {
        firstSafeMetadataValue(
            environment[environmentEnvironmentKey],
            infoDictionary?[environmentInfoKey] as? String
        ) ?? "production"
    }

    static func releaseName(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> String {
        if let releaseOverride = firstSafeMetadataValue(environment[releaseEnvironmentKey]),
           isValidReleaseName(releaseOverride) {
            return releaseOverride
        }

        let prefix = firstSafeMetadataValue(
            infoDictionary?[releasePrefixInfoKey] as? String,
            defaultReleasePrefix
        ) ?? defaultReleasePrefix
        let version = firstSafeMetadataValue(infoDictionary?["CFBundleShortVersionString"] as? String) ?? "unknown"
        let releaseName = "\(prefix)@\(version)"
        return isValidReleaseName(releaseName) ? releaseName : "\(defaultReleasePrefix)@unknown"
    }

    static func dist(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> String? {
        firstSafeMetadataValue(
            environment[distEnvironmentKey],
            infoDictionary?["CFBundleVersion"] as? String
        )
    }

    static func appHangTrackingEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> Bool {
        if let override = firstNonEmpty(environment[appHangTrackingEnvironmentKey]) {
            return parseBoolean(override) ?? false
        }

        if let configured = infoDictionary?[appHangTrackingInfoKey] {
            if let enabled = configured as? Bool {
                return enabled
            }
            if let configuredString = configured as? String {
                return parseBoolean(configuredString) ?? false
            }
        }

        return false
    }

    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func firstSafeMetadataValue(_ candidates: String?...) -> String? {
        candidates
            .compactMap(safeMetadataValue)
            .first
    }

    private static func safeMetadataValue(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              isValidMetadataValue(trimmed),
              SentryPayloadSanitizer.sanitizeText(trimmed) == trimmed else {
            return nil
        }

        return trimmed
    }

    private static func firstValidHTTPSValue(_ candidates: String?...) -> String? {
        candidates
            .compactMap { normalizedHTTPSValue($0) }
            .first
    }

    private static func normalizedHTTPSValue(_ candidate: String?) -> String? {
        guard let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }

        // Security: fail closed on non-HTTPS DSNs so a tampered env var or Info.plist
        // cannot downgrade crash reports to plaintext transport.
        guard trimmed.lowercased().hasPrefix("https://") else {
            return nil
        }

        return trimmed
    }

    private static func isValidReleaseName(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 200, ![".", "..", " "].contains(value) else {
            return false
        }

        return !["\n", "\t", "/", "\\"].contains { value.contains($0) }
    }

    private static func isValidMetadataValue(_ value: String) -> Bool {
        guard value.count <= 200 else { return false }
        return !value.contains { character in
            character == "\n"
                || character == "\r"
                || character == "\t"
                || character == "/"
                || character == "\\"
        }
    }

    private static func parseBoolean(_ value: String) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        case "0", "false", "no", "off":
            return false
        default:
            return nil
        }
    }
}
