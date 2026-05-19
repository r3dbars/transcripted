import Foundation

enum DictationCleanupPreferences {
    static let enabledKey = "dictationCleanupEnabled"

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        if userDefaults.object(forKey: enabledKey) == nil {
            return true
        }
        return userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
    }
}
