// MeetingPromptPreferences.swift
// User preference for detected-meeting prompt nudges.

import Foundation

enum MeetingPromptPreferences {
    static let enabledKey = "transcripted.meeting-prompts.enabled"

    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: enabledKey) != nil else { return true }
        return defaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }
}
