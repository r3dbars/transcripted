import AppKit
import Carbon
import CoreGraphics
import Foundation

func testPhysicalDictationTriggerPreferences() {
    runSuite("PhysicalDictationTriggerPreferences defaults to Fn, Fn Space, and Fn M") {
        let (defaults, suiteName) = makePhysicalTriggerDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(
            PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: defaults),
            PhysicalDictationTriggerPreferences.defaultPushToTalkBinding,
            "fresh installs should use Fn for push-to-talk"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.handsFreeBinding(userDefaults: defaults),
            PhysicalDictationTriggerPreferences.defaultHandsFreeBinding,
            "fresh installs should use Fn Space for hands-free"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.meetingBinding(userDefaults: defaults),
            PhysicalDictationTriggerPreferences.defaultMeetingBinding,
            "fresh installs should use Fn M for meetings"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.defaultPushToTalkBinding),
            "Fn",
            "push-to-talk default should display as Fn"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.defaultHandsFreeBinding),
            "Fn Space",
            "hands-free default should display as Fn Space"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.defaultMeetingBinding),
            "Fn M",
            "meeting default should display as Fn M"
        )
    }

    runSuite("PhysicalDictationTriggerPreferences persists explicit physical keys") {
        let (defaults, suiteName) = makePhysicalTriggerDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let fn = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Function))
        PhysicalDictationTriggerPreferences.save(fn, userDefaults: defaults)

        assertEqual(PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: defaults), fn, "Fn should persist as a bare physical key")
        assertEqual(PhysicalDictationTriggerPreferences.displayString(for: fn), "Fn", "Fn should have a readable display name")
    }

    runSuite("PhysicalDictationTriggerPreferences decodes macOS Fn actions") {
        assertEqual(
            PhysicalDictationTriggerPreferences.functionKeySystemAction(rawValue: nil),
            .notConfigured,
            "missing AppleFnUsageType should be treated as not configured"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.functionKeySystemAction(rawValue: 0),
            .doNothing,
            "AppleFnUsageType 0 should mean Do Nothing"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.functionKeySystemAction(rawValue: 1),
            .changeInputSource,
            "AppleFnUsageType 1 should mean Change Input Source"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.functionKeySystemAction(rawValue: 2),
            .showEmojiAndSymbols,
            "AppleFnUsageType 2 should mean Emoji & Symbols"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.functionKeySystemAction(rawValue: 3),
            .startDictation,
            "AppleFnUsageType 3 should mean Start Dictation"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.functionKeySystemAction(rawValue: 99),
            .unknown(99),
            "unknown values should still be preserved for diagnostics"
        )
    }

    runSuite("PhysicalDictationTriggerPreferences warns when bare Fn conflicts with macOS") {
        let fn = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Function))
        let fnSpace = PhysicalDictationTriggerBinding(
            keyCode: UInt32(kVK_Space),
            modifiers: PhysicalDictationTriggerModifiers.function
        )
        let rightOption = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_RightOption))

        assertNil(
            PhysicalDictationTriggerPreferences.functionKeyConflictWarning(
                for: fn,
                systemAction: .doNothing
            ),
            "bare Fn should be safe when macOS leaves Fn alone"
        )
        assertNotNil(
            PhysicalDictationTriggerPreferences.functionKeyConflictWarning(
                for: fn,
                systemAction: .showEmojiAndSymbols
            ),
            "bare Fn should warn when macOS opens emoji with the same key"
        )
        assertNil(
            PhysicalDictationTriggerPreferences.functionKeyConflictWarning(
                for: fnSpace,
                systemAction: .showEmojiAndSymbols
            ),
            "Fn chords should not warn like bare Fn"
        )
        assertNil(
            PhysicalDictationTriggerPreferences.functionKeyConflictWarning(
                for: rightOption,
                systemAction: .showEmojiAndSymbols
            ),
            "non-Fn physical triggers should not warn about Fn settings"
        )
    }

    runSuite("PhysicalDictationTriggerPreferences migrates legacy hands-free shortcut when right Option is disabled") {
        let (defaults, suiteName) = makePhysicalTriggerDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        HotkeyPreferences.setRightOptionDictation(enabled: false, userDefaults: defaults)
        HotkeyPreferences.save(
            dictation: HotkeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)),
            userDefaults: defaults
        )

        let migrated = PhysicalDictationTriggerPreferences.handsFreeBinding(userDefaults: defaults)

        assertEqual(migrated.keyCode, UInt32(kVK_Space), "disabled right Option should fall back to the old dictation shortcut key")
        assertEqual(
            migrated.modifiers,
            PhysicalDictationTriggerModifiers.option,
            "legacy Carbon Option should migrate to the physical trigger modifier mask"
        )
    }

    runSuite("PhysicalDictationTriggerPreferences preserves legacy push-to-talk physical shortcut") {
        let (defaults, suiteName) = makePhysicalTriggerDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let rightOption = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_RightOption))
        defaults.set(Int(rightOption.keyCode), forKey: "dictationTrigger-keyCode")
        defaults.set(Int(rightOption.modifiers), forKey: "dictationTrigger-modifiers")
        HotkeyPreferences.setDictationShortcutMode(.pushToTalk, userDefaults: defaults)

        assertEqual(
            PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: defaults),
            rightOption,
            "existing push-to-talk users should keep their saved physical key"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.handsFreeBinding(userDefaults: defaults),
            PhysicalDictationTriggerPreferences.defaultHandsFreeBinding,
            "hands-free should move to the new default when the saved key belonged to push-to-talk"
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
