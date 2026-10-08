// The pasteback suite runs the real ClipboardRestoringTextPaster, and the
// whole-second suite runs the shared duration publisher the menu bar uses.
// The meeting overlay subscribes through the same wholeSecondTicks() publisher.

import AppKit
import Combine
import Foundation

@MainActor
func testAuditRegressionCoverageContract() async {
    runSuite("Recording-duration ticks reach timer labels once per whole second") {
        let ticks = PassthroughSubject<TimeInterval, Never>()
        var seconds: [Int] = []
        let subscription = ticks.wholeSecondTicks().sink { seconds.append($0) }
        for tick in [0.0, 0.2, 0.4, 0.6, 0.8, 1.0, 1.2, 1.4, 1.99, 2.0, 2.2, 5.0] {
            ticks.send(tick)
        }
        subscription.cancel()
        assertEqual(
            seconds,
            [0, 1, 2, 5],
            "5 Hz duration ticks must collapse to one update per whole second before a refresh"
        )
    }

    runSuite("AuditRegressionCoverageContract — pasteback focus changes downgrade to copied before Cmd+V") {
        // Behavior: run the real paster against a private pasteboard with a
        // captured target that is not the frontmost app and no time to activate.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("TranscriptedAuditFocusDrift-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("synthetic original clipboard", forType: .string)
        var dispatchedCommandV = false
        let focusDrift = ClipboardRestoringTextPaster().paste(
            "synthetic focus drift dictation",
            target: DictationPasteTarget(processIdentifier: -1, bundleIdentifier: "invalid.test.focus-drift"),
            activationWait: 0,
            pasteboard: pasteboard,
            accessibilityTrusted: { true },
            requestAccessibilityTrust: {},
            pasteDispatcher: { dispatchedCommandV = true; return true },
            pasteConfirmed: { true }
        )
        assertFalse(
            dispatchedCommandV,
            "pasteback must re-check the captured target app before dispatching Cmd+V"
        )
        assertEqual(
            focusDrift.copyReason,
            .focusChanged,
            "focus drift should produce an honest copied result instead of a false pasted result"
        )
        assertEqual(
            pasteboard.string(forType: .string),
            "synthetic focus drift dictation",
            "a focus-drift fallback should leave the text on the clipboard for a manual paste"
        )

        // The dispatcher's own result is still the fallback seam: a Cmd+V
        // that could not be posted becomes a copy, never a pasted claim.
        let failedDispatchBoard = NSPasteboard(name: NSPasteboard.Name("TranscriptedAuditDispatchFailure-\(UUID().uuidString)"))
        failedDispatchBoard.clearContents()
        failedDispatchBoard.setString("synthetic original clipboard", forType: .string)
        let failedDispatch = ClipboardRestoringTextPaster().paste(
            "synthetic failed dispatch dictation",
            pasteboard: failedDispatchBoard,
            accessibilityTrusted: { true },
            requestAccessibilityTrust: {},
            pasteDispatcher: { false },
            pasteConfirmed: { true }
        )
        assertEqual(
            failedDispatch.copyReason,
            .pasteEventCreationFailed,
            "the paste dispatch result must remain an explicit fallback seam"
        )
        assertEqual(
            failedDispatchBoard.string(forType: .string),
            "synthetic failed dispatch dictation",
            "a failed dispatch should leave the text on the clipboard for a manual paste"
        )
    }
}
