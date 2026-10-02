func testMenuBarPrimaryButtonTitle() {
    runSuite("MenuBarPrimaryButtonTitle shortens every title the two buttons can show") {
        let meetingTitles = [
            FirstRunExperience.meetingAction(dictationReady: true, meetingsStatus: "Ready").title,
            FirstRunExperience.meetingAction(dictationReady: true, meetingsStatus: "Ready", isRecording: true).title,
            FirstRunExperience.meetingAction(dictationReady: true, meetingsStatus: "Ready", isRecording: true, isSaving: true).title,
        ]
        assertEqual(
            meetingTitles.map(MenuBarPrimaryButtonTitle.short(for:)),
            ["Record", "Stop", "Saving…"],
            "meeting button titles should be short enough to share a row"
        )

        let dictationTitles = [
            FirstRunExperience.dictationAction(for: .ready).title,
            FirstRunExperience.dictationAction(for: .ready, isDictating: true).title,
        ]
        assertEqual(
            dictationTitles.map(MenuBarPrimaryButtonTitle.short(for:)),
            ["Dictate", "Done"],
            "dictation button titles should be short enough to share a row"
        )
    }

    runSuite("MenuBarPrimaryButtonTitle passes unknown titles through") {
        assertEqual(
            MenuBarPrimaryButtonTitle.short(for: "Something New"),
            "Something New",
            "a title without a short form should show as-is rather than blank"
        )
    }

    runSuite("MenuBarShortcutLabel falls back from a shortcut pair to its first key") {
        assertEqual(
            MenuBarShortcutLabel.candidates(for: "Fn / Right ⌥"),
            ["Fn / Right ⌥", "Fn"],
            "a two-trigger dictation shortcut should try the pair, then the push-to-talk key"
        )
        assertEqual(
            MenuBarShortcutLabel.candidates(for: "⌥M"),
            ["⌥M"],
            "a single shortcut has no shorter form"
        )
        assertEqual(
            MenuBarShortcutLabel.candidates(for: ""),
            [],
            "no shortcut means nothing to show"
        )
    }
}
