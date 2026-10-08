import Foundation

enum AnalyticsPreferences {
    private static let enabledKey = "observability-anonymous-analytics-enabled"

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: enabledKey) != nil else { return true }
        return userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
    }
}

/// Info.plist keys for the anonymous-analytics build configuration. They live
/// here (not in `AnalyticsRuntimeConfiguration`) because the Claude Desktop
/// helper installer in Support copies the same values into the helper's config.
enum AnalyticsInfoPlistKeys {
    static let apiKeyInfoKey = "TranscriptedPostHogAPIKey"
    static let hostInfoKey = "TranscriptedPostHogHost"
    static let buildChannelInfoKey = "TranscriptedBuildChannel"
    static let buildRevisionInfoKey = "TranscriptedBuildRevision"
}
