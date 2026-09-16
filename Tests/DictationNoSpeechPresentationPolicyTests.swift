import Foundation

func testDictationNoSpeechPresentationPolicy() {
    runSuite("Undecoded captured audio offers import without claiming speech certainty") {
        let message = DictationNoSpeechPresentationPolicy.message(
            trigger: "physical_key",
            reason: .audioNeedsRecovery
        )
        assertTrue(message.contains("returned no words"), "an empty model result should be described honestly")
        assertTrue(message.contains("Capture → Transcribe Audio File"), "recovery should name the actual app menu command")
        assertFalse(message.contains("Home"), "do not send users to a page that is now labeled Meetings")
        assertFalse(message.contains("No speech heard"), "audio activity must not be dismissed as silence")
    }
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
