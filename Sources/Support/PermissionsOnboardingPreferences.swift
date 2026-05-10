import Foundation

enum PermissionsOnboardingPreferences {
    static let completionKey = "permissionsOnboardingCompleted"
    static let forceKey = "forcePermissionsOnboarding"

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

    static func requestRerun(userDefaults: UserDefaults = .standard) {
        userDefaults.set(true, forKey: forceKey)
    }
}
