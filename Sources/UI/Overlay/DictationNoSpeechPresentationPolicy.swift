import Foundation

enum DictationNoSpeechPresentationPolicy {
    static func message(
        trigger: String,
        reason: DictationEmptyTranscriptionReason = .noSpeech,
        shortcutMode: DictationShortcutMode? = nil
    ) -> String {
        if reason == .recordingTooShort {
            // A quick tap closes like a cancel before reaching this copy, so the
            // press was long enough and the mic delivered too little audio.
            return "Only a moment of audio came through. Try again, and if it keeps happening, check your microphone."
        }
        if reason == .modelFailure {
            return "The local speech model failed. Try again, or switch transcription models in Settings."
        }
        if reason == .audioNeedsRecovery {
            return "Captured audio did not become text. It's saved, so Transcribe It can try again."
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
