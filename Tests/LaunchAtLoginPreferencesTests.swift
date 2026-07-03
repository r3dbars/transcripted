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

    runSuite("LaunchAtLoginPreferences.shouldApplyDefaultEnable — one-time default after onboarding, never over a choice") {
        assertTrue(
            LaunchAtLoginPreferences.shouldApplyDefaultEnable(
                hasExplicitChoice: false, hasAppliedDefault: false, onboardingCompleted: true
            ),
            "an onboarded install with no choice and no prior default run should get the default"
        )
        assertFalse(
            LaunchAtLoginPreferences.shouldApplyDefaultEnable(
                hasExplicitChoice: false, hasAppliedDefault: false, onboardingCompleted: false
            ),
            "the default must wait for onboarding so the macOS login-item notice has context"
        )
        assertFalse(
            LaunchAtLoginPreferences.shouldApplyDefaultEnable(
                hasExplicitChoice: true, hasAppliedDefault: false, onboardingCompleted: true
            ),
            "an explicit user choice must never be overridden by the default"
        )
        assertFalse(
            LaunchAtLoginPreferences.shouldApplyDefaultEnable(
                hasExplicitChoice: false, hasAppliedDefault: true, onboardingCompleted: true
            ),
            "the default runs at most once, so a System Settings removal is not silently undone"
        )
    }

    runSuite("LaunchAtLoginPreferences default-enable marker persists without recording an explicit choice") {
        let suiteName = "LaunchAtLoginPreferencesTests.marker.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertFalse(
            LaunchAtLoginPreferences.hasAppliedDefaultEnable(userDefaults: defaults),
            "a fresh install should not claim the default already ran"
        )
        LaunchAtLoginPreferences.markDefaultEnableApplied(userDefaults: defaults)
        assertTrue(
            LaunchAtLoginPreferences.hasAppliedDefaultEnable(userDefaults: defaults),
            "the applied marker should persist"
        )
        assertFalse(
            LaunchAtLoginPreferences.hasExplicitChoice(userDefaults: defaults),
            "applying the default must not masquerade as an explicit user choice"
        )
    }
}
