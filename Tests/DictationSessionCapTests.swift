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

    // Source contract: the cap must finalize-and-save, not discard, and the
    // suppressed-paste finalize path must persist without pasting.
    runSuite("The session cap finalizes and saves instead of discarding") {
        let source = dictationControllerSource()

        let timeoutBody = capSlice(
            source,
            from: "func installSessionTimeout()",
            to: "private func overlayStateName"
        )
        assertTrue(
            timeoutBody.contains("stopDictationAndPaste(trigger: .sessionCap, autoPaste: false)"),
            "the session cap should finalize-and-save with auto-paste suppressed"
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
            finalizeBody.contains("ActivationTelemetry.trackDictationArtifactSaved("),
            "the cap finalize path should count successful session-cap saves as dictation artifacts"
        )
        assertFalse(
            finalizeBody.contains("pasteWithClipboardRestore"),
            "the cap finalize path must not paste into the focused app"
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
