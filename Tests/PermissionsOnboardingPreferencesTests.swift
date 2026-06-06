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

    runSuite("PermissionsOnboardingPreferences tracks first saved dictation once") {
        let suiteName = "PermissionsOnboardingPreferencesTests.first-dictation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertTrue(
            PermissionsOnboardingPreferences.markFirstDictationSavedTrackedIfNeeded(userDefaults: defaults),
            "first saved dictation should be tracked while onboarding is incomplete"
        )
        assertFalse(
            PermissionsOnboardingPreferences.markFirstDictationSavedTrackedIfNeeded(userDefaults: defaults),
            "first saved dictation should not be tracked more than once"
        )
        assertTrue(
            defaults.bool(forKey: PermissionsOnboardingPreferences.firstDictationSavedTrackedKey),
            "first saved dictation tracking should persist"
        )
    }

    runSuite("PermissionsOnboardingPreferences skips first saved dictation after completion") {
        let suiteName = "PermissionsOnboardingPreferencesTests.first-dictation-complete.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PermissionsOnboardingPreferences.markCompleted(userDefaults: defaults)

        assertFalse(
            PermissionsOnboardingPreferences.markFirstDictationSavedTrackedIfNeeded(userDefaults: defaults),
            "completed onboarding should not emit first saved dictation telemetry"
        )
        assertNil(
            defaults.object(forKey: PermissionsOnboardingPreferences.firstDictationSavedTrackedKey),
            "skipped tracking should not mark the first saved dictation key"
        )
    }
}
