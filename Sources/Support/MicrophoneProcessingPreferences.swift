// Support/MicrophoneProcessingPreferences.swift
// Preference flag for the meeting microphone's voice-processing strategy.
//
// Two paths exist for cleaning up the meeting mic so transcripts come out at
// usable volume:
//
//   - Software AGC (default): a real-time RealtimeAGC instance in the mic tap
//     callback applies gain to compensate for attenuated streams (e.g. when
//     Safari/Firefox WebRTC has activated VPIO on the same physical mic and
//     the shared device hands us a quiet copy). No system-wide side effects.
//
//   - Apple voice processing (VPIO): we enable
//     setVoiceProcessingEnabled(true) on our AVAudioEngine input node so we
//     get our own AGC'd copy from the OS. This fixes issue #500 most
//     completely for Safari/Firefox calls, but macOS treats any VPIO holder
//     as a voice-comms app and ducks audio playback from other apps. Users
//     on Zoom or other native voice apps will hear those apps get quieter
//     while Transcripted is recording.
//
// Default-off so existing users on v1.1.24 (where VPIO was unconditionally
// armed) get the un-ducked behavior on upgrade. Users who specifically need
// the VPIO path for Safari/Firefox WebRTC meetings can opt in via the
// Meetings settings page.

import Foundation

enum MicrophoneProcessingPreferences {

    static let voiceProcessingEnabledKey = "meeting-mic-voice-processing-enabled"

    /// Whether Apple's AUVoiceProcessingIO (VPIO) is armed on the meeting
    /// mic engine. Default: false. Read once at recording start; changes
    /// during a session do not take effect until the next recording.
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
}

extension Notification.Name {
    static let microphoneProcessingPrefsDidChange = Notification.Name("microphoneProcessingPrefsDidChange")
}
