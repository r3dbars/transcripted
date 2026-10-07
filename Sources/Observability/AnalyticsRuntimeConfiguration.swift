import Foundation


enum AnalyticsRuntimeConfiguration {
    static let apiKeyInfoKey = "TranscriptedPostHogAPIKey"
    static let hostInfoKey = "TranscriptedPostHogHost"
    static let buildChannelInfoKey = "TranscriptedBuildChannel"
    static let buildRevisionInfoKey = "TranscriptedBuildRevision"
    static let buildChannelEnvironmentKey = "TRANSCRIPTED_ANALYTICS_BUILD_CHANNEL"
    static let buildRevisionEnvironmentKey = "TRANSCRIPTED_ANALYTICS_BUILD_REVISION"
    private static let localOverridesFileName = "observability-overrides.plist"

    /// Nil for our own launch harnesses: otherwise every build would look like
    /// a brand-new user who quit on the welcome screen.
    static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> String? {
        guard !AutomatedLaunchEnvironment.isActive(environment: environment) else { return nil }
        return firstNonEmpty(
            environment["POSTHOG_API_KEY"],
            localOverrideValue(forKey: apiKeyInfoKey),
            infoDictionary?[apiKeyInfoKey] as? String
        )
    }

    static func host() -> String? {
        firstNonEmpty(
            ProcessInfo.processInfo.environment["POSTHOG_HOST"],
            localOverrideValue(forKey: hostInfoKey),
            Bundle.main.object(forInfoDictionaryKey: hostInfoKey) as? String
        )
    }

    static func buildChannel(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> String {
        firstSafeBuildMetadata(
            environment[buildChannelEnvironmentKey],
            infoDictionary?[buildChannelInfoKey] as? String
        ) ?? "unknown"
    }

    static func buildRevision(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        infoDictionary: [String: Any]? = Bundle.main.infoDictionary
    ) -> String {
        firstSafeBuildMetadata(
            environment[buildRevisionEnvironmentKey],
            infoDictionary?[buildRevisionInfoKey] as? String
        ) ?? "unknown"
    }

    static func localOverrideValue(forKey key: String) -> String? {
        localOverrideValue(forKey: key, appSupportDirectory: applicationSupportDirectory())
    }

    static func localOverrideValue(forKey key: String, appSupportDirectory: URL) -> String? {
        for url in localOverridesSearchURLs(appSupportDirectory: appSupportDirectory) {
            guard let data = try? Data(contentsOf: url),
                  let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
                  let overrides = plist as? [String: String] else {
                continue
            }
            if let value = firstNonEmpty(overrides[key]) {
                return value
            }
        }

        return nil
    }

    static func localOverridesSearchURLs(appSupportDirectory: URL) -> [URL] {
        [
            appSupportDirectory
                .appendingPathComponent("Transcripted", isDirectory: true)
                .appendingPathComponent(localOverridesFileName),
            appSupportDirectory
                .appendingPathComponent("Draft", isDirectory: true)
                .appendingPathComponent(localOverridesFileName),
        ]
    }

    private static func applicationSupportDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }

    private static func firstSafeBuildMetadata(_ candidates: String?...) -> String? {
        candidates
            .compactMap { value -> String? in
                guard let trimmed = firstNonEmpty(value),
                      trimmed.count <= 80,
                      trimmed.allSatisfy({ character in
                          character.isLetter || character.isNumber || character == "." || character == "_" || character == "-"
                      }),
                      AnalyticsPayloadSanitizer.sanitizeText(trimmed) == trimmed else {
                    return nil
                }
                return trimmed
            }
            .first
    }
}
