import Foundation

enum DictationNoSpeechPresentationPolicy {
    static func message(trigger: String) -> String {
        if trigger == "physical_key" {
            return "No speech heard. Hold the dictation key while you talk."
        }
        return "No speech heard. Start over and speak a little longer."
    }
}
