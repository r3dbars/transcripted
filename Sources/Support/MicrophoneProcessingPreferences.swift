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
//     completely for Safari/Firefox calls. macOS treats any VPIO holder as a
//     voice-comms app and can duck audio playback from other apps, so it is
//     never armed while a desktop call app is open (see
//     `MicrophoneSharingPolicy`).
//
// Default-off so existing users on v1.1.24 (where VPIO was unconditionally
// armed) get the un-ducked behavior on upgrade. Users who specifically need
// the VPIO path for Safari/Firefox WebRTC meetings can pick it in Settings.
// The in-meeting Boost Mic prompt arms VPIO for that one meeting only and
// never saves this preference: before 1.1.63 it did, which left call audio
// quieter in every later meeting (Matthew) and fought Zoom for the mic (Don).
// `migrateBoostedVoiceProcessingIfNeeded` moves those saved choices back to
// software autogain once.

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
            return "Off / raw input (no Transcripted gain)"
        case .softwareAGC:
            return "Software autogain"
        case .appleVoiceProcessing:
            return "Apple voice processing"
        }
    }

    var detail: String {
        switch self {
        case .none:
            return "Transcripted records microphone.m4a without software autogain. Best for tuned USB mics like Blue Yeti; your mic's physical gain controls the level."
        case .softwareAGC:
            return "Default. Transcripted boosts quiet saved mic audio without using Apple voice processing."
        case .appleVoiceProcessing:
            return "Uses Apple's call-mode processing for quiet WebRTC mics. Uses software autogain while Zoom, Teams, Webex or FaceTime is open so the mic stays shared. Other apps' audio may get quieter while recording."
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
        // Any explicit choice answers the one-time Boost note.
        dismissBoostMigrationNote(userDefaults: userDefaults)
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

    // MARK: - One-time move off a saved Boost

    static let boostMigrationDoneKey = "meeting-mic-processing-boost-migration-done"
    static let boostMigrationNoteKey = "meeting-mic-processing-boost-migration-note"

    /// Runs once per install. Up to 1.1.62, accepting the in-meeting Boost
    /// Mic prompt saved Apple voice processing for every later meeting and
    /// dictation. The app can't tell that apart from a Settings choice, and
    /// most saved choices came from the prompt, so any saved voice processing
    /// moves back to software autogain and the Mic processing row explains
    /// why. Anyone who wants it back picks it again in Settings; this never
    /// runs a second time. Returns true when it changed the mode.
    @discardableResult
    static func migrateBoostedVoiceProcessingIfNeeded(
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        guard !userDefaults.bool(forKey: boostMigrationDoneKey) else { return false }
        userDefaults.set(true, forKey: boostMigrationDoneKey)
        guard mode(userDefaults: userDefaults) == .appleVoiceProcessing else { return false }
        setMode(.softwareAGC, userDefaults: userDefaults)
        userDefaults.set(true, forKey: boostMigrationNoteKey)
        // Those meetings were boosted (or the user chose to be); don't bring
        // back the Home "Boost mic" hint on them now that the mode is off.
        hideMicBoostHints(through: Date(), userDefaults: userDefaults)
        return true
    }

    /// Shown under Mic processing until the user picks a mode themselves.
    static func showsBoostMigrationNote(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: boostMigrationNoteKey)
    }

    static func dismissBoostMigrationNote(userDefaults: UserDefaults = .standard) {
        userDefaults.removeObject(forKey: boostMigrationNoteKey)
    }

    static let boostMigrationNote = "Boost Mic now lasts for one meeting, so Transcripted moved you back to Software autogain. Pick Apple voice processing to keep it on."

    // MARK: - Boost the next meeting only

    static let nextMeetingBoostKey = "meeting-mic-processing-boost-next-meeting"
    static let micBoostHintsHiddenThroughKey = "meeting-mic-processing-boost-hints-hidden-through"

    /// The Home row's "Boost mic next meeting" action. Arms Apple voice
    /// processing for the next meeting that starts, never for dictation, and
    /// never saves the mode. Hides the hint on every meeting saved so far,
    /// since the user already answered it.
    static func requestBoostForNextMeeting(userDefaults: UserDefaults = .standard) {
        userDefaults.set(true, forKey: nextMeetingBoostKey)
        hideMicBoostHints(through: Date(), userDefaults: userDefaults)
        NotificationCenter.default.post(name: .microphoneProcessingPrefsDidChange, object: nil)
    }

    static func isBoostRequestedForNextMeeting(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: nextMeetingBoostKey)
    }

    /// Called once a meeting has started with the request applied, so the
    /// boost ends with that meeting.
    static func clearNextMeetingBoostRequest(userDefaults: UserDefaults = .standard) {
        guard userDefaults.bool(forKey: nextMeetingBoostKey) else { return }
        userDefaults.removeObject(forKey: nextMeetingBoostKey)
        NotificationCenter.default.post(name: .microphoneProcessingPrefsDidChange, object: nil)
    }

    /// Meetings saved at or before this moment no longer show the Home
    /// "Boost mic" hint. Nil when the user never answered one.
    static func micBoostHintsHiddenThrough(userDefaults: UserDefaults = .standard) -> Date? {
        userDefaults.object(forKey: micBoostHintsHiddenThroughKey) as? Date
    }

    static func hideMicBoostHints(through date: Date, userDefaults: UserDefaults = .standard) {
        if let existing = micBoostHintsHiddenThrough(userDefaults: userDefaults), existing >= date { return }
        userDefaults.set(date, forKey: micBoostHintsHiddenThroughKey)
    }
}

extension Notification.Name {
    static let microphoneProcessingPrefsDidChange = Notification.Name("microphoneProcessingPrefsDidChange")
}
