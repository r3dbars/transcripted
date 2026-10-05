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

/// Times a held Push to Talk key so its release can say tap or hold
/// (`DictationHoldKeyTapPolicy`). Fed from the detector's tap thread, so a
/// busy main actor can't stretch a tap into a hold or shrink a hold to a tap.
struct PushToTalkTapTracker {
    private var pressUptime: TimeInterval = 0
    private var otherKeyPressed = false

    mutating func pressed(at uptime: TimeInterval) {
        pressUptime = uptime
        otherKeyPressed = false
    }

    /// Another key or modifier went down while it was held (Fn+arrow).
    mutating func otherKeyWentDown() {
        otherKeyPressed = true
    }

    func isTap(releasedAt uptime: TimeInterval) -> Bool {
        DictationHoldKeyTapPolicy.isTap(heldSeconds: uptime - pressUptime, otherKeyPressed: otherKeyPressed)
    }
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

extension PhysicalShortcutAction {
    /// The repeat-guard bucket for this action's press, or nil when its press
    /// is never debounced. Each toggle action has its own bucket, so a meeting
    /// press right after a dictation press still goes through. Push-to-talk
    /// has none: its release is paired to the physical key hold, and a
    /// swallowed press would leave a release with nothing to stop.
    var hotkeyDebounceID: String? {
        switch self {
        case .dictationPushToTalk: return nil
        case .dictationHandsFree: return "dictation_hands_free"
        case .meeting: return "meeting_physical_trigger"
        case .pasteLastDictation: return "paste_last_dictation_physical_trigger"
        }
    }
}

/// Drops rapid repeat presses of the same shortcut so Carbon/CGEventTap
/// double-fires can't race session start/stop. `now` is a monotonic uptime
/// (`ProcessInfo.systemUptime`), so a wall-clock jump can't block presses.
struct HotkeyActionDebouncer {
    let interval: TimeInterval
    private var lastAcceptedUptimeByID: [String: TimeInterval] = [:]

    init(interval: TimeInterval = TranscriptedConstants.hotkeyActionDebounceInterval) {
        self.interval = interval
    }

    /// True when the press should go through. Actions without a debounce ID
    /// always go through and leave no trace.
    mutating func shouldAccept(_ action: PhysicalShortcutAction, now: TimeInterval) -> Bool {
        guard let id = action.hotkeyDebounceID else { return true }
        let elapsed = now - (lastAcceptedUptimeByID[id] ?? 0)
        guard elapsed >= interval else { return false }
        lastAcceptedUptimeByID[id] = now
        return true
    }
}

extension PhysicalShortcutMatcher {
    /// The binding snapshot the event tap matches against. Meetings is
    /// always there; the dictation key comes first, only while dictation
    /// shortcuts are on. Built once per
    /// (re)configure, never per keystroke.
    static func configuredBindings(userDefaults: UserDefaults = .standard) -> [PhysicalShortcutBinding] {
        // No paste-last-dictation shortcut: it was dropped from Settings,
        // and a global chord nobody can see or change shouldn't stay live.
        var bindings = [
            PhysicalShortcutBinding(
                action: .meeting,
                binding: PhysicalDictationTriggerPreferences.meetingBinding(userDefaults: userDefaults)
            )
        ]

        guard HotkeyPreferences.dictationShortcutsEnabled(userDefaults: userDefaults) else {
            return bindings
        }

        // One dictation key. Tap to toggle runs it through the hands-free
        // path; the other behaviors are Push to Talk, where Hold or tap
        // keeps listening after a quick tap (DictationHotkeyRouter).
        let behavior = HotkeyPreferences.dictationKeyBehavior(userDefaults: userDefaults)
        bindings.insert(
            PhysicalShortcutBinding(
                action: behavior == .tapToToggle ? .dictationHandsFree : .dictationPushToTalk,
                binding: PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: userDefaults)
            ),
            at: 0
        )
        return bindings
    }

    /// Whether a key is still held, for recovery after the tap was off. A
    /// modifier key reads its modifier family flag (either Option key keeps
    /// Option down); any other key reads its own key state.
    static func isPhysicalKeyDown(
        _ keyCode: UInt32,
        modifierFlags: UInt32,
        keyState: (UInt32) -> Bool
    ) -> Bool {
        if PhysicalDictationTriggerPreferences.isModifierKey(keyCode),
           let modifier = PhysicalDictationTriggerPreferences.primaryModifierMask(for: keyCode) {
            return (modifierFlags & modifier) != 0
        }
        return keyState(keyCode)
    }

    /// Whether a delayed modifier press should start push-to-talk. It reads
    /// the bound key itself, so Left Option held doesn't count as a held
    /// Right Option binding.
    static func shouldActivateDelayedModifierPress(
        current: DelayedModifierShortcutPress?,
        expected: DelayedModifierShortcutPress,
        keyState: (UInt32) -> Bool
    ) -> Bool {
        shouldActivateDelayedModifierPress(
            current: current,
            expected: expected,
            isPhysicallyDown: keyState(expected.keyCode)
        )
    }

    struct TapDisabledReconciliation: Equatable {
        let activePushToTalkKeyCode: UInt32?
        let consumedKeyCodes: Set<UInt32>
        /// The push-to-talk key was let go while the tap was off, so the
        /// detector must send the release it missed.
        let synthesizesPushToTalkRelease: Bool
    }

    /// Detector state after macOS turned the event tap off
    /// (`tapDisabledByTimeout` / `tapDisabledByUserInput`). Any keyUp in that
    /// window was missed: a push-to-talk key that's no longer down gets a
    /// synthesized release, and consumed keys that are no longer down are
    /// forgotten so their next press isn't swallowed.
    static func reconcileAfterTapDisabled(
        activePushToTalkKeyCode: UInt32?,
        consumedKeyCodes: Set<UInt32>,
        isPhysicallyDown: (UInt32) -> Bool
    ) -> TapDisabledReconciliation {
        var activeKeyCode = activePushToTalkKeyCode
        var consumed = consumedKeyCodes
        var synthesizesRelease = false

        if shouldSynthesizePushToTalkRelease(
            activeKeyCode: activeKeyCode,
            isPhysicallyDown: isPhysicallyDown
        ), let releasedKeyCode = activeKeyCode {
            activeKeyCode = nil
            consumed.remove(releasedKeyCode)
            synthesizesRelease = true
        }

        return TapDisabledReconciliation(
            activePushToTalkKeyCode: activeKeyCode,
            consumedKeyCodes: consumed.filter { isPhysicallyDown($0) },
            synthesizesPushToTalkRelease: synthesizesRelease
        )
    }
}

/// Status text for the physical shortcut event tap.
enum PhysicalShortcutTriggerStatus {
    /// Shown when the tap can't start because Accessibility isn't granted.
    /// The menu bar matches on it to offer the Accessibility pane.
    static let accessibilityPermissionErrorMessage = "Shortcut trigger needs Accessibility permission"
    static let failedToStartMessage = "Shortcut trigger failed to start"

    /// Why the tap couldn't be created.
    static func tapCreateFailureMessage(accessibilityGranted: Bool) -> String {
        accessibilityGranted ? failedToStartMessage : accessibilityPermissionErrorMessage
    }

    /// Only a missing Accessibility grant is worth polling for: once it's
    /// granted the engine re-registers without waiting for wake or relaunch.
    static func retriesAfterAccessibilityGrant(registrationError: String?) -> Bool {
        registrationError == accessibilityPermissionErrorMessage
    }

    /// The one banner the menu bar shows. A registration failure wins; the
    /// Fn conflict is advisory and only matters while dictation shortcuts are
    /// on. It never counts as a registration failure, so wake recovery
    /// (which reads the registration error) doesn't retry over it.
    static func bannerMessage(
        registrationError: String?,
        dictationShortcutsEnabled: Bool,
        functionKeyConflictWarning: String?
    ) -> String? {
        registrationError ?? (dictationShortcutsEnabled ? functionKeyConflictWarning : nil)
    }
}
