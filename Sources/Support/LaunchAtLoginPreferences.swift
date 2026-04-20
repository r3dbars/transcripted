import Foundation

enum LaunchAtLoginPreferences {
    private static let enabledKey = "launch-at-login-enabled"

    static func hasExplicitChoice(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.object(forKey: enabledKey) != nil
    }

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
    }
}
