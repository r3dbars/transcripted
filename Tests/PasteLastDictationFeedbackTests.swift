func testPasteLastDictationFeedback() {
    runSuite("PasteLastDictationFeedback maps pasted outcome to short success copy") {
        let feedback = PasteLastDictationFeedback.presentation(for: .pasted)

        assertEqual(feedback.title, "Last dictation pasted", "pasted title")
        assertEqual(feedback.detail, "Text went to the focused app.", "pasted detail")
        assertEqual(feedback.tone, .success, "pasted tone")
        assertTrue(
            feedback.dismissDelayNanoseconds <= 2_000_000_000,
            "success feedback should clear quickly instead of lingering like a stuck state"
        )
    }

    runSuite("PasteLastDictationFeedback maps copied and failed outcomes to visible caution copy") {
        let copied = PasteLastDictationFeedback.presentation(
            for: .copied("Couldn't paste automatically. The text was copied instead.", reason: .pasteEventCreationFailed)
        )
        let failed = PasteLastDictationFeedback.presentation(
            for: .failed("Couldn't prepare the clipboard for automatic paste.")
        )

        assertEqual(copied.title, "Copied instead", "copied title")
        assertEqual(copied.detail, "Couldn't paste automatically. The text was copied instead.", "copied detail")
        assertEqual(copied.tone, .caution, "copied tone")
        assertEqual(failed.title, "Paste Last failed", "failed title")
        assertEqual(failed.detail, "Couldn't prepare the clipboard for automatic paste.", "failed detail")
        assertEqual(failed.tone, .caution, "failed tone")
        assertTrue(
            copied.dismissDelayNanoseconds >= 3_500_000_000 && failed.dismissDelayNanoseconds >= 3_500_000_000,
            "problem feedback should stay visible long enough to scan"
        )
    }

    runSuite("PasteLastDictationFeedback no-saved state replaces silent beep") {
        let feedback = PasteLastDictationFeedback.noSavedDictation

        assertEqual(feedback.title, "No saved dictation yet", "no saved title")
        assertEqual(feedback.detail, "Dictate once, then use Paste Last.", "no saved detail")
        assertEqual(feedback.tone, .caution, "no saved tone")
        assertEqual(
            feedback.accessibilityValue,
            "No saved dictation yet. Dictate once, then use Paste Last.",
            "notice should expose complete VoiceOver copy"
        )
    }
}
