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

    runSuite("HotkeyPreferences dictation shortcuts default to enabled") {
        let suiteName = "HotkeyPreferencesTests.shortcutsEnabledDefault.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(
            HotkeyPreferences.dictationShortcutsEnabled(userDefaults: defaults),
            true,
            "existing users should keep working dictation shortcuts by default"
        )
    }

    runSuite("HotkeyPreferences stores disabled dictation shortcuts") {
        let suiteName = "HotkeyPreferencesTests.shortcutsDisabled.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        HotkeyPreferences.setRightOptionDictation(enabled: true, userDefaults: defaults)
        HotkeyPreferences.setDictationShortcutsEnabled(false, userDefaults: defaults)

        assertEqual(
            HotkeyPreferences.dictationShortcutsEnabled(userDefaults: defaults),
            false,
            "users should be able to turn off accidental dictation triggers"
        )
        assertEqual(
            HotkeyPreferences.rightOptionDictationEnabled(userDefaults: defaults),
            false,
            "turning dictation shortcuts off should also keep the legacy Right Option trigger off"
        )
    }

    runSuite("Unified onboarding leaves shortcut preferences untouched") {
        let suiteName = "HotkeyPreferencesTests.unifiedOnboarding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // The single-flow onboarding writes no shortcut preference at all, so
        // the stored defaults must already mean "ready to dictate" while
        // meeting-only users opt out later in Settings > Shortcuts (covered by
        // the disabled-shortcuts suite above).
        assertEqual(
            HotkeyPreferences.dictationShortcutsEnabled(userDefaults: defaults),
            true,
            "fresh installs should finish onboarding with dictation shortcuts armed"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.meetingBinding(userDefaults: defaults),
            PhysicalDictationTriggerPreferences.defaultMeetingBinding,
            "meeting capture should still keep its app shortcut path available"
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
        HotkeyPreferences.setDictationShortcutsEnabled(false, userDefaults: defaults)
        HotkeyPreferences.resetToDefaults(userDefaults: defaults)

        assertEqual(
            HotkeyPreferences.dictationShortcutMode(userDefaults: defaults),
            .handsFree,
            "reset should restore the default dictation mode"
        )
        assertEqual(
            HotkeyPreferences.dictationShortcutsEnabled(userDefaults: defaults),
            true,
            "reset should re-enable dictation shortcuts"
        )
        assertEqual(
            HotkeyPreferences.rightOptionDictationEnabled(userDefaults: defaults),
            true,
            "reset should restore the default Right Option behavior"
        )
    }
}
