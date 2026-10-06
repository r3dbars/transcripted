import Foundation

// Behavior tests for what a dictation take with no text does
// (Sources/Dictation/DictationEmptyTranscriptPolicy.swift). These replace
// source-text checks that read the branch order out of DictationSessionController.

func testDictationEmptyTranscriptPolicy() {
    let quickPress: TimeInterval = 0.3
    let longPress: TimeInterval = 4
    let longTake: TimeInterval = 45

    func decide(
        _ reason: DictationEmptyTranscriptionReason,
        press: TimeInterval = 4,
        heldText: Bool = false,
        saved: Bool = false,
        inMemory: Bool = false
    ) -> DictationEmptyTranscriptPolicy.Decision {
        DictationEmptyTranscriptPolicy.decide(
            reason: reason,
            pressDuration: press,
            hasHeldBackText: heldText,
            hasSavedRecording: saved,
            audioStillInMemory: inMemory
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

        let nothingHeld = decide(.otherLanguage, press: longTake, heldText: false, saved: true)
        assertEqual(nothingHeld.action, .offerSavedRecording,
                    "without held-back text, a long take falls back to the saved recording")
    }

    runSuite("A long take's saved recording is offered and kept") {
        for reason in [DictationEmptyTranscriptionReason.modelFailure, .audioNeedsRecovery] {
            let decision = decide(reason, press: longTake, saved: true)
            assertEqual(decision.action, .offerSavedRecording, "\(reason.rawValue): a long take is hard to say again, so offer Transcribe It")
            assertFalse(decision.discardsSavedRecording, "\(reason.rawValue): the long take's audio is kept while it's offered")
        }
        let atThreshold = decide(.audioNeedsRecovery, press: DictationFailedTakePolicy.minimumLengthToKeep, saved: true)
        assertEqual(atThreshold.action, .offerSavedRecording, "exactly the minimum length counts as long")
    }

    runSuite("A short take's saved recording is dropped with the error") {
        let justUnder = DictationFailedTakePolicy.minimumLengthToKeep - 0.1
        for reason in [DictationEmptyTranscriptionReason.modelFailure, .audioNeedsRecovery, .otherLanguage] {
            for press in [longPress, justUnder] {
                let decision = decide(reason, press: press, saved: true)
                assertEqual(decision.action, .showMessage, "\(reason.rawValue) after \(press) s: say why, no Transcribe It")
                assertTrue(decision.discardsSavedRecording, "\(reason.rawValue) after \(press) s: saying it again beats recovering it")
                assertFalse(decision.countsAsCancelled, "\(reason.rawValue): still a give-up, not a cancel")
            }
        }
    }

    runSuite("Audio that needs recovery with no saved WAV offers the checkpoint retry") {
        let decision = decide(.audioNeedsRecovery, saved: false)
        assertEqual(decision.action, .offerCheckpointRetry, "don't call it empty speech when the audio just isn't saved")
    }

    runSuite("Anything else just says why") {
        assertEqual(decide(.modelFailure, saved: false).action, .showMessage, "a model failure with nothing saved")
        assertEqual(decide(.otherLanguage).action, .showMessage, "a language guess with nothing held and nothing saved")
    }

    runSuite("A short take the model never consumed keeps its WAV, so memory audio can't block the next take") {
        for reason in [DictationEmptyTranscriptionReason.modelFailure, .audioNeedsRecovery] {
            let decision = decide(reason, saved: true, inMemory: true)
            assertEqual(decision.action, .showMessage, "\(reason.rawValue): still no Transcribe It for a short take")
            assertFalse(decision.discardsSavedRecording,
                        "\(reason.rawValue): audio in memory with no WAV would refuse the next take and Quit")
            assertFalse(
                DictationTerminationAdmissionPolicy.blocksNewCapture(
                    hasRecoverableRecording: true,
                    recoveryWAVExists: !decision.discardsSavedRecording
                ),
                "\(reason.rawValue): keeping the WAV lets the next take start"
            )
        }
    }

    runSuite("Silence, a too-short take, or a short failed take drops the saved audio; a long one keeps it") {
        for reason in [DictationEmptyTranscriptionReason.modelFailure, .audioNeedsRecovery, .otherLanguage] {
            assertFalse(decide(reason, press: longTake, saved: true).discardsSavedRecording,
                        "\(reason.rawValue) from a long take keeps its audio for Transcribe It")
            assertFalse(decide(reason, saved: false).discardsSavedRecording,
                        "\(reason.rawValue) with nothing saved has nothing to drop")
        }
        assertTrue(decide(.noSpeech).discardsSavedRecording, "silence isn't kept")
        assertTrue(decide(.recordingTooShort).discardsSavedRecording, "a too-short take isn't kept")
        assertTrue(decide(.audioNeedsRecovery, saved: true).discardsSavedRecording, "a short failed take isn't kept")
        assertFalse(decide(.otherLanguage, heldText: true, saved: true).discardsSavedRecording,
                    "Paste Anyway keeps the audio even for a short take, in case the guess was wrong")
    }

    runSuite("Only a mis-tap counts as cancelled") {
        for reason in [DictationEmptyTranscriptionReason.noSpeech, .recordingTooShort, .modelFailure, .audioNeedsRecovery, .otherLanguage] {
            assertFalse(decide(reason, press: longPress).countsAsCancelled, "\(reason.rawValue) from a long press is a give-up")
        }
    }
}
