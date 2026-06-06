// ClipboardRestoringTextPasterTests.swift
// Tests for safe clipboard restore behavior.

import AppKit
import Foundation

func testClipboardRestoringTextPaster() async {
    await MainActor.run {
        runSuite("ClipboardRestoringTextPaster.restorePasteboardItems — preserves user clipboard changes") {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("TranscriptedClipboardTest-\(UUID().uuidString)"))
            let paster = ClipboardRestoringTextPaster()
            let original = "original clipboard"
            let temporary = "temporary dictation"
            let userCopy = "user copied this"

            pasteboard.clearContents()
            pasteboard.setString(original, forType: .string)
            let snapshot = paster.snapshotPasteboardItems(from: pasteboard)

            pasteboard.clearContents()
            pasteboard.setString(temporary, forType: .string)
            let temporaryChangeCount = pasteboard.changeCount

            pasteboard.clearContents()
            pasteboard.setString(userCopy, forType: .string)
            paster.restorePasteboardItems(
                snapshot,
                temporaryString: temporary,
                temporaryChangeCount: temporaryChangeCount,
                to: pasteboard
            )

            assertEqual(
                pasteboard.string(forType: .string),
                userCopy,
                "restore should not overwrite clipboard content copied after paste started"
            )
        }

        runSuite("ClipboardRestoringTextPaster.restorePasteboardItems — restores only unchanged temporary text") {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("TranscriptedClipboardTest-\(UUID().uuidString)"))
            let paster = ClipboardRestoringTextPaster()
            let original = "original clipboard"
            let temporary = "temporary dictation"

            pasteboard.clearContents()
            pasteboard.setString(original, forType: .string)
            let snapshot = paster.snapshotPasteboardItems(from: pasteboard)

            pasteboard.clearContents()
            pasteboard.setString(temporary, forType: .string)
            let temporaryChangeCount = pasteboard.changeCount

            paster.restorePasteboardItems(
                snapshot,
                temporaryString: temporary,
                temporaryChangeCount: temporaryChangeCount,
                to: pasteboard
            )

            assertEqual(
                pasteboard.string(forType: .string),
                original,
                "unchanged temporary pasteboard content should be restored to the previous snapshot"
            )
        }

        runSuite("ClipboardRestoringTextPaster.paste — dispatches after dictation text is on the pasteboard") {
            let pasteboard = FakeClipboardPasteboard(initialString: "synthetic existing clipboard")
            let paster = ClipboardRestoringTextPaster()
            let dictationText = "synthetic just-finished dictation"
            var observedTextAtPost: String?
            var postCount = 0

            let outcome = paster.paste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    postCount += 1
                    observedTextAtPost = pasteboard.string(forType: .string)
                    return true
                }
            )

            assertEqual(outcome, .pasted, "valid pasteboard write should allow automatic paste")
            assertEqual(postCount, 1, "automatic paste should dispatch exactly once")
            assertEqual(
                observedTextAtPost,
                dictationText,
                "paste shortcut should only fire after the borrowed clipboard contains dictation text"
            )
        }

        runSuite("ClipboardRestoringTextPaster.paste — blocks Cmd+V when the dictation clipboard write fails") {
            let existingClipboard = "synthetic existing clipboard"
            let pasteboard = FakeClipboardPasteboard(
                initialString: existingClipboard,
                clearContentsClears: false,
                setStringSucceeds: false,
                writePasteboardItemsSucceeds: false
            )
            let paster = ClipboardRestoringTextPaster()
            var observedTextAtPost: String?
            var postCount = 0

            let outcome = paster.paste(
                "synthetic just-finished dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    postCount += 1
                    observedTextAtPost = pasteboard.string(forType: .string)
                    return true
                }
            )

            assertEqual(
                outcome,
                .failed("Couldn't prepare the clipboard for automatic paste. The dictation was saved, but paste-back did not run."),
                "failed clipboard writes should be reported as paste-back failures"
            )
            assertEqual(postCount, 0, "Cmd+V should not fire when the dictation text is not on the pasteboard")
            assertNil(observedTextAtPost, "failed pasteboard prep should not reach the paste dispatcher")
            assertEqual(
                pasteboard.string(forType: .string),
                existingClipboard,
                "failed pasteback should not paste the pre-existing clipboard contents"
            )
        }

        runSuite("ClipboardRestoringTextPaster.paste — accessibility missing copies text and prompts once") {
            let pasteboard = FakeClipboardPasteboard(initialString: "synthetic existing clipboard")
            let paster = ClipboardRestoringTextPaster()
            let dictationText = "synthetic accessibility fallback dictation"
            var promptCount = 0
            var dispatchCount = 0

            let outcome = paster.paste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { false },
                requestAccessibilityTrust: {
                    promptCount += 1
                },
                pasteDispatcher: {
                    dispatchCount += 1
                    return true
                }
            )

            assertEqual(
                outcome,
                .copied(
                    "Couldn't paste automatically. Accessibility is off, so the text was copied.",
                    reason: .accessibilityMissing
                ),
                "missing Accessibility permission should report a copied fallback with the right reason"
            )
            assertEqual(promptCount, 1, "missing Accessibility permission should request trust exactly once")
            assertEqual(dispatchCount, 0, "missing Accessibility permission should not post Cmd+V")
            assertEqual(
                pasteboard.string(forType: .string),
                dictationText,
                "missing Accessibility permission should leave the dictation text copied"
            )
        }

        runSuite("DictationPasteTarget — accepts only the captured foreground app") {
            let target = DictationPasteTarget(
                processIdentifier: 42,
                bundleIdentifier: "com.example.Target"
            )

            assertTrue(
                target.matches(processIdentifier: 42, bundleIdentifier: "com.example.Other"),
                "matching process id should keep paste directed at the original app"
            )
            assertTrue(
                target.matches(processIdentifier: nil, bundleIdentifier: "com.example.Target"),
                "bundle id should be a fallback when a process id is unavailable"
            )
            assertFalse(
                target.matches(processIdentifier: 7, bundleIdentifier: "com.example.Target"),
                "a different frontmost process should block automatic paste even if bundle ids match"
            )
        }

        runSuite("ClipboardRestoringTextPaster — waits briefly for menu-triggered target activation") {
            let source = readClipboardPasterSource()

            assertTrue(
                TranscriptedConstants.clipboardTargetActivationWait > 0
                    && TranscriptedConstants.clipboardTargetActivationWait < 0.5,
                "activation wait should be short but non-zero"
            )
            assertTrue(
                source.contains("waitForTargetActivation(target, timeout: activationWait)"),
                "paste-back should wait briefly before treating target activation as focus loss"
            )
        }
    }

    await runSuite("ClipboardRestoringTextPaster.paste — keeps dictation available for delayed paste consumers") {
        let existingClipboard = "synthetic existing clipboard"
        let dictationText = "synthetic delayed dictation"
        let pasteboardName = NSPasteboard.Name("TranscriptedDelayedPasteTest-\(UUID().uuidString)")
        let paster = await MainActor.run {
            ClipboardRestoringTextPaster()
        }

        let outcome = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString(existingClipboard, forType: .string)
            return paster.paste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { true },
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 80_000_000
            )
        }

        assertEqual(outcome, .pasted, "valid pasteback should report automatic paste")
        let waitTask = Task { @MainActor in
            await paster.waitForPendingClipboardRestore()
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteboard.string(forType: .string)
        }
        try? await Task.sleep(nanoseconds: 30_000_000)

        let delayedRead = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteboard.string(forType: .string)
        }
        assertEqual(
            delayedRead,
            dictationText,
            "a target that reads after the eager restore delay should still get the dictation text"
        )

        let restoredClipboard = await waitTask.value
        assertEqual(
            restoredClipboard,
            existingClipboard,
            "waiting for pending restore should include the fallback restore before auto-enter"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.paste — covers slower consumers beyond the old fallback window") {
        let existingClipboard = "synthetic existing clipboard"
        let dictationText = "synthetic slow consumer dictation"
        let pasteboardName = NSPasteboard.Name("TranscriptedSlowPasteConsumerTest-\(UUID().uuidString)")
        let paster = await MainActor.run {
            ClipboardRestoringTextPaster()
        }

        let outcome = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString(existingClipboard, forType: .string)
            return paster.paste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { true },
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: TranscriptedConstants.clipboardRestoreFallbackDelay
            )
        }

        assertEqual(outcome, .pasted, "valid pasteback should report automatic paste")
        let waitTask = Task { @MainActor in
            await paster.waitForPendingClipboardRestore()
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteboard.string(forType: .string)
        }
        try? await Task.sleep(nanoseconds: 950_000_000)

        let delayedRead = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteboard.string(forType: .string)
        }
        assertEqual(
            delayedRead,
            dictationText,
            "a target that reads after the old 900ms fallback should still get the dictation text"
        )

        let restoredClipboard = await waitTask.value
        assertEqual(
            restoredClipboard,
            existingClipboard,
            "slow-consumer pasteback should still restore the previous clipboard afterward"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.paste — early observer reads do not race slow consumers") {
        let existingClipboard = "synthetic existing clipboard"
        let dictationText = "synthetic observer-safe dictation"
        let pasteboardName = NSPasteboard.Name("TranscriptedObserverPasteConsumerTest-\(UUID().uuidString)")
        let paster = await MainActor.run {
            ClipboardRestoringTextPaster()
        }

        let outcome = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString(existingClipboard, forType: .string)
            return paster.paste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { true },
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 140_000_000
            )
        }

        assertEqual(outcome, .pasted, "valid pasteback should report automatic paste")
        let waitTask = Task { @MainActor in
            await paster.waitForPendingClipboardRestore()
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteboard.string(forType: .string)
        }

        try? await Task.sleep(nanoseconds: 20_000_000)
        let observerRead = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteboard.string(forType: .string)
        }
        assertEqual(observerRead, dictationText, "a clipboard observer should see the borrowed dictation text")

        try? await Task.sleep(nanoseconds: 70_000_000)
        let slowConsumerRead = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteboard.string(forType: .string)
        }
        assertEqual(
            slowConsumerRead,
            dictationText,
            "an early clipboard observer read should not restore stale clipboard before a slower target reads Cmd+V"
        )

        let restoredClipboard = await waitTask.value
        assertEqual(
            restoredClipboard,
            existingClipboard,
            "observer-safe pasteback should still restore the previous clipboard afterward"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.waitForClipboardReadyForAutoEnter — does not wait for observer fallback") {
        let existingClipboard = "synthetic existing clipboard"
        let dictationText = "synthetic observer auto-enter dictation"
        let pasteboardName = NSPasteboard.Name("TranscriptedObserverAutoEnterTest-\(UUID().uuidString)")
        let paster = await MainActor.run {
            ClipboardRestoringTextPaster()
        }

        let outcome = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString(existingClipboard, forType: .string)
            return paster.paste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { true },
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 300_000_000
            )
        }

        assertEqual(outcome, .pasted, "valid pasteback should report automatic paste")
        try? await Task.sleep(nanoseconds: 20_000_000)
        let observerRead = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteboard.string(forType: .string)
        }
        assertEqual(observerRead, dictationText, "observer read should arm auto-enter readiness")

        let started = Date()
        let readyTask = Task { @MainActor in
            await paster.waitForClipboardReadyForAutoEnter()
        }
        await readyTask.value
        let elapsed = Date().timeIntervalSince(started)
        assertTrue(elapsed < 0.15, "auto-enter readiness should not wait for the long fallback restore")

        let stillBorrowedClipboard = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteboard.string(forType: .string)
        }
        assertEqual(
            stillBorrowedClipboard,
            dictationText,
            "the long fallback should remain active for a slower target after auto-enter is ready"
        )

        let restoredTask = Task { @MainActor in
            await paster.waitForPendingClipboardRestore()
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteboard.string(forType: .string)
        }
        let restoredClipboard = await restoredTask.value
        assertEqual(restoredClipboard, existingClipboard, "fallback restore should still return the previous clipboard")
    }

    await runSuite("ClipboardRestoringTextPaster.waitForClipboardReadyForAutoEnter — waits when no pasteboard read occurs") {
        let existingClipboard = "synthetic existing clipboard"
        let pasteText = "synthetic unread paste text"
        let paster = await MainActor.run {
            ClipboardRestoringTextPaster()
        }
        let pasteboard = await MainActor.run {
            FakeClipboardPasteboard(initialString: existingClipboard)
        }

        let outcome = await MainActor.run {
            paster.paste(
                pasteText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { true },
                fallbackRestoreDelay: 20_000_000
            )
        }

        assertEqual(outcome, .pasted, "valid pasteback should report automatic paste")
        let started = Date()
        let readyTask = Task { @MainActor in
            await paster.waitForClipboardReadyForAutoEnter()
        }
        await readyTask.value
        let elapsed = Date().timeIntervalSince(started)
        assertTrue(elapsed >= 0.01, "without a pasteboard read, auto-enter should still wait for fallback restore")
        let restoredClipboard = await MainActor.run {
            pasteboard.string(forType: .string)
        }
        assertEqual(
            restoredClipboard,
            existingClipboard,
            "waiting for auto-enter readiness without a read should include fallback restore"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.waitForPendingClipboardRestore — waits for fallback restore") {
        let existingClipboard = "synthetic existing clipboard"
        let pasteText = "synthetic paste text"
        let paster = await MainActor.run {
            ClipboardRestoringTextPaster()
        }
        let pasteboard = await MainActor.run {
            FakeClipboardPasteboard(initialString: existingClipboard)
        }

        let outcome = await MainActor.run {
            paster.paste(
                pasteText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { true },
                fallbackRestoreDelay: 2_000_000
            )
        }

        assertEqual(outcome, .pasted, "valid pasteback should report automatic paste")
        await paster.waitForPendingClipboardRestore()
        let restoredClipboard = await MainActor.run {
            pasteboard.string(forType: .string)
        }
        assertEqual(
            restoredClipboard,
            existingClipboard,
            "waiting for pending restore should not return until the previous clipboard is restored"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.waitForPendingClipboardRestore — preserves user copies") {
        let userCopy = "synthetic user clipboard"
        let paster = await MainActor.run {
            ClipboardRestoringTextPaster()
        }
        let pasteboard = await MainActor.run {
            FakeClipboardPasteboard(initialString: "synthetic existing clipboard")
        }

        let outcome = await MainActor.run {
            paster.paste(
                "synthetic paste text",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { true },
                fallbackRestoreDelay: 5_000_000
            )
        }
        await MainActor.run {
            pasteboard.clearContents()
            pasteboard.setString(userCopy, forType: .string)
        }

        assertEqual(outcome, .pasted, "valid pasteback should report automatic paste")
        await paster.waitForPendingClipboardRestore()
        let clipboardAfterRestore = await MainActor.run {
            pasteboard.string(forType: .string)
        }
        assertEqual(
            clipboardAfterRestore,
            userCopy,
            "scheduled restore should not overwrite a clipboard change made after pasteback"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.paste — retry does not snapshot borrowed dictation as the user clipboard") {
        let originalClipboard = "synthetic original clipboard"
        let firstPaste = "synthetic first dictation"
        let secondPaste = "synthetic retry dictation"
        let paster = await MainActor.run {
            ClipboardRestoringTextPaster()
        }
        let pasteboard = await MainActor.run {
            FakeClipboardPasteboard(initialString: originalClipboard)
        }

        let firstOutcome = await MainActor.run {
            paster.paste(
                firstPaste,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { true },
                fallbackRestoreDelay: 50_000_000
            )
        }
        let secondOutcome = await MainActor.run {
            paster.paste(
                secondPaste,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { true },
                fallbackRestoreDelay: 5_000_000
            )
        }

        assertEqual(firstOutcome, .pasted, "first paste should report automatic paste")
        assertEqual(secondOutcome, .pasted, "retry paste should report automatic paste")
        let clipboardDuringRetry = await MainActor.run {
            pasteboard.string(forType: .string)
        }
        assertEqual(clipboardDuringRetry, secondPaste, "retry paste should borrow the new dictation text")

        await paster.waitForPendingClipboardRestore()
        let restoredClipboard = await MainActor.run {
            pasteboard.string(forType: .string)
        }
        assertEqual(
            restoredClipboard,
            originalClipboard,
            "retry paste should restore the user's original clipboard, not the previous borrowed dictation"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.cancelPendingClipboardRestore — cancels scheduled restore") {
        let pasteText = "synthetic paste text"
        let paster = await MainActor.run {
            ClipboardRestoringTextPaster()
        }
        let pasteboard = await MainActor.run {
            FakeClipboardPasteboard(initialString: "synthetic existing clipboard")
        }

        let outcome = await MainActor.run {
            let outcome = paster.paste(
                pasteText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { true },
                fallbackRestoreDelay: 5_000_000
            )
            paster.cancelPendingClipboardRestore()
            return outcome
        }
        try? await Task.sleep(nanoseconds: 10_000_000)

        assertEqual(outcome, .pasted, "valid pasteback should report automatic paste")
        let clipboardAfterCancel = await MainActor.run {
            pasteboard.string(forType: .string)
        }
        assertEqual(
            clipboardAfterCancel,
            pasteText,
            "canceling the pending restore should leave the current clipboard value alone"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.paste — paste dispatcher failure cancels restore") {
        let pasteText = "synthetic paste fallback"
        let pasteboard = await MainActor.run {
            FakeClipboardPasteboard(initialString: "synthetic existing clipboard")
        }
        let paster = await MainActor.run {
            ClipboardRestoringTextPaster()
        }

        let outcome = await MainActor.run {
            paster.paste(
                pasteText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { false },
                fallbackRestoreDelay: 5_000_000
            )
        }
        await paster.waitForPendingClipboardRestore()
        try? await Task.sleep(nanoseconds: 10_000_000)

        assertEqual(
            outcome,
            .copied(
                "Couldn't paste automatically. The text was copied instead.",
                reason: .pasteEventCreationFailed
            ),
            "paste event failures should fall back to a copied result"
        )
        let clipboardAfterFailure = await MainActor.run {
            pasteboard.string(forType: .string)
        }
        assertEqual(
            clipboardAfterFailure,
            pasteText,
            "failed paste dispatch should not later restore over the copied fallback text"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.paste — failed copy fallback reports failure") {
        let existingClipboard = "synthetic existing clipboard"
        let pasteText = "synthetic paste fallback failure"
        let pasteboard = await MainActor.run {
            FakeClipboardPasteboard(
                initialString: existingClipboard,
                setStringResults: [true, false]
            )
        }
        let paster = await MainActor.run {
            ClipboardRestoringTextPaster()
        }

        let outcome = await MainActor.run {
            paster.paste(
                pasteText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { false },
                fallbackRestoreDelay: 5_000_000
            )
        }
        await paster.waitForPendingClipboardRestore()

        assertEqual(
            outcome,
            .failed("Couldn't prepare the clipboard for automatic paste. The dictation was saved, but paste-back did not run."),
            "paste dispatch fallback should report failure when the copied fallback cannot be written"
        )
        let clipboardAfterFailure = await MainActor.run {
            pasteboard.string(forType: .string)
        }
        assertNil(clipboardAfterFailure, "failed copied fallback should not restore stale clipboard content")
    }
}

private func readClipboardPasterSource() -> String {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("Sources/Support/ClipboardRestoringTextPaster.swift")
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

@MainActor
private final class FakeClipboardPasteboard: ClipboardPasteboard {
    var changeCount = 0
    var clearContentsClears: Bool
    var setStringSucceeds: Bool
    var writePasteboardItemsSucceeds: Bool
    private var setStringResults: [Bool]?
    private var storedString: String?
    private var storedItems: [NSPasteboardItem]?

    init(
        initialString: String?,
        clearContentsClears: Bool = true,
        setStringSucceeds: Bool = true,
        writePasteboardItemsSucceeds: Bool = true,
        setStringResults: [Bool]? = nil
    ) {
        self.storedString = initialString
        self.clearContentsClears = clearContentsClears
        self.setStringSucceeds = setStringSucceeds
        self.writePasteboardItemsSucceeds = writePasteboardItemsSucceeds
        self.setStringResults = setStringResults
    }

    var pasteboardItems: [NSPasteboardItem]? {
        if let storedString,
           let data = storedString.data(using: .utf8) {
            let item = NSPasteboardItem()
            item.setData(data, forType: .string)
            return [item]
        }
        return storedItems
    }

    @discardableResult
    func clearContents() -> Int {
        changeCount += 1
        if clearContentsClears {
            storedString = nil
            storedItems = nil
        }
        return changeCount
    }

    @discardableResult
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        if var setStringResults,
           !setStringResults.isEmpty {
            let nextResult = setStringResults.removeFirst()
            self.setStringResults = setStringResults
            guard nextResult else { return false }
        } else {
            guard setStringSucceeds else { return false }
        }
        guard dataType == .string else { return false }
        storedString = string
        storedItems = nil
        changeCount += 1
        return true
    }

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        guard dataType == .string else { return nil }
        if let storedString {
            return storedString
        }
        return storedItems?.compactMap { item in
            item.data(forType: .string)
                .flatMap { String(data: $0, encoding: .utf8) }
        }.first
    }

    @discardableResult
    func writePasteboardItems(_ items: [NSPasteboardItem]) -> Bool {
        guard writePasteboardItemsSucceeds else { return false }
        changeCount += 1
        storedString = nil
        storedItems = items
        return true
    }
}
