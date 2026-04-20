import Foundation

enum SentryRuntimeConfiguration {
    static let dsnInfoKey = "TranscriptedSentryDSN"
    static let environmentInfoKey = "TranscriptedSentryEnvironment"
    static let dsnEnvironmentKey = "SENTRY_DSN"
    static let environmentEnvironmentKey = "SENTRY_ENVIRONMENT"

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

    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}
