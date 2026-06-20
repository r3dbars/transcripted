// Support/CalendarPreArmPreferences.swift
// Opt-in toggle for the calendar pre-arm path (the "armed" meeting prompt).
//
// When enabled AND calendar access is granted, MeetingPromptDetector reads
// upcoming Calendar events with a conferencing link and offers a one-tap
// "Record" prompt as the meeting is about to start. This is the gentle,
// default tier from docs/MEETING_CAPTURE_PROMPTING.md: convenience comes from
// prediction; trust comes from the tap. No file is ever written without the
// explicit Record tap — pre-arm only anticipates and prompts.
//
// Default ON: the rollout recommendation is "on after the user grants calendar
// access". The pref is the kill switch — turning it off stops all calendar
// prompting without disturbing the ad-hoc audio/process fallback
// (AutoCallDetectionPreferences), which stays independently toggleable.

import Foundation

enum CalendarPreArmPreferences {

    static let enabledKey = "calendar-prearm-enabled"

    /// Whether calendar pre-arm prompting runs. Defaults to true: until the user
    /// first toggles it the key is absent, and absence means on. Calendar access
    /// is still required separately — this gate only governs whether we use it.
    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: enabledKey) != nil else { return true }
        return userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
        NotificationCenter.default.post(name: .calendarPreArmPrefsDidChange, object: nil)
    }
}

extension Notification.Name {
    static let calendarPreArmPrefsDidChange = Notification.Name("calendarPreArmPrefsDidChange")
}
