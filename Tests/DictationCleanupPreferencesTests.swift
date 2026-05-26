import Foundation

func testDictationCleanupPreferences() {
    runSuite("DictationCleanupPreferences defaults to enabled") {
        let (defaults, suiteName) = makeDictationCleanupDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertTrue(DictationCleanupPreferences.isEnabled(userDefaults: defaults), "cleanup should be on by default")
    }

    runSuite("DictationCleanupPreferences persists enabled state") {
        let (defaults, suiteName) = makeDictationCleanupDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        DictationCleanupPreferences.setEnabled(false, userDefaults: defaults)
        assertFalse(DictationCleanupPreferences.isEnabled(userDefaults: defaults), "cleanup should read explicit off state")

        DictationCleanupPreferences.setEnabled(true, userDefaults: defaults)
        assertTrue(DictationCleanupPreferences.isEnabled(userDefaults: defaults), "cleanup should read explicit on state")
    }

    runSuite("DictationCleanupPreferences keeps the storage key stable") {
        assertEqual(
            DictationCleanupPreferences.enabledKey,
            "dictationCleanupEnabled",
            "storage key should not drift across updates"
        )
    }
}

private func makeDictationCleanupDefaults() -> (UserDefaults, String) {
    let suiteName = "DictationCleanupPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
