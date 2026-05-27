import Foundation

func testDictationOverlayPresentationPreferences() {
    runSuite("DictationOverlayPresentationPreferences defaults to text-box overlay") {
        let (defaults, suiteName) = makeDictationOverlayPresentationDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(
            DictationOverlayPresentationPreferences.mode(userDefaults: defaults),
            .nearText,
            "overlay should default to the existing text-box anchored presentation"
        )
    }

    runSuite("DictationOverlayPresentationPreferences persists mini cursor mode") {
        let (defaults, suiteName) = makeDictationOverlayPresentationDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        DictationOverlayPresentationPreferences.setMode(.cursorMini, userDefaults: defaults)
        assertEqual(
            DictationOverlayPresentationPreferences.mode(userDefaults: defaults),
            .cursorMini,
            "mini cursor mode should persist"
        )

        DictationOverlayPresentationPreferences.setMode(.nearText, userDefaults: defaults)
        assertEqual(
            DictationOverlayPresentationPreferences.mode(userDefaults: defaults),
            .nearText,
            "text-box mode should persist"
        )
    }

    runSuite("DictationOverlayPresentationPreferences falls back from unknown values") {
        let (defaults, suiteName) = makeDictationOverlayPresentationDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("floatyThing", forKey: DictationOverlayPresentationPreferences.modeKey)
        assertEqual(
            DictationOverlayPresentationPreferences.mode(userDefaults: defaults),
            .nearText,
            "unknown stored mode should not change the overlay behavior"
        )
    }

    runSuite("DictationOverlayPresentationPreferences keeps the storage key stable") {
        assertEqual(
            DictationOverlayPresentationPreferences.modeKey,
            "dictationOverlayPresentationMode",
            "storage key should not drift across updates"
        )
    }

    runSuite("DictationOverlayPresentationMode exposes clear settings labels") {
        assertEqual(
            DictationOverlayPresentationMode.nearText.title,
            "Near text box",
            "full overlay mode should name where the window appears"
        )
        assertEqual(
            DictationOverlayPresentationMode.cursorMini.title,
            "Mini cursor",
            "mini overlay mode should match the settings card label"
        )
        assertTrue(
            DictationOverlayPresentationMode.nearText.detail.contains("Full dictation window"),
            "full overlay mode should describe the larger dictation window"
        )
        assertTrue(
            DictationOverlayPresentationMode.cursorMini.detail.contains("follows the cursor"),
            "mini overlay mode should explain that it follows the pointer"
        )
    }
}

private func makeDictationOverlayPresentationDefaults() -> (UserDefaults, String) {
    let suiteName = "DictationOverlayPresentationPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
