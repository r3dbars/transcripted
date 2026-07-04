import Foundation

func testDictationNoSpeechPresentationPolicy() {
    runSuite("DictationNoSpeechPresentationPolicy gives physical-key users direct recovery copy") {
        let message = DictationNoSpeechPresentationPolicy.message(trigger: "physical_key")

        assertEqual(
            message,
            "No speech heard. Hold the dictation key while you talk.",
            "physical key no-speech copy should explain the press-and-hold behavior"
        )
    }

    runSuite("DictationNoSpeechPresentationPolicy gives menu users a direct retry path") {
        let message = DictationNoSpeechPresentationPolicy.message(trigger: "menu")

        assertEqual(
            message,
            "No speech heard. Start over and speak a little longer.",
            "non-physical-key dictation should explain the next retry action"
        )
    }

    runSuite("DictationNoSpeechPresentationPolicy separates too-short recordings from silence") {
        let message = DictationNoSpeechPresentationPolicy.message(
            trigger: "menu",
            reason: .recordingTooShort
        )

        assertEqual(
            message,
            "Recording ended too soon. Try again and speak for at least a second.",
            "too-short dictation should explain the recording length problem instead of blaming silence"
        )
    }
}
