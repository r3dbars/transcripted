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
            binding(.pasteLastDictation, keyCode: kVK_ANSI_V, modifiers: option | shift),
        ]

        let meeting = PhysicalShortcutMatcher.matchingKeyDownShortcut(
            shortcuts, keyCode: UInt32(kVK_ANSI_M), modifiers: option
        )
        assertTrue(meeting?.action == .meeting, "M+⌥ should resolve to the meeting binding")

        let paste = PhysicalShortcutMatcher.matchingKeyDownShortcut(
            shortcuts, keyCode: UInt32(kVK_ANSI_V), modifiers: option | shift
        )
        assertTrue(paste?.action == .pasteLastDictation, "V+⌥⇧ should resolve to paste-last-dictation")

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
}
