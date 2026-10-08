import Foundation

func testHotkeyPreferences() {
    runSuite("HotkeyPreferences legacy dictation mode defaults to hands-free") {
        let suiteName = "HotkeyPreferencesTests.default.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(
            HotkeyPreferences.legacyDictationShortcutMode(userDefaults: defaults),
            .handsFree,
            "a missing legacy mode was hands-free, so migration must keep treating it that way"
        )
        defaults.set("push_to_talk", forKey: "hotkey-dictation-shortcut-mode")
        assertEqual(
            HotkeyPreferences.legacyDictationShortcutMode(userDefaults: defaults),
            .pushToTalk,
            "an explicit legacy push-to-talk mode must still be read"
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

    runSuite("Onboarding keeps Daniel Goncalves's meeting-only setup fully off") {
        let suiteName = "HotkeyPreferencesTests.danielMeetingOnly.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        OnboardingDictationShortcutPolicy.apply(
            useCase: .meetings,
            leaveDictationShortcutsOff: true,
            userDefaults: defaults
        )

        assertEqual(
            HotkeyPreferences.dictationShortcutsEnabled(userDefaults: defaults),
            false,
            "meeting-only onboarding should let users leave dictation shortcuts off"
        )
        assertEqual(
            HotkeyPreferences.rightOptionDictationEnabled(userDefaults: defaults),
            false,
            "meeting-only onboarding should not leave Right Option armed behind the master switch"
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
            HotkeyPreferences.legacyDictationShortcutMode(userDefaults: defaults),
            .handsFree,
            "unknown saved modes should fall back to hands-free"
        )
    }

    runSuite("HotkeyPreferences reset restores dictation defaults") {
        let suiteName = "HotkeyPreferencesTests.reset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        HotkeyPreferences.setDictationShortcutsEnabled(false, userDefaults: defaults)
        HotkeyPreferences.resetToDefaults(userDefaults: defaults)

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
