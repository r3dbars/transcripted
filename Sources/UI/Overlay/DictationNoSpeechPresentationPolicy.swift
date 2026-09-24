import Foundation

enum DictationNoSpeechPresentationPolicy {
    static func message(
        trigger: String,
        reason: DictationEmptyTranscriptionReason = .noSpeech
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
            return "Captured audio did not become text. Retry the saved audio with Capture → Transcribe Audio File."
        }

        if trigger == "physical_key" {
            return "No speech heard. Hold the dictation key while you talk."
        }
        return "No speech heard. Start over and speak a little longer."
    }
}
