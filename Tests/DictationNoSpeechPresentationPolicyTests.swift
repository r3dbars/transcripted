import Foundation

func testDictationNoSpeechPresentationPolicy() {
    runSuite("DictationNoSpeechPresentationPolicy gives physical-key users direct recovery copy") {
        let message = DictationNoSpeechPresentationPolicy.message(trigger: "physical_key")

        assertEqual(
            message,
            "Transcripted didn't catch your voice. Keep holding the dictation key until you're done talking.",
            "physical key no-speech copy should explain the press-and-hold behavior"
        )
    }

    runSuite("DictationNoSpeechPresentationPolicy keeps generic copy for menu dictation") {
        let message = DictationNoSpeechPresentationPolicy.message(trigger: "menu")

        assertEqual(
            message,
            "No speech heard. Try speaking a little longer.",
            "non-physical-key dictation should keep the broader no-speech guidance"
        )
    }
}
