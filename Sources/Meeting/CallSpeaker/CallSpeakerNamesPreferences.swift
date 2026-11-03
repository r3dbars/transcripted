// CallSpeakerNamesPreferences.swift
// Settings > Speakers "Name speakers from the call app". Default on. Read on
// every poll, so turning it off mid-meeting stops the reads at once.

import Foundation

enum CallSpeakerNamesPreferences {
    static let enabledKey = "call-speaker-names-enabled"

    /// Until the user first turns it off the key is absent, and absence means on.
    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        guard userDefaults.object(forKey: enabledKey) != nil else { return true }
        return userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
    }
}
