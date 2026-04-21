// Support/LocalSpeakerPreferences.swift
// Preference flag for local (mic-channel) speaker diarization.
//
// When enabled, the meeting pipeline runs PyAnnote offline diarization on
// the mic track and surfaces multiple local speakers in the post-meeting
// SpeakerNamingSheet. When disabled (default) the mic track is tagged as
// a single "You" speaker exactly as before.
//
// Shipped default-off so the feature rolls out behind a settings toggle.
// Flip the default once real-world DER on room recordings is validated.

import Foundation

enum LocalSpeakerPreferences {

    private static let enabledKey = "local-speaker-split-enabled"

    /// Whether mic-channel diarization runs during meeting transcription.
    /// Default: false. Read by the pipeline runner on each meeting.
    static func isEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        NotificationCenter.default.post(name: .localSpeakerPrefsDidChange, object: nil)
    }
}

extension Notification.Name {
    static let localSpeakerPrefsDidChange = Notification.Name("localSpeakerPrefsDidChange")
}
