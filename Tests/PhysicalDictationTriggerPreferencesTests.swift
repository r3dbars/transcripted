import AppKit
import Carbon
import CoreGraphics
import Foundation

func testPhysicalDictationTriggerPreferences() {
    runSuite("PhysicalDictationTriggerPreferences defaults to Fn, Right Option, Option-Shift-V, and Option M") {
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
            "fresh installs should use Right Option for hands-free"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.meetingBinding(userDefaults: defaults),
            PhysicalDictationTriggerPreferences.defaultMeetingBinding,
            "fresh installs should use Option M for meetings"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.pasteLastDictationBinding(userDefaults: defaults),
            PhysicalDictationTriggerPreferences.defaultPasteLastDictationBinding,
            "fresh installs should use Option Shift V for paste-last-dictation"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.defaultPushToTalkBinding),
            "Fn",
            "push-to-talk default should display as Fn"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.defaultHandsFreeBinding),
            "Right ⌥",
            "hands-free default should display as Right Option"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.defaultMeetingBinding),
            "⌥M",
            "meeting default should display as Option M"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.defaultPasteLastDictationBinding),
            "⌥⇧V",
            "paste-last-dictation default should display as Option Shift V"
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

    runSuite("PhysicalDictationTriggerPreferences persists paste-last-dictation shortcut") {
        let (defaults, suiteName) = makePhysicalTriggerDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let commandShiftP = PhysicalDictationTriggerBinding(
            keyCode: UInt32(kVK_ANSI_P),
            modifiers: PhysicalDictationTriggerModifiers.command | PhysicalDictationTriggerModifiers.shift
        )

        PhysicalDictationTriggerPreferences.savePasteLastDictation(commandShiftP, userDefaults: defaults)

        assertEqual(
            PhysicalDictationTriggerPreferences.pasteLastDictationBinding(userDefaults: defaults),
            commandShiftP,
            "paste-last-dictation should persist its own independent shortcut"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.displayString(for: commandShiftP),
            "⇧⌘P",
            "custom paste-last-dictation shortcuts should share the normal display formatter"
        )
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

        let capsLock = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_CapsLock))
        defaults.set(Int(capsLock.keyCode), forKey: "dictationTrigger-keyCode")
        defaults.set(Int(capsLock.modifiers), forKey: "dictationTrigger-modifiers")
        HotkeyPreferences.setDictationShortcutMode(.pushToTalk, userDefaults: defaults)

        assertEqual(
            PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: defaults),
            capsLock,
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

    runSuite("PhysicalDictationTriggerPreferences records Caps Lock without treating it as a held modifier") {
        let capsLock = PhysicalDictationTriggerPreferences.bindingForFlagsChanged(
            keyCode: UInt32(kVK_CapsLock),
            modifierFlags: [.capsLock]
        )

        assertEqual(capsLock, PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_CapsLock)), "Caps Lock should record as a physical key")
        assertTrue(
            PhysicalDictationTriggerPreferences.matchesFlagsChangedPress(
                PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_CapsLock)),
                keyCode: UInt32(kVK_CapsLock),
                modifiers: PhysicalDictationTriggerModifiers.capsLock
            ),
            "Caps Lock should match on the press flagsChanged event"
        )
        assertFalse(
            PhysicalDictationTriggerPreferences.matchesFlagsChangedRelease(
                PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_CapsLock)),
                keyCode: UInt32(kVK_CapsLock),
                modifiers: 0
            ),
            "Caps Lock release should not double-fire a modifier-only action"
        )
    }

    runSuite("PhysicalDictationTriggerPreferences converts event modifier masks consistently") {
        assertEqual(
            PhysicalDictationTriggerPreferences.modifiers(from: CGEventFlags([.maskCommand, .maskSecondaryFn, .maskAlphaShift])),
            PhysicalDictationTriggerModifiers.command
                | PhysicalDictationTriggerModifiers.function
                | PhysicalDictationTriggerModifiers.capsLock,
            "CGEvent flags should map into the physical-trigger mask"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.modifiers(
                fromCarbon: UInt32(cmdKey) | UInt32(optionKey) | UInt32(kEventKeyModifierFnMask)
            ),
            PhysicalDictationTriggerModifiers.command
                | PhysicalDictationTriggerModifiers.option
                | PhysicalDictationTriggerModifiers.function,
            "Carbon flags should map into the same physical-trigger mask"
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

    runSuite("PhysicalDictationTriggerPreferences reset writes all four modern bindings") {
        let (defaults, suiteName) = makePhysicalTriggerDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PhysicalDictationTriggerPreferences.savePushToTalk(
            PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_ANSI_A)),
            userDefaults: defaults
        )
        PhysicalDictationTriggerPreferences.saveHandsFree(
            PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_ANSI_B)),
            userDefaults: defaults
        )
        PhysicalDictationTriggerPreferences.saveMeeting(
            PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_ANSI_C)),
            userDefaults: defaults
        )
        PhysicalDictationTriggerPreferences.savePasteLastDictation(
            PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_ANSI_D)),
            userDefaults: defaults
        )

        PhysicalDictationTriggerPreferences.resetToDefaults(userDefaults: defaults)

        assertEqual(
            PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: defaults),
            PhysicalDictationTriggerPreferences.defaultPushToTalkBinding,
            "reset should restore push-to-talk"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.handsFreeBinding(userDefaults: defaults),
            PhysicalDictationTriggerPreferences.defaultHandsFreeBinding,
            "reset should restore hands-free"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.meetingBinding(userDefaults: defaults),
            PhysicalDictationTriggerPreferences.defaultMeetingBinding,
            "reset should restore meeting shortcut"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.pasteLastDictationBinding(userDefaults: defaults),
            PhysicalDictationTriggerPreferences.defaultPasteLastDictationBinding,
            "reset should restore paste-last-dictation shortcut"
        )
    }
}

private func makePhysicalTriggerDefaults() -> (UserDefaults, String) {
    let suiteName = "PhysicalDictationTriggerPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}
