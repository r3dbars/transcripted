// DictationSessionCapTests.swift
// Guards the 5-minute dictation session cap: a session that hits the cap is
// finalized and saved (not discarded), and is never auto-pasted / auto-sent
// into whatever app happens to hold focus when the user walked away.
//
// DictationSessionController pulls in the whole app and can't be instantiated in
// the fast runner, so this pairs behavioral checks on the pure policy / delivery
// types with a source-level contract on the controller wiring.

import Foundation

func testDictationSessionCap() {
    // The cap's whole point: recover the work without injecting it anywhere.
    // DictationAutoSendPolicy gates auto-send on `delivery == .pasted`, so the
    // session-cap delivery can never auto-send — even with every other condition
    // satisfied.
    runSuite("A session-cap save can never auto-send into the focused app") {
        let allowed: Set<String> = ["com.example.editor"]
        let satisfiedDuration = TranscriptedConstants.dictationAutoEnterMinimumDuration + 1

        // Control: a normal pasted delivery with everything satisfied DOES send.
        assertTrue(
            DictationAutoSendPolicy.shouldSend(
                isEnabled: true,
                delivery: .pasted,
                text: "ship the release notes",
                duration: satisfiedDuration,
                sourceBundleID: "com.example.editor",
                allowedBundleIDs: allowed
            ),
            "a pasted delivery in an allowed app should auto-send (control)"
        )

        // The cap delivery must NOT send, with otherwise-identical inputs.
        assertFalse(
            DictationAutoSendPolicy.shouldSend(
                isEnabled: true,
                delivery: .savedWithoutPaste,
                text: "ship the release notes",
                duration: satisfiedDuration,
                sourceBundleID: "com.example.editor",
                allowedBundleIDs: allowed
            ),
            "a session-cap save must never auto-send into the focused app"
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

    // Source contract: the cap must finalize-and-save, not discard. It may
    // paste only when the original paste target still owns focus; otherwise it
    // uses the suppressed-paste finalize path.
    runSuite("The session cap warns, then pastes only when the original target is still active") {
        let source = dictationControllerSource()

        let timeoutBody = capSlice(
            source,
            from: "func installSessionTimeout()",
            to: "private func overlayStateName"
        )
        assertTrue(
            timeoutBody.contains("title: \"Long dictation\"")
                && timeoutBody.contains("30 seconds left"),
            "the session cap should warn before it auto-finalizes"
        )
        assertTrue(
            timeoutBody.contains("let shouldAutoPaste = self.sessionPasteTarget?.matchesCurrentFrontmostApp() ?? false"),
            "the session cap should only paste when the original target still matches the frontmost app"
        )
        assertTrue(
            timeoutBody.contains("stopDictationAndPaste(trigger: .sessionCap, autoPaste: shouldAutoPaste)"),
            "the session cap should route the target-match decision into the normal stop pipeline"
        )
        assertFalse(
            timeoutBody.contains("cancelDictation()"),
            "the session cap must not discard the buffer via cancelDictation()"
        )

        let finalizeBody = capSlice(
            source,
            from: "private func finalizeWithoutPaste(",
            to: "/// Cancel dictation without pasting"
        )
        assertTrue(
            finalizeBody.contains("persistDictationTranscript(text: text, delivery: .savedWithoutPaste)"),
            "the cap finalize path should persist the transcript to the daily Markdown file"
        )
        assertTrue(
            finalizeBody.contains("overlayController.showSuccessAndDismiss(title: DictationDelivery.savedWithoutPaste.summaryText)"),
            "the cap confirmation should say Saved only instead of reusing the pasted success label"
        )
        let headerBody = try? String(
            contentsOf: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Sources/UI/Overlay/OverlayHeaderView.swift"),
            encoding: .utf8
        )
        assertTrue(
            headerBody?.contains("return \"Dictation saved only\"") == true
                && headerBody?.contains("return \"Text saved without paste\"") == true,
            "the save-only confirmation should also have truthful VoiceOver copy"
        )
        assertTrue(
            finalizeBody.contains("ActivationTelemetry.trackDictationArtifactSaved("),
            "the cap finalize path should count successful session-cap saves as dictation artifacts"
        )
        assertFalse(
            finalizeBody.contains("pasteWithClipboardRestore"),
            "the cap finalize path must not paste into the focused app"
        )
    }

    runSuite("Dictation stop path preserves recovered audio and surfaces invisible hotkey states") {
        let source = dictationControllerSource()
        let stopBody = capSlice(
            source,
            from: "func stopDictationAndPaste(",
            to: "/// Finalize a dictation"
        )

        assertTrue(
            stopBody.contains("cancelPendingDictationStartAfterEarlyRelease"),
            "a push-to-talk release during model/mic warmup should show a clear no-audio message instead of a generic cancel animation"
        )
        assertTrue(
            stopBody.contains("Still finishing the last dictation. Try again in a moment."),
            "a hotkey press during the drafting/transcribing window should visibly respond"
        )
        assertTrue(
            stopBody.contains("let hasRecoverableRecording = appState.sttRouter.hasRecoverableRecording"),
            "stop during device recovery should detect preserved recovered audio"
        )
        assertTrue(
            stopBody.contains("guard appState.sttRouter.isRecording || hasRecoverableRecording else"),
            "a recovered timeline should continue into transcription instead of taking the mic-start failure path"
        )
    }

    runSuite("Dictation interruption offers preserved captured audio for transcription") {
        let source = dictationControllerSource()
        let interruptionBody = capSlice(
            source,
            from: "private func handleDictationInterruption()",
            to: "private func shouldOfferMicrophoneRecoveryAction"
        )

        assertTrue(
            interruptionBody.contains("hasRecoverableRecording"),
            "interruption UI should branch when the speech engine has retained audio"
        )
        assertTrue(
            interruptionBody.contains("Transcribe Captured Audio"),
            "wake/device interruption with preserved audio should offer a transcribe action"
        )
        assertTrue(
            interruptionBody.contains("cancelActiveTasks(cancelRecording: !hasRecoverableRecording)"),
            "preserved-audio interruptions should not clear the recovered timeline before the action can transcribe it"
        )
        assertTrue(
            interruptionBody.contains("stopDictationAndPaste(trigger: .unknown, autoPaste: false)"),
            "the recovered-audio action should save safely without pasting into a possibly changed app"
        )
    }
}

private func dictationControllerSource() -> String {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("Sources/UI/Overlay/DictationSessionController.swift")
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

private func capSlice(_ contents: String, from start: String, to end: String) -> String {
    guard let startRange = contents.range(of: start) else { return "" }
    let tail = contents[startRange.upperBound...]
    guard let endRange = tail.range(of: end) else { return String(tail) }
    return String(tail[..<endRange.lowerBound])
}
