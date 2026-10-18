import Carbon
import Foundation

/// 1.1.70 made Right Option the one dictation key. This upgrade leaves
/// people on that one key: unstored 1.1.69 defaults and reset-to-defaults
/// (stored Fn) become Right Option; an explicit non-Fn primary key stays
/// chosen, otherwise a custom Hands-Free key becomes the one key.
/// Dual Fn + Right Option is not restored.
///
/// A one-time Settings note ("Dictation moved to Right Option") is armed
/// only for installs whose previous launched version is before 1.1.70.
/// Fresh installs and anyone already on 1.1.70+ never see it.
enum DictationShortcutUpgrade {
    static let lastLaunchedAppVersionKey = "Transcripted.LastLaunchedAppVersion"
    /// Written before Sparkle overwrites `lastLaunchedAppVersionKey` on launch,
    /// so migrate still sees 1.1.69 after `TranscriptedAppState` constructs
    /// the updater (that happens before `registerHotkey`).
    static let previousLaunchedAppVersionKey = "Transcripted.PreviousLaunchedAppVersion"
    static let oneKeyReleaseVersion = "1.1.70"
    static let movedToRightOptionNoticeKey = "dictation-shortcut-moved-to-right-option-notice"
    static let movedToRightOptionNotice = "Dictation moved to Right Option"
    static let movedToRightOptionNoticeIdentifier =
        "transcripted.settings.general.dictation-key-moved-note"
    static let movedToRightOptionNoticeDismissIdentifier =
        "transcripted.settings.general.dictation-key-moved-note-dismiss"
    static let legacyHoldDefault = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Function))

    static func rememberPreviousLaunchedVersion(
        _ previous: String?,
        userDefaults: UserDefaults = .standard
    ) {
        guard let previous = meaningfulVersion(previous) else { return }
        guard userDefaults.string(forKey: previousLaunchedAppVersionKey) == nil else { return }
        userDefaults.set(previous, forKey: previousLaunchedAppVersionKey)
    }

    static func launchedVersionBeforeThisBuild(userDefaults: UserDefaults = .standard) -> String? {
        meaningfulVersion(userDefaults.string(forKey: previousLaunchedAppVersionKey))
            ?? meaningfulVersion(userDefaults.string(forKey: lastLaunchedAppVersionKey))
    }

    static func isVersionBeforeOneKeyRelease(_ version: String?) -> Bool {
        guard let version = meaningfulVersion(version) else { return false }
        return version.compare(oneKeyReleaseVersion, options: .numeric) == .orderedAscending
    }

    static func showsMovedToRightOptionNotice(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: movedToRightOptionNoticeKey)
    }

    static func dismissMovedToRightOptionNotice(userDefaults: UserDefaults = .standard) {
        userDefaults.removeObject(forKey: movedToRightOptionNoticeKey)
    }

    /// One dictation key. An explicit non-Fn primary key wins, then custom
    /// Hands-Free; otherwise 1.1.69 Fn /
    /// unstored defaults become Right Option; Carbon-era Option+Space stays
    /// when Right Option was off. Harness launches skip it: they use a
    /// throwaway HOME and must not write migrate/notice flags.
    static func apply(
        userDefaults: UserDefaults,
        isAutomatedLaunch: Bool = AutomatedLaunchEnvironment.isActive()
    ) {
        guard !isAutomatedLaunch else { return }
        let storedHold = PhysicalDictationTriggerPreferences.storedPushToTalkBinding(
            userDefaults: userDefaults
        )
        let storedToggle = PhysicalDictationTriggerPreferences.storedHandsFreeBinding(
            userDefaults: userDefaults
        )
        let rightOption = PhysicalDictationTriggerPreferences.defaultPushToTalkBinding
        let fromBeforeOneKey = isVersionBeforeOneKeyRelease(
            launchedVersionBeforeThisBuild(userDefaults: userDefaults)
        )

        // An old, unused Hands-Free slot must not replace the primary key
        // the user explicitly chose, or change its hold/toggle behavior.
        if let storedHold, storedHold != legacyHoldDefault {
            PhysicalDictationTriggerPreferences.clearHandsFree(userDefaults: userDefaults)
            return
        }

        if let custom = storedToggle, custom != rightOption {
            PhysicalDictationTriggerPreferences.savePushToTalk(custom, userDefaults: userDefaults)
            PhysicalDictationTriggerPreferences.clearHandsFree(userDefaults: userDefaults)
            HotkeyPreferences.setDictationKeyBehavior(.tapToToggle, userDefaults: userDefaults)
            return
        }

        let carbonRightOptionDisabled = !HotkeyPreferences.rightOptionDictationEnabled(
            userDefaults: userDefaults
        )
        if persistCarbonEraShortcutIfNeeded(
            storedHold: storedHold,
            storedToggle: storedToggle,
            carbonRightOptionDisabled: carbonRightOptionDisabled,
            userDefaults: userDefaults
        ) {
            return
        }

        guard fromBeforeOneKey, storedHold == nil || storedHold == legacyHoldDefault else {
            return
        }

        PhysicalDictationTriggerPreferences.savePushToTalk(rightOption, userDefaults: userDefaults)
        PhysicalDictationTriggerPreferences.clearHandsFree(userDefaults: userDefaults)
        userDefaults.set(true, forKey: movedToRightOptionNoticeKey)
    }

    /// Pre-physical-trigger installs that turned Right Option off used the
    /// Carbon RegisterEventHotKey chord (default Option+Space). Persist it as
    /// the one dictation key — that chord is their custom shortcut.
    @discardableResult
    private static func persistCarbonEraShortcutIfNeeded(
        storedHold: PhysicalDictationTriggerBinding?,
        storedToggle: PhysicalDictationTriggerBinding?,
        carbonRightOptionDisabled: Bool,
        userDefaults: UserDefaults
    ) -> Bool {
        guard carbonRightOptionDisabled, storedHold == nil, storedToggle == nil else { return false }
        let old = HotkeyPreferences.dictationBinding(userDefaults: userDefaults)
        let carbon = PhysicalDictationTriggerBinding(
            keyCode: old.keyCode,
            modifiers: PhysicalDictationTriggerPreferences.modifiers(fromCarbon: old.modifiers)
        )
        guard PhysicalDictationTriggerPreferences.rejectionReason(for: carbon) == nil,
              carbon != PhysicalDictationTriggerPreferences.defaultPushToTalkBinding else {
            return false
        }
        PhysicalDictationTriggerPreferences.savePushToTalk(carbon, userDefaults: userDefaults)
        HotkeyPreferences.setDictationKeyBehavior(.tapToToggle, userDefaults: userDefaults)
        return true
    }

    static func analyticsProperties(userDefaults: UserDefaults = .standard) -> [String: String] {
        let hold = PhysicalDictationTriggerPreferences.pushToTalkBinding(userDefaults: userDefaults)
        let toggle = PhysicalDictationTriggerPreferences.storedHandsFreeBinding(userDefaults: userDefaults) ?? hold
        return [
            "hold_key": analyticsKeyLabel(for: hold),
            "toggle_key": analyticsKeyLabel(for: toggle),
            "key_behavior": HotkeyPreferences.dictationKeyBehavior(userDefaults: userDefaults).rawValue,
        ]
    }

    static func analyticsKeyLabel(for binding: PhysicalDictationTriggerBinding) -> String {
        var parts: [String] = []
        let mods = binding.modifiers
        if mods & PhysicalDictationTriggerModifiers.control != 0 { parts.append("control") }
        if mods & PhysicalDictationTriggerModifiers.option != 0 { parts.append("option") }
        if mods & PhysicalDictationTriggerModifiers.shift != 0 { parts.append("shift") }
        if mods & PhysicalDictationTriggerModifiers.command != 0 { parts.append("command") }
        if mods & PhysicalDictationTriggerModifiers.function != 0 { parts.append("fn") }
        parts.append(analyticsKeyName(for: binding.keyCode))
        return parts.joined(separator: "_")
    }

    private static func analyticsKeyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Function: return "fn"
        case kVK_RightOption: return "right_option"
        case kVK_Option: return "left_option"
        case kVK_RightCommand: return "right_command"
        case kVK_Command: return "left_command"
        case kVK_RightShift: return "right_shift"
        case kVK_Shift: return "left_shift"
        case kVK_RightControl: return "right_control"
        case kVK_Control: return "left_control"
        case kVK_CapsLock: return "caps_lock"
        case kVK_Space: return "space"
        case kVK_F1: return "f1"
        case kVK_F2: return "f2"
        case kVK_F3: return "f3"
        case kVK_F4: return "f4"
        case kVK_F5: return "f5"
        case kVK_F6: return "f6"
        case kVK_F7: return "f7"
        case kVK_F8: return "f8"
        case kVK_F9: return "f9"
        case kVK_F10: return "f10"
        case kVK_F11: return "f11"
        case kVK_F12: return "f12"
        case kVK_F13: return "f13"
        case kVK_F14: return "f14"
        case kVK_F15: return "f15"
        case kVK_F16: return "f16"
        case kVK_F17: return "f17"
        case kVK_F18: return "f18"
        case kVK_F19: return "f19"
        case kVK_F20: return "f20"
        default:
            return "keycode_\(keyCode)"
        }
    }

    private static func meaningfulVersion(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              trimmed != "unknown" else {
            return nil
        }
        return trimmed
    }
}
