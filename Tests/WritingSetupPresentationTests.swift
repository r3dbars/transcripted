import Foundation

// Behavioral coverage for the Writing tab's copy and rules
// (Sources/Writing/WritingSetupPresentation.swift). The copy
// suites pin docs/writing-plan.md's approved design word for word.

func testWritingSetupPresentation() {
    typealias Copy = WritingSetupPresentation

    runSuite("Writing setup screen 1 pitch uses the approved copy") {
        assertEqual(Copy.Intro.smallTitle, "Writing")
        assertEqual(Copy.Intro.headline, "Your AI knows what you said. Not what you wrote.")
        assertEqual(
            Copy.Intro.body,
            "A lot of your work happens in writing: Slack replies, emails, notes. Writing saves it next to your meetings and dictations, and helps you finish your sentences."
        )
        assertEqual(Copy.Intro.keyHints.map(\.key), ["Tab", "~", "Esc"])
        assertEqual(
            Copy.Intro.keyHints.map(\.text),
            ["adds the next word", "takes the whole suggestion", "hides it"]
        )
        assertFalse(
            Copy.Intro.keyHints.contains { $0.text.contains("above Tab") },
            "the ~ key is not 'the key above Tab' on ISO keyboards"
        )
        assertEqual(Copy.Intro.privacy.title, "Stays on your Mac.")
        assertEqual(
            Copy.Intro.privacy.line,
            "No account. It's saved as plain files you can point any AI agent at. Only Write for Me sends text, and only when you press its key."
        )
        assertFalse(
            Copy.Intro.privacy.line.contains("never leaves"),
            "Write for Me sends a window when asked, so the privacy line can't promise nothing leaves"
        )
    }

    runSuite("Delete model warns that it turns Autocomplete off and the model downloads again") {
        let bytes: Int64 = 3_430_000_000
        let size = WritingStorageUsage.formatted(bytes)
        let on = Copy.deleteModelConfirmMessage(autocompleteOn: true, modelBytes: bytes)
        assertTrue(on.contains(size), "says how much it frees: \(on)")
        assertTrue(on.contains("turns Autocomplete off"), "warns before Autocomplete stops: \(on)")
        assertTrue(on.contains("downloads the model again"), "warns about the re-download: \(on)")
        assertTrue(on.contains("saved writing and learning data stay"), "says writing is kept: \(on)")

        let off = Copy.deleteModelConfirmMessage(autocompleteOn: false, modelBytes: bytes)
        assertTrue(off.contains(size), "says how much it frees: \(off)")
        assertFalse(off.contains("turns Autocomplete off"), "Autocomplete is already off: \(off)")
        assertTrue(off.contains("downloads the model again"), "warns about the re-download: \(off)")

        let unknown = Copy.deleteModelConfirmMessage(autocompleteOn: true, modelBytes: 0)
        assertFalse(unknown.contains("frees"), "no size claim before the size is known: \(unknown)")
        assertTrue(unknown.contains("turns Autocomplete off"), "still warns: \(unknown)")
    }

    runSuite("Delete all writing says the model stays") {
        assertTrue(Copy.deleteConfirmMessage.contains("model stays"))
        assertTrue(Copy.deleteConfirmMessage.contains(Copy.deleteModel))
    }

    runSuite("Writing copy says what you wrote, never what you typed") {
        let allCopy = [
            Copy.Intro.headline, Copy.Intro.body, Copy.Intro.privacy.line,
            Copy.Step1.saveLine, Copy.nothingSavedYet, Copy.deleteConfirmMessage,
        ]
        for line in allCopy {
            assertFalse(line.contains("what you typed"), "keylogger wording: \(line)")
        }
    }

    runSuite("Writing setup is two screens with the approved copy") {
        assertEqual(Copy.setupStepCount, 2, "owner-approved two-screen setup")
        assertEqual(Copy.Step1.title, "What should Writing do?")
        assertEqual(Copy.Step1.saveTitle, "Save my writing")
        assertEqual(Copy.Step1.saveLine, "Your AI can read what you wrote. Files stay on this Mac, only in apps you choose.")
        assertEqual(Copy.Step1.autocompleteTitle, "Autocomplete")
        assertEqual(Copy.Step1.autocompleteLine, "Suggests the next words. Tab to accept.")
        assertEqual(Copy.Step1.continueTitle, "Continue")
        assertEqual(Copy.Step1.needsOne, "Turn on at least one to continue.")
        assertEqual(Copy.Step1.appsTitle, "Which apps?")
        assertEqual(Copy.Step1.allApps, "All apps")
        assertEqual(Copy.Step1.allAppsLine, "Password managers are always skipped.")
        assertEqual(Copy.Step1.pickedApps, "Only apps I pick")
        assertEqual(Copy.Step1.sameApps, "Both use the same apps.")
        assertEqual(Copy.Step1.needsOneApp, "Pick at least one app.")
        assertEqual(Copy.Step1.editTitle, "Edit setup")

        assertEqual(Copy.Step2.title, "Allow and download")
        assertEqual(Copy.Step2.keyboardTitle, "Transcripted keyboard")
        assertEqual(Copy.Step2.keyboardLine, "You add it in Keyboard settings. No privacy prompt.")
        assertEqual(Copy.Step2.screenRecordingTitle, "Screen Recording")
        assertEqual(Copy.Step2.screenRecordingLine, "Reads the window you're replying in, on this Mac.")
        assertEqual(Copy.Step2.modelTitle, "Model")
        assertEqual(Copy.Step2.autocompleteBadge, "Autocomplete")
        assertEqual(Copy.Step2.qwenIneligible, "Your Mac needs 16 GB of memory for this model.")
        assertEqual(Copy.Step2.footnote, "Suggestion counts only, never text. Follows your analytics setting.")
        assertEqual(Copy.Step2.turnOn, "Turn on writing")
        assertEqual(Copy.back, "Back")
        assertEqual(Copy.notNow, "Not now")
        assertEqual(Copy.finishRecordingFirst, "Finish recording and transcribing first")
    }

    runSuite("Writing setup screen 2 names the model it picked and where to change it") {
        assertEqual(
            Copy.modelLine(for: .gemma4E2B),
            "Gemma 4 E2B (3.4 GB) downloads after you turn on writing. You can switch models later on this page."
        )
        assertEqual(
            Copy.modelLine(for: .qwen35B9B),
            "Qwen 3.5 9B (5.6 GB) downloads after you turn on writing. You can switch models later on this page.",
            "an earlier pick from the Settings card carries into setup"
        )
    }

    runSuite("Writing setup screen 2 shows only the rows the screen 1 toggles need") {
        assertEqual(Copy.step2Rows(saveMyWriting: true, autocomplete: true), [.keyboard, .screenRecording, .model])
        assertEqual(
            Copy.step2Rows(saveMyWriting: true, autocomplete: false),
            [.keyboard],
            "Save my writing needs no Screen Recording and no model download"
        )
        assertEqual(Copy.step2Rows(saveMyWriting: false, autocomplete: true), [.keyboard, .screenRecording, .model])
        assertEqual(Copy.step2Rows(saveMyWriting: false, autocomplete: false), [])
    }

    // macOS 26 ignores an app's TISEnableInputSource, so the keyboard row
    // tells the user what to do instead of claiming it turned on.
    runSuite("Writing keyboard row gives the steps for where the keyboard stands") {
        assertEqual(
            Copy.keyboardStep(.needsUserToAdd),
            Copy.KeyboardStep(
                line: "Add Transcripted in Keyboard settings: Input Sources › Edit… › +, then English › Transcripted.",
                buttonTitle: "Open keyboard settings",
                isDone: false
            )
        )
        assertEqual(
            Copy.keyboardStep(.needsRelogin),
            Copy.KeyboardStep(
                line: "macOS lists new keyboards after you log out and back in. Log out, then add Transcripted in Keyboard settings.",
                buttonTitle: "Open keyboard settings",
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
            "before the keyboard is installed, screen 2 shows the plain line"
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

    runSuite("Edit setup can turn both features off") {
        // In-app feedback (1.1.74): with both switches off, Edit setup's
        // Continue stayed disabled, so the user couldn't turn Writing off.
        assertEqual(
            Copy.step1Primary(saveMyWriting: false, autocomplete: false, isEditing: true),
            .turnOffWriting,
            "Edit setup with both off offers Turn off writing"
        )
        assertEqual(
            Copy.step1Message(saveMyWriting: false, autocomplete: false, isEditing: true),
            "Both off turns writing off.",
            "Edit setup with both off explains, not blocks"
        )
        var draft = Copy.Draft()
        draft.saveMyWriting = false
        draft.autocomplete = false
        assertTrue(draft.canFinishStep1(isEditing: true), "Edit setup's button stays enabled with both off")
        draft.scope = .picked
        assertTrue(draft.canFinishStep1(isEditing: true), "turning writing off doesn't need an app picked")
        draft.scope = .all
        assertEqual(Copy.Step1.turnOffTitle, "Turn off writing")

        // First setup still needs one feature on: there's nothing to turn off.
        assertEqual(
            Copy.step1Primary(saveMyWriting: false, autocomplete: false, isEditing: false),
            .continueSetup
        )
        assertEqual(
            Copy.step1Message(saveMyWriting: false, autocomplete: false, isEditing: false),
            "Turn on at least one to continue."
        )
        assertFalse(draft.canFinishStep1(isEditing: false))

        // With one on, both flows continue as before.
        assertEqual(Copy.step1Primary(saveMyWriting: true, autocomplete: false, isEditing: true), .continueSetup)
        assertNil(Copy.step1Message(saveMyWriting: false, autocomplete: true, isEditing: true))
        draft.autocomplete = true
        assertTrue(draft.canFinishStep1(isEditing: true))
        assertTrue(draft.canFinishStep1(isEditing: false))
    }

    runSuite("Writing setup validation") {
        assertNil(Copy.step1Message(saveMyWriting: true, autocomplete: false))
        assertNil(Copy.step1Message(saveMyWriting: false, autocomplete: true))
        assertEqual(Copy.step1Message(saveMyWriting: false, autocomplete: false), "Turn on at least one to continue.")
        assertNil(Copy.appsMessage(scope: .all, pickedCount: 0), "all apps needs no picks")
        assertEqual(Copy.appsMessage(scope: .picked, pickedCount: 0), "Pick at least one app.")
        assertNil(Copy.appsMessage(scope: .picked, pickedCount: 1))

        var draft = Copy.Draft()
        assertTrue(draft.saveMyWriting && draft.autocomplete, "both toggles start on")
        assertEqual(draft.scope, .all, "setup starts on all apps")
        assertEqual(draft.model, .gemma4E2B, "Gemma is the default model")
        assertTrue(draft.canContinueStep1 && draft.canContinueApps)
        assertTrue(draft.canFinishStep1(isEditing: false), "the defaults go straight to screen 2")
        draft.saveMyWriting = false
        draft.autocomplete = false
        assertFalse(draft.canContinueStep1)
        draft.autocomplete = true
        draft.scope = .picked
        assertFalse(draft.canContinueApps)
        assertFalse(draft.canFinishStep1(isEditing: false), "screen 1 asks for an app when picking")
        assertFalse(draft.canFinishStep1(isEditing: true), "editing too, unless it's turning writing off")
        draft.pickedBundleIdentifiers = ["com.apple.Notes"]
        assertTrue(draft.canContinueApps)
        assertTrue(draft.canFinishStep1(isEditing: false))
    }

    runSuite("Writing model options match the approved sizes and eligibility line") {
        assertEqual(Copy.modelOptions.map(\.choice), [.gemma4E2B, .qwen35B9B])
        assertEqual(Copy.modelOptions.map(\.name), ["Gemma 4 E2B", "Qwen 3.5 9B"])
        assertEqual(Copy.modelOptions.map(\.size), ["3.4 GB", "5.6 GB"])
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
        assertNil(Copy.summary(saveMyWriting: true, autocomplete: true), "Today owns the word count")
        assertNil(Copy.summary(saveMyWriting: true, autocomplete: false))
        assertNil(Copy.summary(saveMyWriting: false, autocomplete: true))
        assertEqual(Copy.summary(saveMyWriting: false, autocomplete: false), "Writing is off")
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

    // Granting Screen Recording can make macOS ask Transcripted to quit and
    // reopen, so the ask never happens while a meeting or dictation records.
    runSuite("Screen Recording is never asked for while anything records") {
        assertEqual(Copy.screenRecordingAsk(captureBusy: true, alreadyRequested: false), .waitForCapture, "Allow waits while a capture records")
        assertEqual(Copy.screenRecordingAsk(captureBusy: true, alreadyRequested: true), .waitForCapture, "Settings waits too while a capture records")
        assertEqual(Copy.screenRecordingAsk(captureBusy: false, alreadyRequested: false), .request, "the first ask is the system prompt")
        assertEqual(Copy.screenRecordingAsk(captureBusy: false, alreadyRequested: true), .openSettings, "after the one prompt, System Settings is the only way")
        assertTrue(
            Copy.asksForScreenRecordingAfterSetup(autocomplete: true, granted: false, captureBusy: false),
            "finishing setup with Autocomplete on asks once"
        )
        assertFalse(
            Copy.asksForScreenRecordingAfterSetup(autocomplete: true, granted: false, captureBusy: true),
            "finishing setup while a capture records doesn't ask"
        )
        assertFalse(
            Copy.asksForScreenRecordingAfterSetup(autocomplete: true, granted: true, captureBusy: false),
            "a granted permission isn't asked for again"
        )
        assertFalse(
            Copy.asksForScreenRecordingAfterSetup(autocomplete: false, granted: false, captureBusy: false),
            "Save my writing alone doesn't need Screen Recording"
        )
    }
}
