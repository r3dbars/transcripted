// Support/MeetingReminderPreferences.swift
// Preference flag for calendar-based meeting reminders.
//
// When enabled (and calendar access is granted), MeetingPromptDetector reads
// upcoming calendar events and offers a quiet record prompt shortly before a
// call starts. The first-run onboarding calendar step and the Settings General
// page both write this flag. Ad-hoc call detection has its own toggle in
// AutoCallDetectionPreferences; this one only gates the calendar source.
//
// Default ON, matching the other prompt surfaces. Calendar prompts still stay
// silent until the user grants calendar access.

import Foundation

enum MeetingReminderPreferences {

    static let enabledKey = "meeting-reminders-enabled"

    /// Whether calendar-based meeting reminders run. Defaults to true: until the
    /// user first toggles it the key is absent, and absence means on.
    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: enabledKey) != nil else { return true }
        return userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
    }
}
