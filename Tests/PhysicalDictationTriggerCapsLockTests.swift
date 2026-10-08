import Carbon
import CoreGraphics
import Foundation

// Caps Lock is a latched toggle, not a held modifier. With it on, every event
// tap flag set carries the capsLock bit, and the shortcuts must still fire.
func testPhysicalDictationTriggerCapsLock() {
    let option = PhysicalDictationTriggerModifiers.option
    let capsLock = PhysicalDictationTriggerModifiers.capsLock
    let rightOption = UInt32(kVK_RightOption)

    runSuite("The Right Option dictation key still presses and releases with Caps Lock on") {
        let binding = PhysicalDictationTriggerPreferences.defaultPushToTalkBinding
        let pressFlags = PhysicalDictationTriggerPreferences.modifiers(from: CGEventFlags([.maskAlternate, .maskAlphaShift]))
        let releaseFlags = PhysicalDictationTriggerPreferences.modifiers(from: CGEventFlags([.maskAlphaShift]))

        assertTrue(
            PhysicalDictationTriggerPreferences.matchesFlagsChangedPress(binding, keyCode: rightOption, modifiers: pressFlags),
            "Right Option down with Caps Lock latched should start dictation"
        )
        assertTrue(
            PhysicalDictationTriggerPreferences.matchesFlagsChangedRelease(binding, keyCode: rightOption, modifiers: releaseFlags),
            "Right Option up with Caps Lock latched should end the hold"
        )
        assertFalse(
            PhysicalDictationTriggerPreferences.matchesFlagsChangedPress(
                binding,
                keyCode: rightOption,
                modifiers: option | capsLock | PhysicalDictationTriggerModifiers.shift
            ),
            "a real extra modifier (Shift) still blocks the bare Right Option key"
        )
    }

    runSuite("A modifier chord recorded with Caps Lock on does not need Caps Lock to fire") {
        let recorded = PhysicalDictationTriggerPreferences.bindingForFlagsChanged(
            keyCode: rightOption,
            modifierFlags: [.option, .capsLock]
        )
        assertEqual(
            recorded,
            PhysicalDictationTriggerBinding(keyCode: rightOption),
            "recording Right Option while Caps Lock is on should save plain Right Option"
        )
    }

    runSuite("Option-M and other chord shortcuts still fire with Caps Lock on") {
        let meeting = PhysicalDictationTriggerPreferences.defaultMeetingBinding
        let flags = PhysicalDictationTriggerPreferences.modifiers(from: CGEventFlags([.maskAlternate, .maskAlphaShift]))

        assertTrue(
            PhysicalDictationTriggerPreferences.matchesKeyDown(meeting, keyCode: meeting.keyCode, modifiers: flags),
            "Option-M with Caps Lock latched should still start a meeting"
        )
        assertFalse(
            PhysicalDictationTriggerPreferences.matchesKeyDown(
                meeting,
                keyCode: meeting.keyCode,
                modifiers: option | capsLock | PhysicalDictationTriggerModifiers.command
            ),
            "a real extra modifier (Command) still keeps Option-M from matching"
        )

        let recorded = PhysicalDictationTriggerPreferences.bindingForKeyDown(
            keyCode: meeting.keyCode,
            modifierFlags: [.option, .capsLock]
        )
        assertEqual(recorded, meeting, "recording Option-M while Caps Lock is on should save plain Option-M")
        assertTrue(
            PhysicalDictationTriggerPreferences.matchesKeyDown(recorded, keyCode: meeting.keyCode, modifiers: option),
            "a chord recorded with Caps Lock on should fire after Caps Lock is turned off"
        )
    }

    runSuite("A key saved with the Caps Lock bit by an older build loads without it") {
        let suiteName = "PhysicalDictationTriggerCapsLockTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let leftOption = UInt32(kVK_Option)
        // Older builds recorded the latched Caps Lock bit with the key.
        PhysicalDictationTriggerPreferences.savePushToTalk(
            PhysicalDictationTriggerBinding(keyCode: leftOption, modifiers: capsLock),
            userDefaults: defaults
        )
        let loaded = PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: defaults)

        assertEqual(loaded, PhysicalDictationTriggerBinding(keyCode: leftOption), "the stored Caps Lock bit should be dropped on load")
        assertFalse(
            PhysicalDictationTriggerPreferences.matchesFlagsChangedPress(loaded, keyCode: UInt32(kVK_CapsLock), modifiers: option | capsLock),
            "pressing Caps Lock while holding Left Option must not count as the dictation key"
        )
        assertTrue(
            PhysicalDictationTriggerPreferences.matchesFlagsChangedPress(loaded, keyCode: leftOption, modifiers: option | capsLock),
            "Left Option itself still starts dictation with Caps Lock on"
        )
        assertFalse(
            PhysicalDictationTriggerPreferences.displayString(for: loaded).contains("Caps"),
            "Settings should not label the key with Caps"
        )

        PhysicalDictationTriggerPreferences.saveMeeting(
            PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_ANSI_M), modifiers: option | capsLock),
            userDefaults: defaults
        )
        assertEqual(
            PhysicalDictationTriggerPreferences.meetingBinding(userDefaults: defaults),
            PhysicalDictationTriggerPreferences.defaultMeetingBinding,
            "a stored Option-Caps-M loads as plain Option-M"
        )
    }
}
