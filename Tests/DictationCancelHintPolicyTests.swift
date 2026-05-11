func testDictationCancelHintPolicy() {
    runSuite("DictationCancelHintPolicy shows active dictation shortcut hints") {
        let hint = DictationCancelHintPolicy.shortcutHint(
            dictationShortcutsEnabled: true,
            pushToTalkDisplay: "Right Option",
            handsFreeDisplay: "Control Space"
        )

        assertEqual(
            hint,
            "Right Option / Control Space",
            "enabled dictation shortcuts should stay visible as cancel hints"
        )
        assertEqual(
            DictationCancelHintPolicy.cancelHintText(for: hint),
            "Cancel: Right Option / Control Space",
            "starting/loading overlays should label active cancel shortcuts"
        )
    }

    runSuite("DictationCancelHintPolicy hides disabled dictation shortcut hints") {
        let hint = DictationCancelHintPolicy.shortcutHint(
            dictationShortcutsEnabled: false,
            pushToTalkDisplay: "Right Option",
            handsFreeDisplay: "Control Space"
        )

        assertEqual(
            hint,
            "",
            "disabled dictation shortcuts should not appear usable in the overlay"
        )
        assertEqual(
            DictationCancelHintPolicy.cancelHintText(for: hint),
            "",
            "starting/loading overlays should not show an empty Cancel label"
        )
    }
}
