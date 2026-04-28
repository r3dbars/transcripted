import Foundation

func testDictationOverlayPreferences() {
    runSuite("DictationOverlayPreferences defaults to near text") {
        let (defaults, suiteName) = makeDictationOverlayDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(
            DictationOverlayPreferences.presentation(userDefaults: defaults),
            .nearText,
            "Dictation overlay should start near the active text area"
        )
        assertFalse(
            DictationOverlayPreferences.isDockShelfEnabled(userDefaults: defaults),
            "Dock shelf should be opt-in"
        )
    }

    runSuite("DictationOverlayPreferences persists dock shelf opt in") {
        let (defaults, suiteName) = makeDictationOverlayDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        DictationOverlayPreferences.setPresentation(.dockShelf, userDefaults: defaults)

        assertEqual(
            DictationOverlayPreferences.presentation(userDefaults: defaults),
            .dockShelf,
            "Dock shelf choice should persist"
        )
        assertTrue(
            DictationOverlayPreferences.isDockShelfEnabled(userDefaults: defaults),
            "Dock shelf helper should reflect the saved choice"
        )
    }

    runSuite("DictationOverlayPreferences ignores unknown stored values") {
        let (defaults, suiteName) = makeDictationOverlayDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("future-shape", forKey: DictationOverlayPreferences.presentationKey)

        assertEqual(
            DictationOverlayPreferences.presentation(userDefaults: defaults),
            .nearText,
            "Unknown values should fall back to the stable default"
        )
    }

    runSuite("DictationOverlayPreferences uses a stable storage key") {
        assertEqual(
            DictationOverlayPreferences.presentationKey,
            "dictation-overlay-presentation",
            "Storage key must remain stable across releases"
        )
    }
}

private func makeDictationOverlayDefaults() -> (UserDefaults, String) {
    let suiteName = "DictationOverlayPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
