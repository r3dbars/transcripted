func testMenuBarShortcutWarningPresentation() {
    let axMessage = "Accessibility permission needed for dictation shortcuts"
    let fnWarning = "Fn also opens the emoji picker"

    func resolve(_ hotkeyError: String?) -> MenuBarShortcutWarningPresentation? {
        MenuBarShortcutWarningPresentation.resolve(
            hotkeyError: hotkeyError,
            accessibilityErrorMessage: axMessage,
            functionKeyConflictWarning: fnWarning,
            functionKeySystemActionTitle: "Show Emoji & Symbols"
        )
    }

    runSuite("MenuBarShortcutWarningPresentation — no warning shows nothing") {
        assertEqual(resolve(nil), nil, "no hotkey error should hide the warning row")
        assertEqual(resolve(""), nil, "an empty hotkey error should hide the warning row")
    }

    runSuite("MenuBarShortcutWarningPresentation — known warnings say what to do and open the fix") {
        let accessibility = resolve(axMessage)
        assertEqual(accessibility?.action, .openAccessibilitySettings, "the Accessibility warning should open Accessibility settings")
        assertTrue(
            accessibility?.text.contains("Click to turn it on") == true,
            "the Accessibility warning should say clicking fixes it"
        )

        let fn = resolve(fnWarning)
        assertEqual(fn?.action, .openKeyboardSettings, "the Fn conflict should open Keyboard settings")
        assertTrue(
            fn?.text.contains("Show Emoji & Symbols") == true,
            "the Fn warning should name what macOS does with Fn"
        )
        assertTrue(
            fn?.text.contains("Do Nothing") == true,
            "the Fn warning should name the setting to pick"
        )
    }

    runSuite("MenuBarShortcutWarningPresentation — other warnings still show, without an action") {
        let other = resolve("Some other shortcut problem")
        assertEqual(other?.text, "Some other shortcut problem", "unknown warnings should show as-is")
        assertEqual(other?.action, nil, "unknown warnings should not pretend to open a fix")

        let noFnConflict = MenuBarShortcutWarningPresentation.resolve(
            hotkeyError: fnWarning,
            accessibilityErrorMessage: axMessage,
            functionKeyConflictWarning: nil,
            functionKeySystemActionTitle: "Show Emoji & Symbols"
        )
        assertEqual(noFnConflict?.action, nil, "without a live Fn conflict the same text should not open Keyboard settings")
    }
}
