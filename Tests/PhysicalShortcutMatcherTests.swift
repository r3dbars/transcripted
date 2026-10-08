// PhysicalShortcutMatcherTests.swift
// Pins the chord-resolution precedence the capture engine relies on:
// keyed key-down exactness, modifier-press exact-then-fallback selection,
// release detection, and shared-modifier chord guarding. The stateful
// debounce + CGEventTap wiring stays in ContextCaptureEngine; this only
// exercises the deterministic binding-selection helpers.

import Carbon
import Foundation

private func binding(
    _ action: PhysicalShortcutAction,
    keyCode: Int,
    modifiers: UInt32 = 0
) -> PhysicalShortcutBinding {
    PhysicalShortcutBinding(
        action: action,
        binding: PhysicalDictationTriggerBinding(keyCode: UInt32(keyCode), modifiers: modifiers)
    )
}

func testPhysicalShortcutMatcher() {
    let option = PhysicalDictationTriggerModifiers.option
    let shift = PhysicalDictationTriggerModifiers.shift
    let function = PhysicalDictationTriggerModifiers.function

    runSuite("PhysicalShortcutMatcher — keyed key-down matches exactly") {
        let shortcuts = [
            binding(.dictationPushToTalk, keyCode: kVK_Function),
            binding(.dictationHandsFree, keyCode: kVK_RightOption),
            binding(.meeting, keyCode: kVK_ANSI_M, modifiers: option),
        ]

        let meeting = PhysicalShortcutMatcher.matchingKeyDownShortcut(
            shortcuts, keyCode: UInt32(kVK_ANSI_M), modifiers: option
        )
        assertTrue(meeting?.action == .meeting, "M+⌥ should resolve to the meeting binding")

        // Extra modifiers break the exact match — a key-down chord is precise.
        let withExtra = PhysicalShortcutMatcher.matchingKeyDownShortcut(
            shortcuts,
            keyCode: UInt32(kVK_ANSI_M),
            modifiers: option | PhysicalDictationTriggerModifiers.command
        )
        assertTrue(withExtra == nil, "M+⌥⌘ must not match the bare M+⌥ meeting binding")

        // Modifier-only bindings never fire on key-down events.
        let fnAsKeyDown = PhysicalShortcutMatcher.matchingKeyDownShortcut(
            shortcuts, keyCode: UInt32(kVK_Function), modifiers: function
        )
        assertTrue(fnAsKeyDown == nil, "modifier-only Fn binding must not match a key-down event")
    }

    runSuite("PhysicalShortcutMatcher — modifier press prefers the exact key") {
        let shortcuts = [
            binding(.dictationPushToTalk, keyCode: kVK_Function),
            binding(.dictationHandsFree, keyCode: kVK_RightOption),
        ]

        let handsFree = PhysicalShortcutMatcher.matchingFlagsChangedPressShortcut(
            shortcuts, keyCode: UInt32(kVK_RightOption), modifiers: option
        )
        assertTrue(handsFree?.action == .dictationHandsFree, "right ⌥ press resolves to hands-free")

        let pushToTalk = PhysicalShortcutMatcher.matchingFlagsChangedPressShortcut(
            shortcuts, keyCode: UInt32(kVK_Function), modifiers: function
        )
        assertTrue(pushToTalk?.action == .dictationPushToTalk, "Fn press resolves to push-to-talk")
    }

    runSuite("PhysicalShortcutMatcher — modifier press falls back to a chord owner") {
        // Fn+⌥ chord and a bare right-⌥ binding. Pressing right ⌥ while Fn is
        // already held should NOT fire bare hands-free (its exact match needs no
        // extra modifier) and should instead fall back to the Fn+⌥ chord owner.
        let shortcuts = [
            binding(.dictationPushToTalk, keyCode: kVK_Function, modifiers: option),
            binding(.dictationHandsFree, keyCode: kVK_RightOption),
        ]

        let resolved = PhysicalShortcutMatcher.matchingFlagsChangedPressShortcut(
            shortcuts,
            keyCode: UInt32(kVK_RightOption),
            modifiers: function | option
        )
        assertTrue(resolved?.action == .dictationPushToTalk, "Fn+⌥ chord owns the right-⌥ event when Fn is held")
    }

    runSuite("PhysicalShortcutMatcher — release detection") {
        let shortcuts = [binding(.dictationHandsFree, keyCode: kVK_RightOption)]

        let released = PhysicalShortcutMatcher.matchesRelease(
            for: .dictationHandsFree, in: shortcuts, keyCode: UInt32(kVK_RightOption), modifiers: 0
        )
        assertTrue(released, "dropping ⌥ with no modifiers left is a release")

        let stillHeld = PhysicalShortcutMatcher.matchesRelease(
            for: .dictationHandsFree, in: shortcuts, keyCode: UInt32(kVK_RightOption), modifiers: option
        )
        assertTrue(!stillHeld, "⌥ still active is not a release")

        let unknownAction = PhysicalShortcutMatcher.matchesRelease(
            for: .meeting, in: shortcuts, keyCode: UInt32(kVK_RightOption), modifiers: 0
        )
        assertTrue(!unknownAction, "release for an unconfigured action is false")
    }

    runSuite("PhysicalShortcutMatcher — shared-modifier chord guard") {
        let shortcuts = [
            binding(.meeting, keyCode: kVK_ANSI_M, modifiers: option),
            binding(.dictationHandsFree, keyCode: kVK_RightOption),
        ]

        // Releasing right ⌥ must not fire hands-free while a keyed chord (⌥+M)
        // also depends on the option modifier.
        let blocked = PhysicalShortcutMatcher.hasChordUsingModifier(
            UInt32(kVK_RightOption), in: shortcuts, excluding: .dictationHandsFree
        )
        assertTrue(blocked, "⌥+M chord should guard the right-⌥ hands-free release")

        // Excluding the chord owner itself removes the guard.
        let unguarded = PhysicalShortcutMatcher.hasChordUsingModifier(
            UInt32(kVK_RightOption), in: shortcuts, excluding: .meeting
        )
        assertTrue(!unguarded, "with the ⌥ chord excluded there is nothing left to guard")

        // A non-modifier key has no primary modifier mask, so nothing to guard.
        let nonModifier = PhysicalShortcutMatcher.hasChordUsingModifier(
            UInt32(kVK_ANSI_M), in: shortcuts, excluding: .meeting
        )
        assertTrue(!nonModifier, "a typing key has no shared-modifier chord to guard")
    }

    runSuite("PhysicalShortcutMatcher — tap re-enable synthesizes missed push-to-talk release only when key is up") {
        let activeKey = UInt32(kVK_Function)

        assertFalse(
            PhysicalShortcutMatcher.shouldSynthesizePushToTalkRelease(
                activeKeyCode: nil,
                isPhysicallyDown: { _ in false }
            ),
            "no active push-to-talk key means there is no release to synthesize"
        )
        assertFalse(
            PhysicalShortcutMatcher.shouldSynthesizePushToTalkRelease(
                activeKeyCode: activeKey,
                isPhysicallyDown: { _ in true }
            ),
            "a still-held push-to-talk key must keep recording after tap re-enable"
        )
        assertTrue(
            PhysicalShortcutMatcher.shouldSynthesizePushToTalkRelease(
                activeKeyCode: activeKey,
                isPhysicallyDown: { _ in false }
            ),
            "a released push-to-talk key must synthesize release if macOS dropped keyUp while the tap was disabled"
        )
    }

    runSuite("PhysicalShortcutMatcher — delayed modifier press requires current ownership and a held key") {
        let current = DelayedModifierShortcutPress(
            generation: 2,
            keyCode: UInt32(kVK_RightOption),
            action: .dictationPushToTalk
        )
        let stale = DelayedModifierShortcutPress(
            generation: 1,
            keyCode: UInt32(kVK_RightOption),
            action: .dictationPushToTalk
        )

        assertTrue(
            PhysicalShortcutMatcher.shouldActivateDelayedModifierPress(
                current: current,
                expected: current,
                isPhysicallyDown: true
            ),
            "the current delayed press may activate while its modifier is still held"
        )
        assertFalse(
            PhysicalShortcutMatcher.shouldActivateDelayedModifierPress(
                current: current,
                expected: stale,
                isPhysicallyDown: true
            ),
            "a cancelled or superseded work item must not consume the current pending press"
        )
        assertFalse(
            PhysicalShortcutMatcher.shouldActivateDelayedModifierPress(
                current: current,
                expected: current,
                isPhysicallyDown: false
            ),
            "a modifier released at the debounce deadline must not start push-to-talk"
        )
        let physicallyDownKeyCodes: Set<UInt32> = [UInt32(kVK_Option)]
        assertFalse(
            PhysicalShortcutMatcher.shouldActivateDelayedModifierPress(
                current: current,
                expected: current,
                isPhysicallyDown: physicallyDownKeyCodes.contains(current.keyCode)
            ),
            "left Option staying down must not activate a released right-side bound key"
        )
    }

    runSuite("PhysicalShortcutMatcher — shared hands-free modifier fires on press unless mid-typing") {
        assertTrue(
            PhysicalShortcutMatcher.firesSharedModifierOnPress(secondsSinceLastTypedKey: 30, isDictating: false),
            "a Right Option tap after a pause starts on press, not on release"
        )
        assertTrue(
            PhysicalShortcutMatcher.firesSharedModifierOnPress(secondsSinceLastTypedKey: .infinity, isDictating: false),
            "nothing typed since launch"
        )
        assertTrue(
            PhysicalShortcutMatcher.firesSharedModifierOnPress(
                secondsSinceLastTypedKey: PhysicalShortcutMatcher.typingWindowForModifierCombos,
                isDictating: false
            ),
            "the window edge counts as a pause"
        )
        assertFalse(
            PhysicalShortcutMatcher.firesSharedModifierOnPress(secondsSinceLastTypedKey: 0.2, isDictating: false),
            "mid-typing, Right Option is likely a combo like Option+E, so it waits for release"
        )
        assertFalse(
            PhysicalShortcutMatcher.firesSharedModifierOnPress(secondsSinceLastTypedKey: 30, isDictating: true),
            "a press during a dictation stops and pastes it, which a combo can't undo, so it waits for release"
        )
    }

    // The detector's session tap consumes the Right Option flagsChanged
    // event, so the OS key state never sees Option go down. These feed the
    // tracker only the events the tap sees, the way the tap does, with no
    // physical-key lookup to lean on.
    let rightOption = UInt32(kVK_RightOption)
    let leftOption = UInt32(kVK_Option)
    let rightShift = UInt32(kVK_RightShift)

    runSuite("Right Option then M while it's held drops the dictation the press started") {
        var tracker = HandsFreeModifierComboTracker()
        tracker.firedOnPress(keyCode: rightOption, sharesModifier: true)
        assertTrue(tracker.keyDown(), "Option+M must report a combo so the stray dictation is dropped")
    }

    runSuite("Right Option then E or an arrow while it's held drops the dictation the press started") {
        var accent = HandsFreeModifierComboTracker()
        accent.firedOnPress(keyCode: rightOption, sharesModifier: true)
        assertTrue(accent.keyDown(), "typing é with Option+E must report a combo")

        var arrow = HandsFreeModifierComboTracker()
        arrow.firedOnPress(keyCode: rightOption, sharesModifier: true)
        assertTrue(arrow.keyDown(), "Option+arrow must report a combo")
    }

    runSuite("Holding Right Option alone and letting go keeps the dictation") {
        var tracker = HandsFreeModifierComboTracker()
        tracker.firedOnPress(keyCode: rightOption, sharesModifier: true)
        assertTrue(
            tracker.flagsChanged(keyCode: rightOption, modifiers: 0, isHandsFreeRelease: true),
            "the key's own release ends the press and is the tap's to consume"
        )
        assertFalse(tracker.keyDown(), "typing after the key is back up is dictation, not a combo")
    }

    runSuite("A combo drops the dictation once, not on every later key") {
        var tracker = HandsFreeModifierComboTracker()
        tracker.firedOnPress(keyCode: rightOption, sharesModifier: true)
        assertTrue(tracker.keyDown(), "the first key makes the press a combo")
        assertFalse(tracker.keyDown(), "a second key while still held has nothing left to drop")
        assertFalse(
            tracker.flagsChanged(keyCode: rightOption, modifiers: 0, isHandsFreeRelease: true),
            "the release after a combo isn't a tracked release anymore"
        )
    }

    runSuite("Adding Shift under Right Option still lets the next key make a combo") {
        var tracker = HandsFreeModifierComboTracker()
        tracker.firedOnPress(keyCode: rightOption, sharesModifier: true)
        assertFalse(
            tracker.flagsChanged(
                keyCode: rightShift,
                modifiers: PhysicalDictationTriggerModifiers.option | PhysicalDictationTriggerModifiers.shift,
                isHandsFreeRelease: false
            ),
            "Shift going down isn't Option's release"
        )
        assertTrue(tracker.keyDown(), "Option+Shift+V is still a combo")
    }

    runSuite("Right Option let go under a held Left Option doesn't drop a later dictation") {
        var tracker = HandsFreeModifierComboTracker()
        tracker.firedOnPress(keyCode: rightOption, sharesModifier: true)
        // Right Option comes up but Left Option keeps the option flag set,
        // so this isn't the binding's release.
        _ = tracker.flagsChanged(
            keyCode: rightOption,
            modifiers: PhysicalDictationTriggerModifiers.option,
            isHandsFreeRelease: false
        )
        _ = tracker.flagsChanged(keyCode: leftOption, modifiers: 0, isHandsFreeRelease: false)
        assertFalse(tracker.keyDown(), "once no Option key is down, a later key is not a combo")
    }

    runSuite("A hands-free key no other shortcut shares never drops its dictation") {
        var tracker = HandsFreeModifierComboTracker()
        tracker.firedOnPress(keyCode: rightOption, sharesModifier: false)
        assertFalse(tracker.keyDown(), "with no Option chord bound, Right Option plus a key is just dictation plus typing")
    }

    runSuite("Push to Talk: a combo key right after Right Option drops the start") {
        var window = PushToTalkModifierComboWindow()
        window.firedOnPress(keyCode: rightOption, at: 100, window: 0.14)
        assertTrue(window.keyDown(at: 100.05), "Option+M inside the chord window is a combo, not a hold")
        assertFalse(window.keyDown(at: 100.06), "it reports once per press")
    }

    runSuite("Push to Talk: a key later in a hold never drops the take") {
        var window = PushToTalkModifierComboWindow()
        window.firedOnPress(keyCode: rightOption, at: 100, window: 0.14)
        assertFalse(window.keyDown(at: 160), "Esc, an arrow or Return a minute into a hold is typing, not a combo")
        assertFalse(window.keyDown(at: 160.01), "and nothing after it is either")
    }

    runSuite("Push to Talk: after the key is let go, typing is not a combo") {
        var window = PushToTalkModifierComboWindow()
        window.firedOnPress(keyCode: rightOption, at: 100, window: 0.14)
        window.flagsChanged(keyCode: rightOption, modifiers: 0, isPushToTalkRelease: true)
        assertFalse(window.keyDown(at: 100.05), "a quick tap then a key is a tap plus typing")
    }

    runSuite("Push to Talk: a key after the event tap was disabled doesn't drop the take") {
        var window = PushToTalkModifierComboWindow()
        window.firedOnPress(keyCode: rightOption, at: 100, window: 0.14)
        window.reset()
        assertFalse(window.keyDown(at: 100.05), "the release may have been missed while the tap was off")
    }

    runSuite("A key after the event tap was disabled doesn't drop the dictation") {
        var tracker = HandsFreeModifierComboTracker()
        tracker.firedOnPress(keyCode: rightOption, sharesModifier: true)
        tracker.reset()
        assertFalse(tracker.keyDown(), "the release may have been missed while the tap was off")
    }
}
