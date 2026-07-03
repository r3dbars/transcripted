import Foundation

enum LaunchAtLoginPreferences {
    private static let enabledKey = "launch-at-login-enabled"
    private static let defaultEnableAppliedKey = "launch-at-login-default-applied"

    static func hasExplicitChoice(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.object(forKey: enabledKey) != nil
    }

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
    }

    // MARK: - Default-on policy

    /// Whether the one-time default-enable has already run for this install.
    /// Tracked separately from `hasExplicitChoice` so applying the default never
    /// masquerades as a user decision, and so a user who later removes the login
    /// item in System Settings (which leaves no explicit choice here) is not
    /// silently re-registered on every launch.
    static func hasAppliedDefaultEnable(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: defaultEnableAppliedKey)
    }

    static func markDefaultEnableApplied(userDefaults: UserDefaults = .standard) {
        userDefaults.set(true, forKey: defaultEnableAppliedKey)
    }

    /// Meeting detection only works while the app is running, so launch-at-login
    /// defaults on — but only once per install, only after onboarding completes
    /// (so the macOS "added to Login Items" notice lands in context), and never
    /// over an explicit user choice.
    static func shouldApplyDefaultEnable(
        hasExplicitChoice: Bool,
        hasAppliedDefault: Bool,
        onboardingCompleted: Bool
    ) -> Bool {
        onboardingCompleted && !hasExplicitChoice && !hasAppliedDefault
    }
}
