import Foundation

// Behavioral coverage for the Writing tab's copy and rules
// (Sources/UI/Settings/Writing/WritingSetupPresentation.swift). The copy
// suites pin docs/writing-plan.md's approved design word for word.

func testWritingSetupPresentation() {
    typealias Copy = WritingSetupPresentation

    runSuite("Writing intro page 1 uses the approved copy") {
        assertEqual(Copy.IntroPage1.smallTitle, "Writing")
        assertEqual(Copy.IntroPage1.headline, "Your AI knows what you said. Not what you wrote.")
        assertEqual(
            Copy.IntroPage1.body,
            "Transcripted already saves your meetings and dictations. But a lot of your work happens in writing: Slack replies, emails, notes. Writing in Transcripted adds that context, and helps you write faster."
        )
        assertEqual(Copy.IntroPage1.contextLabel, "Your context")
        assertEqual(Copy.IntroPage1.contextItems.map(\.title), ["Meetings", "Dictations", "Writing"])
        assertEqual(
            Copy.IntroPage1.contextItems.map(\.isAdded),
            [false, false, true],
            "Meetings and Dictations are checked; only Writing is the highlighted add"
        )
        assertEqual(
            Copy.IntroPage1.points.map(\.title),
            ["Fuller context for your AI.", "You're in control.", "100% local."]
        )
        assertEqual(
            Copy.IntroPage1.points.map(\.line),
            [
                "Your notes and replies sit next to your meetings, so your AI can pick up where you left off.",
                "Pick the apps. Pause or delete anytime.",
                "No account. Your writing never leaves your Mac. It's saved as plain files you can point any AI agent at.",
            ]
        )
        assertEqual(Copy.IntroPage1.next, "Next")
        assertEqual(Copy.introPageCount, 2)
    }

    runSuite("Writing intro page 2 uses the approved copy and key hints") {
        assertEqual(Copy.IntroPage2.headline, "Autocomplete finishes your sentences.")
        assertEqual(
            Copy.IntroPage2.body,
            "As you type, Transcripted suggests the next few words right where you're typing. Take them or leave them."
        )
        assertEqual(Copy.IntroPage2.keyHints.map(\.key), ["Tab", "~", nil, "Esc"])
        assertEqual(
            Copy.IntroPage2.keyHints.map(\.text),
            ["adds the next word", "takes the whole suggestion", "Keep typing to ignore it", "hides it"]
        )
        assertFalse(
            Copy.IntroPage2.keyHints.contains { $0.text.contains("above Tab") },
            "the ~ key is not 'the key above Tab' on ISO keyboards"
        )
        assertEqual(Copy.IntroPage2.back, "Back")
        assertEqual(Copy.IntroPage2.setUp, "Set up writing")
    }

    runSuite("Writing copy says what you wrote, never what you typed") {
        let allCopy = [
            Copy.IntroPage1.headline, Copy.IntroPage1.body,
            Copy.Step1.saveLine, Copy.nothingSavedYet, Copy.deleteConfirmMessage,
        ] + Copy.IntroPage1.points.map(\.line)
        for line in allCopy {
            assertFalse(line.contains("what you typed"), "keylogger wording: \(line)")
        }
    }

    runSuite("Writing setup steps use the approved copy") {
        assertEqual(Copy.stepLabel(1), "Step 1 of 3")
        assertEqual(Copy.Step1.title, "What should writing do?")
        assertEqual(Copy.Step1.saveTitle, "Save my writing")
        assertEqual(Copy.Step1.saveLine, "Your AI can read what you wrote. Files stay on this Mac, only in apps you choose.")
        assertEqual(Copy.Step1.autocompleteTitle, "Autocomplete")
        assertEqual(Copy.Step1.autocompleteLine, "Suggests the next words. Hit Tab to accept.")
        assertEqual(Copy.Step1.continueTitle, "Continue")
        assertEqual(Copy.Step1.needsOne, "Turn on at least one to continue.")

        assertEqual(Copy.Step2.title, "Which apps?")
        assertEqual(Copy.Step2.allApps, "All apps")
        assertEqual(Copy.Step2.allAppsLine, "Password managers are always skipped.")
        assertEqual(Copy.Step2.pickedApps, "Only apps I pick")
        assertEqual(Copy.Step2.sameApps, "Autocomplete uses the same apps.")
        assertEqual(Copy.Step2.needsOne, "Pick at least one app.")

        assertEqual(Copy.Step3.title, "Allow and download")
        assertEqual(Copy.Step3.keyboardTitle, "Transcripted keyboard")
        assertEqual(Copy.Step3.keyboardLine, "You add it in Keyboard settings. No privacy prompt.")
        assertEqual(Copy.Step3.screenRecordingTitle, "Screen Recording")
        assertEqual(Copy.Step3.screenRecordingLine, "Reads the window you're replying in, on this Mac.")
        assertEqual(Copy.Step3.modelTitle, "Model")
        assertEqual(Copy.Step3.autocompleteBadge, "Autocomplete")
        assertEqual(Copy.Step3.qwenIneligible, "Your Mac needs 16 GB of memory for this model.")
        assertEqual(Copy.Step3.footnote, "Suggestion counts only, never text. Follows your analytics setting.")
        assertEqual(Copy.Step3.turnOn, "Turn on writing")
        assertEqual(Copy.back, "Back")
        assertEqual(Copy.finishRecordingFirst, "Finish recording and transcribing first")
    }

    runSuite("Writing step 3 shows only the rows the step 1 toggles need") {
        assertEqual(Copy.step3Rows(saveMyWriting: true, autocomplete: true), [.keyboard, .screenRecording, .model])
        assertEqual(
            Copy.step3Rows(saveMyWriting: true, autocomplete: false),
            [.keyboard],
            "Save my writing needs no Screen Recording and no model download"
        )
        assertEqual(Copy.step3Rows(saveMyWriting: false, autocomplete: true), [.keyboard, .screenRecording, .model])
        assertEqual(Copy.step3Rows(saveMyWriting: false, autocomplete: false), [])
    }

    // macOS 26 ignores an app's TISEnableInputSource, so the keyboard row
    // tells the user what to do instead of claiming it turned on.
    runSuite("Writing keyboard row gives the steps for where the keyboard stands") {
        assertEqual(
            Copy.keyboardStep(.needsUserToAdd),
            Copy.KeyboardStep(
                line: "Add Transcripted in Keyboard settings: Input Sources › Edit… › +, then English › Transcripted.",
                buttonTitle: "Open Keyboard Settings",
                isDone: false
            )
        )
        assertEqual(
            Copy.keyboardStep(.needsRelogin),
            Copy.KeyboardStep(
                line: "macOS lists new keyboards after you log out and back in. Log out, then add Transcripted in Keyboard settings.",
                buttonTitle: "Open Keyboard Settings",
                isDone: false
            )
        )
        assertEqual(
            Copy.keyboardStep(.enabledNotSelected),
            Copy.KeyboardStep(
                line: "Choose Transcripted from the input menu in the menu bar.",
                buttonTitle: nil,
                isDone: false
            ),
            "an added keyboard only needs picking from the input menu; Keyboard settings wouldn't help"
        )
        assertEqual(
            Copy.keyboardStep(.selected),
            Copy.KeyboardStep(line: "You add it in Keyboard settings. No privacy prompt.", buttonTitle: nil, isDone: true)
        )
        assertEqual(
            Copy.keyboardStep(nil),
            Copy.KeyboardStep(line: "You add it in Keyboard settings. No privacy prompt.", buttonTitle: nil, isDone: false),
            "before the keyboard is installed, step 3 shows the plain line"
        )
        assertEqual(
            Copy.everydayKeyboardStep(nil),
            Copy.keyboardStep(.needsUserToAdd),
            "after setup, a keyboard that isn't installed gets the add steps and the button"
        )
        assertEqual(Copy.everydayKeyboardStep(.needsRelogin), Copy.keyboardStep(.needsRelogin))
        let guidance = [
            Copy.KeyboardGuidance.needsUserToAdd,
            Copy.KeyboardGuidance.needsRelogin,
            Copy.KeyboardGuidance.enabledNotSelected,
        ]
        assertFalse(
            guidance.contains { $0.contains("Turns on") || $0.contains("!") },
            "the guidance never claims the app turned the keyboard on, and stays plain"
        )
    }

    runSuite("Writing keyboard badge says Both only when both features use it") {
        assertEqual(Copy.keyboardBadge(saveMyWriting: true, autocomplete: true), "Both")
        assertEqual(Copy.keyboardBadge(saveMyWriting: true, autocomplete: false), "Needed")
        assertEqual(Copy.keyboardBadge(saveMyWriting: false, autocomplete: true), "Needed")
    }

    runSuite("Writing setup validation") {
        assertNil(Copy.step1Message(saveMyWriting: true, autocomplete: false))
        assertNil(Copy.step1Message(saveMyWriting: false, autocomplete: true))
        assertEqual(Copy.step1Message(saveMyWriting: false, autocomplete: false), "Turn on at least one to continue.")
        assertNil(Copy.step2Message(scope: .all, pickedCount: 0), "all apps needs no picks")
        assertEqual(Copy.step2Message(scope: .picked, pickedCount: 0), "Pick at least one app.")
        assertNil(Copy.step2Message(scope: .picked, pickedCount: 1))

        var draft = Copy.Draft()
        assertTrue(draft.saveMyWriting && draft.autocomplete, "both toggles start on")
        assertEqual(draft.scope, .all, "setup starts on all apps")
        assertEqual(draft.model, .gemma4E2B, "Gemma is the default model")
        assertTrue(draft.canContinueStep1 && draft.canContinueStep2)
        draft.saveMyWriting = false
        draft.autocomplete = false
        assertFalse(draft.canContinueStep1)
        draft.autocomplete = true
        draft.scope = .picked
        assertFalse(draft.canContinueStep2)
        draft.pickedBundleIdentifiers = ["com.apple.Notes"]
        assertTrue(draft.canContinueStep2)
    }

    runSuite("Writing model options match the approved sizes and eligibility line") {
        assertEqual(Copy.modelOptions.map(\.choice), [.gemma4E2B, .qwen35B9B])
        assertEqual(Copy.modelOptions.map(\.name), ["Gemma 4 E2B", "Qwen 3.5 9B"])
        assertEqual(Copy.modelOptions.map(\.detail), ["3.4 GB, faster", "5.6 GB, better"])
        assertEqual(Copy.modelOptions.map(\.isDefault), [true, false])
        assertEqual(Copy.defaultTag, "(default)")
        assertNil(Copy.ineligibleLine(for: .qwen35B9B, isEligible: true))
        assertEqual(
            Copy.ineligibleLine(for: .qwen35B9B, isEligible: false),
            "Your Mac needs 16 GB of memory for this model."
        )
    }

    runSuite("Writing app chips lead with the preferred apps when installed") {
        let apps = [
            Copy.AppChoice(bundleIdentifier: "com.example.zebra", name: "Zebra"),
            Copy.AppChoice(bundleIdentifier: "com.linear", name: "Linear"),
            Copy.AppChoice(bundleIdentifier: "com.apple.mail", name: "Mail"),
            Copy.AppChoice(bundleIdentifier: "com.example.alpha", name: "alpha"),
            Copy.AppChoice(bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack"),
            Copy.AppChoice(bundleIdentifier: "com.apple.Notes", name: "Notes"),
            Copy.AppChoice(bundleIdentifier: "com.apple.notes", name: "Notes duplicate"),
        ]
        assertEqual(
            Copy.orderedApps(apps).map(\.name),
            ["Slack", "Notes", "Mail", "Linear", "alpha", "Zebra"],
            "Slack, Notes, Mail, Messages, Chrome, Notion, Linear first (those installed), then by name; duplicates dropped"
        )
        assertEqual(
            Copy.preferredBundleIdentifiers,
            [
                "com.tinyspeck.slackmacgap", "com.apple.Notes", "com.apple.mail", "com.apple.MobileSMS",
                "com.google.Chrome", "notion.id", "com.linear",
            ]
        )

        let many = (0..<20).map { Copy.AppChoice(bundleIdentifier: "com.example.app\($0)", name: String(format: "App %02d", $0)) }
        let collapsed = Copy.visibleApps(ordered: many, picked: ["com.example.app19"], showAll: false)
        assertEqual(collapsed.count, Copy.collapsedAppCount + 1, "collapsed shows the first chips plus a pick further down")
        assertEqual(collapsed.last?.bundleIdentifier, "com.example.app19")
        assertEqual(Copy.visibleApps(ordered: many, picked: [], showAll: true).count, 20)
        assertEqual(Copy.visibleApps(ordered: Array(many.prefix(5)), picked: [], showAll: false).count, 5)
    }

    runSuite("Writing everyday summary") {
        assertEqual(Copy.summary(saveMyWriting: true, autocomplete: true, wordsToday: 42), "42 words today")
        assertEqual(Copy.summary(saveMyWriting: true, autocomplete: false, wordsToday: 1), "1 word today")
        assertEqual(Copy.summary(saveMyWriting: true, autocomplete: true, wordsToday: 0), "0 words today")
        assertEqual(Copy.summary(saveMyWriting: false, autocomplete: true, wordsToday: 12), "Autocomplete only")
        assertEqual(Copy.summary(saveMyWriting: false, autocomplete: false, wordsToday: 0), "Writing is off")
        assertEqual(Copy.suggestionsAcceptedLine(3), "3 suggestions accepted today")
        assertEqual(Copy.suggestionsAcceptedLine(1), "1 suggestion accepted today")
        assertEqual(
            Copy.keystrokesSavedLine(today: 12, last7Days: 90, partial: false),
            "12 keystrokes saved today · 90 in the last 7 days"
        )
        assertEqual(
            Copy.keystrokesSavedLine(today: 1, last7Days: 1, partial: true),
            "1 keystroke saved today · 1 in the last 7 days (partial)"
        )
        assertEqual(
            Copy.suggestionsAcceptedToday(ledgerAccepted: 4, ledgerHasTodayEvidence: true, keyboardCounter: 9),
            4,
            "the ledger wins once it has today's evidence"
        )
        assertEqual(
            Copy.suggestionsAcceptedToday(ledgerAccepted: 0, ledgerHasTodayEvidence: false, keyboardCounter: 9),
            9
        )
        assertEqual(
            Copy.entryMetaLine(sourceApp: "Slack", words: 42, acceptedWords: 3),
            "Slack · 42 words · 3 accepted"
        )
        assertEqual(Copy.entryMetaLine(sourceApp: "Notes", words: 1, acceptedWords: 0), "Notes · 1 word")
    }

    runSuite("Writing everyday status line") {
        assertEqual(
            Copy.statusLine(keyboardOn: true, autocomplete: true, model: .gemma4E2B, modelStatus: .ready, scope: .all, pickedCount: 0),
            "Keyboard on · Gemma 4 E2B ready · All apps"
        )
        assertEqual(
            Copy.statusLine(
                keyboardOn: false,
                autocomplete: true,
                model: .qwen35B9B,
                modelStatus: .downloading(fraction: 0.426),
                scope: .picked,
                pickedCount: 3
            ),
            "Keyboard off · Qwen 3.5 9B downloading 42% · 3 apps"
        )
        assertEqual(
            Copy.statusLine(keyboardOn: nil, autocomplete: false, model: .gemma4E2B, modelStatus: .ready, scope: .picked, pickedCount: 1),
            "1 app",
            "no model part with Autocomplete off, no keyboard part until it's known"
        )
        assertEqual(Copy.modelStatusText(.downloading(fraction: nil)), "downloading")
        assertEqual(Copy.modelStatusText(.failed(.offline)), "download paused, no connection")
        assertEqual(Copy.modelStatusText(.failed(.diskSpace)), "needs more disk space")
        assertTrue(Copy.isProblem(.failed(.install)))
        assertTrue(Copy.isProblem(.stopped))
        assertFalse(Copy.isProblem(.downloading(fraction: 0.5)))
        assertFalse(Copy.isProblem(.ready))
    }

    runSuite("Writing paused line") {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Chicago")
        formatter.dateFormat = "h:mm a"
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 15, minute: 45))!
        assertEqual(Copy.pausedLine(until: date, timeFormatter: formatter), "Paused until 3:45 PM")
    }
}
