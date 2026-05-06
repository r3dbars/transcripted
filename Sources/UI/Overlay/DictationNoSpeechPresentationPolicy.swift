import Foundation

enum DictationNoSpeechPresentationPolicy {
    static func message(trigger: String) -> String {
        if trigger == "physical_key" {
            return "No speech caught. Hold the key while you talk."
        }
        return "No speech heard. Try speaking a little longer."
    }
}
