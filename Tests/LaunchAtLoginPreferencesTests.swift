import Foundation

func testLaunchAtLoginPreferences() {
    runSuite("LaunchAtLoginPreferences defaults to off until the user chooses otherwise") {
        let suiteName = "LaunchAtLoginPreferencesTests.default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertFalse(
            LaunchAtLoginPreferences.hasExplicitChoice(userDefaults: defaults),
            "launch at login should start without an explicit saved choice"
        )
        assertFalse(
            LaunchAtLoginPreferences.isEnabled(userDefaults: defaults),
            "launch at login should default off before the user opts in"
        )
    }

    runSuite("LaunchAtLoginPreferences persists opt-in and opt-out choices") {
        let suiteName = "LaunchAtLoginPreferencesTests.persist.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        LaunchAtLoginPreferences.setEnabled(true, userDefaults: defaults)
        assertTrue(
            LaunchAtLoginPreferences.hasExplicitChoice(userDefaults: defaults),
            "turning launch at login on should record an explicit choice"
        )
        assertTrue(
            LaunchAtLoginPreferences.isEnabled(userDefaults: defaults),
            "turning launch at login on should persist true"
        )

        LaunchAtLoginPreferences.setEnabled(false, userDefaults: defaults)
        assertTrue(
            LaunchAtLoginPreferences.hasExplicitChoice(userDefaults: defaults),
            "turning launch at login off should keep an explicit choice"
        )
        assertFalse(
            LaunchAtLoginPreferences.isEnabled(userDefaults: defaults),
            "turning launch at login off should persist false"
        )
    }
}
