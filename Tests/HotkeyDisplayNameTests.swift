import Carbon
import Foundation

func testHotkeyDisplayName() {
    let functionKeys: [(code: UInt32, title: String)] = [
        (UInt32(kVK_F13), "F13"), (UInt32(kVK_F14), "F14"),
        (UInt32(kVK_F15), "F15"), (UInt32(kVK_F16), "F16"),
        (UInt32(kVK_F17), "F17"), (UInt32(kVK_F18), "F18"),
        (UInt32(kVK_F19), "F19"), (UInt32(kVK_F20), "F20"),
    ]
    let navigationKeys: [(code: UInt32, title: String)] = [
        (UInt32(kVK_Home), "Home"), (UInt32(kVK_End), "End"),
        (UInt32(kVK_PageUp), "Page Up"), (UInt32(kVK_PageDown), "Page Down"),
    ]

    runSuite("Extended function keys have readable names in both shortcut display paths") {
        for key in functionKeys {
            assertEqual(HotkeyPreferences.keyName(for: key.code), key.title)
            assertEqual(HotkeyPreferences.displayString(for: HotkeyBinding(keyCode: key.code, modifiers: 0)),
                        key.title)
            assertEqual(PhysicalDictationTriggerPreferences.displayString(for:
                PhysicalDictationTriggerBinding(keyCode: key.code)), key.title,
                "Settings uses the physical-binding display path")
        }
    }

    runSuite("Control navigation shortcuts show key names rather than numeric fallback labels") {
        for key in navigationKeys {
            assertEqual(HotkeyPreferences.keyName(for: key.code), key.title)
            assertEqual(HotkeyPreferences.displayString(for:
                HotkeyBinding(keyCode: key.code, modifiers: UInt32(controlKey))), "⌃" + key.title)
            assertEqual(PhysicalDictationTriggerPreferences.displayString(for:
                PhysicalDictationTriggerBinding(keyCode: key.code, modifiers: PhysicalDictationTriggerModifiers.control)),
                "⌃" + key.title)
        }
    }

    runSuite("Duplicate shortcut messages identify extended and navigation bindings by readable name") {
        let function = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_F20))
        assertEqual(PhysicalDictationTriggerPreferences.duplicateReason(
            for: function, otherShortcuts: [(name: "Meetings", binding: function)]
        ), "F20 is already used for Meetings. Choose a different key.")
        let navigation = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Home),
                                                        modifiers: PhysicalDictationTriggerModifiers.control)
        assertEqual(PhysicalDictationTriggerPreferences.duplicateReason(
            for: navigation, otherShortcuts: [(name: "Dictation key", binding: navigation)]
        ), "⌃Home is already used for Dictation key. Choose a different key.")
    }

    runSuite("Existing shortcut names modifiers and unknown-key fallback remain stable") {
        assertEqual(HotkeyPreferences.keyName(for: UInt32(kVK_F12)), "F12")
        assertEqual(HotkeyPreferences.keyName(for: UInt32(kVK_LeftArrow)), "←")
        assertEqual(PhysicalDictationTriggerPreferences.displayString(for:
            PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_ANSI_D),
                                            modifiers: PhysicalDictationTriggerModifiers.command | PhysicalDictationTriggerModifiers.option)),
            "⌥⌘D")
        assertEqual(HotkeyPreferences.keyName(for: 65_535), "Key65535")
        assertEqual(PhysicalDictationTriggerPreferences.displayString(for:
            PhysicalDictationTriggerBinding(keyCode: 65_535)), "Key65535")
    }
}
