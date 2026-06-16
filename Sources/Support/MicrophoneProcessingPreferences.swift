// Support/MicrophoneProcessingPreferences.swift
// Preference flag for Transcripted's microphone voice-processing strategy.
//
// Two paths exist for cleaning up the mic so meeting and dictation transcripts
// come out at usable volume:
//
//   - Software AGC (default): meeting capture runs a real-time RealtimeAGC
//     instance in the mic tap callback to compensate for attenuated streams
//     (e.g. when Safari/Firefox WebRTC has activated VPIO on the same physical
//     mic and the shared device hands us a quiet copy). No system-wide side
//     effects.
//
//   - Apple voice processing (VPIO): we enable
//     setVoiceProcessingEnabled(true) on our AVAudioEngine input nodes so we
//     get our own AGC'd copy from the OS. This fixes issue #500 most
//     completely for Safari/Firefox calls and now covers dictation starts after
//     the user accepts the in-meeting boost. macOS treats any VPIO holder as a
//     voice-comms app and can duck audio playback from other apps. Users on
//     Zoom or other native voice apps may hear those apps get quieter while
//     Transcripted is recording.
//
// Default-off so existing users on v1.1.24 (where VPIO was unconditionally
// armed) get the un-ducked behavior on upgrade. Users who specifically need
// the VPIO path for Safari/Firefox WebRTC meetings can opt in via the
// Meetings settings page or the in-meeting boost prompt.

import Foundation

enum MicrophoneProcessingPreferences {

    static let voiceProcessingEnabledKey = "meeting-mic-voice-processing-enabled"
    static let micBoostPromptDeclinedAtKey = "meeting-mic-boost-prompt-declined-at"

    /// Whether Apple's AUVoiceProcessingIO (VPIO) is armed on Transcripted's
    /// mic engines. Default: false. Read once at recording start; changes
    /// during a session do not take effect until the next recording, except
    /// meeting capture can explicitly restart its engine after prompt consent.
    /// Tests can inject a sandboxed `UserDefaults` to avoid touching
    /// `.standard` global state.
    static func isVoiceProcessingEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: voiceProcessingEnabledKey)
    }

    static func setVoiceProcessingEnabled(
        _ enabled: Bool,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(enabled, forKey: voiceProcessingEnabledKey)
        NotificationCenter.default.post(name: .microphoneProcessingPrefsDidChange, object: nil)
    }

    static func lastMicBoostPromptDeclinedAt(userDefaults: UserDefaults = .standard) -> Date? {
        let timestamp = userDefaults.double(forKey: micBoostPromptDeclinedAtKey)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    static func markMicBoostPromptDeclined(
        at date: Date = Date(),
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(date.timeIntervalSince1970, forKey: micBoostPromptDeclinedAtKey)
    }
}

extension Notification.Name {
    static let microphoneProcessingPrefsDidChange = Notification.Name("microphoneProcessingPrefsDidChange")
}
