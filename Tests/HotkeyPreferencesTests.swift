import Foundation
import AppKit
import Carbon

func testHotkeyPreferences() {
    runSuite("HotkeyPreferences dictation and meeting bindings default when empty") {
        let suiteName = "HotkeyPreferencesTests.emptyDefaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(
            HotkeyPreferences.dictationBinding(userDefaults: defaults),
            HotkeyPreferences.defaultDictation,
            "dictation binding should fall back to the default shortcut"
        )
        assertEqual(
            HotkeyPreferences.meetingBinding(userDefaults: defaults),
            HotkeyPreferences.defaultMeeting,
            "meeting binding should fall back to the default shortcut"
        )
    }

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

    runSuite("HotkeyPreferences reset clears retired Draft hotkey keys") {
        let suiteName = "HotkeyPreferencesTests.legacyDraft.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        defaults.set(2, forKey: "hotkey-draft-keyCode")
        defaults.set(2048, forKey: "hotkey-draft-modifiers")

        HotkeyPreferences.resetToDefaults(userDefaults: defaults)

        assertNil(
            defaults.object(forKey: "hotkey-draft-keyCode"),
            "reset should clear retired Draft key-code preferences"
        )
        assertNil(
            defaults.object(forKey: "hotkey-draft-modifiers"),
            "reset should clear retired Draft modifier preferences"
        )
    }

    runSuite("HotkeyPreferences validates global shortcut bindings") {
        assertFalse(
            HotkeyPreferences.isValid(HotkeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: 0)),
            "bare letters should not be global hotkeys"
        )
        assertFalse(
            HotkeyPreferences.isValid(HotkeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(shiftKey))),
            "shift-only shortcuts should not count as meaningful global hotkeys"
        )
        assertFalse(
            HotkeyPreferences.isValid(HotkeyBinding(keyCode: UInt32(kVK_Command), modifiers: UInt32(cmdKey))),
            "modifier-only key codes should not be saved as global shortcuts"
        )
        assertFalse(
            HotkeyPreferences.isValid(HotkeyBinding(keyCode: UInt32(kVK_Escape), modifiers: UInt32(optionKey))),
            "Escape should stay reserved for cancellation"
        )
        assertFalse(
            HotkeyPreferences.isValid(HotkeyBinding(keyCode: UInt32(kVK_Tab), modifiers: UInt32(optionKey))),
            "Tab should stay available for keyboard navigation"
        )

        assertTrue(
            HotkeyPreferences.isValid(HotkeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey))),
            "command plus a real key should be valid"
        )
        assertTrue(
            HotkeyPreferences.isValid(HotkeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey))),
            "option plus a real key should be valid"
        )
        assertTrue(
            HotkeyPreferences.isValid(HotkeyBinding(keyCode: UInt32(kVK_ANSI_M), modifiers: UInt32(controlKey))),
            "control plus a real key should be valid"
        )
        assertTrue(
            HotkeyPreferences.isValid(HotkeyBinding(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey))),
            "shift can join a meaningful modifier"
        )
    }

    runSuite("HotkeyPreferences converts AppKit modifiers to Carbon masks") {
        assertEqual(HotkeyPreferences.carbonModifiers(from: [.command]), UInt32(cmdKey), "command should map to cmdKey")
        assertEqual(HotkeyPreferences.carbonModifiers(from: [.option]), UInt32(optionKey), "option should map to optionKey")
        assertEqual(HotkeyPreferences.carbonModifiers(from: [.control]), UInt32(controlKey), "control should map to controlKey")
        assertEqual(HotkeyPreferences.carbonModifiers(from: [.shift]), UInt32(shiftKey), "shift should map to shiftKey")

        let combined = HotkeyPreferences.carbonModifiers(from: [.command, .option, .control, .shift])
        assertEqual(
            combined,
            UInt32(cmdKey | optionKey | controlKey | shiftKey),
            "combined modifier flags should preserve every supported Carbon bit"
        )
    }

    runSuite("HotkeyPreferences renders display strings for common keys") {
        assertEqual(HotkeyPreferences.displayString(for: HotkeyBinding(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey))), "⌘A")
        assertEqual(HotkeyPreferences.keyName(for: UInt32(kVK_ANSI_7)), "7")
        assertEqual(HotkeyPreferences.keyName(for: UInt32(kVK_F5)), "F5")
        assertEqual(HotkeyPreferences.keyName(for: UInt32(kVK_LeftArrow)), "←")
        assertEqual(HotkeyPreferences.keyName(for: UInt32(kVK_ANSI_Slash)), "/")
        assertEqual(HotkeyPreferences.keyName(for: 999), "Key999")
    }
}
