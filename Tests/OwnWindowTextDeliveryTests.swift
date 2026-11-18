// OwnWindowTextDeliveryTests.swift
// Promise: a dictation aimed at one of Transcripted's own text fields (setup's
// practice field, search, rename) lands in that field and counts as pasted,
// without borrowing the clipboard or posting ⌘V. Takes aimed at any other app
// keep the usual paste path and never reach the own-window insert.

import AppKit
import Foundation

func testOwnWindowTextDelivery() async {
    await MainActor.run {
        let ownProcess = ProcessInfo.processInfo.processIdentifier

        runSuite("Own-window delivery only claims targets in this process") {
            assertTrue(
                OwnWindowTextDelivery.targetsThisProcess(
                    DictationPasteTarget(processIdentifier: ownProcess, bundleIdentifier: "com.example.Transcripted")
                ),
                "a take started in Transcripted's own window targets this process"
            )
            assertFalse(
                OwnWindowTextDelivery.targetsThisProcess(
                    DictationPasteTarget(processIdentifier: 4242, bundleIdentifier: "com.example.Notes"),
                    processIdentifier: 99
                ),
                "another app's take is never an own-window take"
            )
            assertFalse(
                OwnWindowTextDelivery.targetsThisProcess(
                    DictationPasteTarget(processIdentifier: nil, bundleIdentifier: "com.example.Transcripted")
                ),
                "without a process id the target can't be proven to be this process"
            )
            assertFalse(OwnWindowTextDelivery.targetsThisProcess(nil), "no target, no own-window insert")
        }

        runSuite("Own-window insert puts the words at the field's selection") {
            let field = NSTextView()
            field.string = "Draft: "
            field.setSelectedRange(NSRange(location: 7, length: 0))
            assertTrue(OwnWindowTextDelivery.insert("hello there", into: field), "an editable field takes the words")
            assertEqual(field.string, "Draft: hello there", "the words land where the cursor was")

            let readOnly = NSTextView()
            readOnly.isEditable = false
            assertFalse(OwnWindowTextDelivery.insert("hello", into: readOnly), "a read-only text view is not a field")
            assertEqual(readOnly.string, "", "nothing is written into read-only text")

            assertFalse(OwnWindowTextDelivery.insert("hello", into: nil), "no focused responder, nothing inserted")
            assertFalse(OwnWindowTextDelivery.insert("hello", into: NSView()), "a plain view is not a text field")
            assertFalse(OwnWindowTextDelivery.insert("", into: NSTextView()), "an empty take changes nothing")
        }

        runSuite("A take aimed at this process with a focused field is pasted, not copied") {
            let board = OwnWindowFakePasteboard(initialString: "the user's clipboard")
            let paster = ClipboardRestoringTextPaster()
            var inserted: [String] = []
            var dispatched = false
            let outcome = paster.paste(
                "practice words",
                target: DictationPasteTarget(processIdentifier: ownProcess, bundleIdentifier: "com.example.Transcripted"),
                activationWait: 0,
                pasteboard: board,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { dispatched = true; return true },
                ownWindowTextInput: { inserted.append($0); return true }
            )
            assertEqual(outcome, .pasted, "the island shows Pasted, not a Not pasted notice")
            assertEqual(outcome.delivery, .pasted, "the take is saved as pasted")
            assertEqual(inserted, ["practice words"], "the words go to the focused field once")
            assertFalse(dispatched, "no ⌘V is posted to our own window")
            assertEqual(board.string(forType: .string), "the user's clipboard", "the clipboard is never borrowed")
            assertEqual(board.mutationCount, 0, "the clipboard is not written at all")
            assertEqual(
                paster.lastConfirmationDiagnostic?.context["confirmation_mode"],
                ClipboardPasteConfirmationDiagnostic.ownWindowInsertMode,
                "diagnostics say how the paste was confirmed"
            )
            assertEqual(
                DictationTargetConfirmationMode.resolve(outcome: outcome, diagnostic: paster.lastConfirmationDiagnostic),
                .none,
                "analytics keep their existing coarse values"
            )
        }

        runSuite("Own window with no editable field keeps the usual paste path") {
            let board = OwnWindowFakePasteboard(initialString: "the user's clipboard")
            let paster = ClipboardRestoringTextPaster()
            var asked = 0
            let outcome = paster.paste(
                "practice words",
                target: DictationPasteTarget(processIdentifier: ownProcess, bundleIdentifier: "com.example.Transcripted"),
                activationWait: 0,
                pasteboard: board,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { true },
                ownWindowTextInput: { _ in asked += 1; return false }
            )
            assertEqual(asked, 1, "the focused field is checked once")
            assertTrue(outcome != .pasted, "without a field the take is not reported as pasted by the insert")
        }

        runSuite("Takes aimed at other apps never reach the own-window insert") {
            let board = OwnWindowFakePasteboard(initialString: "the user's clipboard")
            let paster = ClipboardRestoringTextPaster()
            var asked = false
            let outcome = paster.paste(
                "words for another app",
                target: DictationPasteTarget(processIdentifier: -1, bundleIdentifier: "com.example.Notes"),
                activationWait: 0,
                pasteboard: board,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { true },
                ownWindowTextInput: { _ in asked = true; return true }
            )
            assertFalse(asked, "the own-window insert is only for this process")
            assertEqual(outcome.copyReason, .focusChanged, "another app keeps its own delivery checks")
        }
    }
}

@MainActor
private final class OwnWindowFakePasteboard: ClipboardPasteboard {
    var changeCount = 0
    private var stored: String?
    private(set) var mutationCount = 0

    init(initialString: String?) {
        stored = initialString
    }

    var pasteboardItems: [NSPasteboardItem]? {
        guard let stored, let data = stored.data(using: .utf8) else { return nil }
        let item = NSPasteboardItem()
        item.setData(data, forType: .string)
        return [item]
    }

    @discardableResult
    func clearContents() -> Int {
        mutationCount += 1
        changeCount += 1
        stored = nil
        return changeCount
    }

    @discardableResult
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
        guard dataType == .string else { return false }
        mutationCount += 1
        changeCount += 1
        stored = string
        return true
    }

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        dataType == .string ? stored : nil
    }

    @discardableResult
    func writePasteboardItems(_ items: [NSPasteboardItem]) -> Bool {
        mutationCount += 1
        changeCount += 1
        stored = items.first?.string(forType: .string)
        return true
    }
}
