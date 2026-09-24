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

    runSuite("DictationEscapeCancelPolicy cancels at once before much audio exists") {
        assertEqual(
            DictationEscapeCancelPolicy.decision(capturedSeconds: nil, secondsSinceFirstPress: nil),
            .cancel,
            "Esc before the mic starts recording should cancel straight away"
        )
        assertEqual(
            DictationEscapeCancelPolicy.decision(capturedSeconds: 4.9, secondsSinceFirstPress: nil),
            .cancel,
            "a short take has little to lose, so one Esc cancels"
        )
    }

    runSuite("DictationEscapeCancelPolicy asks before discarding a long take") {
        assertEqual(
            DictationEscapeCancelPolicy.decision(capturedSeconds: 240, secondsSinceFirstPress: nil),
            .askToConfirm,
            "a stray Esc must not silently throw away a long hands-free dictation"
        )
        assertEqual(
            DictationEscapeCancelPolicy.decision(capturedSeconds: 240, secondsSinceFirstPress: 1.2),
            .cancel,
            "a second Esc inside the window confirms the discard"
        )
        assertEqual(
            DictationEscapeCancelPolicy.decision(capturedSeconds: 240, secondsSinceFirstPress: 3.5),
            .askToConfirm,
            "an Esc long after the first one asks again instead of discarding"
        )
        assertEqual(
            DictationEscapeCancelPolicy.decision(capturedSeconds: 240, secondsSinceFirstPress: -1),
            .askToConfirm,
            "a clock that went backwards never counts as a confirm"
        )
        assertEqual(
            DictationEscapeCancelPolicy.confirmNotice,
            "Press Esc again to discard",
            "the confirm prompt says what the second press does"
        )
    }
}
