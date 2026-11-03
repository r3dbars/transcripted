// Support/AutoRecordDetectedCallsPreferences.swift
// Opt-in auto-start for proven detected calls. Nested under Auto-detect
// calls; off until the user turns it on. See MeetingAutoRecordPolicy.

import Foundation

enum AutoRecordDetectedCallsPreferences {

    static let enabledKey = "auto-record-detected-calls-enabled"
    static let consentAcknowledgedKey = "auto-record-detected-calls-consent-acknowledged"

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

    static func hasAcknowledgedConsent(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: consentAcknowledgedKey)
    }

    static func acknowledgeConsent(userDefaults: UserDefaults = .standard) {
        userDefaults.set(true, forKey: consentAcknowledgedKey)
    }
}

/// Copy and the one-time enable confirmation for auto-record.
enum AutoRecordDetectedCallsConsentPolicy {
    static let title = "Record other people without asking?"
    static let message = "When Transcripted is sure you're in a Zoom, Teams, or Meet call, it will start recording on its own. The other people on the call are not asked."
    static let confirmTitle = "Record automatically"

    static func shouldConfirm(acknowledged: Bool) -> Bool {
        !acknowledged
    }
}

extension Notification.Name {
    static let autoRecordDetectedCallsPrefsDidChange = Notification.Name("autoRecordDetectedCallsPrefsDidChange")
}
