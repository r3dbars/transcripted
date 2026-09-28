import Foundation

func testDictationOverlayPresentationPreferences() {
    runSuite("Someone who never picked a dictation window gets the Notch island") {
        let (defaults, suiteName) = makeDictationOverlayPresentationDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(
            DictationOverlayPresentationPreferences.mode(userDefaults: defaults),
            .notchIsland,
            "with nothing saved, dictation uses the Notch island"
        )
        assertNil(
            defaults.string(forKey: DictationOverlayPresentationPreferences.modeKey),
            "reading the default saves nothing, so a later default change still reaches this user"
        )
    }

    runSuite("A window someone picked survives the Notch island default") {
        for picked in DictationOverlayPresentationMode.allCases {
            let (defaults, suiteName) = makeDictationOverlayPresentationDefaults()
            defer { defaults.removePersistentDomain(forName: suiteName) }

            DictationOverlayPresentationPreferences.setMode(picked, userDefaults: defaults)
            assertEqual(
                DictationOverlayPresentationPreferences.mode(userDefaults: defaults),
                picked,
                "\(picked.rawValue) stays picked"
            )
        }
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

    runSuite("DictationOverlayPresentationPreferences persists notch island mode") {
        let (defaults, suiteName) = makeDictationOverlayPresentationDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        DictationOverlayPresentationPreferences.setMode(.notchIsland, userDefaults: defaults)
        assertEqual(
            DictationOverlayPresentationPreferences.mode(userDefaults: defaults),
            .notchIsland,
            "notch island mode should persist"
        )
        assertEqual(
            defaults.string(forKey: DictationOverlayPresentationPreferences.modeKey),
            "notchIsland",
            "the stored value is the raw case name, so it survives updates"
        )
    }

    runSuite("NotchIslandPreferences keeps the island out of screen sharing unless turned on") {
        let (defaults, suiteName) = makeDictationOverlayPresentationDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertFalse(
            NotchIslandPreferences.visibleInScreenSharing(userDefaults: defaults),
            "a shared screen must not show live dictation by default"
        )
        NotchIslandPreferences.setVisibleInScreenSharing(true, userDefaults: defaults)
        assertTrue(NotchIslandPreferences.visibleInScreenSharing(userDefaults: defaults), "turning it on persists")
        assertEqual(
            NotchIslandPreferences.visibleInScreenSharingKey,
            "notchIslandVisibleInScreenSharing",
            "the Settings toggle and the island read the same key"
        )
    }

    runSuite("DictationOverlayPresentationPreferences falls back from unknown values") {
        let (defaults, suiteName) = makeDictationOverlayPresentationDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("floatyThing", forKey: DictationOverlayPresentationPreferences.modeKey)
        assertEqual(
            DictationOverlayPresentationPreferences.mode(userDefaults: defaults),
            .notchIsland,
            "an unreadable stored mode falls back to the default window"
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
        assertTrue(
            DictationOverlayPresentationMode.cursorMini.detail.contains("Stop with your dictation shortcut"),
            "mini overlay mode should explain how to stop when the stop button is hidden"
        )
        assertTrue(
            DictationOverlayPresentationMode.cursorMini.detail.contains("Esc cancels"),
            "Esc throws the take away, so the copy must never say it stops"
        )
        assertFalse(
            DictationOverlayPresentationMode.cursorMini.detail.contains("shortcut or Escape"),
            "Esc is not a second way to stop and paste"
        )
        assertEqual(
            DictationOverlayPresentationMode.notchIsland.title,
            "Notch island",
            "island mode should match the settings card label"
        )
        assertTrue(
            DictationOverlayPresentationMode.notchIsland.detail.contains("top of other displays"),
            "island mode should say what happens on a display without a notch"
        )
        assertTrue(
            DictationOverlayPresentationMode.notchIsland.detail.contains("Meetings use it too"),
            "island mode changes the meeting pill as well, so the card has to say so"
        )
        assertEqual(
            DictationOverlayPresentationMode.allCases,
            [.nearText, .cursorMini, .notchIsland],
            "the settings picker shows the three styles in this order"
        )
    }
}

private func makeDictationOverlayPresentationDefaults() -> (UserDefaults, String) {
    let suiteName = "DictationOverlayPresentationPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
