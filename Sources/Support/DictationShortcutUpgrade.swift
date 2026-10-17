import Carbon
import Foundation

/// Restores the 1.1.69 two-key dictation layout for people upgrading through
/// 1.1.70's one-key default, and names the chosen keys for analytics.
///
/// 1.1.70 made Right Option the one dictation key. Unstored 1.1.69 defaults
/// were Fn hold-to-talk plus Right Option hands-free, so a naive read of the
/// new default dropped Fn. A stored hold key made migrate return early and
/// drop Hands-Free. Both keys are valid together.
enum DictationShortcutUpgrade {
    static let lastLaunchedAppVersionKey = "Transcripted.LastLaunchedAppVersion"
    /// Written before Sparkle overwrites `lastLaunchedAppVersionKey` on launch,
    /// so migrate still sees 1.1.69 after `TranscriptedAppState` constructs
    /// the updater (that happens before `registerHotkey`).
    static let previousLaunchedAppVersionKey = "Transcripted.PreviousLaunchedAppVersion"
    static let oneKeyReleaseVersion = "1.1.70"
    static let legacyHoldDefault = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_Function))
    static let legacyToggleDefault = PhysicalDictationTriggerBinding(keyCode: UInt32(kVK_RightOption))

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

    /// Persist every 1.1.69 dictation key that still worked. Carbon-era
    /// Right-Option-disabled installs keep Option+Space (or whatever Carbon
    /// shortcut they saved) as the one dictation key — the lazy read path
    /// cannot, because a missing mode is Hands-Free and that returns today's
    /// Right Option default.
    static func apply(userDefaults: UserDefaults) {
        let storedHold = PhysicalDictationTriggerPreferences.storedPushToTalkBinding(
            userDefaults: userDefaults
        )
        let storedToggle = PhysicalDictationTriggerPreferences.storedHandsFreeBinding(
            userDefaults: userDefaults
        )
        let carbonRightOptionDisabled = !HotkeyPreferences.rightOptionDictationEnabled(
            userDefaults: userDefaults
        )

        if shouldKeepEveryLegacyKey(
            storedHold: storedHold,
            storedToggle: storedToggle,
            carbonRightOptionDisabled: carbonRightOptionDisabled,
            launchedVersionBeforeThisBuild: launchedVersionBeforeThisBuild(userDefaults: userDefaults),
            onboardingCompleted: PermissionsOnboardingPreferences.hasCompleted(userDefaults: userDefaults)
        ) {
            let hold = storedHold ?? legacyHoldDefault
            PhysicalDictationTriggerPreferences.savePushToTalk(hold, userDefaults: userDefaults)
            let toggle = storedToggle ?? legacyToggleDefault
            if toggle != hold {
                PhysicalDictationTriggerPreferences.saveHandsFree(toggle, userDefaults: userDefaults)
            }
            return
        }

        persistCarbonEraShortcutIfNeeded(
            storedHold: storedHold,
            storedToggle: storedToggle,
            carbonRightOptionDisabled: carbonRightOptionDisabled,
            userDefaults: userDefaults
        )
    }

    /// Pre-physical-trigger installs that turned Right Option off used the
    /// Carbon RegisterEventHotKey chord (default Option+Space). Persist it as
    /// the one dictation key, matching the 1.1.70 migrate for this cohort.
    private static func persistCarbonEraShortcutIfNeeded(
        storedHold: PhysicalDictationTriggerBinding?,
        storedToggle: PhysicalDictationTriggerBinding?,
        carbonRightOptionDisabled: Bool,
        userDefaults: UserDefaults
    ) {
        guard carbonRightOptionDisabled, storedHold == nil, storedToggle == nil else { return }
        let old = HotkeyPreferences.dictationBinding(userDefaults: userDefaults)
        let carbon = PhysicalDictationTriggerBinding(
            keyCode: old.keyCode,
            modifiers: PhysicalDictationTriggerPreferences.modifiers(fromCarbon: old.modifiers)
        )
        guard PhysicalDictationTriggerPreferences.rejectionReason(for: carbon) == nil,
              carbon != PhysicalDictationTriggerPreferences.defaultPushToTalkBinding else {
            return
        }
        PhysicalDictationTriggerPreferences.savePushToTalk(carbon, userDefaults: userDefaults)
        HotkeyPreferences.setDictationKeyBehavior(.tapToToggle, userDefaults: userDefaults)
    }

    static func shouldKeepEveryLegacyKey(
        storedHold: PhysicalDictationTriggerBinding?,
        storedToggle: PhysicalDictationTriggerBinding?,
        carbonRightOptionDisabled: Bool,
        launchedVersionBeforeThisBuild: String?,
        onboardingCompleted: Bool
    ) -> Bool {
        if carbonRightOptionDisabled, storedHold == nil, storedToggle == nil {
            return false
        }
        if storedHold != nil || storedToggle != nil {
            return true
        }
        if let version = launchedVersionBeforeThisBuild,
           version.compare(oneKeyReleaseVersion, options: .numeric) == .orderedAscending {
            return true
        }
        // Sparkle writes last-launched to the current version before
        // registerHotkey. Onboarding is still completed for a 1.1.69
        // upgrader, and still incomplete on a fresh 1.1.70 first launch
        // (`registerHotkey` runs before the onboarding window).
        return onboardingCompleted
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
