// PhysicalShortcutMatcher.swift
// Pure chord-resolution matchers extracted from ContextCaptureEngine's
// PhysicalShortcutDetector. These pick which configured shortcut binding a key
// event belongs to, applying the same exact-then-fallback precedence the
// detector relied on. Kept Foundation-pure (delegating only to the already
// fast-tested PhysicalDictationTriggerPreferences matchers) so the chord
// precedence can be pinned by tests without the Carbon/CGEventTap engine.
//
// The stateful per-action debounce and the CGEventTap wiring stay in
// ContextCaptureEngine; only the deterministic binding-selection logic lives
// here.

import Foundation

enum PhysicalShortcutAction: Equatable {
    case dictationPushToTalk
    case dictationHandsFree
    case meeting
    case pasteLastDictation
}

struct PhysicalShortcutBinding {
    let action: PhysicalShortcutAction
    let binding: PhysicalDictationTriggerBinding
}

struct DelayedModifierShortcutPress: Equatable {
    let generation: UInt64
    let keyCode: UInt32
    let action: PhysicalShortcutAction
}

/// Follows a hands-free modifier that fired on press while other shortcuts
/// share it (Right Option vs Option+M) until it's let go, so a key that goes
/// down in between turns that press into a combo and its dictation is dropped.
///
/// It trusts the event stream alone. The detector's session tap consumes the
/// modifier's own flagsChanged event, so the session key state
/// (`CGEventSource.keyState(.combinedSessionState, ...)`) never sees it go
/// down. Gating on that check left every Option+M, Option+E, and
/// Option+arrow with a stray dictation running.
struct HandsFreeModifierComboTracker {
    private var heldKeyCode: UInt32?

    /// A hands-free modifier fired on press. Only one other shortcuts also
    /// use can turn out to be a combo.
    mutating func firedOnPress(keyCode: UInt32, sharesModifier: Bool) {
        heldKeyCode = sharesModifier ? keyCode : nil
    }

    /// A non-modifier key went down. True when that makes the held press a
    /// combo. It reports once per press.
    mutating func keyDown() -> Bool {
        guard heldKeyCode != nil else { return false }
        heldKeyCode = nil
        return true
    }

    /// A modifier changed. `isHandsFreeRelease` says whether the event
    /// matches the hands-free binding's release. Returns true when it was the
    /// tracked key's own release, which the tap consumes. Tracking also ends
    /// once no modifier of that kind is left down (Right Option let go under
    /// a held Left Option, then Left Option let go).
    mutating func flagsChanged(keyCode: UInt32, modifiers: UInt32, isHandsFreeRelease: Bool) -> Bool {
        guard let heldKeyCode else { return false }
        if heldKeyCode == keyCode, isHandsFreeRelease {
            self.heldKeyCode = nil
            return true
        }
        if let mask = PhysicalDictationTriggerPreferences.primaryModifierMask(for: heldKeyCode),
           modifiers & mask == 0 {
            self.heldKeyCode = nil
        }
        return false
    }

    /// The tap was off, so the release may have been missed.
    mutating func reset() {
        heldKeyCode = nil
    }
}

enum PhysicalShortcutMatcher {
    /// A typed key this recent means the user is mid-typing, where a
    /// hands-free modifier press is likely the start of a combo (typing é
    /// with Option+E) rather than a dictation tap.
    static let typingWindowForModifierCombos: TimeInterval = 1.0

    /// Whether a hands-free modifier that other shortcuts also use in combos
    /// (Right Option vs Option+M) fires on press instead of on release.
    /// Waiting for release costs the whole time the key is held, so a start
    /// fires on press unless a key was typed just before. If a combo key does
    /// follow while it's held, the detector reports `.comboInterrupted` and
    /// the just-started dictation is dropped quietly.
    ///
    /// A press during a dictation stops and pastes it, which a combo can't
    /// undo, so that one still waits for release.
    static func firesSharedModifierOnPress(
        secondsSinceLastTypedKey: TimeInterval,
        isDictating: Bool
    ) -> Bool {
        !isDictating && secondsSinceLastTypedKey >= typingWindowForModifierCombos
    }

    static func shouldActivateDelayedModifierPress(
        current: DelayedModifierShortcutPress?,
        expected: DelayedModifierShortcutPress,
        isPhysicallyDown: Bool
    ) -> Bool {
        current == expected && isPhysicallyDown
    }

    static func shouldSynthesizePushToTalkRelease(
        activeKeyCode: UInt32?,
        isPhysicallyDown: (UInt32) -> Bool
    ) -> Bool {
        guard let activeKeyCode else { return false }
        return !isPhysicallyDown(activeKeyCode)
    }

    static func matchingKeyDownShortcut(
        _ shortcuts: [PhysicalShortcutBinding],
        keyCode: UInt32,
        modifiers: UInt32
    ) -> PhysicalShortcutBinding? {
        shortcuts.first {
            PhysicalDictationTriggerPreferences.matchesKeyDown($0.binding, keyCode: keyCode, modifiers: modifiers)
        }
    }

    static func matchingFlagsChangedPressShortcut(
        _ shortcuts: [PhysicalShortcutBinding],
        keyCode: UInt32,
        modifiers: UInt32
    ) -> PhysicalShortcutBinding? {
        if let exact = shortcuts.first(where: {
            $0.binding.keyCode == keyCode
                && PhysicalDictationTriggerPreferences.matchesFlagsChangedPress($0.binding, keyCode: keyCode, modifiers: modifiers)
        }) {
            return exact
        }

        return shortcuts.first {
            PhysicalDictationTriggerPreferences.matchesFlagsChangedPress($0.binding, keyCode: keyCode, modifiers: modifiers)
        }
    }

    static func matchesRelease(
        for action: PhysicalShortcutAction,
        in shortcuts: [PhysicalShortcutBinding],
        keyCode: UInt32,
        modifiers: UInt32
    ) -> Bool {
        guard let shortcut = shortcuts.first(where: { $0.action == action }) else { return false }
        return PhysicalDictationTriggerPreferences.matchesFlagsChangedRelease(
            shortcut.binding,
            keyCode: keyCode,
            modifiers: modifiers
        )
    }

    static func hasChordUsingModifier(
        _ keyCode: UInt32,
        in shortcuts: [PhysicalShortcutBinding],
        excluding action: PhysicalShortcutAction
    ) -> Bool {
        guard let modifier = PhysicalDictationTriggerPreferences.primaryModifierMask(for: keyCode) else {
            return false
        }

        return shortcuts.contains {
            $0.action != action
                && !PhysicalDictationTriggerPreferences.isModifierKey($0.binding.keyCode)
                && ($0.binding.modifiers & modifier) != 0
        }
    }
}
