import Foundation

enum SpeechModelBetaPreferences {
    static let nemotronEnabledKey = "speech-nemotron-beta-enabled"
    static let defaultNemotronEnabled = false

    static func nemotronBetaEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        if userDefaults.object(forKey: nemotronEnabledKey) == nil {
            return defaultNemotronEnabled
        }
        return userDefaults.bool(forKey: nemotronEnabledKey)
    }

    static func setNemotronBetaEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: nemotronEnabledKey)
        NotificationCenter.default.post(name: .speechModelBetaPreferencesDidChange, object: nil)
    }
}

extension Notification.Name {
    static let speechModelBetaPreferencesDidChange = Notification.Name("speechModelBetaPreferencesDidChange")
}
