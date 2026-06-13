// Support/AutoCallDetectionPreferences.swift
// Preference flag for ad-hoc call detection via mic activity.
//
// When enabled, MicActivityMonitor watches which process holds the microphone
// input and the meeting-prompt detector offers to record when a call starts —
// including a spontaneous Google Meet with no calendar invite. See
// docs/auto-call-detection-spec.md.
//
// Default ON (product decision 2026-06-14), matching Notion/Plaud. Everything
// stays on-device — we read which app holds the mic (metadata), never audio —
// but it is still surfaced behind a clear Settings toggle so it can be turned off.

import Foundation

enum AutoCallDetectionPreferences {

    static let enabledKey = "auto-call-detection-enabled"

    /// Whether mic-activity call detection runs. Defaults to true: until the user
    /// first toggles it the key is absent, and absence means on.
    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: enabledKey) != nil else { return true }
        return userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
        NotificationCenter.default.post(name: .autoCallDetectionPrefsDidChange, object: nil)
    }
}

extension Notification.Name {
    static let autoCallDetectionPrefsDidChange = Notification.Name("autoCallDetectionPrefsDidChange")
}
