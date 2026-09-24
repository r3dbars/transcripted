import Foundation

enum DictationNoSpeechPresentationPolicy {
    static func message(
        trigger: String,
        reason: DictationEmptyTranscriptionReason = .noSpeech,
        shortcutMode: DictationShortcutMode? = nil
    ) -> String {
        if reason == .recordingTooShort {
            return "Recording ended too soon. Try again and speak for at least a second."
        }
        if reason == .modelFailure {
            return "The local speech model failed. Try again, or switch transcription models in Settings."
        }
        if reason == .audioNeedsRecovery {
            return "Captured audio did not become text. Retry the saved audio with Capture → Transcribe Audio File."
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
