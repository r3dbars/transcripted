import AppKit
import Carbon
import CoreGraphics
import Foundation

func testPhysicalDictationTriggerPreferences() {
    runSuite("PhysicalDictationTriggerPreferences defaults to right Option") {
        let (defaults, suiteName) = makePhysicalTriggerDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(
            PhysicalDictationTriggerPreferences.binding(userDefaults: defaults),
            PhysicalDictationTriggerPreferences.defaultBinding,
            "fresh installs should keep the existing right Option dictation trigger"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.defaultBinding),
            "Right ⌥",
            "default trigger should display as right Option"
        )
    }

    runSuite("PhysicalDictationTriggerPreferences persists explicit physical keys") {
        let (defaults, suiteName) = makePhysicalTriggerDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fn = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Function))
        PhysicalDictationTriggerPreferences.save(fn, userDefaults: defaults)

        assertEqual(PhysicalDictationTriggerPreferences.binding(userDefaults: defaults), fn, "Fn should persist as a bare physical key")
        assertEqual(PhysicalDictationTriggerPreferences.displayString(for: fn), "Fn", "Fn should have a readable display name")
    }

    runSuite("PhysicalDictationTriggerPreferences migrates legacy shortcut when right Option is disabled") {
        let (defaults, suiteName) = makePhysicalTriggerDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        HotkeyPreferences.setRightOptionDictation(enabled: false, userDefaults: defaults)
        HotkeyPreferences.save(
            dictation: HotkeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)),
            userDefaults: defaults
        )

        let migrated = PhysicalDictationTriggerPreferences.binding(userDefaults: defaults)

        assertEqual(migrated.keyCode, UInt32(kVK_Space), "disabled right Option should fall back to the old dictation shortcut key")
        assertEqual(
            migrated.modifiers,
            PhysicalDictationTriggerModifiers.option,
            "legacy Carbon Option should migrate to the physical trigger modifier mask"
        )
    }

    runSuite("PhysicalDictationTriggerPreferences records modifier-only keys from flagsChanged") {
        let fn = PhysicalDictationTriggerPreferences.bindingForFlagsChanged(
            keyCode: UInt32(kVK_Function),
            modifierFlags: [.function]
        )
        let rightCommandWithShift = PhysicalDictationTriggerPreferences.bindingForFlagsChanged(
            keyCode: UInt32(kVK_RightCommand),
            modifierFlags: [.command, .shift]
        )

        assertEqual(fn, PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Function)), "bare Fn press should record as a physical key")
        assertEqual(
            rightCommandWithShift,
            PhysicalDictationTriggerBinding(
                keyCode: UInt32(kVK_RightCommand),
                modifiers: PhysicalDictationTriggerModifiers.shift
            ),
            "modifier chords should keep the already-held modifiers"
        )
    }

    runSuite("PhysicalDictationTriggerPreferences matches keyDown and flagsChanged triggers") {
        let bareA = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_ANSI_A))
        let fnSpace = PhysicalDictationTriggerBinding(
            keyCode: UInt32(kVK_Space),
            modifiers: PhysicalDictationTriggerModifiers.function
        )
        let rightShift = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_RightShift))
        let rightCommandShift = PhysicalDictationTriggerBinding(
            keyCode: UInt32(kVK_RightCommand),
            modifiers: PhysicalDictationTriggerModifiers.shift
        )

        assertTrue(
            PhysicalDictationTriggerPreferences.matchesKeyDown(bareA, keyCode: UInt32(kVK_ANSI_A), modifiers: 0),
            "bare normal keys should be valid dictation triggers"
        )
        assertFalse(
            PhysicalDictationTriggerPreferences.matchesKeyDown(bareA, keyCode: UInt32(kVK_ANSI_A), modifiers: PhysicalDictationTriggerModifiers.shift),
            "extra modifiers should not accidentally fire a bare-key trigger"
        )
        assertTrue(
            PhysicalDictationTriggerPreferences.matchesKeyDown(fnSpace, keyCode: UInt32(kVK_Space), modifiers: PhysicalDictationTriggerModifiers.function),
            "Fn+Space should match as a trigger chord"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.displayString(for: fnSpace),
            "Fn Space",
            "Fn chords should display with a readable separator"
        )
        assertTrue(
            PhysicalDictationTriggerPreferences.matchesFlagsChangedPress(
                rightShift,
                keyCode: UInt32(kVK_RightShift),
                modifiers: PhysicalDictationTriggerModifiers.shift
            ),
            "right Shift press should match as a modifier-only trigger"
        )
        assertTrue(
            PhysicalDictationTriggerPreferences.matchesFlagsChangedRelease(
                rightShift,
                keyCode: UInt32(kVK_RightShift),
                modifiers: 0
            ),
            "right Shift release should reset the trigger"
        )
        assertTrue(
            PhysicalDictationTriggerPreferences.matchesFlagsChangedPress(
                rightCommandShift,
                keyCode: UInt32(kVK_RightCommand),
                modifiers: PhysicalDictationTriggerModifiers.command | PhysicalDictationTriggerModifiers.shift
            ),
            "modifier chords should match when the selected physical modifier is pressed last"
        )
        assertTrue(
            PhysicalDictationTriggerPreferences.matchesFlagsChangedPress(
                rightCommandShift,
                keyCode: UInt32(kVK_Shift),
                modifiers: PhysicalDictationTriggerModifiers.command | PhysicalDictationTriggerModifiers.shift
            ),
            "modifier chords should also match when a secondary modifier completes the chord"
        )
        assertTrue(
            PhysicalDictationTriggerPreferences.matchesFlagsChangedRelease(
                rightCommandShift,
                keyCode: UInt32(kVK_Shift),
                modifiers: PhysicalDictationTriggerModifiers.command
            ),
            "modifier chords should reset when a secondary modifier is released"
        )
    }
}

private func makePhysicalTriggerDefaults() -> (UserDefaults, String) {
    let suiteName = "PhysicalDictationTriggerPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
