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
