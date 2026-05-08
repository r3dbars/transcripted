import Foundation

enum DictationNoSpeechPresentationPolicy {
    static func message(trigger: String) -> String {
        if trigger == "physical_key" {
            return "Transcripted didn't catch your voice. Hold the dictation key while you talk."
        }
        return "No speech heard. Try speaking a little longer."
    }
}
