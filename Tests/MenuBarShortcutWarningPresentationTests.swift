func testMenuBarShortcutWarningPresentation() {
    let axMessage = "Accessibility permission needed for dictation shortcuts"
    let fnWarning = "Fn also opens the emoji picker"

    func resolve(_ hotkeyError: String?) -> MenuBarShortcutWarningPresentation? {
        MenuBarShortcutWarningPresentation.resolve(
            hotkeyError: hotkeyError,
            accessibilityErrorMessage: axMessage,
            functionKeyConflictWarning: fnWarning
        )
    }

    runSuite("MenuBarShortcutWarningPresentation — no warning shows nothing") {
        assertEqual(resolve(nil), nil, "no hotkey error should hide the warning row")
        assertEqual(resolve(""), nil, "an empty hotkey error should hide the warning row")
    }

    runSuite("MenuBarShortcutWarningPresentation — the Accessibility warning says what to do and opens the fix") {
        let accessibility = resolve(axMessage)
        assertEqual(accessibility?.action, .openAccessibilitySettings, "the Accessibility warning should open Accessibility settings")
        assertTrue(
            accessibility?.text.contains("Click to turn it on") == true,
            "the Accessibility warning should say clicking fixes it"
        )
    }

    runSuite("MenuBarShortcutWarningPresentation — the Fn conflict stays out of the menu") {
        assertEqual(
            resolve(fnWarning),
            nil,
            "the Fn conflict belongs in Settings > Shortcuts, not the menu bar menu"
        )
    }

    runSuite("MenuBarShortcutWarningPresentation — other warnings still show, without an action") {
        let other = resolve("Some other shortcut problem")
        assertEqual(other?.text, "Some other shortcut problem", "unknown warnings should show as-is")
        assertEqual(other?.action, nil, "unknown warnings should not pretend to open a fix")

        let noFnConflict = MenuBarShortcutWarningPresentation.resolve(
            hotkeyError: fnWarning,
            accessibilityErrorMessage: axMessage,
            functionKeyConflictWarning: nil
        )
        assertEqual(noFnConflict?.text, fnWarning, "without a live Fn conflict the same text is just another warning")
    }

    runSuite("A Secure Keyboard Entry notice occupies the header when there is no hotkey warning") {
        let notice = "Obsidian is blocking keyboard shortcuts (Secure Keyboard Entry)."
        let shown = MenuBarShortcutWarningPresentation.resolve(
            hotkeyWarning: nil,
            secureKeyboardEntryNotice: notice
        )
        assertEqual(shown?.text, notice, "the secure-input copy should appear as-is")
        assertEqual(shown?.action, nil, "there is no settings pane to open for another app's Secure Keyboard Entry")
        assertEqual(
            MenuBarShortcutWarningPresentation.resolve(
                hotkeyWarning: nil,
                secureKeyboardEntryNotice: nil
            ),
            nil,
            "no notice and no hotkey warning should hide the row"
        )
        assertEqual(
            MenuBarShortcutWarningPresentation.resolve(
                hotkeyWarning: nil,
                secureKeyboardEntryNotice: ""
            ),
            nil,
            "an empty notice should hide the row"
        )
    }

    runSuite("A hotkey warning wins over a Secure Keyboard Entry notice") {
        let hotkey = MenuBarShortcutWarningPresentation(
            text: "Shortcuts need Accessibility access. Click to turn it on.",
            action: .openAccessibilitySettings
        )
        let shown = MenuBarShortcutWarningPresentation.resolve(
            hotkeyWarning: hotkey,
            secureKeyboardEntryNotice: "Obsidian is blocking keyboard shortcuts (Secure Keyboard Entry)."
        )
        assertEqual(shown, hotkey, "the tap has to work at all before Secure Keyboard Entry matters")
    }

    runSuite("A suppressed Fn conflict still lets a Secure Keyboard Entry notice through") {
        assertEqual(resolve(fnWarning), nil, "setup: Fn stays out of the menu")
        let notice = "Obsidian is blocking keyboard shortcuts (Secure Keyboard Entry)."
        let shown = MenuBarShortcutWarningPresentation.resolve(
            hotkeyWarning: resolve(fnWarning),
            secureKeyboardEntryNotice: notice
        )
        assertEqual(shown?.text, notice, "hiding the Fn conflict must not hide a live Secure Keyboard Entry block")
    }
}
