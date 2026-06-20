// Support/MeetingTitlePrivacyPreferences.swift
// Privacy toggle for whether the floating meeting prompt shows the real
// calendar event title or a generic "Meeting" label.
//
// Calendar event titles are PII and the floating pill can be visible while the
// user is screen-sharing (the shoulder-surf risk called out in
// docs/MEETING_CAPTURE_PROMPTING.md §4.2 B5). This pref lets the user keep the
// pill showing a generic label. The policy that consumes it
// (MeetingArmedPromptCopyPolicy) ALSO forces the generic label when a
// screen-share / system-audio capture is detected, regardless of this toggle.
//
// Default ON (show real titles): better day-to-day UX, matching the spec's Q5
// recommendation of "real title normally, generic when screen-share detected".
// Everything stays local — titles are never sent off-device.

import Foundation

enum MeetingTitlePrivacyPreferences {

    static let showRealTitlesKey = "meeting-prompt-show-real-titles"

    /// The label used whenever the real event title must be hidden.
    static let genericTitle = "Meeting"

    /// Whether the meeting prompt may show the real calendar event title.
    /// Defaults to true: absence of the key means "show real titles".
    static func showRealTitles(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: showRealTitlesKey) != nil else { return true }
        return userDefaults.bool(forKey: showRealTitlesKey)
    }

    static func setShowRealTitles(_ show: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(show, forKey: showRealTitlesKey)
        NotificationCenter.default.post(name: .meetingTitlePrivacyPrefsDidChange, object: nil)
    }
}

extension Notification.Name {
    static let meetingTitlePrivacyPrefsDidChange = Notification.Name("meetingTitlePrivacyPrefsDidChange")
}
