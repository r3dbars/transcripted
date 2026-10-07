import AppKit
import Carbon
import CoreGraphics
import Foundation

func testPhysicalDictationTriggerPreferences() {
    runSuite("PhysicalDictationTriggerPreferences defaults to Right Option and Option M") {
        let (defaults, suiteName) = makePhysicalTriggerDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        assertEqual(
            PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: defaults),
            PhysicalDictationTriggerPreferences.defaultPushToTalkBinding,
            "fresh installs should use Right Option for the dictation key"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.meetingBinding(userDefaults: defaults),
            PhysicalDictationTriggerPreferences.defaultMeetingBinding,
            "fresh installs should use Option M for meetings"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.defaultPushToTalkBinding),
            "Right ⌥",
            "the dictation key default should display as Right Option, not Fn (which opens emoji)"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.defaultMeetingBinding),
            "⌥M",
            "meeting default should display as Option M"
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

    runSuite("PhysicalDictationTriggerPreferences records an editor chord from keyDown") {
        let recorded = PhysicalDictationTriggerPreferences.bindingForKeyDown(
            keyCode: UInt32(kVK_ANSI_M),
            modifierFlags: [.option]
        )

        assertEqual(
            recorded,
            PhysicalDictationTriggerPreferences.defaultMeetingBinding,
            "shortcut editor input for Option-M should round-trip into the meeting default"
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

    runSuite("PhysicalDictationTriggerPreferences migrates the legacy single dictation shortcut when right Option is disabled") {
        let (defaults, suiteName) = makePhysicalTriggerDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        HotkeyPreferences.setRightOptionDictation(enabled: false, userDefaults: defaults)
        HotkeyPreferences.save(
            dictation: HotkeyBinding(keyCode: UInt32(kVK_Space), modifiers: UInt32(optionKey)),
            userDefaults: defaults
        )

        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(userDefaults: defaults)
        let migrated = PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: defaults)

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
        defaults.set("push_to_talk", forKey: "hotkey-dictation-shortcut-mode")

        assertEqual(
            PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: defaults),
            capsLock,
            "existing push-to-talk users should keep their saved physical key"
        )
        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(userDefaults: defaults)
        assertEqual(
            PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: defaults),
            capsLock,
            "the old hands-free slot held the default, so migration must not replace the saved key"
        )
        assertEqual(HotkeyPreferences.dictationKeyBehavior(userDefaults: defaults), .holdOrTap, "and the behavior stays Hold or tap")
    }

    runSuite("One dictation key: a custom hands-free key carries over as Tap to toggle") {
        let (defaults, suiteName) = makePhysicalTriggerDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let f5 = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_F5))
        seedLegacyHandsFree(f5, in: defaults)

        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(userDefaults: defaults)
        assertEqual(PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: defaults), f5, "their key becomes the dictation key")
        assertEqual(HotkeyPreferences.dictationKeyBehavior(userDefaults: defaults), .tapToToggle, "and it still toggles")

        PhysicalDictationTriggerPreferences.savePushToTalk(PhysicalDictationTriggerPreferences.defaultPushToTalkBinding, userDefaults: defaults)
        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(userDefaults: defaults)
        assertEqual(
            PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: defaults),
            PhysicalDictationTriggerPreferences.defaultPushToTalkBinding,
            "it runs once, so a later choice sticks"
        )
    }

    runSuite("One dictation key: defaults and a set hold key are left alone") {
        let (defaults, suiteName) = makePhysicalTriggerDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(userDefaults: defaults)
        assertEqual(
            PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: defaults),
            PhysicalDictationTriggerPreferences.defaultPushToTalkBinding,
            "a fresh install keeps Fn"
        )
        assertEqual(HotkeyPreferences.dictationKeyBehavior(userDefaults: defaults), .holdOrTap, "with Hold or tap")

        let (custom, customSuite) = makePhysicalTriggerDefaults()
        defer { custom.removePersistentDomain(forName: customSuite) }
        let capsLock = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_CapsLock))
        PhysicalDictationTriggerPreferences.savePushToTalk(capsLock, userDefaults: custom)
        seedLegacyHandsFree(PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_F5)), in: custom)
        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded(userDefaults: custom)
        assertEqual(PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: custom), capsLock, "a chosen hold key wins")
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

    runSuite("PhysicalDictationTriggerPreferences reset writes the modern bindings") {
        let (defaults, suiteName) = makePhysicalTriggerDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        PhysicalDictationTriggerPreferences.savePushToTalk(
            PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_ANSI_A)),
            userDefaults: defaults
        )
        PhysicalDictationTriggerPreferences.saveMeeting(
            PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_ANSI_C)),
            userDefaults: defaults
        )

        PhysicalDictationTriggerPreferences.resetToDefaults(userDefaults: defaults)

        assertEqual(
            PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: defaults),
            PhysicalDictationTriggerPreferences.defaultPushToTalkBinding,
            "reset should restore push-to-talk"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.meetingBinding(userDefaults: defaults),
            PhysicalDictationTriggerPreferences.defaultMeetingBinding,
            "reset should restore meeting shortcut"
        )
    }

    runSuite("PhysicalDictationTriggerPreferences rejects chords the event tap must never swallow") {
        let command = PhysicalDictationTriggerModifiers.command
        let shift = PhysicalDictationTriggerModifiers.shift
        let option = PhysicalDictationTriggerModifiers.option
        let control = PhysicalDictationTriggerModifiers.control

        let function = PhysicalDictationTriggerModifiers.function

        let rejected: [(String, PhysicalDictationTriggerBinding)] = [
            ("⌘V", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_ANSI_V), modifiers: command)),
            ("⇧⌘V", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_ANSI_V), modifiers: command | shift)),
            ("⌘C", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_ANSI_C), modifiers: command)),
            ("⌘Q", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_ANSI_Q), modifiers: command)),
            ("⌘Tab", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Tab), modifiers: command)),
            ("bare V", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_ANSI_V))),
            ("⇧V", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_ANSI_V), modifiers: shift)),
            ("bare Space", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Space))),
            // macOS reports arrow/navigation keys with the Fn flag already set,
            // so the plain "needs a modifier" rule would let these through.
            ("bare Left (implicit Fn)", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_LeftArrow), modifiers: function)),
            ("bare Left", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_LeftArrow))),
            ("⌘Left (line start)", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_LeftArrow), modifiers: command | function)),
            ("⌥Right (word jump)", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_RightArrow), modifiers: option | function)),
            ("⇧Down (select)", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_DownArrow), modifiers: shift | function)),
            ("bare Home", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Home), modifiers: function)),
            ("bare Forward Delete", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_ForwardDelete), modifiers: function)),
        ]
        for (name, binding) in rejected {
            assertNotNil(
                PhysicalDictationTriggerPreferences.rejectionReason(for: binding),
                "\(name) would hijack system input and must be rejected"
            )
        }

        let allowed: [(String, PhysicalDictationTriggerBinding)] = [
            ("default meeting ⌥M", PhysicalDictationTriggerPreferences.defaultMeetingBinding),
            ("default dictation key Right ⌥", PhysicalDictationTriggerPreferences.defaultPushToTalkBinding),
            ("Fn", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Function))),
            ("bare F5", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_F5))),
            ("⌥⌘V", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_ANSI_V), modifiers: command | option)),
            ("⌃V", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_ANSI_V), modifiers: control)),
            ("⌘D", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_ANSI_D), modifiers: command)),
            ("Caps Lock", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_CapsLock))),
            ("⌃Left", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_LeftArrow), modifiers: control | function)),
            ("⌘⌥Up", PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_UpArrow), modifiers: command | option | function)),
        ]
        for (name, binding) in allowed {
            assertNil(
                PhysicalDictationTriggerPreferences.rejectionReason(for: binding),
                "\(name) is a legitimate shortcut and must stay allowed"
            )
        }
    }

    runSuite("PhysicalDictationTriggerPreferences falls back to the default when the stored chord is unsafe") {
        let (defaults, suiteName) = makePhysicalTriggerDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Older builds let the recorder save these. Reading them back must not
        // hand the event tap a chord it would swallow system-wide, and Settings
        // must show the same binding the tap installs.
        PhysicalDictationTriggerPreferences.saveMeeting(
            PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_ANSI_M)),
            userDefaults: defaults
        )
        PhysicalDictationTriggerPreferences.savePushToTalk(
            PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_LeftArrow), modifiers: PhysicalDictationTriggerModifiers.function),
            userDefaults: defaults
        )

        assertEqual(
            PhysicalDictationTriggerPreferences.meetingBinding(userDefaults: defaults),
            PhysicalDictationTriggerPreferences.defaultMeetingBinding,
            "a stored bare-letter meeting chord must read back as the default"
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: defaults),
            PhysicalDictationTriggerPreferences.defaultPushToTalkBinding,
            "a stored bare arrow dictation chord must read back as the default"
        )

        PhysicalDictationTriggerPreferences.saveMeeting(
            PhysicalDictationTriggerBinding(
                keyCode: UInt32(kVK_ANSI_V),
                modifiers: PhysicalDictationTriggerModifiers.command | PhysicalDictationTriggerModifiers.option
            ),
            userDefaults: defaults
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.meetingBinding(userDefaults: defaults).modifiers,
            PhysicalDictationTriggerModifiers.command | PhysicalDictationTriggerModifiers.option,
            "a safe stored chord must read back unchanged"
        )
    }

    runSuite("PhysicalDictationTriggerPreferences refuses a key another shortcut already uses") {
        let others: [(name: String, binding: PhysicalDictationTriggerBinding)] = [
            (name: "Push to Talk", binding: PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Function))),
            (name: "Meetings", binding: PhysicalDictationTriggerPreferences.defaultMeetingBinding),
        ]

        let fnReason = PhysicalDictationTriggerPreferences.duplicateReason(
            for: PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Function)),
            otherShortcuts: others
        )
        assertEqual(fnReason, "Fn is already used for Push to Talk. Choose a different key.", "a shared modifier key should name the shortcut that has it")

        let optionM = PhysicalDictationTriggerBinding(
            keyCode: UInt32(kVK_ANSI_M),
            modifiers: PhysicalDictationTriggerModifiers.option | PhysicalDictationTriggerModifiers.capsLock
        )
        assertTrue(
            PhysicalDictationTriggerPreferences.duplicateReason(for: optionM, otherShortcuts: others)?.contains("Meetings") == true,
            "Caps Lock being on while recording should not hide a clash"
        )

        let optionShiftM = PhysicalDictationTriggerBinding(
            keyCode: UInt32(kVK_ANSI_M),
            modifiers: PhysicalDictationTriggerModifiers.option | PhysicalDictationTriggerModifiers.shift
        )
        assertNil(
            PhysicalDictationTriggerPreferences.duplicateReason(for: optionShiftM, otherShortcuts: others),
            "a different chord on the same letter is free"
        )
        assertNil(
            PhysicalDictationTriggerPreferences.duplicateReason(
                for: PhysicalDictationTriggerPreferences.defaultPushToTalkBinding,
                otherShortcuts: others
            ),
            "Right Option is free when no other shortcut uses it"
        )
        assertNil(
            PhysicalDictationTriggerPreferences.duplicateReason(
                for: PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Option)),
                otherShortcuts: [(name: "Dictation", binding: PhysicalDictationTriggerPreferences.defaultPushToTalkBinding)]
            ),
            "Left and Right Option are different keys"
        )
    }
}


private func makePhysicalTriggerDefaults() -> (UserDefaults, String) {
    let suiteName = "PhysicalDictationTriggerPreferencesTests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
}

/// Pre-one-key builds stored a separate Hands-Free key under these raw keys.
private func seedLegacyHandsFree(_ binding: PhysicalDictationTriggerBinding, in defaults: UserDefaults) {
    defaults.set(Int(binding.keyCode), forKey: "dictationHandsFreeTrigger-keyCode")
    defaults.set(Int(binding.modifiers), forKey: "dictationHandsFreeTrigger-modifiers")
}
