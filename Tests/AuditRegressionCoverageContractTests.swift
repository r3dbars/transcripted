// The pasteback suite runs the real ClipboardRestoringTextPaster. The other three suites still
// read source as text: MeetingOverlayController, MenuBarPanelController, and
// TranscriptionQueueCoordinator are not compiled into the fast runner (see
// docs/testing-source-text-inventory.md for the seam each one needs).

import AppKit
import Foundation

@MainActor
func testAuditRegressionCoverageContract() async {
    runSuite("AuditRegressionCoverageContract — meeting overlay duration updates are whole-second throttled") {
        let source = readSourceFixture("Sources/UI/Overlay/MeetingOverlayController.swift")
        assertTrue(
            source.contains("session.$recordingDuration"),
            "meeting overlay should subscribe to the recording-duration publisher directly"
        )
        assertTrue(
            source.contains(".map { Int($0) }") && source.contains(".removeDuplicates()"),
            "5 Hz recording-duration ticks must be collapsed to whole seconds before pushing a full overlay layout update"
        )
    }

    runSuite("AuditRegressionCoverageContract — menubar duration updates stay deduped to whole seconds") {
        let source = readSourceFixture("Sources/UI/MenuBar/MenuBarPanelController.swift")
        assertTrue(
            source.contains(".map { Int($0) }"),
            "menubar recording-duration sink should collapse subsecond ticks"
        )
        assertTrue(
            source.contains(".removeDuplicates()"),
            "menubar timer refreshes should skip unchanged whole-second values"
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

    runSuite("AuditRegressionCoverageContract — failed meeting queue survives synchronous terminal failures") {
        // Queue-dispatch logic moved to TranscriptionQueueCoordinator.swift
        // (audit 2026-07-08 wave 2, W2-B).
        let source = readSourceFixture("Sources/Meeting/TranscriptionQueueCoordinator.swift")
        assertTrue(
            source.contains("finalizeBackgroundTranscriptionStateIfNeeded()"),
            "terminal display-status handlers should revisit background queue state"
        )
        assertTrue(
            source.contains("handleBackgroundTranscriptionWorkChanged(snapshot: currentBackgroundTranscriptionWorkSnapshot)"),
            "queue draining should have a no-argument path for terminal status changes that do not publish activeCount"
        )
    }
}
