// Support/MissedCallNudgePreferences.swift
// Preference flag for the post-call "that call wasn't recorded" nudge.
//
// When auto call detection notices a long call end without a Transcripted
// recording, the meeting overlay can show a one-line awareness nudge (see
// MissedCallNudgePolicy in Sources/Meeting/MeetingPromptHeuristics.swift for
// the rate limits). Default ON; the nudge itself carries a "Don't show again"
// action that writes this preference, and Settings exposes the same toggle.

import Foundation

enum MissedCallNudgePreferences {

    static let enabledKey = "missed-call-nudge-enabled"

    /// Whether the missed-call nudge may show. Defaults to true: until the user
    /// first opts out the key is absent, and absence means on.
    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: enabledKey) != nil else { return true }
        return userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
    }
}
