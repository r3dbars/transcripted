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
            return "Captured audio did not become text. Transcribe It adds it to Meetings."
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

/// The button on dictation messages about a saved recording. It runs the
/// same import as Capture → Transcribe Audio File on that recording.
enum DictationSavedAudioActionCopy {
    static let transcribeTitle = "Transcribe It"
}

/// The button on the wrong-language message. It pastes the held-back text.
enum DictationHeldTextActionCopy {
    static let pasteAnywayTitle = "Paste Anyway"
}
