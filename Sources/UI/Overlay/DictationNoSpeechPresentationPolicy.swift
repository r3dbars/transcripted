import Foundation

enum DictationNoSpeechPresentationPolicy {
    /// `silentMicName` is set when the mic sent audio that was all exact
    /// zeros (a muted mic, not a quiet room), so the message can say so.
    /// `savedRecordingOffered` is true when the message carries Transcribe It
    /// (a long take, see `DictationFailedTakePolicy`); otherwise the audio is
    /// already gone and the message must not promise it.
    static func message(
        trigger: String,
        reason: DictationEmptyTranscriptionReason = .noSpeech,
        shortcutMode: DictationShortcutMode? = nil,
        silentMicName: String? = nil,
        savedRecordingOffered: Bool = false
    ) -> String {
        if reason == .noSpeech, let silentMicName {
            let name = silentMicName.trimmingCharacters(in: .whitespacesAndNewlines)
            let mic = name.isEmpty ? "Your microphone" : name
            return "\(mic) sent only silence. If it has a mute button or switch, turn it off, or pick another mic in Settings."
        }
        if reason == .recordingTooShort {
            // A quick tap closes like a cancel before reaching this copy, so the
            // press was long enough and the mic delivered too little audio.
            return "Only a moment of audio came through. Try again, and if it keeps happening, check your microphone."
        }
        if reason == .modelFailure {
            return "The local speech model failed. Try again, or switch transcription models in Settings."
        }
        if reason == .otherLanguage {
            return "This came out in a language your Mac isn't set up for, so it wasn't pasted. If it's right, choose \(DictationHeldTextActionCopy.pasteAnywayTitle)."
        }
        if reason == .audioNeedsRecovery {
            guard savedRecordingOffered else {
                // Not "No speech heard": the mic did pick up sound.
                return "Didn't catch that. Try again."
            }
            return "Captured audio did not become text. Choose Transcribe to add it to Meetings."
        }

        if trigger == "physical_key" {
            // Only push-to-talk has a key to hold. Hands-free people already
            // talked with nothing held, so "hold the key" is wrong for them.
            if shortcutMode == .pushToTalk {
                return "No speech heard. Hold the dictation key while you talk."
            }
            return "No speech heard. Check your mic and try again."
        }
        return "No speech heard. Start over and speak a little longer."
    }
}

extension DictationNoSpeechPresentationPolicy {
    /// The wing's few words when the message is only a passing note: a take
    /// with no speech, one too short, or one that didn't turn into words.
    /// Nothing to rescue and nothing to press, so the island never opens its
    /// drop-down for these; hovering shows the full sentence. Nil for a
    /// message that needs reading or acting on (a muted mic, a model failure).
    static func passingLabel(for message: String) -> String? {
        if message.hasPrefix("No speech heard.") { return "No speech" }
        if message.hasPrefix("Only a moment of audio") { return "Too short" }
        if message == "Didn't catch that. Try again." { return "Didn't catch that" }
        return nil
    }

    /// The wing's words for any no-speech message.
    static func wingLabel(for message: String) -> String {
        if let passing = passingLabel(for: message) { return passing }
        if message.contains("sent only silence") { return "Mic is silent" }
        if message.hasPrefix("The local speech model failed") { return "Model failed" }
        return "No speech"
    }
}

/// The button on dictation messages about a saved recording. It runs the
/// same import as Capture → Transcribe Audio File on that recording.
enum DictationSavedAudioActionCopy {
    static let transcribeTitle = "Transcribe"
}

/// The button on the wrong-language message. It pastes the held-back text.
enum DictationHeldTextActionCopy {
    static let pasteAnywayTitle = "Paste anyway"
}
