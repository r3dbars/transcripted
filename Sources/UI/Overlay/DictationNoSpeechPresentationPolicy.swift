import Foundation

enum DictationNoSpeechPresentationPolicy {
    static func message(trigger: String) -> String {
        if trigger == "physical_key" {
            return "Transcripted didn't catch your voice. Keep holding the dictation key until you're done talking."
        }
        return "No speech heard. Try speaking a little longer."
    }
}
