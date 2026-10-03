import Foundation

func testDictationMufflePreferences() {
    runSuite("Muffling other audio while dictating is off until the user turns it on") {
        let (defaults, suiteName) = makeDictationMuffleDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertFalse(DictationMufflePreferences.isEnabled(userDefaults: defaults), "muffle should be off by default")
    }

    runSuite("The muffle setting remembers both on and off") {
        let (defaults, suiteName) = makeDictationMuffleDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        DictationMufflePreferences.setEnabled(true, userDefaults: defaults)
        assertTrue(DictationMufflePreferences.isEnabled(userDefaults: defaults), "explicit on should read back as on")

        DictationMufflePreferences.setEnabled(false, userDefaults: defaults)
        assertFalse(DictationMufflePreferences.isEnabled(userDefaults: defaults), "explicit off should read back as off")

        DictationMufflePreferences.setEnabled(true, userDefaults: defaults)
        assertTrue(DictationMufflePreferences.isEnabled(userDefaults: defaults), "turning it back on should stick")
    }

    runSuite("The muffle setting is stored under a stable key") {
        assertEqual(
            DictationMufflePreferences.enabledKey,
            "dictationMuffleOtherAudioEnabled",
            "storage key should not drift across updates"
        )

        let (defaults, suiteName) = makeDictationMuffleDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "dictationMuffleOtherAudioEnabled")
        assertTrue(
            DictationMufflePreferences.isEnabled(userDefaults: defaults),
            "a value already saved under the key should be honored"
        )
    }
}

private func makeDictationMuffleDefaults() -> (UserDefaults, String) {
    let suiteName = "DictationMufflePreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
