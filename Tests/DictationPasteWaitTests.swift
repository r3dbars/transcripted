// DictationPasteWaitTests.swift
// A dictation that won't press Auto Enter stops waiting for an Accessibility
// confirmation once the target has read the clipboard right after Cmd+V, and
// the user's clipboard still comes back on the same schedule a full wait
// would have given it. Runs the real ClipboardRestoringTextPaster against real
// named NSPasteboards with a fake Accessibility source.

import AppKit
import Foundation

func testDictationPasteWait() async {
    runSuite("The paste wait never ends on a clipboard read when Auto Enter is expected") {
        let expected = DictationAutoSendRequestDecision(expected: true, key: .enter, blockReason: .none)
        let notExpected = DictationAutoSendRequestDecision(expected: false, key: .enter, blockReason: .featureOff)
        assertFalse(expected.pasteMayEndWaitOnLikelyPaste, "Auto Enter needs a confirmed paste, so it keeps the full wait")
        assertTrue(notExpected.pasteMayEndWaitOnLikelyPaste, "a take that won't press Return may end the wait on a likely paste")
        assertFalse(
            FocusedTextPasteConfirmationPolicy.endsWaitOnLikelyPaste(
                callerAllows: false, focusRefutesPaste: false, pasteDispatchedAt: 100, clipboardReadAt: 100.01
            ),
            "a caller that needs a confirmed paste never ends the wait on a read"
        )
    }

    runSuite("Only a quick read into a place that takes text ends the paste wait") {
        func ends(focusRefutes: Bool = false, readAt: CFAbsoluteTime?) -> Bool {
            FocusedTextPasteConfirmationPolicy.endsWaitOnLikelyPaste(
                callerAllows: true, focusRefutesPaste: focusRefutes, pasteDispatchedAt: 100, clipboardReadAt: readAt
            )
        }
        assertTrue(ends(readAt: 100.02), "a read right after Cmd+V ends the wait")
        assertFalse(ends(focusRefutes: true, readAt: 100.02), "a read while focus can't take text is no paste, so the wait goes on")
        assertFalse(ends(readAt: 99.9), "a read before Cmd+V isn't the target pasting")
        assertFalse(ends(readAt: 100.4), "a read long after Cmd+V looks like a clipboard manager")
        assertFalse(ends(readAt: nil), "no read, no evidence")
    }

    runSuite("Ending the wait early never brings the user's clipboard back sooner") {
        let fallback: UInt64 = 2_500_000_000
        assertEqual(
            FocusedTextPasteConfirmationPolicy.likelyPasteRestoreDelay(fallbackDelay: fallback, unusedWait: 0.3),
            2_800_000_000,
            "the skipped part of the wait is added to the fallback delay"
        )
        assertEqual(
            FocusedTextPasteConfirmationPolicy.likelyPasteRestoreDelay(fallbackDelay: fallback, unusedWait: 0),
            fallback,
            "a full wait keeps the plain fallback delay"
        )
        assertEqual(
            FocusedTextPasteConfirmationPolicy.likelyPasteRestoreDelay(fallbackDelay: fallback, unusedWait: -1),
            fallback,
            "a wait that ran past its deadline adds nothing"
        )
        assertEqual(
            FocusedTextPasteConfirmationPolicy.likelyPasteRestoreDelay(fallbackDelay: fallback, unusedWait: .nan),
            fallback,
            "a broken clock reading adds nothing"
        )
        assertEqual(
            FocusedTextPasteConfirmationPolicy.likelyPasteRestoreDelay(fallbackDelay: .max, unusedWait: 1),
            .max,
            "the delay saturates instead of wrapping around to a short one"
        )
    }

    let fallbackRestoreDelay: UInt64 = 60_000_000_000
    let restoreDelay: UInt64 = 5_000_000

    await runSuite("A take without Auto Enter stops waiting once a target that could confirm reads the clipboard") {
        let original = "synthetic original clipboard"
        let pasteboardName = NSPasteboard.Name("TranscriptedPasteWaitEarly-\(UUID().uuidString)")
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }
        let source = await MainActor.run { ConfirmsOnAskSource(confirmOnAsk: 3) }

        let outcome = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString(original, forType: .string)
            return paster.paste(
                "synthetic early dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                confirmationSource: { source },
                targetIsFrontmost: { true },
                restoreDelay: restoreDelay,
                fallbackRestoreDelay: fallbackRestoreDelay,
                pasteConfirmationWait: 5,
                endWaitOnLikelyPaste: true
            )
        }
        let askedDuringPaste = await MainActor.run { source.asked }
        let diagnostic = await MainActor.run { paster.lastConfirmationDiagnostic }
        let delayAfterPaste = await MainActor.run { paster.scheduledClipboardRestoreDelay } ?? 0

        assertEqual(outcome, .likelyPasted, "the read right after Cmd+V makes it a likely paste, the same pill and saved entry as before")
        assertEqual(askedDuringPaste, 1, "the wait ends at the first check after the read instead of pumping on")
        assertEqual(diagnostic?.context["likely_paste_ended_wait"], "true", "the diagnostic says the read ended the wait")
        assertEqual(diagnostic?.context["paste_evidence"], "clipboard_read", "the evidence is the same as a full-wait likely paste")
        assertTrue(delayAfterPaste > fallbackRestoreDelay, "the clipboard stays borrowed past the fallback delay plus the skipped wait")

        await paster.waitForLateConfirmationWatch()
        let delayAfterWatch = await MainActor.run { paster.scheduledClipboardRestoreDelay }
        assertEqual(
            delayAfterWatch,
            restoreDelay,
            "a confirmation the full wait would have seen brings the clipboard back on the confirmed-paste delay"
        )
        if delayAfterWatch != restoreDelay {
            await MainActor.run { paster.cancelPendingClipboardRestore() }
        }
        await paster.waitForPendingClipboardRestore()
        let finalClipboard = await MainActor.run { NSPasteboard(name: pasteboardName).string(forType: .string) }
        assertEqual(finalClipboard, original, "the user's clipboard comes back")
    }

    await runSuite("A take that expects Auto Enter keeps waiting for the confirmation") {
        let original = "synthetic original clipboard"
        let pasteboardName = NSPasteboard.Name("TranscriptedPasteWaitFull-\(UUID().uuidString)")
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }
        let source = await MainActor.run { ConfirmsOnAskSource(confirmOnAsk: 3) }

        let outcome = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString(original, forType: .string)
            return paster.paste(
                "synthetic auto enter dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                confirmationSource: { source },
                targetIsFrontmost: { true },
                restoreDelay: restoreDelay,
                fallbackRestoreDelay: fallbackRestoreDelay,
                pasteConfirmationWait: 5,
                endWaitOnLikelyPaste: false
            )
        }
        let delay = await MainActor.run { paster.scheduledClipboardRestoreDelay }

        assertEqual(outcome, .pasted, "the wait runs until Accessibility confirms, so Auto Enter can still press Return")
        assertTrue(outcome.allowsAutoSend, "a confirmed paste still authorizes Auto Enter")
        assertEqual(delay, restoreDelay, "a confirmed paste restores the clipboard on the short delay")
        if delay != restoreDelay {
            await MainActor.run { paster.cancelPendingClipboardRestore() }
        }
        await paster.waitForPendingClipboardRestore()
        let finalClipboard = await MainActor.run { NSPasteboard(name: pasteboardName).string(forType: .string) }
        assertEqual(finalClipboard, original, "the user's clipboard comes back")
    }

    await runSuite("Without a late confirmation the clipboard comes back no sooner than after a full wait") {
        let original = "synthetic original clipboard"
        let pasteboardName = NSPasteboard.Name("TranscriptedPasteWaitNoLate-\(UUID().uuidString)")
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }
        let source = await MainActor.run { ConfirmsOnAskSource(confirmOnAsk: nil) }

        let outcome = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString(original, forType: .string)
            return paster.paste(
                "synthetic unconfirmed dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                confirmationSource: { source },
                targetIsFrontmost: { true },
                restoreDelay: restoreDelay,
                fallbackRestoreDelay: fallbackRestoreDelay,
                pasteConfirmationWait: 0.3,
                endWaitOnLikelyPaste: true
            )
        }
        assertEqual(outcome, .likelyPasted, "a quick read without Accessibility proof is a likely paste")

        await paster.waitForLateConfirmationWatch()
        let askedAfterWatch = await MainActor.run { source.asked }
        let delay = await MainActor.run { paster.scheduledClipboardRestoreDelay } ?? 0
        let clipboardDuringRestoreWait = await MainActor.run { NSPasteboard(name: pasteboardName).string(forType: .string) }

        assertTrue(askedAfterWatch > 1, "the watch kept asking Accessibility after the paste returned")
        assertTrue(delay > fallbackRestoreDelay, "with no confirmation the restore stays on the long schedule")
        assertEqual(
            clipboardDuringRestoreWait,
            "synthetic unconfirmed dictation",
            "the dictation stays on the clipboard for a slow target until the long restore"
        )
        await MainActor.run { paster.cancelPendingClipboardRestore() }
        let finalClipboard = await MainActor.run { NSPasteboard(name: pasteboardName).string(forType: .string) }
        assertEqual(finalClipboard, original, "the user's clipboard comes back")
    }

    await runSuite("A focus that can't take text keeps the full wait and its Not pasted outcome") {
        let pasteboardName = NSPasteboard.Name("TranscriptedPasteWaitRefuted-\(UUID().uuidString)")
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }
        let source = await MainActor.run { ConfirmsOnAskSource(confirmOnAsk: nil, clearlyNotTextEntry: true) }

        let outcome = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString("synthetic original clipboard", forType: .string)
            return paster.paste(
                "synthetic refuted dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                confirmationSource: { source },
                targetIsFrontmost: { true },
                restoreDelay: restoreDelay,
                fallbackRestoreDelay: fallbackRestoreDelay,
                pasteConfirmationWait: 0.05,
                endWaitOnLikelyPaste: true
            )
        }
        let diagnostic = await MainActor.run { paster.lastConfirmationDiagnostic }
        assertEqual(outcome.copyReason, .pasteNotConfirmed, "a read with focus on something that can't take text is still not a paste")
        assertEqual(diagnostic?.context["likely_paste_ended_wait"], "false", "the read didn't end the wait")
        await MainActor.run { paster.cancelPendingClipboardRestore() }
    }

    await runSuite("A new paste stops the late-confirmation watch of the one before") {
        let pasteboardName = NSPasteboard.Name("TranscriptedPasteWaitSuperseded-\(UUID().uuidString)")
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }
        let source = await MainActor.run { ConfirmsOnAskSource(confirmOnAsk: nil) }

        let askedBeforeNextPaste = await MainActor.run { () -> Int in
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString("synthetic original clipboard", forType: .string)
            _ = paster.paste(
                "synthetic first dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                confirmationSource: { source },
                targetIsFrontmost: { true },
                restoreDelay: restoreDelay,
                fallbackRestoreDelay: fallbackRestoreDelay,
                pasteConfirmationWait: 5,
                endWaitOnLikelyPaste: true
            )
            let asked = source.asked
            _ = paster.paste(
                "synthetic next dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { true },
                pasteConfirmed: { true },
                restoreDelay: restoreDelay,
                fallbackRestoreDelay: fallbackRestoreDelay
            )
            return asked
        }
        await paster.waitForLateConfirmationWatch()
        let askedAfter = await MainActor.run { source.asked }
        assertEqual(askedAfter, askedBeforeNextPaste, "the earlier paste's watch never asks the target again once a new paste starts")
        await paster.waitForPendingClipboardRestore()
        let finalClipboard = await MainActor.run { NSPasteboard(name: pasteboardName).string(forType: .string) }
        assertEqual(finalClipboard, "synthetic original clipboard", "the user's clipboard comes back after both pastes")
    }
}

/// A focus that can observe a paste and confirms it on the given Accessibility
/// check (never when nil), like an editor whose value updates a beat after the
/// clipboard read.
@MainActor
private final class ConfirmsOnAskSource: ClipboardPasteConfirmationSource {
    private let confirmOnAsk: Int?
    private let clearlyNotTextEntry: Bool
    private(set) var asked = 0

    init(confirmOnAsk: Int?, clearlyNotTextEntry: Bool = false) {
        self.confirmOnAsk = confirmOnAsk
        self.clearlyNotTextEntry = clearlyNotTextEntry
    }

    var canObservePaste: Bool { true }
    var focusIsClearlyNotTextEntry: Bool { clearlyNotTextEntry }

    func confirmationMode(
        _ text: String,
        clipboardWasRead: Bool,
        clipboardReadAt: CFAbsoluteTime?,
        pasteDispatchedAt: CFAbsoluteTime
    ) -> String? {
        asked += 1
        guard let confirmOnAsk, asked >= confirmOnAsk else { return nil }
        return "text_value"
    }

    func diagnosticsContext(clipboardReadAt: CFAbsoluteTime?, pasteDispatchedAt: CFAbsoluteTime) -> [String: String] {
        [:]
    }
}
