import Foundation

func testAutoCallDetectionPreferences() {
    runSuite("AutoCallDetectionPreferences defaults to enabled") {
        let (defaults, suiteName) = makeAutoCallDetectionDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertTrue(
            AutoCallDetectionPreferences.isEnabled(userDefaults: defaults),
            "ad-hoc call detection should be on for new installs (default ON, like Notion/Plaud)"
        )
    }

    runSuite("AutoCallDetectionPreferences persists disabled and re-enabled states") {
        let (defaults, suiteName) = makeAutoCallDetectionDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        AutoCallDetectionPreferences.setEnabled(false, userDefaults: defaults)
        assertFalse(
            AutoCallDetectionPreferences.isEnabled(userDefaults: defaults),
            "an explicit opt-out should round-trip and stay off"
        )

        AutoCallDetectionPreferences.setEnabled(true, userDefaults: defaults)
        assertTrue(
            AutoCallDetectionPreferences.isEnabled(userDefaults: defaults),
            "an explicit opt-in should round-trip back on"
        )
    }

    runSuite("AutoCallDetectionPreferences uses a stable storage key") {
        assertEqual(
            AutoCallDetectionPreferences.enabledKey,
            "auto-call-detection-enabled",
            "storage key must stay stable across releases"
        )
    }
}

private func makeAutoCallDetectionDefaults() -> (UserDefaults, String) {
    let suiteName = "AutoCallDetectionPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
