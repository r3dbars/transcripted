import Foundation

enum LiveMeetingCodexPreferences {
    static let enabledKey = "liveMeetingCodexModeEnabled"
    static let defaultEnabled = false

    // Meeting-overlay transcript drawer state. The drawer remembers whether
    // the user left it open and how tall they made it, so every meeting
    // starts the way the last one was used.
    static let drawerOpenKey = "liveMeetingTranscriptDrawerOpen"
    static let defaultDrawerOpen = true
    static let drawerHeightKey = "liveMeetingTranscriptDrawerHeight"
    static let defaultDrawerHeight: Double = 240
    static let minimumDrawerHeight: Double = 140
    static let maximumDrawerHeight: Double = 520

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
    }

    static func isDrawerOpenPreferred(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: drawerOpenKey) != nil else {
            return defaultDrawerOpen
        }
        return userDefaults.bool(forKey: drawerOpenKey)
    }

    static func setDrawerOpenPreferred(_ open: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(open, forKey: drawerOpenKey)
    }

    static func clampedDrawerHeight(_ height: Double) -> Double {
        min(max(height, minimumDrawerHeight), maximumDrawerHeight)
    }

    static func preferredDrawerHeight(userDefaults: UserDefaults = .standard) -> Double {
        let stored = userDefaults.double(forKey: drawerHeightKey)
        guard stored > 0 else { return defaultDrawerHeight }
        return clampedDrawerHeight(stored)
    }

    static func setPreferredDrawerHeight(_ height: Double, userDefaults: UserDefaults = .standard) {
        userDefaults.set(clampedDrawerHeight(height), forKey: drawerHeightKey)
    }
}
