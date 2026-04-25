import Foundation

enum SentryRuntimeConfiguration {
    static let dsnInfoKey = "TranscriptedSentryDSN"
    static let environmentInfoKey = "TranscriptedSentryEnvironment"
    static let appHangTrackingInfoKey = "TranscriptedSentryAppHangTrackingEnabled"
    static let dsnEnvironmentKey = "SENTRY_DSN"
    static let environmentEnvironmentKey = "SENTRY_ENVIRONMENT"
    static let appHangTrackingEnvironmentKey = "SENTRY_ENABLE_APP_HANG_TRACKING"

    static func dsn(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> String? {
        firstNonEmpty(
            environment[dsnEnvironmentKey],
            infoDictionary?[dsnInfoKey] as? String
        )
    }

    static func environment(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> String {
        firstNonEmpty(
            environment[environmentEnvironmentKey],
            infoDictionary?[environmentInfoKey] as? String
        ) ?? "production"
    }

    static func releaseName(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> String {
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        return "transcripted@\(version)"
    }

    static func dist(infoDictionary: [String: Any]? = Bundle.main.infoDictionary) -> String? {
        firstNonEmpty(infoDictionary?["CFBundleVersion"] as? String)
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
