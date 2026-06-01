import Foundation

enum LiveMeetingCodexPreferences {
    static let enabledKey = "liveMeetingCodexModeEnabled"
    static let defaultEnabled = false

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
    }
}
