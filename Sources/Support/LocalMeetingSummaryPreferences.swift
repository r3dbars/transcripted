import Foundation

enum LocalMeetingSummaryPreferences {
    static let enabledKey = "localMeetingSummaryBetaEnabled"
    static let defaultEnabled = false

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        if userDefaults.object(forKey: enabledKey) == nil {
            return defaultEnabled
        }
        return userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
    }
}
