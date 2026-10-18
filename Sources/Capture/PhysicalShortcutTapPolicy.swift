// PhysicalShortcutTapPolicy.swift
// Foundation/CoreGraphics-pure decisions the physical-shortcut event tap
// uses for its event mask, media-key (NSSystemDefined) handling, Fn-vs-
// modifier mismatch logging, tap-disable recovery logs, and the installed-
// binding snapshot. The CGEventTap class stays in PhysicalShortcutDetector;
// this file is the testable seam so a macOS Fn/media-key change can be
// diagnosed without reading Sources as text.

import Carbon
import CoreGraphics
import Foundation

enum PhysicalShortcutDiagnosticEvent {
    static let mediaKey = "hotkey_fkey_arrived_as_media_key"
    static let modifierMismatch = "hotkey_modifier_mismatch"
    static let tapDisabled = "physical_shortcut_tap_disabled"
    static let installed = "physical_shortcut_trigger_installed"
}

enum PhysicalShortcutTapPolicy {
    /// `NSEvent.EventType.system` / NX_SYSDEFINED. Play/pause and other
    /// hardware media keys arrive as this instead of keyDown when F-keys
    /// are in media-key mode (F8 is NX_KEYTYPE_PLAY = 16).
    static let systemDefinedEventTypeRawValue: UInt32 = 14

    /// How long to wait before logging the same diagnostic again.
    static let diagnosticLogInterval: TimeInterval = 5

    static var systemDefinedEventType: CGEventType {
        CGEventType(rawValue: systemDefinedEventTypeRawValue)!
    }

    static func eventsOfInterestMask() -> CGEventMask {
        (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
            | (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << systemDefinedEventTypeRawValue)
    }

    /// Media-key events must always continue to the rest of the system.
    /// Swallowing play/pause or volume would steal the hardware keys.
    static func mustPassThrough(eventTypeRawValue: UInt32) -> Bool {
        eventTypeRawValue == systemDefinedEventTypeRawValue
    }

    static func tapDisabledReason(for type: CGEventType) -> String? {
        tapDisabledReason(forEventTypeRawValue: type.rawValue)
    }

    static func tapDisabledReason(forEventTypeRawValue raw: UInt32) -> String? {
        switch raw {
        case CGEventType.tapDisabledByTimeout.rawValue:
            return "timeout"
        case CGEventType.tapDisabledByUserInput.rawValue:
            return "user_input"
        default:
            return nil
        }
    }

    static func tapDisabledContext(reason: String, reenabled: Bool) -> [String: String] {
        [
            "reason": reason,
            "reenabled": reenabled ? "true" : "false",
        ]
    }

    static func installedBindingsContext(_ bindings: [PhysicalShortcutBinding]) -> [String: String] {
        let actions = bindings.map(actionID).joined(separator: ",")
        let dictation = bindings.first { $0.action != .meeting }
        let isFKey = dictation.map {
            PhysicalDictationTriggerPreferences.isFunctionKey($0.binding.keyCode)
        } ?? false
        return [
            "actions": actions.isEmpty ? "none" : actions,
            "dictation_is_fkey": isFKey ? "true" : "false",
        ]
    }

    private static func actionID(_ binding: PhysicalShortcutBinding) -> String {
        switch binding.action {
        case .dictationPushToTalk: return "dictation_push_to_talk"
        case .dictationHandsFree: return "dictation_hands_free"
        case .meeting: return "meeting"
        }
    }
}

enum PhysicalShortcutMediaKeyPolicy {
    /// NX_KEYTYPE_PLAY. F8 in media-key mode.
    static let playPauseNXKeyType = 16
    /// NX_SUBTYPE_AUX_CONTROL_BUTTONS
    static let auxControlButtonsSubtype = 8
    static let keyDownState = 0xA
    static let keyUpState = 0xB

    static func parseAuxControl(subtype: Int, data1: Int) -> (nxKeyType: Int, isKeyDown: Bool)? {
        guard subtype == auxControlButtonsSubtype else { return nil }
        let nxKeyType = (data1 & 0xFFFF0000) >> 16
        let keyState = (data1 & 0xFF00) >> 8
        guard keyState == keyDownState || keyState == keyUpState else { return nil }
        return (nxKeyType, keyState == keyDownState)
    }

    /// Hardware media-key type for F1-F12. F13-F20 have no media-key form.
    static func nxKeyType(forFunctionKey keyCode: UInt32) -> Int? {
        switch Int(keyCode) {
        case kVK_F1: return 3
        case kVK_F2: return 2
        case kVK_F5: return 22
        case kVK_F6: return 21
        case kVK_F7: return 18
        case kVK_F8: return playPauseNXKeyType
        case kVK_F9: return 17
        case kVK_F10: return 7
        case kVK_F11: return 1
        case kVK_F12: return 0
        default: return nil
        }
    }

    static func dictationFunctionKeyArrivedAsMediaKey(
        nxKeyType: Int,
        dictationBinding: PhysicalDictationTriggerBinding?
    ) -> Bool {
        guard let dictationBinding,
              PhysicalDictationTriggerPreferences.isFunctionKey(dictationBinding.keyCode),
              let expected = nxKeyType(forFunctionKey: dictationBinding.keyCode) else {
            return false
        }
        return canonicalNXKeyType(nxKeyType) == expected
    }

    static func nxKeyKind(_ nxKeyType: Int) -> String {
        switch canonicalNXKeyType(nxKeyType) {
        case 0: return "sound_up"
        case 1: return "sound_down"
        case 2: return "brightness_up"
        case 3: return "brightness_down"
        case 7: return "mute"
        case 16: return "play"
        case 17: return "next"
        case 18: return "previous"
        case 21: return "illumination_up"
        case 22: return "illumination_down"
        default: return "other"
        }
    }

    static func mediaKeyContext(nxKeyType: Int) -> [String: String] {
        ["nx_key_kind": nxKeyKind(nxKeyType)]
    }

    /// NX_KEYTYPE_FAST (19) is F9's next-track alias; REWIND (20) is F7's.
    private static func canonicalNXKeyType(_ nxKeyType: Int) -> Int {
        switch nxKeyType {
        case 19: return 17
        case 20: return 18
        default: return nxKeyType
        }
    }
}

enum PhysicalShortcutModifierMismatchPolicy {
    /// True only when this event is the saved binding's keycode with a
    /// different Cmd/Ctrl/Opt/Shift set. Fn on F-keys is not a mismatch.
    /// Bare typing of the same letter without extra modifiers is not logged.
    static func shouldLog(
        saved: PhysicalDictationTriggerBinding,
        keyCode: UInt32,
        modifiers: UInt32
    ) -> Bool {
        guard saved.keyCode == keyCode else { return false }
        guard !PhysicalDictationTriggerPreferences.isModifierKey(saved.keyCode) else { return false }
        let relevant = PhysicalDictationTriggerPreferences.relevantHeldModifiers(forKeyCode: saved.keyCode)
        let savedMods = saved.modifiers & relevant
        let eventMods = modifiers & relevant
        guard savedMods != eventMods else { return false }
        let explicit = PhysicalDictationTriggerModifiers.command
            | PhysicalDictationTriggerModifiers.shift
            | PhysicalDictationTriggerModifiers.option
            | PhysicalDictationTriggerModifiers.control
        return (eventMods & explicit) != 0
    }

    static func context(keyCode: UInt32) -> [String: String] {
        [
            "dictation_is_fkey": PhysicalDictationTriggerPreferences.isFunctionKey(keyCode) ? "true" : "false",
        ]
    }
}

/// Injected-clock rate limit so tests never assert wall-clock time.
struct PhysicalShortcutDiagnosticRateLimiter {
    let interval: TimeInterval
    private var lastAccepted: [String: TimeInterval] = [:]

    init(interval: TimeInterval = PhysicalShortcutTapPolicy.diagnosticLogInterval) {
        self.interval = interval
    }

    mutating func shouldEmit(_ id: String, now: TimeInterval) -> Bool {
        if let last = lastAccepted[id], now - last < interval {
            return false
        }
        lastAccepted[id] = now
        return true
    }
}
