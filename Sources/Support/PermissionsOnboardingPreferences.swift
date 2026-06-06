import Foundation

enum PermissionsOnboardingPreferences {
    static let completionKey = "permissionsOnboardingCompleted"
    static let forceKey = "forcePermissionsOnboarding"
    static let firstDictationSavedTrackedKey = "permissionsOnboardingFirstDictationSavedTracked"

    static func hasCompleted(userDefaults: UserDefaults = .standard) -> Bool {
        if userDefaults.bool(forKey: forceKey) {
            return false
        }
        return userDefaults.bool(forKey: completionKey)
    }

    static func markCompleted(userDefaults: UserDefaults = .standard) {
        userDefaults.set(true, forKey: completionKey)
        userDefaults.removeObject(forKey: forceKey)
    }

    static func markFirstDictationSavedTrackedIfNeeded(userDefaults: UserDefaults = .standard) -> Bool {
        guard !hasCompleted(userDefaults: userDefaults) else { return false }
        guard !userDefaults.bool(forKey: firstDictationSavedTrackedKey) else { return false }

        userDefaults.set(true, forKey: firstDictationSavedTrackedKey)
        return true
    }
}
