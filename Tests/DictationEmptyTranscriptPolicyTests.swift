import Foundation

// Behavior tests for what a dictation take with no text does
// (Sources/Dictation/DictationEmptyTranscriptPolicy.swift). These replace
// source-text checks that read the branch order out of DictationSessionController.

func testDictationEmptyTranscriptPolicy() {
    let quickPress: TimeInterval = 0.3
    let longPress: TimeInterval = 4

    func decide(
        _ reason: DictationEmptyTranscriptionReason,
        press: TimeInterval = 4,
        heldText: Bool = false,
        saved: Bool = false
    ) -> DictationEmptyTranscriptPolicy.Decision {
        DictationEmptyTranscriptPolicy.decide(
            reason: reason,
            pressDuration: press,
            hasHeldBackText: heldText,
            hasSavedRecording: saved
        )
    }

    runSuite("A quick, too-short press closes like a cancel and counts as cancelled") {
        let decision = decide(.recordingTooShort, press: quickPress, saved: true)
        assertEqual(decision.action, .closeLikeCancel, "a mis-tap shows no error text to dismiss")
        assertTrue(decision.countsAsCancelled, "friction telemetry counts a mis-tap as cancelled, not a give-up")
        assertTrue(decision.discardsSavedRecording, "a mis-tap's audio isn't worth keeping")
    }

    runSuite("A too-short recording from a long press is not a mis-tap") {
        let decision = decide(.recordingTooShort, press: longPress)
        assertEqual(decision.action, .showNoSpeechAndDismiss, "held the key but said almost nothing: a real no-speech result")
        assertFalse(decision.countsAsCancelled, "that's a give-up, not a cancel")
    }

    runSuite("No speech shows the note and drops the audio") {
        let decision = decide(.noSpeech, saved: true)
        assertEqual(decision.action, .showNoSpeechAndDismiss, "no speech wins over offering the saved recording")
        assertTrue(decision.discardsSavedRecording, "silent audio isn't kept")
    }

    runSuite("A wrong-language guess with held-back text offers Paste Anyway and keeps the audio") {
        let decision = decide(.otherLanguage, heldText: true, saved: true)
        assertEqual(decision.action, .offerPasteAnyway, "the check can be wrong, so the text is one press away")
        assertFalse(decision.discardsSavedRecording, "the audio stays in case the guess was wrong")

        let nothingHeld = decide(.otherLanguage, heldText: false, saved: true)
        assertEqual(nothingHeld.action, .offerSavedRecording(remindAtLaunch: false),
                    "without held-back text, fall back to the saved recording")
    }

    runSuite("A saved recording is offered for another try") {
        let modelFailed = decide(.modelFailure, saved: true)
        assertEqual(modelFailed.action, .offerSavedRecording(remindAtLaunch: false), "the audio is saved, so offer to transcribe it again")
        assertFalse(modelFailed.discardsSavedRecording, "the saved audio is kept")

        let heardNothing = decide(.audioNeedsRecovery, saved: true)
        assertEqual(heardNothing.action, .offerSavedRecording(remindAtLaunch: true),
                    "audio the model heard nothing in keeps its launch reminder")
    }

    runSuite("Audio that needs recovery with no saved WAV offers the checkpoint retry") {
        let decision = decide(.audioNeedsRecovery, saved: false)
        assertEqual(decision.action, .offerCheckpointRetry, "don't call it empty speech when the audio just isn't saved")
    }

    runSuite("Anything else just says why") {
        assertEqual(decide(.modelFailure, saved: false).action, .showMessage, "a model failure with nothing saved")
        assertEqual(decide(.otherLanguage).action, .showMessage, "a language guess with nothing held and nothing saved")
    }

    runSuite("Only a mis-tap counts as cancelled") {
        for reason in [DictationEmptyTranscriptionReason.noSpeech, .recordingTooShort, .modelFailure, .audioNeedsRecovery, .otherLanguage] {
            assertFalse(decide(reason, press: longPress).countsAsCancelled, "\(reason.rawValue) from a long press is a give-up")
        }
    }
}
