import Foundation

func testHotkeyPreferences() {
    runSuite("HotkeyPreferences dictation mode defaults to hands-free") {
        let suiteName = "HotkeyPreferencesTests.default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(
            HotkeyPreferences.dictationShortcutMode(userDefaults: defaults),
            .handsFree,
            "dictation should keep the existing tap-to-toggle behavior by default"
        )
    }

    runSuite("HotkeyPreferences stores push-to-talk dictation mode") {
        let suiteName = "HotkeyPreferencesTests.pushToTalk.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        HotkeyPreferences.setDictationShortcutMode(.pushToTalk, userDefaults: defaults)

        assertEqual(
            HotkeyPreferences.dictationShortcutMode(userDefaults: defaults),
            .pushToTalk,
            "users should be able to opt into hold-to-record behavior"
        )
    }

    runSuite("HotkeyPreferences ignores unknown dictation modes") {
        let suiteName = "HotkeyPreferencesTests.unknown.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set("not-a-real-mode", forKey: "hotkey-dictation-shortcut-mode")

        assertEqual(
            HotkeyPreferences.dictationShortcutMode(userDefaults: defaults),
            .handsFree,
            "unknown saved modes should fall back to hands-free"
        )
    }

    runSuite("HotkeyPreferences reset restores hands-free dictation mode") {
        let suiteName = "HotkeyPreferencesTests.reset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        HotkeyPreferences.setDictationShortcutMode(.pushToTalk, userDefaults: defaults)
        HotkeyPreferences.resetToDefaults(userDefaults: defaults)

        assertEqual(
            HotkeyPreferences.dictationShortcutMode(userDefaults: defaults),
            .handsFree,
            "reset should restore the default dictation mode"
        )
    }
}
