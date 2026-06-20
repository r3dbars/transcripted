// Support/MicrophoneProcessingPreferences.swift
// Preference flag for Transcripted's microphone processing strategy.
//
// Three paths exist for handling the mic so meeting and dictation transcripts
// match what the user needs:
//
//   - Off / raw input: meeting capture records the copied mic buffer without
//     Transcripted software gain. This is for tuned hardware mics like a Blue
//     Yeti where the user has already set physical gain and does not want the
//     saved microphone.m4a lifted during silence.
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

enum MicrophoneProcessingMode: String, CaseIterable, Identifiable {
    case none
    case softwareAGC = "software_agc"
    case appleVoiceProcessing = "apple_voice_processing"

    var id: String { rawValue }

    var usesSoftwareAutogain: Bool {
        self == .softwareAGC
    }

    var allowsSoftwareAutogainFallback: Bool {
        self != .none
    }

    var usesAppleVoiceProcessing: Bool {
        self == .appleVoiceProcessing
    }

    var title: String {
        switch self {
        case .none:
            return "Off / raw input"
        case .softwareAGC:
            return "Software autogain"
        case .appleVoiceProcessing:
            return "Apple voice processing"
        }
    }

    var detail: String {
        switch self {
        case .none:
            return "No Transcripted gain is applied to the saved mic track. Best for tuned USB mics."
        case .softwareAGC:
            return "Default. Transcripted boosts quiet saved mic audio without using Apple voice processing."
        case .appleVoiceProcessing:
            return "Uses Apple's call-mode processing for quiet WebRTC mics. Other apps' audio may get quieter while recording."
        }
    }
}

enum MicrophoneProcessingPreferences {

    static let modeKey = "meeting-mic-processing-mode"
    static let voiceProcessingEnabledKey = "meeting-mic-voice-processing-enabled"

    static func mode(userDefaults: UserDefaults = .standard) -> MicrophoneProcessingMode {
        if let rawValue = userDefaults.string(forKey: modeKey),
           let mode = MicrophoneProcessingMode(rawValue: rawValue) {
            return mode
        }

        if userDefaults.bool(forKey: voiceProcessingEnabledKey) {
            return .appleVoiceProcessing
        }

        return .softwareAGC
    }

    static func setMode(
        _ mode: MicrophoneProcessingMode,
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(mode.rawValue, forKey: modeKey)
        userDefaults.set(mode.usesAppleVoiceProcessing, forKey: voiceProcessingEnabledKey)
        NotificationCenter.default.post(name: .microphoneProcessingPrefsDidChange, object: nil)
    }

    static func isSoftwareAutogainEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        mode(userDefaults: userDefaults).usesSoftwareAutogain
    }

    /// Whether Apple's AUVoiceProcessingIO (VPIO) is armed on Transcripted's
    /// mic engines. Default: false. Read once at recording start; changes
    /// during a session do not take effect until the next recording, except
    /// meeting capture can explicitly restart its engine after prompt consent.
    /// Tests can inject a sandboxed `UserDefaults` to avoid touching
    /// `.standard` global state.
    static func isVoiceProcessingEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        mode(userDefaults: userDefaults).usesAppleVoiceProcessing
    }

    static func setVoiceProcessingEnabled(
        _ enabled: Bool,
        userDefaults: UserDefaults = .standard
    ) {
        setMode(enabled ? .appleVoiceProcessing : .softwareAGC, userDefaults: userDefaults)
    }
}

extension Notification.Name {
    static let microphoneProcessingPrefsDidChange = Notification.Name("microphoneProcessingPrefsDidChange")
}
