import Foundation

enum DictationNoSpeechPresentationPolicy {
    static func message(
        trigger: String,
        reason: DictationEmptyTranscriptionReason = .noSpeech
    ) -> String {
        if reason == .recordingTooShort {
            return "Recording ended too soon. Try again and speak for at least a second."
        }
        if reason == .modelFailure {
            return "The local speech model failed. Try again, or switch transcription models in Settings."
        }

        if trigger == "physical_key" {
            return "No speech heard. Hold the dictation key while you talk."
        }
        return "No speech heard. Start over and speak a little longer."
    }
}
