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
}
