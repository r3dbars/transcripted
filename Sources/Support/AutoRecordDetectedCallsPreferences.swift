// Support/AutoRecordDetectedCallsPreferences.swift
// Opt-in auto-start for proven detected calls. Nested under Auto-detect
// calls; off until the user turns it on. See MeetingAutoRecordPolicy.

import Foundation

enum AutoRecordDetectedCallsPreferences {

    static let enabledKey = "auto-record-detected-calls-enabled"

    /// Stored toggle, ignoring whether auto-detect is on. Absent means off.
    static func isStoredOn(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: enabledKey)
    }

    /// Whether auto-start may fire. Requires Auto-detect calls as well.
    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        AutoCallDetectionPreferences.isEnabled(userDefaults: userDefaults)
            && isStoredOn(userDefaults: userDefaults)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
        NotificationCenter.default.post(name: .autoRecordDetectedCallsPrefsDidChange, object: nil)
    }
}

extension Notification.Name {
    static let autoRecordDetectedCallsPrefsDidChange = Notification.Name("autoRecordDetectedCallsPrefsDidChange")
}
