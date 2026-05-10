import Foundation

func testPermissionsOnboardingPreferences() {
    runSuite("PermissionsOnboardingPreferences treats force-on as incomplete") {
        let suiteName = "PermissionsOnboardingPreferencesTests.force.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: PermissionsOnboardingPreferences.completionKey)
        assertTrue(
            PermissionsOnboardingPreferences.hasCompleted(userDefaults: defaults),
            "completed onboarding should stay completed when no force override exists"
        )

        defaults.set(true, forKey: PermissionsOnboardingPreferences.forceKey)
        assertFalse(
            PermissionsOnboardingPreferences.hasCompleted(userDefaults: defaults),
            "force-on should temporarily show onboarding even after completion"
        )
    }

    runSuite("PermissionsOnboardingPreferences clears stale force override on completion") {
        let suiteName = "PermissionsOnboardingPreferencesTests.complete.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(true, forKey: PermissionsOnboardingPreferences.forceKey)
        PermissionsOnboardingPreferences.markCompleted(userDefaults: defaults)

        assertTrue(
            defaults.bool(forKey: PermissionsOnboardingPreferences.completionKey),
            "completion should be persisted"
        )
        assertNil(
            defaults.object(forKey: PermissionsOnboardingPreferences.forceKey),
            "completion should clear force-on so onboarding does not loop forever"
        )
        assertTrue(
            PermissionsOnboardingPreferences.hasCompleted(userDefaults: defaults),
            "completion should win after clearing the stale force override"
        )
    }

    runSuite("PermissionsOnboardingPreferences can request a user rerun") {
        let suiteName = "PermissionsOnboardingPreferencesTests.rerun.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PermissionsOnboardingPreferences.markCompleted(userDefaults: defaults)
        PermissionsOnboardingPreferences.requestRerun(userDefaults: defaults)

        assertTrue(
            defaults.bool(forKey: PermissionsOnboardingPreferences.forceKey),
            "rerun request should set the force-on flag"
        )
        assertFalse(
            PermissionsOnboardingPreferences.hasCompleted(userDefaults: defaults),
            "rerun request should make onboarding presentable even after completion"
        )
    }
}
