import Foundation

enum DockVisibilityPreferences {
    static let showInDockKey = "show-transcripted-in-dock"

    static func isVisible(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: showInDockKey) != nil else { return true }
        return userDefaults.bool(forKey: showInDockKey)
    }

    static func setVisible(
        _ visible: Bool,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(visible, forKey: showInDockKey)
        NotificationCenter.default.post(name: .dockVisibilityPreferencesDidChange, object: nil)
    }
}

extension Notification.Name {
    static let dockVisibilityPreferencesDidChange = Notification.Name("dockVisibilityPreferencesDidChange")
}
