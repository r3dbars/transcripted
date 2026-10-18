// DictationSessionCapTests.swift
// Guards the 15-minute dictation session cap: a session that hits the cap is
// finalized and saved (not discarded), pastes only when the original target is
// still active, and offers a recovery paste action otherwise.
//
// DictationSessionController pulls in the whole app and can't be instantiated in
// the fast runner, so these check the decisions it hands off to: the cap's
// finish action, the cap save's notice and telemetry, the stop routing, and the
// interruption offer.

import Foundation

func testDictationSessionCap() {
    // The cap path (finalizeWithoutPaste) never reaches the Auto Enter step.
    // This only checks the outcome it reports: a failed paste can't authorize
    // Auto Enter if it ever did.
    runSuite("A saved-without-paste outcome never allows Auto Enter") {
        assertTrue(TextPasteOutcome.pasted.allowsAutoSend, "a pasted delivery allows Auto Enter (control)")
        assertFalse(
            TextPasteOutcome.failed("saved without paste", reason: .unknown).allowsAutoSend,
            "a failed paste outcome must never allow Auto Enter"
        )
    }

    // The cap delivery is a genuine save, surfaced honestly — not the failure
    // case in disguise.
    runSuite("savedWithoutPaste delivery is a save, not a failure") {
        assertEqual(
            DictationDelivery.savedWithoutPaste.rawValue,
            "saved_without_paste",
            "cap saves should persist a distinct, truthful delivery value"
        )
        assertEqual(
            DictationDelivery.savedWithoutPaste.summaryText,
            "Saved only",
            "a cap save is a save, surfaced as 'Saved only'"
        )
        assertTrue(
            DictationDelivery.savedWithoutPaste != .failed,
            "cap saves must not be mislabeled as paste failures"
        )
    }

    runSuite("The session cap finalizes the take, pasting only when the original app is still in front") {
        assertEqual(
            DictationSessionCapFinish.action(isDictating: true, originalTargetIsFrontmost: true),
            .finalize(autoPaste: true),
            "the original target still in front gets the paste"
        )
        assertEqual(
            DictationSessionCapFinish.action(isDictating: true, originalTargetIsFrontmost: false),
            .finalize(autoPaste: false),
            "another app in front: save without pasting, never discard"
        )
        var checkedTarget = false
        assertEqual(
            DictationSessionCapFinish.action(
                isDictating: false,
                originalTargetIsFrontmost: { checkedTarget = true; return true }()
            ),
            .none,
            "a take that already stopped is left alone"
        )
        assertFalse(checkedTarget, "the frontmost app is only checked for a take still recording")
    }

    runSuite("A cap save is good news with a Paste It action, and a failed save is an error") {
        assertEqual(DictationSessionCapSavePolicy.delivery, .savedWithoutPaste, "the cap saves to Markdown as saved-without-paste")
        assertEqual(
            DictationSessionCapSavePolicy.presentation(saveFailureMessage: nil),
            .savedNotice(
                message: "Saved to Markdown. Paste it now, or find it later in Dictations.",
                actionTitle: "Paste It"
            ),
            "a saved cap take is a notice that says where the words are, not a warning"
        )
        assertEqual(
            DictationSessionCapSavePolicy.presentation(saveFailureMessage: "Couldn't save."),
            .error("Couldn't save."),
            "a failed save must not claim the words are saved"
        )
        assertEqual(DictationSessionCapSavePolicy.pasteItResult(.pasted), .pasted, "Paste It that landed says Pasted")
        assertEqual(DictationSessionCapSavePolicy.pasteItResult(.likelyPasted), .pasted, "a likely paste reads as pasted")
        assertEqual(
            DictationSessionCapSavePolicy.pasteItResult(.copied("On the clipboard.", reason: .focusChanged)),
            .error("On the clipboard."),
            "a Paste It that fell back to the clipboard says so"
        )
        assertEqual(
            DictationSessionCapSavePolicy.pasteItResult(.failed("Couldn't paste.", reason: .unknown)),
            .error("Couldn't paste."),
            "a failed Paste It shows why"
        )
    }

    runSuite("A Stop on a warming-up start, a busy take, or recovered audio each gets a visible answer") {
        assertEqual(
            DictationStopRoute.route(
                stopDecision: .cancelPendingStart, trigger: .physicalKey,
                isFinishingPreviousTake: false, isRecording: false, hasRecoverableRecording: false
            ),
            .cancelPendingStartAfterEarlyRelease,
            "a hotkey release during model or mic warmup explains that nothing was recorded"
        )
        assertEqual(
            DictationStopRoute.route(
                stopDecision: .cancelPendingStart, trigger: .keyboardShortcut,
                isFinishingPreviousTake: false, isRecording: false, hasRecoverableRecording: false
            ),
            .cancelPendingStart,
            "other triggers cancel the pending start"
        )
        assertEqual(
            DictationStopRoute.route(
                stopDecision: .ignoreInactive, trigger: .physicalKey,
                isFinishingPreviousTake: true, isRecording: false, hasRecoverableRecording: false
            ),
            .ignore(showStillFinishing: true),
            "a hotkey press while the last take transcribes visibly responds"
        )
        assertEqual(DictationStopRoute.stillFinishingMessage, "Still finishing the last dictation. Try again in a moment.")
        assertEqual(
            DictationStopRoute.route(
                stopDecision: .ignoreInactive, trigger: .physicalKey,
                isFinishingPreviousTake: false, isRecording: false, hasRecoverableRecording: false
            ),
            .ignore(showStillFinishing: false),
            "an idle stop is ignored quietly"
        )
        assertEqual(
            DictationStopRoute.route(
                stopDecision: .stopRecording, trigger: .physicalKey,
                isFinishingPreviousTake: false, isRecording: false, hasRecoverableRecording: true
            ),
            .stopRecording,
            "audio kept through device recovery goes on to transcription, not the mic-start failure"
        )
        assertEqual(
            DictationStopRoute.route(
                stopDecision: .stopRecording, trigger: .physicalKey,
                isFinishingPreviousTake: false, isRecording: false, hasRecoverableRecording: false
            ),
            .captureNotStarted,
            "no recording and nothing kept is the capture-not-started failure"
        )
        assertEqual(
            DictationStopRoute.route(
                stopDecision: .stopRecording, trigger: .physicalKey,
                isFinishingPreviousTake: false, isRecording: true, hasRecoverableRecording: false
            ),
            .stopRecording,
            "a live recording stops normally"
        )
    }

    runSuite("An interruption with kept audio offers to transcribe it without pasting") {
        let kept = DictationInterruptionPlan.make(hasRecoverableRecording: true)
        assertFalse(kept.cancelRecording, "the kept audio must survive until the action can transcribe it")
        assertEqual(kept.actionTitle, "Transcribe Captured Audio", "wake or device interruption offers a transcribe action")
        assertEqual(kept.action, .transcribeCapturedAudio(autoPaste: false), "it saves without pasting into a possibly changed app")

        let lost = DictationInterruptionPlan.make(hasRecoverableRecording: false)
        assertTrue(lost.cancelRecording, "with nothing kept, the recording is torn down")
        assertEqual(lost.action, .retryDictation, "with nothing kept, it offers a fresh dictation")
        assertEqual(lost.actionTitle, "Retry Dictation")
    }
}
