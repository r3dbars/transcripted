// ClipboardRestoringTextPasterTests.swift
// Tests for safe clipboard restore behavior.
//
// Most suites run the real ClipboardRestoringTextPaster against real or fake
// NSPasteboards. The AX bounds and the focused-element type check run through
// FocusedTextPasteConfirmationPolicy.boundedFocusedElement with a fake AX reader.
// The delivery notice after a dictation is DictationDeliveryPresentation. One
// suite checks the Not pasted notice preview through
// NotchIslandDictationContent.Message.make.

import AppKit
import Foundation

/// True if the task completes before a generous give-up margin. The margin only keeps a
/// broken wait from hanging the suite; it is not a speed limit. A stuck task is left
/// behind rather than awaited, so a wait that never ends still reports false.
private func clipboardTestFinishes(_ task: Task<Void, Never>) async -> Bool {
    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func resume(_ value: Bool) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }
    return await withCheckedContinuation { continuation in
        let once = Once(continuation)
        Task { await task.value; once.resume(true) }
        Task { try? await Task.sleep(nanoseconds: 30_000_000_000); once.resume(false) }
    }
}

func testClipboardRestoringTextPaster() async {
    await MainActor.run {
        runSuite("ClipboardRestoringTextPaster cancellation while restoring the previous paste cannot restart") {
            let board = FakeClipboardPasteboard(initialString: "original")
            let paster = ClipboardRestoringTextPaster()
            _ = paster.paste("previous", pasteboard: board, accessibilityTrusted: { true },
                requestAccessibilityTrust: {}, pasteDispatcher: { true }, pasteConfirmed: { true })
            board.onStringRead = {
                board.onStringRead = nil
                paster.restorePendingClipboardNow()
            }
            var dispatched = false
            let result = paster.paste("cancelled next paste", pasteboard: board,
                accessibilityTrusted: { true }, requestAccessibilityTrust: {},
                pasteDispatcher: { dispatched = true; return true }, pasteConfirmed: { true })
            assertEqual(result.failureReason, .cancelled, "restoring a prior clipboard cannot mint a new operation after cancellation")
            assertFalse(dispatched, "cancelled operation must not dispatch")
            assertEqual(board.string(forType: .string), "original", "prior clipboard should remain restored")
        }
        runSuite("ClipboardRestoringTextPaster cancellation inside initial write restores the original snapshot") {
            let board = FakeClipboardPasteboard(initialString: "original")
            let paster = ClipboardRestoringTextPaster()
            board.onStringWritten = {
                board.onStringWritten = nil
                paster.restorePendingClipboardNow()
            }
            var dispatched = false
            let result = paster.paste("cancelled", pasteboard: board,
                accessibilityTrusted: { true }, requestAccessibilityTrust: {},
                pasteDispatcher: { dispatched = true; return true }, pasteConfirmed: { true })
            assertEqual(result.failureReason, .cancelled, "write callback cancellation must remain terminal")
            assertFalse(dispatched, "write callback cancellation must not dispatch")
            assertEqual(board.string(forType: .string), "original", "rollback must restore before the pending record exists")
        }

        runSuite("ClipboardRestoringTextPaster cancellation during activation cannot copy or dispatch") {
            let board = FakeClipboardPasteboard(initialString: "original")
            let paster = ClipboardRestoringTextPaster()
            var cancelled = false
            var dispatched = false
            CFRunLoopPerformBlock(CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue) {
                MainActor.assumeIsolated {
                    cancelled = true
                    paster.restorePendingClipboardNow()
                }
            }
            let result = paster.paste("cancelled dictation",
                target: DictationPasteTarget(processIdentifier: -1, bundleIdentifier: "invalid.test.target"),
                activationWait: 0.2, pasteboard: board,
                pasteDispatcher: { dispatched = true; return true })
            assertTrue(cancelled, "activation wait must run the queued cancellation")
            assertEqual(result.failureReason, .cancelled, "cancelled attempt cannot report copied")
            assertFalse(dispatched, "cancelled activation must never send Cmd+V")
            assertEqual(board.string(forType: .string), "original", "cancelled activation must preserve clipboard")
        }
        runSuite("ClipboardRestoringTextPaster cancellation during confirmation restores without fallback copy") {
            let board = FakeClipboardPasteboard(initialString: "original")
            let paster = ClipboardRestoringTextPaster()
            let result = paster.paste("cancelled dictation", pasteboard: board,
                accessibilityTrusted: { true }, requestAccessibilityTrust: {},
                pasteDispatcher: { true }, pasteConfirmed: {
                    paster.restorePendingClipboardNow()
                    return true
                })
            assertEqual(result.failureReason, .cancelled, "late confirmation must not resurrect a cancelled paste")
            assertEqual(board.string(forType: .string), "original", "no recovery copy may overwrite restored clipboard")
        }

        runSuite("ClipboardRestoringTextPaster stops fetching lazy data after snapshot budget is full") {
            let board = FakeClipboardPasteboard(initialString: nil)
            let item = NSPasteboardItem()
            for type in [NSPasteboard.PasteboardType.string, .html, .rtf] {
                assertTrue(item.setData(Data([1]), forType: type), "budget fixture must install each supported pasteboard representation")
            }
            assertEqual(item.types.count, 3, "budget fixture must expose three representations")
            _ = board.writePasteboardItems([item])
            let data = Data(repeating: 1, count: TranscriptedConstants.clipboardSnapshotMaxTypeBytes)
            var reads = 0
            let snapshot = ClipboardRestoringTextPaster().snapshotPasteboardItems(from: board) { _, _ in
                reads += 1
                return data
            }
            assertEqual(reads, 2, "do not materialize a third representation after retaining the full budget")
            assertTrue(snapshot.isComplete, "same item still has restorable representations")
            let secondItem = NSPasteboardItem()
            secondItem.setString("another item", forType: .string)
            _ = board.writePasteboardItems([item, secondItem])
            reads = 0
            let incomplete = ClipboardRestoringTextPaster().snapshotPasteboardItems(from: board) { _, _ in
                reads += 1
                return data
            }
            assertEqual(reads, 2, "later items must not trigger fetches after the total budget")
            assertFalse(incomplete.isComplete, "an item with no saved representation must still block destructive paste")
        }

        runSuite("ClipboardRestoringTextPaster preserves a clipboard changed during lazy snapshot") {
            let board = FakeClipboardPasteboard(initialString: "old")
            board.onPasteboardItemsRead = { _ = board.setString("new external copy", forType: .string) }
            let paster = ClipboardRestoringTextPaster()
            var dispatched = false
            let outcome = paster.paste("dictation", pasteboard: board,
                accessibilityTrusted: { true }, requestAccessibilityTrust: {},
                pasteDispatcher: { dispatched = true; return true },
                pasteConfirmed: { true })
            board.onPasteboardItemsRead = nil
            assertFalse(dispatched, "do not send Cmd+V after losing clipboard snapshot ownership")
            assertEqual(outcome.failureReason, .clipboardSnapshotIncomplete, "changed snapshot must fail safely")
            assertEqual(board.string(forType: .string), "new external copy", "new clipboard must remain intact")
            assertNotNil(paster.lastPasteTiming?.measurements()["paste_ax_capture_ms"], "AX capture has separate timing")
            assertNotNil(paster.lastPasteTiming?.measurements()["paste_clipboard_snapshot_ms"], "snapshot has separate timing")
        }

        runSuite("DictationTargetConfirmationMode stays coarse and privacy-safe") {
            assertEqual(
                DictationTargetConfirmationMode.resolve(
                    outcome: .pasted,
                    diagnostic: ClipboardPasteConfirmationDiagnostic(
                        event: "dictation_paste_confirmed",
                        context: ["confirmation_mode": "text_value"]
                    )
                ),
                .textValue,
                "AX value confirmation should keep only its coarse mode"
            )
            assertEqual(
                DictationTargetConfirmationMode.resolve(
                    outcome: .copied("unconfirmed", reason: .pasteNotConfirmed),
                    diagnostic: ClipboardPasteConfirmationDiagnostic(
                        event: "dictation_paste_confirmation_diagnostics",
                        context: ["clipboard_read_after_dispatch": "false"]
                    )
                ),
                .none,
                "unconfirmed targets should not claim a confirmation mode"
            )
            assertEqual(
                DictationTargetConfirmationMode.resolve(
                    outcome: .likelyPasted,
                    diagnostic: ClipboardPasteConfirmationDiagnostic(
                        event: "dictation_paste_confirmation_diagnostics",
                        context: ["paste_evidence": "clipboard_read"]
                    )
                ),
                .clipboardRead,
                "a likely paste should report its clipboard-read evidence, not an Accessibility mode"
            )
            assertEqual(DictationTargetConfirmationMode.clipboardRead.rawValue, "clipboard_read", "analytics value stays coarse")
        }
    }

    await MainActor.run {
        runSuite("ClipboardRestoringTextPaster confirmation bounds synchronous AX reads") {
            // Promise: a busy editor can't stall delivery, because every AX read
            // on the system-wide and focused elements has a short timeout.
            let systemWide = AXUIElementCreateSystemWide()
            let focused = AXUIElementCreateApplication(getpid())
            var bounded: [(element: AXUIElement, timeout: Float)] = []
            let element = FocusedTextPasteConfirmationPolicy.boundedFocusedElement(
                systemWide: systemWide,
                setMessagingTimeout: { bounded.append(($0, $1)) },
                copyFocusedElement: { _ in focused }
            )
            assertTrue(element.map { CFEqual($0, focused) } == true, "the focused element comes back for confirmation")
            assertEqual(bounded.count, 2, "both the system-wide and the focused element are bounded")
            assertTrue(
                bounded.count == 2 && CFEqual(bounded[0].element, systemWide) && CFEqual(bounded[1].element, focused),
                "the system-wide element is bounded before the read, the focused one before its reads"
            )
            assertTrue(
                bounded.allSatisfy { $0.timeout > 0 && $0.timeout <= 0.1 },
                "paste confirmation should fail fast when a target editor is temporarily unresponsive"
            )
        }

        runSuite("ClipboardRestoringTextPaster timing separates dispatch from confirmation") {
            let pasteboard = NSPasteboard(
                name: NSPasteboard.Name("TranscriptedPasteTiming-\(UUID().uuidString)")
            )
            let paster = ClipboardRestoringTextPaster()
            let dictationText = "synthetic paste timing"
            var dispatchedAt: CFAbsoluteTime?

            pasteboard.clearContents()
            pasteboard.setString("synthetic original clipboard", forType: .string)
            let outcome = paster.paste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    dispatchedAt = CFAbsoluteTimeGetCurrent()
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                pasteConfirmed: {
                    guard let dispatchedAt else { return false }
                    return CFAbsoluteTimeGetCurrent() - dispatchedAt >= 0.06
                },
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 20_000_000,
                pasteConfirmationWait: 0.15
            )

            let measurements = paster.lastPasteTiming?.measurements() ?? [:]
            assertEqual(outcome, .pasted, "the delayed synthetic confirmation should succeed")
            assertNotNil(measurements["paste_prepare_ms"], "paste preparation should be measured")
            assertNotNil(measurements["paste_dispatch_ms"], "Cmd+V dispatch should be measured")
            assertNotNil(measurements["paste_clipboard_read_ms"], "the target clipboard read should be measured")
            assertTrue(
                (measurements["paste_clipboard_read_ms"] ?? 1_000) < 30,
                "an immediate target clipboard read should stay separate from the later confirmation"
            )
            assertTrue(
                (measurements["paste_confirmation_wait_ms"] ?? 0) >= 40,
                "the delayed confirmation should be visible as confirmation wait instead of dispatch time"
            )
        }

        runSuite("ClipboardRestoringTextPaster timing excludes non-confirmation work") {
            let pasteboard = NSPasteboard(
                name: NSPasteboard.Name("TranscriptedPasteTimingFailure-\(UUID().uuidString)")
            )
            let paster = ClipboardRestoringTextPaster()

            pasteboard.clearContents()
            pasteboard.setString("synthetic original clipboard", forType: .string)
            let outcome = paster.paste(
                "synthetic failed dispatch",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { false },
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 20_000_000
            )

            let measurements = paster.lastPasteTiming?.measurements() ?? [:]
            assertEqual(
                outcome.copyReason,
                .pasteEventCreationFailed,
                "the synthetic dispatcher failure should use the manual-copy fallback"
            )
            assertNil(
                measurements["paste_confirmation_wait_ms"],
                "fallback clipboard work must not be mislabeled as confirmation waiting"
            )

            let preDispatchRead = ClipboardPasteTiming(
                startedAt: 10,
                dispatchStartedAt: 11,
                dispatchFinishedAt: 11.01,
                clipboardReadAt: 10.5,
                confirmationStartedAt: nil,
                confirmationFinishedAt: nil
            ).measurements()
            assertNil(
                preDispatchRead["paste_clipboard_read_ms"],
                "a clipboard manager read before Cmd+V must not look like an immediate target read"
            )
        }

        runSuite("ClipboardRestoringTextPaster stops waiting and reports a likely paste after a target reads") {
            if ProcessInfo.processInfo.environment["TRANSCRIPTED_SKIP_TIMING_SENSITIVE_TESTS"] == "1" {
                print("    SKIPPED: wall-clock timing proof — covered by local runs")
                return
            }
            let pasteboard = NSPasteboard(
                name: NSPasteboard.Name("TranscriptedPasteReadExit-\(UUID().uuidString)")
            )
            let paster = ClipboardRestoringTextPaster()
            let dictationText = "synthetic immediate target read"

            pasteboard.clearContents()
            pasteboard.setString("synthetic original clipboard", forType: .string)
            let outcome = paster.paste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                confirmationSource: { NeutralFocusConfirmationSource() },
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 20_000_000,
                pasteConfirmationWait: 0.35
            )

            let measurements = paster.lastPasteTiming?.measurements() ?? [:]
            assertEqual(
                outcome,
                .likelyPasted,
                "a frontmost target that reads the clipboard right after Cmd+V most likely pasted"
            )
            assertTrue(
                (measurements["paste_confirmation_wait_ms"] ?? 350) < 50,
                "a post-dispatch clipboard read should avoid the remaining 350ms wait when Auto Enter is off"
            )
        }

        runSuite("ClipboardRestoringTextPaster.capture — focused element cast is crash-proof") {
            // Regression: kAXFocusedUIElementAttribute's CFTypeRef was force-cast
            // straight to AXUIElement with no type check. Swift can't verify that
            // cast at runtime, so a value of the wrong CF type must be refused
            // before any AX API sees it.
            let systemWide = AXUIElementCreateSystemWide()
            var bounded: [AXUIElement] = []
            let wrongType = FocusedTextPasteConfirmationPolicy.boundedFocusedElement(
                systemWide: systemWide,
                setMessagingTimeout: { element, _ in bounded.append(element) },
                copyFocusedElement: { _ in "not an AXUIElement" as CFString }
            )
            assertNil(wrongType, "a mismatched CF type degrades to no confirmation")
            assertEqual(bounded.count, 1, "the wrong object is never handed to an AX API")

            let missing = FocusedTextPasteConfirmationPolicy.boundedFocusedElement(
                systemWide: systemWide,
                setMessagingTimeout: { _, _ in },
                copyFocusedElement: { _ in nil }
            )
            assertNil(missing, "no focused element means no confirmation")
        }

        runSuite("An ambiguous paste reads as pasted and never offers a duplicate paste") {
            assertEqual(
                DictationDeliveryPresentation.resolve(
                    outcome: .likelyPasted, saveFailureMessage: nil, autoSend: .disabled, autoSendExpected: true
                ),
                .clipboardNotice("Pasted. Press Return to send it."),
                "a likely paste tells Auto Enter users to press Return themselves"
            )
            assertEqual(
                DictationDeliveryPresentation.resolve(
                    outcome: .likelyPasted, saveFailureMessage: nil, autoSend: .disabled, autoSendExpected: false
                ),
                .success(title: "Pasted"),
                "without Auto Enter a likely paste is just Pasted"
            )
            assertEqual(
                DictationDeliveryPresentation.resolve(
                    outcome: .likelyPasted, saveFailureMessage: "Couldn't save.", autoSend: .disabled, autoSendExpected: true
                ),
                .error("Couldn't save."),
                "a save failure still surfaces after a likely paste"
            )
        }

        runSuite("A clipboard fallback is a calm Not pasted notice, and an unconfirmed paste says so") {
            assertEqual(
                DictationDeliveryPresentation.resolve(
                    outcome: .copied("Press ⌘V.", reason: .pasteNotConfirmed),
                    saveFailureMessage: nil, autoSend: .disabled, autoSendExpected: false
                ),
                .notPasted(message: "Press ⌘V.", unconfirmed: true),
                "an unconfirmed paste uses the Not pasted notice and says it couldn't confirm"
            )
            assertEqual(
                DictationDeliveryPresentation.resolve(
                    outcome: .copied("Press ⌘V.", reason: .focusChanged),
                    saveFailureMessage: nil, autoSend: .disabled, autoSendExpected: false
                ),
                .notPasted(message: "Press ⌘V.", unconfirmed: false),
                "a focus change is a plain Not pasted notice"
            )
            assertEqual(
                DictationDeliveryPresentation.resolve(
                    outcome: .copied("Press ⌘V.", reason: .focusChanged),
                    saveFailureMessage: "Couldn't save.", autoSend: .disabled, autoSendExpected: false
                ),
                .error("Press ⌘V. Couldn't save."),
                "a simultaneous save failure keeps the clipboard-recovery message"
            )
            assertEqual(
                DictationDeliveryPresentation.resolve(
                    outcome: .failed("Clipboard too big.", reason: .clipboardSnapshotIncomplete),
                    saveFailureMessage: nil, autoSend: .disabled, autoSendExpected: false
                ),
                .clipboardBusy(message: "Clipboard too big."),
                "words that never reached the clipboard are offered back"
            )
            assertEqual(
                DictationDeliveryPresentation.resolve(
                    outcome: .failed("Paste failed.", reason: .unknown),
                    saveFailureMessage: "Couldn't save.", autoSend: .disabled, autoSendExpected: false
                ),
                .error("Paste failed. Couldn't save."),
                "a failed paste and a failed save are both reported"
            )
        }

        runSuite("A confirmed paste shows the Auto Enter result") {
            assertEqual(
                DictationDeliveryPresentation.resolve(
                    outcome: .pasted, saveFailureMessage: nil, autoSend: .sent(.enter), autoSendExpected: true
                ),
                .success(title: DictationAutoSendOutcome.sent(.enter).confirmationTitle ?? ""),
                "a sent paste names the key it pressed"
            )
            assertEqual(
                DictationDeliveryPresentation.resolve(
                    outcome: .pasted, saveFailureMessage: nil, autoSend: .failed(.targetChanged), autoSendExpected: true
                ),
                .error(DictationAutoSendFailure.targetChanged.message),
                "a paste whose send failed says why"
            )
            assertEqual(
                DictationDeliveryPresentation.resolve(
                    outcome: .pasted, saveFailureMessage: nil, autoSend: .disabled, autoSendExpected: false
                ),
                .success(title: "Pasted")
            )
        }

        runSuite("Diagnostics and analytics report the delivery value dictation history saves") {
            assertEqual(
                TextPasteOutcome.likelyPasted.deliveryProperties,
                ["delivery": DictationDelivery.pasted.rawValue],
                "a likely paste is recorded as pasted, not by its diagnostic name"
            )
            assertTrue(
                TextPasteOutcome.likelyPasted.diagnosticName != DictationDelivery.pasted.rawValue,
                "the diagnostic name differs, which is why events must not use it for delivery"
            )
            assertEqual(
                TextPasteOutcome.copied("Press ⌘V.", reason: .focusChanged).deliveryProperties,
                ["delivery": "copied"]
            )
            assertEqual(
                TextPasteOutcome.failed("Paste failed.", reason: .temporaryClipboardWriteFailed).deliveryProperties,
                ["delivery": "failed", "failure_kind": "temporary_clipboard_write_failed"],
                "a failed paste carries its coarse failure kind"
            )
        }

        runSuite("The Not pasted notice previews the dictation it would paste") {
            typealias Message = NotchIslandDictationContent.Message
            let notPasted = Message.make(
                tone: .notice,
                text: "Not pasted",
                errorActionTitle: "Retry",
                notPasted: .init(text: "the words", actionTitle: "Paste", hint: "Click where it goes.", dismissSeconds: 15)
            )
            assertEqual(notPasted.preview, "the words", "the Not pasted notice shows the dictation it would paste")
            assertEqual(notPasted.actionTitle, "Paste", "the not-pasted action replaces the error action")
            assertEqual(notPasted.dismissSeconds, 15, "the not-pasted notice counts down")
            assertEqual(notPasted.hint, "Click where it goes.", "the not-pasted hint rides along")

            let plain = Message.make(tone: .error, text: "Failed", errorActionTitle: "Retry", notPasted: nil)
            assertEqual(plain.preview, nil, "a plain error has no preview")
            assertEqual(plain.actionTitle, "Retry", "a plain error keeps its own action")
            assertEqual(plain.dismissSeconds, nil, "a plain error does not count down")
            assertEqual(plain.hint, nil, "a plain error has no hint")
        }

        runSuite("DictationPasteRetryTelemetry — emits one aggregate terminal event") {
            var captures: [(String, [String: String])] = []
            var attempts = 0
            let outcome = DictationPasteRetryTelemetry.performUserRetry(
                track: { event, properties in captures.append((event, properties)) },
                retry: {
                    attempts += 1
                    return .copied(
                        "synthetic private path /Users/test/secret.txt",
                        reason: .pasteNotConfirmed
                    )
                }
            )

            assertEqual(attempts, 1, "retry telemetry should invoke the retry exactly once")
            assertEqual(captures.count, 1, "retry telemetry should emit one terminal event")
            assertEqual(captures.first?.0, "dictation_paste_retry_completed", "retry telemetry should use the canonical event")
            assertEqual(
                captures.first?.1,
                ["reason": "paste_not_confirmed", "result": "copied"],
                "retry telemetry should expose only coarse outcome properties"
            )
            assertEqual(
                outcome,
                .copied(
                    "synthetic private path /Users/test/secret.txt",
                    reason: .pasteNotConfirmed
                ),
                "retry telemetry should preserve the actual user-facing outcome"
            )
        }

        runSuite("DictationPasteRetryTelemetry — a likely paste reports its own coarse result") {
            var captured: [String: String] = [:]
            let outcome = DictationPasteRetryTelemetry.performUserRetry(
                track: { _, properties in captured = properties },
                retry: { .likelyPasted }
            )
            assertEqual(captured, ["result": "likely_pasted"], "a likely paste should be countable apart from confirmed pastes")
            assertEqual(outcome, .likelyPasted, "retry telemetry should preserve the actual outcome")
        }

        runSuite("DictationPasteRetryTelemetry — preserves typed failure reason without private copy") {
            var captured: [String: String] = [:]
            let outcome = DictationPasteRetryTelemetry.performUserRetry(
                track: { _, properties in captured = properties },
                retry: {
                    .failed(
                        "private failure detail /Users/test/secret.txt",
                        reason: .fallbackClipboardRecoveryUnverified
                    )
                }
            )

            assertEqual(
                captured,
                ["reason": "fallback_clipboard_recovery_unverified", "result": "failed"],
                "retry telemetry should keep only the typed terminal failure"
            )
            assertEqual(outcome.failureReason, .fallbackClipboardRecoveryUnverified, "the user-facing outcome should retain the same typed cause")
            assertFalse(captured.values.contains(where: { $0.contains("/Users/") }), "retry telemetry must not carry raw failure copy")
        }

        runSuite("ClipboardRestoringTextPaster production confirmation adapters — Codex, Notes, and browser editors") {
            let cases: [(SyntheticPasteTargetAdapter.EditorKind, String)] = [
                (.codex, "text_value"),
                (.notes, "selection_range"),
                (.browser, "target_change_notification"),
            ]

            for (kind, expectedMode) in cases {
                let pasteboard = NSPasteboard(name: NSPasteboard.Name("TranscriptedProductionPasteAdapter-\(UUID().uuidString)"))
                let paster = ClipboardRestoringTextPaster()
                let adapter = SyntheticPasteTargetAdapter(kind: kind)
                let dictationText = "synthetic \(kind.rawValue) dictation"

                pasteboard.clearContents()
                pasteboard.setString("synthetic original clipboard", forType: .string)
                let outcome = paster.paste(
                    dictationText,
                    pasteboard: pasteboard,
                    accessibilityTrusted: { true },
                    requestAccessibilityTrust: {},
                    pasteDispatcher: {
                        let clipboardRead = pasteboard.string(forType: .string)
                        adapter.receivePaste(dictationText, clipboardRead: clipboardRead != nil)
                        return true
                    },
                    confirmationSource: { adapter },
                    targetIsFrontmost: { adapter.isFocused },
                    restoreDelay: 5_000_000,
                    fallbackRestoreDelay: 20_000_000,
                    pasteConfirmationWait: 0.03
                )

                assertEqual(outcome, .pasted, "\(kind.rawValue) should confirm through its production adapter")
                assertEqual(adapter.pasteCount, 1, "\(kind.rawValue) should receive exactly one paste gesture")
                assertEqual(
                    paster.lastConfirmationDiagnostic?.context["confirmation_mode"],
                    expectedMode,
                    "\(kind.rawValue) should report only its coarse confirmation mode"
                )
            }
        }

        runSuite("ClipboardRestoringTextPaster production adapters — focus loss is sticky") {
            let kinds: [SyntheticPasteTargetAdapter.EditorKind] = [.codex, .notes, .browser]
            for kind in kinds {
                let pasteboard = NSPasteboard(name: NSPasteboard.Name("TranscriptedProductionFocusAdapter-\(UUID().uuidString)"))
                let paster = ClipboardRestoringTextPaster()
                let adapter = SyntheticPasteTargetAdapter(kind: kind)
                let dictationText = "synthetic focus loss \(kind.rawValue)"
                var focusChecks = 0

                pasteboard.clearContents()
                pasteboard.setString("synthetic focus clipboard", forType: .string)
                let outcome = paster.paste(
                    dictationText,
                    pasteboard: pasteboard,
                    accessibilityTrusted: { true },
                    requestAccessibilityTrust: {},
                    pasteDispatcher: {
                        adapter.receivePaste(dictationText, clipboardRead: false)
                        return true
                    },
                    confirmationSource: { adapter },
                    targetIsFrontmost: {
                        focusChecks += 1
                        return focusChecks == 1
                    },
                    pasteConfirmationWait: 0
                )

                assertEqual(
                    outcome,
                    .copied(
                        "Focus moved before Transcripted could confirm paste. The text is on your clipboard — press ⌘V.",
                        reason: .focusChanged
                    ),
                    "\(kind.rawValue) focus loss should not become neutral confirmation-unavailable feedback"
                )
                assertEqual(adapter.pasteCount, 1, "\(kind.rawValue) focus loss should not duplicate Cmd+V")
                assertEqual(
                    pasteboard.string(forType: .string),
                    dictationText,
                    "\(kind.rawValue) focus loss should keep text available for manual recovery"
                )
            }
        }

        runSuite("ClipboardRestoringTextPaster confirmation diagnostics survive the local event sanitizer") {
            // Regression: "target_text_observable" contained the sensitive fragment
            // "text", so LocalObservabilityPayloadSanitizer blanked the boolean to
            // "[redacted-sensitive-value]" in events.jsonl and blinded a paste
            // investigation. Pin that every emitted diagnostics key stays readable.
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("TranscriptedDiagnosticsSanitizer-\(UUID().uuidString)"))
            let paster = ClipboardRestoringTextPaster()
            let adapter = SyntheticPasteTargetAdapter(kind: .codex, appliesPaste: false)

            pasteboard.clearContents()
            pasteboard.setString("synthetic original clipboard", forType: .string)
            let outcome = paster.paste(
                "synthetic unconfirmed dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { true },
                confirmationSource: { adapter },
                targetIsFrontmost: { true },
                pasteConfirmationWait: 0
            )

            assertEqual(
                outcome.copyReason,
                .pasteNotConfirmed,
                "an unread, unconfirmed paste with a live confirmation source should report paste-not-confirmed"
            )
            let diagnostic = paster.lastConfirmationDiagnostic
            assertEqual(
                diagnostic?.event,
                "dictation_paste_confirmation_diagnostics",
                "the unconfirmed path should emit the confirmation diagnostics event"
            )
            let context = diagnostic?.context ?? [:]
            assertTrue(
                context.keys.contains("target_value_observable"),
                "the AX-value observability flag should be present under its sanitizer-safe name"
            )
            assertEqual(context["paste_evidence"], "none", "an unread paste has no delivery evidence")
            for key in context.keys {
                assertFalse(
                    PayloadSanitizationCore.shouldDrop(
                        key: key,
                        sensitiveFragments: LocalObservabilityPayloadSanitizer.sensitiveKeyFragments
                    ),
                    "diagnostics key \(key) must not match a sensitive fragment or events.jsonl loses the value"
                )
            }

            let sanitized = LocalObservabilityPayloadSanitizer.sanitize(
                ObservabilityEvent(
                    timestamp: "2026-08-24T00:00:00Z",
                    level: "warning",
                    engine: "overlay",
                    event: diagnostic?.event ?? "dictation_paste_confirmation_diagnostics",
                    message: "Paste delivery could not be confirmed from privacy-safe target signals",
                    context: context,
                    appVersion: "1.0.0",
                    osVersion: "26.0"
                )
            )
            for (key, value) in context {
                assertEqual(
                    sanitized.context?[key],
                    value,
                    "diagnostics value for \(key) should reach events.jsonl unredacted"
                )
            }
        }

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

        runSuite("ClipboardRestoringTextPaster.restorePasteboardItems — incomplete snapshots do not clear clipboard") {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("TranscriptedClipboardTest-\(UUID().uuidString)"))
            let paster = ClipboardRestoringTextPaster()
            let customType = NSPasteboard.PasteboardType("com.transcripted.clipboard-test")
            let customData = Data(repeating: 0xab, count: TranscriptedConstants.clipboardSnapshotMaxTypeBytes + 1)
            let originalString = "original rich clipboard"
            let temporary = "temporary dictation"

            let stringItem = NSPasteboardItem()
            stringItem.setString(originalString, forType: .string)
            let customItem = NSPasteboardItem()
            customItem.setData(customData, forType: customType)
            pasteboard.clearContents()
            pasteboard.writeObjects([stringItem, customItem])
            let snapshot = paster.snapshotPasteboardItems(from: pasteboard)
            assertFalse(snapshot.isComplete, "oversized pasteboard data should mark the snapshot incomplete")

            pasteboard.clearContents()
            pasteboard.setString(temporary, forType: .string)
            let temporaryChangeCount = pasteboard.changeCount

            paster.restorePasteboardItems(
                snapshot,
                temporaryString: temporary,
                temporaryChangeCount: temporaryChangeCount,
                to: pasteboard
            )

            let restoredItems = pasteboard.pasteboardItems ?? []
            assertEqual(restoredItems.count, 1, "restore should keep cheap textual data without re-materializing custom data")
            assertEqual(
                restoredItems.first?.string(forType: .string),
                temporary,
                "incomplete snapshots should leave the temporary clipboard untouched instead of clearing it"
            )
            assertNil(restoredItems.first?.data(forType: customType), "oversized data should not be eagerly snapshotted")
        }

        runSuite("ClipboardRestoringTextPaster.snapshotPasteboardItems — an item keeps its cheap types when a heavy one is skipped") {
            // A screenshot puts a PNG and a much larger TIFF on the same
            // item. Skipping the TIFF must not abort paste-back: the item is
            // still restorable from its PNG. Only an item that loses every
            // representation makes the snapshot incomplete.
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("TranscriptedClipboardTest-\(UUID().uuidString)"))
            let paster = ClipboardRestoringTextPaster()
            let heavyType = NSPasteboard.PasteboardType("com.transcripted.clipboard-test-heavy")
            let heavyData = Data(repeating: 0xef, count: TranscriptedConstants.clipboardSnapshotMaxTypeBytes + 1)
            let originalString = "original clipboard next to a heavy representation"

            let item = NSPasteboardItem()
            item.setString(originalString, forType: .string)
            item.setData(heavyData, forType: heavyType)
            pasteboard.clearContents()
            pasteboard.writeObjects([item])

            let snapshot = paster.snapshotPasteboardItems(from: pasteboard)

            assertTrue(snapshot.isComplete, "dropping one heavy type from an item that still has a cheap type must not mark the snapshot incomplete")
            assertEqual(snapshot.items.count, 1, "the item itself should be kept")
            assertEqual(
                snapshot.items.first?[.string].flatMap { String(data: $0, encoding: .utf8) },
                originalString,
                "the cheap representation should be captured for restore"
            )
            assertNil(snapshot.items.first?[heavyType], "the heavy representation should be skipped, not copied")
        }

        runSuite("ClipboardRestoringTextPaster.paste — incomplete snapshots preserve current clipboard") {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("TranscriptedClipboardTest-\(UUID().uuidString)"))
            let paster = ClipboardRestoringTextPaster()
            let customType = NSPasteboard.PasteboardType("com.transcripted.clipboard-test")
            let customData = Data(repeating: 0xcd, count: TranscriptedConstants.clipboardSnapshotMaxTypeBytes + 1)
            let customItem = NSPasteboardItem()
            customItem.setData(customData, forType: customType)
            pasteboard.clearContents()
            pasteboard.writeObjects([customItem])
            var dispatchCount = 0

            let outcome = paster.paste(
                "synthetic just-finished dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    dispatchCount += 1
                    return true
                },
                pasteConfirmed: { true }
            )

            assertEqual(
                outcome,
                .failed(
                    "Couldn't paste automatically without risking your current clipboard. The dictation was saved, but paste-back did not run.",
                    reason: .clipboardSnapshotIncomplete
                ),
                "unsupported clipboard contents should block paste-back before replacing the user's clipboard"
            )
            assertEqual(dispatchCount, 0, "unsupported clipboard contents should not dispatch Cmd+V")
            assertEqual(
                pasteboard.pasteboardItems?.first?.data(forType: customType),
                customData,
                "unsupported clipboard contents should remain untouched"
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
                },
                confirmationSource: { NeutralFocusConfirmationSource() }
            )

            assertEqual(
                outcome,
                .copied(
                    ClipboardRestoringTextPaster.pasteNotConfirmedMessage,
                    reason: .pasteNotConfirmed
                ),
                "unverified paste dispatch should be reported as copied instead of pasted"
            )
            assertEqual(postCount, 1, "automatic paste should dispatch exactly once")
            assertEqual(
                observedTextAtPost,
                dictationText,
                "paste shortcut should only fire after the borrowed clipboard contains dictation text"
            )
        }

        runSuite("ClipboardRestoringTextPaster.paste — unconfirmed lazy clipboard stays manually pasteable") {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("TranscriptedUnconfirmedLazyClipboardTest-\(UUID().uuidString)"))
            let paster = ClipboardRestoringTextPaster()
            let dictationText = "synthetic lazy provider dictation"

            pasteboard.clearContents()
            pasteboard.setString("synthetic original clipboard", forType: .string)
            let outcome = paster.paste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { true },
                confirmationSource: { NeutralFocusConfirmationSource() },
                pasteConfirmationWait: 0.01
            )

            assertEqual(
                outcome,
                .copied(
                    ClipboardRestoringTextPaster.pasteNotConfirmedMessage,
                    reason: .pasteNotConfirmed
                ),
                "unconfirmed paste should leave the dictation available for manual recovery"
            )
            assertEqual(
                pasteboard.string(forType: .string),
                dictationText,
                "unconfirmed lazy clipboard content should be materialized before provider cleanup"
            )
        }

        runSuite("ClipboardRestoringTextPaster.paste — empty clipboard is recovered with verified dictation") {
            let pasteboard = FakeClipboardPasteboard(initialString: "synthetic original clipboard")
            let paster = ClipboardRestoringTextPaster()

            let outcome = paster.paste(
                "synthetic unconfirmed dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    pasteboard.clearContents()
                    return true
                },
                confirmationSource: { NeutralFocusConfirmationSource() },
                pasteConfirmationWait: 0
            )

            assertEqual(
                outcome,
                .copied(
                    ClipboardRestoringTextPaster.pasteNotConfirmedMessage,
                    reason: .pasteNotConfirmed
                ),
                "an unconfirmed paste should recover a truly empty clipboard with a verified copy"
            )
            assertEqual(
                pasteboard.string(forType: .string),
                "synthetic unconfirmed dictation",
                "the dictation should be recopied after the paste path clears the clipboard"
            )
            assertEqual(
                paster.lastConfirmationDiagnostic?.context["clipboard_fallback_state"],
                "dictation_present",
                "the diagnostic should report the verified recovery copy"
            )
        }

        runSuite("ClipboardRestoringTextPaster.paste — user clipboard change is not reported as copied") {
            let pasteboard = FakeClipboardPasteboard(initialString: "synthetic original clipboard")
            let paster = ClipboardRestoringTextPaster()

            let outcome = paster.paste(
                "synthetic unconfirmed dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    pasteboard.clearContents()
                    pasteboard.setString("synthetic user copy", forType: .string)
                    return true
                },
                confirmationSource: { NeutralFocusConfirmationSource() },
                pasteConfirmationWait: 0
            )

            assertEqual(
                outcome,
                .failed(
                    "Transcripted sent paste, but could not confirm it or place a recovery copy on the clipboard. Check your dictation history.",
                    reason: .fallbackClipboardRecoveryUnverified
                ),
                "an unconfirmed paste must not claim copied delivery after a different user copy"
            )
            assertEqual(
                pasteboard.string(forType: .string),
                "synthetic user copy",
                "a user clipboard change should remain untouched"
            )
            assertEqual(
                paster.lastConfirmationDiagnostic?.context["clipboard_fallback_state"],
                "clipboard_changed",
                "the diagnostic should distinguish a user clipboard change from a verified recovery copy"
            )
        }

        runSuite("ClipboardRestoringTextPaster.paste — rich clipboard change is preserved and diagnosed") {
            let pasteboard = FakeClipboardPasteboard(initialString: "synthetic original clipboard")
            let paster = ClipboardRestoringTextPaster()
            let richType = NSPasteboard.PasteboardType("com.transcripted.synthetic-rich-copy")
            let richData = Data([0xca, 0xfe])

            let outcome = paster.paste(
                "synthetic unconfirmed dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    let richItem = NSPasteboardItem()
                    richItem.setData(richData, forType: richType)
                    pasteboard.clearContents()
                    pasteboard.writePasteboardItems([richItem])
                    return true
                },
                confirmationSource: { NeutralFocusConfirmationSource() },
                pasteConfirmationWait: 0
            )

            assertEqual(
                outcome,
                .failed(
                    "Transcripted sent paste, but could not confirm it or place a recovery copy on the clipboard. Check your dictation history.",
                    reason: .fallbackClipboardRecoveryUnverified
                ),
                "an unconfirmed paste must not claim copied delivery after a rich user copy"
            )
            assertEqual(
                pasteboard.pasteboardItems?.first?.data(forType: richType),
                richData,
                "a rich user clipboard change should remain untouched"
            )
            assertEqual(
                paster.lastConfirmationDiagnostic?.context["clipboard_fallback_state"],
                "clipboard_changed",
                "a non-text clipboard item is changed, not empty"
            )
        }

        runSuite("ClipboardRestoringTextPaster.paste — clipboard generation change during read is preserved") {
            let dictationText = "synthetic unconfirmed dictation"
            let pasteboard = FakeClipboardPasteboard(initialString: "synthetic original clipboard")
            let paster = ClipboardRestoringTextPaster()

            let outcome = paster.paste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    pasteboard.clearContents()
                    pasteboard.setString(dictationText, forType: .string)
                    pasteboard.onStringRead = {
                        pasteboard.onStringRead = nil
                        pasteboard.setString("synthetic clipboard-manager rewrite", forType: .string)
                    }
                    return true
                },
                confirmationSource: { NeutralFocusConfirmationSource() },
                pasteConfirmationWait: 0
            )

            assertEqual(
                outcome,
                .failed(
                    "Transcripted sent paste, but could not confirm it or place a recovery copy on the clipboard. Check your dictation history.",
                    reason: .fallbackClipboardRecoveryUnverified
                ),
                "text read from a superseded clipboard generation must not count as verified recovery"
            )
            assertEqual(
                pasteboard.string(forType: .string),
                "synthetic clipboard-manager rewrite",
                "a clipboard-manager rewrite during a lazy read should remain untouched"
            )
            assertEqual(
                paster.lastConfirmationDiagnostic?.context["clipboard_fallback_state"],
                "clipboard_changed",
                "the diagnostic should classify a generation race as a clipboard change"
            )
        }

        runSuite("ClipboardRestoringTextPaster.paste — clipboard generation change during item query is preserved") {
            let pasteboard = FakeClipboardPasteboard(initialString: "synthetic original clipboard")
            let paster = ClipboardRestoringTextPaster()

            let outcome = paster.paste(
                "synthetic unconfirmed dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    pasteboard.clearContents()
                    pasteboard.onPasteboardItemsRead = {
                        pasteboard.onPasteboardItemsRead = nil
                        pasteboard.setString("synthetic user copy during item query", forType: .string)
                    }
                    return true
                },
                confirmationSource: { NeutralFocusConfirmationSource() },
                pasteConfirmationWait: 0
            )

            assertEqual(
                outcome,
                .failed(
                    "Transcripted sent paste, but could not confirm it or place a recovery copy on the clipboard. Check your dictation history.",
                    reason: .fallbackClipboardRecoveryUnverified
                ),
                "an item-query generation change must not be overwritten by recovery"
            )
            assertEqual(
                pasteboard.string(forType: .string),
                "synthetic user copy during item query",
                "a user copy arriving during item inspection should remain untouched"
            )
            assertEqual(
                paster.lastConfirmationDiagnostic?.context["clipboard_fallback_state"],
                "clipboard_changed",
                "the diagnostic should classify an item-query race as a clipboard change"
            )
        }

        runSuite("ClipboardRestoringTextPaster.paste — same-text user rich clipboard survives unconfirmed paste") {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("TranscriptedSameTextRichClipboardTest-\(UUID().uuidString)"))
            let paster = ClipboardRestoringTextPaster()
            let dictationText = "synthetic shared text"
            let customType = NSPasteboard.PasteboardType("com.transcripted.same-text-rich-clipboard")
            let customData = Data([0xca, 0xfe, 0xba, 0xbe])

            pasteboard.clearContents()
            pasteboard.setString("synthetic original clipboard", forType: .string)
            let outcome = paster.paste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    let userItem = NSPasteboardItem()
                    userItem.setString(dictationText, forType: .string)
                    userItem.setData(customData, forType: customType)
                    pasteboard.clearContents()
                    pasteboard.writeObjects([userItem])
                    return true
                },
                confirmationSource: { NeutralFocusConfirmationSource() },
                pasteConfirmationWait: 0.01
            )

            assertEqual(
                outcome,
                .copied(
                    ClipboardRestoringTextPaster.pasteNotConfirmedMessage,
                    reason: .pasteNotConfirmed
                ),
                "unconfirmed paste should keep same-text user clipboard content available"
            )
            assertEqual(
                pasteboard.pasteboardItems?.first?.data(forType: customType),
                customData,
                "same-text user rich clipboard data should not be flattened to plain text"
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
                },
                confirmationSource: { NeutralFocusConfirmationSource() }
            )

            assertEqual(
                outcome,
                .failed(
                    "Couldn't paste or copy the text automatically. It's still saved in your dictation history.",
                    reason: .temporaryClipboardWriteFailed
                ),
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
                    "Accessibility is off, so Transcripted can't paste for you. Your text is on the clipboard — press ⌘V.",
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

        runSuite("ClipboardRestoringTextPaster.paste — focus fallback reports a failed clipboard write") {
            let existingClipboard = "synthetic existing clipboard"
            let pasteboard = FakeClipboardPasteboard(
                initialString: existingClipboard,
                clearContentsClears: false,
                setStringSucceeds: false
            )
            let paster = ClipboardRestoringTextPaster()
            var dispatchCount = 0

            let outcome = paster.paste(
                "synthetic focus fallback dictation",
                target: DictationPasteTarget(
                    processIdentifier: Int32.max,
                    bundleIdentifier: "com.example.NotFrontmost"
                ),
                activationWait: 0,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    dispatchCount += 1
                    return true
                }
            )

            assertEqual(
                outcome,
                .failed(
                    "Focus moved, and Transcripted couldn't put the text on your clipboard. It's still saved in your dictation history.",
                    reason: .focusChangeClipboardWriteFailed
                ),
                "focus fallback must not claim copied when its clipboard write failed"
            )
            assertEqual(dispatchCount, 0, "focus fallback should not post Cmd+V")
            assertEqual(pasteboard.string(forType: .string), existingClipboard, "a failed focus fallback should preserve the prior clipboard")
        }

        runSuite("ClipboardRestoringTextPaster.paste — accessibility fallback reports a failed clipboard write") {
            let existingClipboard = "synthetic existing clipboard"
            let pasteboard = FakeClipboardPasteboard(
                initialString: existingClipboard,
                clearContentsClears: false,
                setStringSucceeds: false
            )
            let paster = ClipboardRestoringTextPaster()
            var promptCount = 0
            var dispatchCount = 0

            let outcome = paster.paste(
                "synthetic accessibility fallback dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { false },
                requestAccessibilityTrust: { promptCount += 1 },
                pasteDispatcher: {
                    dispatchCount += 1
                    return true
                }
            )

            assertEqual(
                outcome,
                .failed(
                    "Accessibility is off, and Transcripted couldn't put the text on your clipboard. It's still saved in your dictation history.",
                    reason: .accessibilityFallbackClipboardWriteFailed
                ),
                "Accessibility fallback must not claim copied when its clipboard write failed"
            )
            assertEqual(promptCount, 1, "the Accessibility prompt should still be requested once")
            assertEqual(dispatchCount, 0, "Accessibility fallback should not post Cmd+V")
            assertEqual(pasteboard.string(forType: .string), existingClipboard, "a failed Accessibility fallback should preserve the prior clipboard")
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

        runSuite("DictationPasteTarget — follows the app focused at paste time") {
            let originalTarget = DictationPasteTarget(
                processIdentifier: 42,
                bundleIdentifier: "com.example.Original"
            )

            assertEqual(
                DictationPasteTarget.preferredDestination(
                    frontmostProcessIdentifier: 84,
                    frontmostBundleIdentifier: "com.example.Current",
                    transcriptedBundleIdentifier: "com.justinbetker.draft",
                    fallback: originalTarget
                ),
                DictationPasteTarget(
                    processIdentifier: 84,
                    bundleIdentifier: "com.example.Current"
                ),
                "manual dictation should paste into the app focused when pasteback runs"
            )
            assertEqual(
                DictationPasteTarget.preferredDestination(
                    frontmostProcessIdentifier: 7,
                    frontmostBundleIdentifier: "com.justinbetker.draft",
                    transcriptedBundleIdentifier: "com.justinbetker.draft",
                    fallback: originalTarget
                ),
                originalTarget,
                "Transcripted's own overlay should not replace the user's last external target"
            )
            assertEqual(
                DictationPasteTarget.preferredDestination(
                    frontmostProcessIdentifier: nil,
                    frontmostBundleIdentifier: nil,
                    transcriptedBundleIdentifier: "com.justinbetker.draft",
                    fallback: originalTarget
                ),
                originalTarget,
                "missing frontmost-app metadata should preserve the safe fallback target"
            )
        }

        runSuite("FocusedTextPasteConfirmationPolicy — accepts editor-normalized paste changes") {
            assertEqual(
                FocusedTextPasteConfirmationPolicy.observableString(
                    from: NSAttributedString(string: "Notes editor value")
                ),
                "Notes editor value",
                "rich editors should expose attributed AX values as confirmable text"
            )
            assertTrue(
                FocusedTextPasteConfirmationPolicy.didObservePaste(
                    initialValue: "Before ",
                    currentValue: "Before Transcripted changed \u{201C}straight quotes\u{201D} to smart quotes",
                    pastedText: "Transcripted changed \"straight quotes\" to smart quotes"
                ),
                "a changed focused-editor value should confirm paste even when the target normalizes text"
            )
            assertFalse(
                FocusedTextPasteConfirmationPolicy.didObservePaste(
                    initialValue: "Unchanged",
                    currentValue: "Unchanged",
                    pastedText: "Expected paste"
                ),
                "an unchanged editor value should not confirm paste"
            )
            assertFalse(
                FocusedTextPasteConfirmationPolicy.didObservePaste(
                    initialValue: nil,
                    currentValue: "Changed",
                    pastedText: "Changed"
                ),
                "confirmation remains unavailable when the initial editor value cannot be observed"
            )
            assertFalse(
                FocusedTextPasteConfirmationPolicy.didObservePaste(
                    initialValue: "Before",
                    currentValue: "Before unrelated edit",
                    pastedText: "A much longer expected dictation that was not inserted"
                ),
                "an unrelated editor change should not confirm the requested paste"
            )
            assertTrue(
                FocusedTextPasteConfirmationPolicy.didObservePaste(
                    initialValue: "Replace this",
                    currentValue: "Replacement",
                    pastedText: "Replacement",
                    replacedSelectionLength: "Replace this".utf16.count
                ),
                "replacement pastes should confirm from the observed length change"
            )
            assertTrue(
                FocusedTextPasteConfirmationPolicy.didObserveSelectionPaste(
                    initialRange: .init(location: 7, length: 0),
                    currentRange: .init(location: 7 + "Inserted text".utf16.count, length: 0),
                    pastedText: "Inserted text",
                    clipboardWasRead: true
                ),
                "rich editors should confirm a clipboard read plus the expected cursor movement"
            )
            assertFalse(
                FocusedTextPasteConfirmationPolicy.didObserveSelectionPaste(
                    initialRange: .init(location: 7, length: 0),
                    currentRange: .init(location: 7 + "Inserted text".utf16.count, length: 0),
                    pastedText: "Inserted text",
                    clipboardWasRead: false
                ),
                "cursor movement alone should not treat an unrelated edit as paste proof"
            )
            assertFalse(
                FocusedTextPasteConfirmationPolicy.didObserveSelectionPaste(
                    initialRange: .init(location: 7, length: 0),
                    currentRange: .init(location: 8, length: 0),
                    pastedText: "Inserted text",
                    clipboardWasRead: true
                ),
                "an observer read plus unrelated cursor movement should not confirm paste"
            )
            let dispatchTime: CFAbsoluteTime = 100
            assertTrue(
                FocusedTextPasteConfirmationPolicy.didObserveTargetChange(
                    pasteDispatchedAt: dispatchTime,
                    clipboardReadAt: dispatchTime + 0.02,
                    targetChangedAt: dispatchTime + 0.04
                ),
                "the exact target changing immediately after its post-dispatch clipboard read should confirm paste"
            )
            assertFalse(
                FocusedTextPasteConfirmationPolicy.didObserveTargetChange(
                    pasteDispatchedAt: dispatchTime,
                    clipboardReadAt: dispatchTime - 0.01,
                    targetChangedAt: dispatchTime + 0.04
                ),
                "a clipboard observer read before Cmd+V should not confirm a later target edit"
            )
            assertFalse(
                FocusedTextPasteConfirmationPolicy.didObserveTargetChange(
                    pasteDispatchedAt: dispatchTime,
                    clipboardReadAt: dispatchTime + 0.02,
                    targetChangedAt: dispatchTime + 1.5
                ),
                "an unrelated delayed target edit should not confirm paste"
            )
        }

        runSuite("ClipboardRestoringTextPaster — waits briefly for menu-triggered target activation") {
            assertTrue(
                TranscriptedConstants.clipboardTargetActivationWait > 0
                    && TranscriptedConstants.clipboardTargetActivationWait < 0.5,
                "activation wait should be short but non-zero"
            )

            assertTrue(
                ClipboardTargetActivationPolicy.shouldWait(
                    targetIsFrontmost: false,
                    elapsed: 0,
                    timeout: 0.2
                ),
                "paste-back should keep waiting while the target is not frontmost and the timeout has not elapsed"
            )
            assertTrue(
                ClipboardTargetActivationPolicy.shouldWait(
                    targetIsFrontmost: false,
                    elapsed: 0.19,
                    timeout: 0.2
                ),
                "paste-back should keep waiting just under the activation timeout"
            )
            assertFalse(
                ClipboardTargetActivationPolicy.shouldWait(
                    targetIsFrontmost: true,
                    elapsed: 0,
                    timeout: 0.2
                ),
                "paste-back should stop waiting as soon as the target becomes frontmost"
            )
            assertFalse(
                ClipboardTargetActivationPolicy.shouldWait(
                    targetIsFrontmost: false,
                    elapsed: 0.2,
                    timeout: 0.2
                ),
                "paste-back should stop waiting once the activation timeout has elapsed"
            )
            assertFalse(
                ClipboardTargetActivationPolicy.shouldWait(
                    targetIsFrontmost: false,
                    elapsed: 0.5,
                    timeout: 0.2
                ),
                "paste-back should stop waiting after the activation timeout is exceeded"
            )
        }
    }

    await runSuite("ClipboardRestoringTextPaster.paste — never asks the target over Accessibility before it reads the clipboard") {
        // A target mid-paste is blocked on our main thread for the string; an
        // AX call to it then blocks until its timeouts (~100 ms) expire.
        let asked = await MainActor.run { () -> (unread: Int, read: Int, readBeforeAsk: Bool) in
            let unreadSource = CountingConfirmationSource()
            let unreadPasteboard = NSPasteboard(name: NSPasteboard.Name("TranscriptedNoEarlyAX-\(UUID().uuidString)"))
            unreadPasteboard.clearContents()
            _ = ClipboardRestoringTextPaster().paste(
                "synthetic unread dictation",
                pasteboard: unreadPasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { true },
                confirmationSource: { unreadSource },
                targetIsFrontmost: { true },
                retainClipboardForPasteRetry: false,
                pasteConfirmationWait: 0.06
            )

            let readSource = CountingConfirmationSource()
            let readPasteboard = NSPasteboard(name: NSPasteboard.Name("TranscriptedLateAX-\(UUID().uuidString)"))
            readPasteboard.clearContents()
            _ = ClipboardRestoringTextPaster().paste(
                "synthetic read dictation",
                pasteboard: readPasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = readPasteboard.string(forType: .string)
                    return true
                },
                confirmationSource: { readSource },
                targetIsFrontmost: { true },
                retainClipboardForPasteRetry: false,
                pasteConfirmationWait: 0.06
            )
            return (unreadSource.asked, readSource.asked, readSource.askedBeforeRead == 0)
        }
        assertEqual(asked.unread, 0, "while nothing has read the clipboard, the text can't have landed, so Accessibility is never asked")
        assertTrue(asked.read > 0, "once the target has read the clipboard, the paste is confirmed over Accessibility as before")
        assertTrue(asked.readBeforeAsk, "every Accessibility check comes after the read")
    }

    runSuite("A dictation that didn't paste is offered back with its words") {
        assertEqual(
            TextPasteOutcome.copied(ClipboardRestoringTextPaster.pasteNotConfirmedMessage, reason: .pasteNotConfirmed).notPastedOffer,
            .onClipboard,
            "words left on the clipboard are offered to paste"
        )
        assertEqual(
            TextPasteOutcome.failed("synthetic busy clipboard", reason: .clipboardSnapshotIncomplete).notPastedOffer,
            .clipboardBusy,
            "a clipboard too big to set aside never got the words, so they're offered to copy"
        )
        assertEqual(TextPasteOutcome.pasted.notPastedOffer, nil, "a paste that landed offers nothing")
        assertEqual(TextPasteOutcome.likelyPasted.notPastedOffer, nil, "a likely paste offers nothing")
        assertEqual(
            TextPasteOutcome.failed("synthetic write failure", reason: .temporaryClipboardWriteFailed).notPastedOffer,
            nil,
            "other failures keep their own message"
        )
    }

    runSuite("A focused element counts as somewhere text can't go only when it plainly can't take text") {
        // Claude, Chrome: the page body has focus, in no text box.
        assertTrue(FocusedTextPasteConfirmationPolicy.isClearlyNotTextEntry(
            role: "AXWebArea", valueIsSettable: false, hasEditableAncestor: false
        ), "a web page body outside any text box can't take a paste")
        assertTrue(FocusedTextPasteConfirmationPolicy.isClearlyNotTextEntry(
            role: "AXButton", valueIsSettable: false, hasEditableAncestor: false
        ), "a plain button can't take a paste")
        // Muse: a button inside the editable composer routes the paste in.
        assertFalse(FocusedTextPasteConfirmationPolicy.isClearlyNotTextEntry(
            role: "AXButton", valueIsSettable: false, hasEditableAncestor: true
        ), "anything inside an editable region may take the paste")
        assertFalse(FocusedTextPasteConfirmationPolicy.isClearlyNotTextEntry(
            role: "AXGroup", valueIsSettable: true, hasEditableAncestor: false
        ), "a group whose value can be set is an editor (contenteditable)")
        assertFalse(FocusedTextPasteConfirmationPolicy.isClearlyNotTextEntry(
            role: "AXTextArea", valueIsSettable: false, hasEditableAncestor: false
        ), "a text area is always somewhere text can go")
        assertFalse(FocusedTextPasteConfirmationPolicy.isClearlyNotTextEntry(
            role: nil, valueIsSettable: false, hasEditableAncestor: false
        ), "an unknown focus never overrules a paste")
        assertFalse(FocusedTextPasteConfirmationPolicy.isClearlyNotTextEntry(
            role: "AXSomethingNew", valueIsSettable: false, hasEditableAncestor: false
        ), "a role we don't know isn't treated as a dead end")
    }

    runSuite("Spreadsheet cells, terminal windows and groups are never ruled out as paste targets") {
        // Each row: what AX reports for the focus, and whether a quick
        // clipboard read there is overruled as "Not pasted".
        let rows: [(target: String, role: String, settable: Bool, editableAncestor: Bool, refutes: Bool)] = [
            ("selected spreadsheet cell (Numbers, Excel)", "AXCell", false, false, false),
            ("spreadsheet row", "AXRow", false, false, false),
            ("spreadsheet table", "AXTable", false, false, false),
            ("GPU terminal whose focus is its window (kitty, Alacritty)", "AXWindow", false, false, false),
            ("GPU terminal whose focus is a group (Ghostty, Warp)", "AXGroup", false, false, false),
            ("outline", "AXOutline", false, false, false),
            ("list", "AXList", false, false, false),
            ("split group", "AXSplitGroup", false, false, false),
            ("tab group", "AXTabGroup", false, false, false),
            ("scroll area", "AXScrollArea", false, false, false),
            ("web page body with no text box", "AXWebArea", false, false, true),
            ("web page body inside an editable region", "AXWebArea", false, true, false),
            ("web page body that is itself editable", "AXWebArea", true, false, false),
            ("plain text on a page", "AXStaticText", false, false, true),
            ("a link", "AXLink", false, false, true),
            ("an image", "AXImage", false, false, true),
            ("a menu item", "AXMenuItem", false, false, true),
            ("a toolbar", "AXToolbar", false, false, true),
        ]
        for row in rows {
            assertEqual(
                FocusedTextPasteConfirmationPolicy.isClearlyNotTextEntry(
                    role: row.role, valueIsSettable: row.settable, hasEditableAncestor: row.editableAncestor
                ),
                row.refutes,
                "refutes a paste into: \(row.target) (\(row.role))"
            )
        }
    }

    await runSuite("A quick clipboard read counts as a paste only when the focus could take text") {
        func pasteWithImmediateRead(focus: FocusClaimConfirmationSource, pasteConfirmed: (@MainActor () -> Bool)? = nil) async -> TextPasteOutcome {
            await MainActor.run {
                let pasteboard = NSPasteboard(name: NSPasteboard.Name("TranscriptedFocusRefutes-\(UUID().uuidString)"))
                pasteboard.clearContents()
                pasteboard.setString("synthetic original clipboard", forType: .string)
                let paster = ClipboardRestoringTextPaster()
                let outcome = paster.paste(
                    "synthetic dictation for a focus check",
                    pasteboard: pasteboard,
                    accessibilityTrusted: { true },
                    requestAccessibilityTrust: {},
                    pasteDispatcher: {
                        _ = pasteboard.string(forType: .string)
                        return true
                    },
                    confirmationSource: { focus },
                    pasteConfirmed: pasteConfirmed,
                    targetIsFrontmost: { true },
                    restoreDelay: 5_000_000,
                    fallbackRestoreDelay: 20_000_000,
                    pasteConfirmationWait: 0.05
                )
                paster.cancelPendingClipboardRestore()
                return outcome
            }
        }

        let intoPage = await pasteWithImmediateRead(focus: FocusClaimConfirmationSource(clearlyNotTextEntry: true))
        assertEqual(
            intoPage,
            .copied(ClipboardRestoringTextPaster.pasteNotConfirmedMessage, reason: .pasteNotConfirmed),
            "an app that reads the clipboard with no text box focused did not paste"
        )
        let intoEditor = await pasteWithImmediateRead(focus: FocusClaimConfirmationSource(clearlyNotTextEntry: false))
        assertEqual(intoEditor, .likelyPasted, "the same quick read into a place that takes text is still a likely paste")
        let callerDecides = await pasteWithImmediateRead(
            focus: FocusClaimConfirmationSource(clearlyNotTextEntry: true),
            pasteConfirmed: { false }
        )
        assertEqual(callerDecides, .likelyPasted, "a caller that decides confirmation itself isn't overruled by the focus")
    }

    await runSuite("ClipboardRestoringTextPaster.cancelPendingClipboardRestore — keeps neutral recovery text copied") {
        let originalClipboard = "synthetic cancel clipboard"
        let dictationText = "synthetic cancel retry"
        let pasteboard = await MainActor.run {
            FakeClipboardPasteboard(initialString: originalClipboard)
        }
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }
        let adapter = await MainActor.run {
            SyntheticPasteTargetAdapter(kind: .notes, appliesPaste: false)
        }

        let outcome = await MainActor.run {
            let outcome = paster.paste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    adapter.receivePaste(dictationText, clipboardRead: true)
                    return true
                },
                confirmationSource: { adapter },
                targetIsFrontmost: { adapter.isFocused },
                pasteConfirmationWait: 0
            )
            paster.cancelPendingClipboardRestore()
            return outcome
        }

        assertEqual(
            outcome,
            .copied(
                ClipboardRestoringTextPaster.pasteNotConfirmedMessage,
                reason: .pasteNotConfirmed
            ),
            "an ambiguous dispatch should stay neutral without retaining stale clipboard ownership"
        )
        let restoredClipboard = await MainActor.run {
            pasteboard.string(forType: .string)
        }
        assertEqual(restoredClipboard, dictationText, "cancellation must not replace the promised recovery text with stale clipboard content")
    }

    await runSuite("ClipboardRestoringTextPaster.discardPasteRetry — keeps neutral recovery text copied") {
        let originalClipboard = "synthetic superseded clipboard"
        let dictationText = "synthetic superseded retry"
        let pasteboard = await MainActor.run {
            FakeClipboardPasteboard(initialString: originalClipboard)
        }
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }
        let adapter = await MainActor.run {
            SyntheticPasteTargetAdapter(kind: .browser, appliesPaste: false)
        }

        await MainActor.run {
            _ = paster.paste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    adapter.receivePaste(dictationText, clipboardRead: false)
                    return true
                },
                confirmationSource: { adapter },
                targetIsFrontmost: { adapter.isFocused },
                pasteConfirmationWait: 0
            )
            paster.discardPasteRetry()
        }

        let restoredClipboard = await MainActor.run {
            pasteboard.string(forType: .string)
        }
        assertEqual(
            restoredClipboard,
            dictationText,
            "discarding obsolete retry state must not replace the promised recovery text with stale clipboard content"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.paste — confirmed target read restores clipboard") {
        if ProcessInfo.processInfo.environment["TRANSCRIPTED_SKIP_TIMING_SENSITIVE_TESTS"] == "1" {
            print("    SKIPPED: wall-clock timing proof — scheduler jitter on shared CI runners makes the 30/80ms windows unprovable there; covered by local runs")
            return
        }
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
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                pasteConfirmed: { true },
                restoreDelay: 20_000_000,
                fallbackRestoreDelay: 120_000_000,
                pasteConfirmationWait: 0.2
            )
        }

        assertEqual(outcome, .pasted, "valid pasteback should report automatic paste")
        let waitTask = Task { @MainActor in
            await paster.waitForPendingClipboardRestore()
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteboard.string(forType: .string)
        }

        let restoredClipboard = await waitTask.value
        assertEqual(
            restoredClipboard,
            existingClipboard,
            "waiting for pending restore should include the fallback restore before auto-enter"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.paste — an immediate read with the target in front is a likely paste that restores the clipboard") {
        let existingClipboard = "selected app original clipboard"
        let dictationText = "selected app dictation"
        let pasteboardName = NSPasteboard.Name("TranscriptedSelectedAutoEnterPasteTest-\(UUID().uuidString)")
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }

        let outcome = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString(existingClipboard, forType: .string)
            return paster.paste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                confirmationSource: { NeutralFocusConfirmationSource() },
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 120_000_000,
                pasteConfirmationWait: 0.2
            )
        }

        assertEqual(
            outcome,
            .likelyPasted,
            "a read right after Cmd+V while the target stays in front should count as a likely paste, not a confirmed one"
        )
        let diagnostic = await MainActor.run { paster.lastConfirmationDiagnostic }
        assertEqual(
            diagnostic?.context["paste_evidence"],
            "clipboard_read",
            "the diagnostic should name the evidence behind a likely paste"
        )
        assertTrue(
            diagnostic?.event != "dictation_paste_confirmed",
            "an unattributed read must never be logged as a confirmed paste"
        )
        await paster.waitForPendingClipboardRestore()
        let restoredClipboard = await MainActor.run {
            NSPasteboard(name: pasteboardName).string(forType: .string)
        }
        assertEqual(restoredClipboard, existingClipboard, "a likely paste should give the user's clipboard back")
    }

    await runSuite("ClipboardRestoringTextPaster.paste — a likely paste into a selected target never authorizes Auto Enter") {
        let existingClipboard = "selected app original clipboard"
        let dictationText = "selected app dictation"
        let pasteboardName = NSPasteboard.Name("TranscriptedSelectedAutoEnterReadTest-\(UUID().uuidString)")
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }

        let outcome = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString(existingClipboard, forType: .string)
            let target = DictationPasteTarget.capture(sourceApp: NSWorkspace.shared.frontmostApplication)
            return paster.paste(
                dictationText,
                target: target,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                confirmationSource: { NeutralFocusConfirmationSource() },
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 120_000_000,
                pasteConfirmationWait: 0.02
            )
        }

        assertEqual(outcome, .likelyPasted, "an immediate read by the still-frontmost target should be a likely paste")
        assertFalse(outcome.allowsAutoSend, "an unattributed pasteboard read must not make an Auto Enter attempt eligible")
        assertFalse(
            outcome.requiresClipboardReadinessBeforeAutoSend,
            "a likely paste must not arm the Auto Enter readiness path"
        )
        assertEqual(outcome.autoSendBlockReason, .pasteUnverified, "Auto Enter telemetry should say why Return was not pressed")
        await paster.waitForPendingClipboardRestore()
        let restoredClipboard = await MainActor.run {
            NSPasteboard(name: pasteboardName).string(forType: .string)
        }
        assertEqual(restoredClipboard, existingClipboard, "a likely paste should restore the user's clipboard")
    }

    await runSuite("ClipboardRestoringTextPaster.paste — Auto Enter target read skips the dead confirmation wait") {
        if ProcessInfo.processInfo.environment["TRANSCRIPTED_SKIP_TIMING_SENSITIVE_TESTS"] == "1" {
            print("    SKIPPED: wall-clock timing proof — covered by local runs")
            return
        }
        let existingClipboard = "auto enter timing original clipboard"
        let dictationText = "auto enter timing dictation"
        let pasteboardName = NSPasteboard.Name("TranscriptedAutoEnterReadExit-\(UUID().uuidString)")
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }

        let (outcome, measurements) = await MainActor.run { () -> (TextPasteOutcome, [String: Int]) in
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString(existingClipboard, forType: .string)
            let target = DictationPasteTarget.capture(sourceApp: NSWorkspace.shared.frontmostApplication)
            let outcome = paster.paste(
                dictationText,
                target: target,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                confirmationSource: { NeutralFocusConfirmationSource() },
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 120_000_000,
                pasteConfirmationWait: 0.35
            )
            return (outcome, paster.lastPasteTiming?.measurements() ?? [:])
        }

        assertEqual(
            outcome,
            .likelyPasted,
            "an immediate unattributed read should be a likely paste, never a confirmed one"
        )
        assertTrue(
            (measurements["paste_confirmation_wait_ms"] ?? 350) < 50,
            "a confirmation-less target can never confirm, so its post-dispatch read should end the wait for Auto Enter targets too"
        )
        await paster.waitForPendingClipboardRestore()
        let restoredClipboard = await MainActor.run {
            NSPasteboard(name: pasteboardName).string(forType: .string)
        }
        assertEqual(restoredClipboard, existingClipboard, "the early exit should still give the user's clipboard back")
    }

    // "Provider reads are not an Auto Enter confirmation API" used to be a
    // source grep for two removed parameter names. The promise itself (an
    // unattributed pasteboard read never counts as a confirmed paste or arms
    // Auto Enter) is exercised by "a likely paste into a selected target never
    // authorizes Auto Enter" and "a read with a silent AX source is a likely
    // paste, not a confirmed one".

    await runSuite("ClipboardRestoringTextPaster.paste — unconfirmed slow consumers keep text copied") {
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
                confirmationSource: { NeutralFocusConfirmationSource() },
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: TranscriptedConstants.clipboardRestoreFallbackDelay
            )
        }

        assertEqual(
            outcome,
            .copied(
                ClipboardRestoringTextPaster.pasteNotConfirmedMessage,
                reason: .pasteNotConfirmed
            ),
            "unconfirmed slow pasteback should not claim automatic paste success"
        )
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
            dictationText,
            "unconfirmed pasteback should keep the dictation copied for a later manual paste"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.paste — early observer reads do not race slow consumers") {
        if ProcessInfo.processInfo.environment["TRANSCRIPTED_SKIP_TIMING_SENSITIVE_TESTS"] == "1" {
            print("    SKIPPED: wall-clock timing proof — scheduler jitter on shared CI runners makes the 20/70ms windows unprovable there; covered by local runs")
            return
        }
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
                confirmationSource: { NeutralFocusConfirmationSource() },
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 140_000_000
            )
        }

        assertEqual(
            outcome,
            .copied(
                ClipboardRestoringTextPaster.pasteNotConfirmedMessage,
                reason: .pasteNotConfirmed
            ),
            "an unread paste should not report automatic paste success"
        )
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
            dictationText,
            "unconfirmed pasteback should keep the dictation copied instead of restoring too early"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.paste — a read with a silent AX source is a likely paste, not a confirmed one") {
        let existingClipboard = "synthetic existing clipboard"
        let dictationText = "synthetic observer-read dictation"
        let pasteboardName = NSPasteboard.Name("TranscriptedObserverReadPasteTest-\(UUID().uuidString)")
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
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                pasteConfirmed: { false },
                pasteConfirmationWait: 0.05
            )
        }

        assertEqual(
            outcome,
            .likelyPasted,
            "a pasteboard read alone should not prove receipt, and should not trigger a false delivery warning either"
        )
        let diagnosticEvent = await MainActor.run { paster.lastConfirmationDiagnostic?.event }
        assertTrue(
            diagnosticEvent != "dictation_paste_confirmed",
            "a silent confirmation source plus a read is never a confirmed paste"
        )
        await paster.waitForPendingClipboardRestore()
        let clipboardAfterLikelyPaste = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteboard.string(forType: .string)
        }
        assertEqual(
            clipboardAfterLikelyPaste,
            existingClipboard,
            "a likely paste should restore the user's clipboard"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.waitForClipboardReadyForAutoEnter — unconfirmed paste does not arm Auto Enter") {
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
                confirmationSource: { NeutralFocusConfirmationSource() },
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 300_000_000
            )
        }

        assertEqual(
            outcome,
            .copied(
                ClipboardRestoringTextPaster.pasteNotConfirmedMessage,
                reason: .pasteNotConfirmed
            ),
            "unconfirmed pasteback should not claim automatic paste success"
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let observerRead = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteboard.string(forType: .string)
        }
        assertEqual(observerRead, dictationText, "unconfirmed pasteback should keep the text copied")

        // The "no pending readiness wait" promise is proven with an hour-long restore
        // delay in the suite below; here the wait just has to come back.
        let readyTask = Task { @MainActor in
            await paster.waitForClipboardReadyForAutoEnter()
        }
        await readyTask.value

        let stillBorrowedClipboard = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteboard.string(forType: .string)
        }
        assertEqual(
            stillBorrowedClipboard,
            dictationText,
            "unconfirmed pasteback should keep the text available for manual paste"
        )

        let restoredTask = Task { @MainActor in
            await paster.waitForPendingClipboardRestore()
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteboard.string(forType: .string)
        }
        let restoredClipboard = await restoredTask.value
        assertEqual(restoredClipboard, dictationText, "unconfirmed pasteback should not restore away the copied dictation")
    }

    await runSuite("ClipboardRestoringTextPaster.waitForClipboardReadyForAutoEnter — waits when no pasteboard read occurs") {
        let existingClipboard = "synthetic existing clipboard"
        let pasteText = "synthetic unread paste text"
        // An hour: if auto-enter readiness waited for the fallback restore it would
        // never come back, so "came back" proves there is no pending wait.
        let fallbackRestoreDelay: UInt64 = 3_600_000_000_000
        let paster = await MainActor.run {
            ClipboardRestoringTextPaster()
        }
        let pasteboard = await MainActor.run {
            FakeClipboardPasteboard(initialString: existingClipboard)
        }

        let outcome = await MainActor.run {
            return paster.paste(
                pasteText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { true },
                confirmationSource: { NeutralFocusConfirmationSource() },
                fallbackRestoreDelay: fallbackRestoreDelay
            )
        }

        assertEqual(
            outcome,
            .copied(
                ClipboardRestoringTextPaster.pasteNotConfirmedMessage,
                reason: .pasteNotConfirmed
            ),
            "unconfirmed pasteback should not claim automatic paste success"
        )
        try? await Task.sleep(nanoseconds: 5_000_000)
        let borrowedClipboardBeforeFallback = await MainActor.run {
            return pasteboard.string(forType: .string)
        }
        assertEqual(
            borrowedClipboardBeforeFallback,
            pasteText,
            "without a pasteboard read, borrowed dictation should remain available before fallback restore"
        )

        let readyTask = Task { @MainActor in
            await paster.waitForClipboardReadyForAutoEnter()
        }
        let readyWithoutWaiting = await clipboardTestFinishes(readyTask)
        assertTrue(readyWithoutWaiting, "without confirmed paste, auto-enter should have no pending readiness wait")
        let restoredClipboard = await MainActor.run {
            pasteboard.string(forType: .string)
        }
        assertEqual(
            restoredClipboard,
            pasteText,
            "unconfirmed pasteback should leave the dictation copied"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.waitForPendingClipboardRestore — waits for fallback restore") {
        let existingClipboard = "synthetic existing clipboard"
        let pasteText = "synthetic paste text"
        let pasteboardName = NSPasteboard.Name("TranscriptedWaitRestoreTest-\(UUID().uuidString)")
        let paster = await MainActor.run {
            ClipboardRestoringTextPaster()
        }

        let outcome = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString(existingClipboard, forType: .string)
            return paster.paste(
                pasteText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                pasteConfirmed: { true },
                fallbackRestoreDelay: 2_000_000
            )
        }

        assertEqual(outcome, .pasted, "valid pasteback should report automatic paste")
        await paster.waitForPendingClipboardRestore()
        let restoredClipboard = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteboard.string(forType: .string)
        }
        assertEqual(
            restoredClipboard,
            existingClipboard,
            "waiting for pending restore should not return until the previous clipboard is restored"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.waitForPendingClipboardRestore — preserves user copies") {
        let userCopy = "synthetic user clipboard"
        let pasteboardName = NSPasteboard.Name("TranscriptedPreserveUserCopyTest-\(UUID().uuidString)")
        let paster = await MainActor.run {
            ClipboardRestoringTextPaster()
        }

        let outcome = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString("synthetic existing clipboard", forType: .string)
            return paster.paste(
                "synthetic paste text",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                pasteConfirmed: { true },
                fallbackRestoreDelay: 5_000_000
            )
        }
        await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString(userCopy, forType: .string)
        }

        assertEqual(outcome, .pasted, "valid pasteback should report automatic paste")
        await paster.waitForPendingClipboardRestore()
        let clipboardAfterRestore = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteboard.string(forType: .string)
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
        let pasteboardName = NSPasteboard.Name("TranscriptedRetryRestoreTest-\(UUID().uuidString)")
        let paster = await MainActor.run {
            ClipboardRestoringTextPaster()
        }

        let firstOutcome = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString(originalClipboard, forType: .string)
            return paster.paste(
                firstPaste,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                pasteConfirmed: { true },
                fallbackRestoreDelay: 50_000_000
            )
        }
        let secondOutcome = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            return paster.paste(
                secondPaste,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                pasteConfirmed: { true },
                fallbackRestoreDelay: 5_000_000
            )
        }

        assertEqual(firstOutcome, .pasted, "first paste should report automatic paste")
        assertEqual(secondOutcome, .pasted, "retry paste should report automatic paste")
        let clipboardDuringRetry = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteboard.string(forType: .string)
        }
        assertEqual(clipboardDuringRetry, secondPaste, "retry paste should borrow the new dictation text")

        await paster.waitForPendingClipboardRestore()
        let restoredClipboard = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteboard.string(forType: .string)
        }
        assertEqual(
            restoredClipboard,
            originalClipboard,
            "retry paste should restore the user's original clipboard, not the previous borrowed dictation"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.cancelPendingClipboardRestore — restores scheduled clipboard") {
        let pasteText = "synthetic paste text"
        let existingClipboard = "synthetic existing clipboard"
        let pasteboardName = NSPasteboard.Name("TranscriptedCancelRestoreTest-\(UUID().uuidString)")
        let paster = await MainActor.run {
            ClipboardRestoringTextPaster()
        }

        let outcome = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString(existingClipboard, forType: .string)
            let outcome = paster.paste(
                pasteText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                pasteConfirmed: { true },
                fallbackRestoreDelay: 5_000_000
            )
            paster.cancelPendingClipboardRestore()
            return outcome
        }
        try? await Task.sleep(nanoseconds: 10_000_000)

        assertEqual(outcome, .pasted, "valid pasteback should report automatic paste")
        let clipboardAfterCancel = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteboard.string(forType: .string)
        }
        assertEqual(
            clipboardAfterCancel,
            existingClipboard,
            "canceling the pending restore should restore the user's previous clipboard"
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
                "Couldn't paste automatically. Your text is on the clipboard — press ⌘V.",
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
            .failed(
                "Couldn't paste or copy the text automatically. It's still saved in your dictation history.",
                reason: .pasteDispatchClipboardRecoveryFailed
            ),
            "paste dispatch fallback should report failure when the copied fallback cannot be written"
        )
        let clipboardAfterFailure = await MainActor.run {
            pasteboard.string(forType: .string)
        }
        assertNil(clipboardAfterFailure, "failed copied fallback should not restore stale clipboard content")
    }

    runSuite("FocusedTextPasteConfirmationPolicy — likely paste needs a read soon after Cmd+V") {
        let dispatchTime: CFAbsoluteTime = 500
        assertTrue(
            FocusedTextPasteConfirmationPolicy.didObserveLikelyPaste(
                pasteDispatchedAt: dispatchTime,
                clipboardReadAt: dispatchTime + 0.015,
                window: 0.25
            ),
            "a read 15ms after Cmd+V looks like the target's own paste handler"
        )
        assertTrue(
            FocusedTextPasteConfirmationPolicy.didObserveLikelyPaste(
                pasteDispatchedAt: dispatchTime,
                clipboardReadAt: dispatchTime + 0.25,
                window: 0.25
            ),
            "a read right at the window edge still counts"
        )
        assertFalse(
            FocusedTextPasteConfirmationPolicy.didObserveLikelyPaste(
                pasteDispatchedAt: dispatchTime,
                clipboardReadAt: dispatchTime + 0.3,
                window: 0.25
            ),
            "a read well after Cmd+V looks like a clipboard manager poll"
        )
        assertFalse(
            FocusedTextPasteConfirmationPolicy.didObserveLikelyPaste(
                pasteDispatchedAt: dispatchTime,
                clipboardReadAt: dispatchTime - 0.01,
                window: 0.25
            ),
            "a read before Cmd+V cannot be the paste"
        )
        assertFalse(
            FocusedTextPasteConfirmationPolicy.didObserveLikelyPaste(
                pasteDispatchedAt: dispatchTime,
                clipboardReadAt: nil,
                window: 0.25
            ),
            "no read means no evidence"
        )
        assertTrue(
            TranscriptedConstants.clipboardLikelyPasteReadWindow >= 0.1
                && TranscriptedConstants.clipboardLikelyPasteReadWindow <= TranscriptedConstants.clipboardPasteConfirmationWait,
            "the window should cover slow paste handlers (field reads were 5-49ms) and fit inside the confirmation wait"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.paste — the borrowed clipboard is marked transient, the fallback copy is not") {
        let pasteboardName = NSPasteboard.Name("TranscriptedTransientMarkerTest-\(UUID().uuidString)")
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }

        let (outcome, markedWhileBorrowed, markedAfterFallback) = await MainActor.run { () -> (TextPasteOutcome, Bool, Bool) in
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString("synthetic transient original", forType: .string)
            var marked = false
            let outcome = paster.paste(
                "synthetic transient dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    // Listing types does not ask the lazy provider for data.
                    marked = pasteboard.types?.contains(ClipboardRestoringTextPaster.transientPasteboardType) == true
                    return true
                },
                confirmationSource: { NeutralFocusConfirmationSource() },
                pasteConfirmationWait: 0
            )
            let markedAfter = pasteboard.types?.contains(ClipboardRestoringTextPaster.transientPasteboardType) == true
            return (outcome, marked, markedAfter)
        }

        assertTrue(markedWhileBorrowed, "clipboard managers should be told to skip the borrowed dictation")
        assertEqual(outcome.copyReason, .pasteNotConfirmed, "an unread paste falls back to a manual copy")
        assertFalse(markedAfterFallback, "the copy left for a manual ⌘V is the user's to keep, so clipboard managers may record it")
    }

    await runSuite("ClipboardRestoringTextPaster.paste — the next paste puts back the clipboard saved before a fallback") {
        let originalClipboard = "synthetic clipboard before fallback"
        let firstDictation = "synthetic unconfirmed dictation"
        let secondDictation = "synthetic confirmed dictation"
        let pasteboardName = NSPasteboard.Name("TranscriptedFallbackRestoreTest-\(UUID().uuidString)")
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }

        let firstOutcome = await MainActor.run { () -> TextPasteOutcome in
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString(originalClipboard, forType: .string)
            return paster.paste(
                firstDictation,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { true },
                confirmationSource: { NeutralFocusConfirmationSource() },
                pasteConfirmationWait: 0
            )
        }
        assertEqual(firstOutcome.copyReason, .pasteNotConfirmed, "the first paste should fall back to a manual copy")
        let afterFallback = await MainActor.run { NSPasteboard(name: pasteboardName).string(forType: .string) }
        assertEqual(afterFallback, firstDictation, "the fallback must keep the dictation copied until the next paste")

        let secondOutcome = await MainActor.run { () -> TextPasteOutcome in
            let pasteboard = NSPasteboard(name: pasteboardName)
            return paster.paste(
                secondDictation,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                pasteConfirmed: { true },
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 20_000_000
            )
        }
        assertEqual(secondOutcome, .pasted, "the second paste should succeed")
        await paster.waitForPendingClipboardRestore()
        let finalClipboard = await MainActor.run { NSPasteboard(name: pasteboardName).string(forType: .string) }
        assertEqual(finalClipboard, originalClipboard, "the user's clipboard from before the fallback should come back, not the old dictation")
    }

    runSuite("ClipboardRestoringTextPaster.paste — the no-evidence notice never claims the paste failed") {
        let message = ClipboardRestoringTextPaster.pasteNotConfirmedMessage
        assertFalse(message.contains("didn't go through"), "a slow paste can still land, so the notice must not invite a double paste")
        assertTrue(message.contains("⌘V"), "the notice should still say how to paste by hand")
        assertFalse(message.contains("\u{2014}"), "user-facing copy should not use em dashes")
    }

    await runSuite("ClipboardRestoringTextPaster.snapshotPasteboardItems — privacy markers are flagged and kept") {
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let pasteboardName = NSPasteboard.Name("TranscriptedConcealedSnapshotTest-\(UUID().uuidString)")
        let (snapshot, markerData) = await MainActor.run { () -> (ClipboardRestoringTextPaster.PasteboardSnapshot, Data?) in
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setString("synthetic secret", forType: .string)
            item.setData(Data(), forType: concealed)
            pasteboard.writeObjects([item])
            let snapshot = ClipboardRestoringTextPaster().snapshotPasteboardItems(from: pasteboard)
            return (snapshot, pasteboard.pasteboardItems?.first?.data(forType: concealed))
        }
        assertTrue(snapshot.containsPrivacyMarker, "a password manager's concealed copy should be flagged")
        if let markerData {
            assertEqual(snapshot.items.first?[concealed], markerData, "an empty concealed marker should survive the snapshot")
        }
        assertTrue(
            ClipboardRestoringTextPaster.privacyMarkerTypes.contains(ClipboardRestoringTextPaster.transientPasteboardType),
            "the marker Transcripted writes is one it also honors"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.paste — a concealed clipboard is never brought back after a fallback") {
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let secret = "synthetic concealed clipboard"
        let firstDictation = "synthetic unconfirmed dictation over a secret"
        let pasteboardName = NSPasteboard.Name("TranscriptedConcealedFallbackTest-\(UUID().uuidString)")
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }

        let firstOutcome = await MainActor.run { () -> TextPasteOutcome in
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            let item = NSPasteboardItem()
            item.setString(secret, forType: .string)
            item.setData(Data(), forType: concealed)
            pasteboard.writeObjects([item])
            return paster.paste(
                firstDictation,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { true },
                confirmationSource: { NeutralFocusConfirmationSource() },
                pasteConfirmationWait: 0
            )
        }
        assertEqual(firstOutcome.copyReason, .pasteNotConfirmed, "the first paste should fall back to a manual copy")

        let secondOutcome = await MainActor.run { () -> TextPasteOutcome in
            let pasteboard = NSPasteboard(name: pasteboardName)
            return paster.paste(
                "synthetic next dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                pasteConfirmed: { true },
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 20_000_000
            )
        }
        assertEqual(secondOutcome, .pasted, "the second paste should succeed")
        await paster.waitForPendingClipboardRestore()
        let finalClipboard = await MainActor.run { NSPasteboard(name: pasteboardName).string(forType: .string) }
        assertTrue(finalClipboard != secret, "a concealed clipboard must not come back on a later paste")
        assertEqual(finalClipboard, firstDictation, "the next paste should restore what was on the clipboard when it started")
    }

    await runSuite("ClipboardRestoringTextPaster.paste — a different paster still restores the clipboard saved before a fallback") {
        let originalClipboard = "synthetic clipboard before a dictation fallback"
        let pasteboardName = NSPasteboard.Name("TranscriptedSharedFallbackSlotTest-\(UUID().uuidString)")
        let dictationPaster = await MainActor.run { ClipboardRestoringTextPaster() }
        let pasteLastPaster = await MainActor.run { ClipboardRestoringTextPaster() }

        await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString(originalClipboard, forType: .string)
            _ = dictationPaster.paste(
                "synthetic unconfirmed dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { true },
                confirmationSource: { NeutralFocusConfirmationSource() },
                pasteConfirmationWait: 0
            )
        }
        let pasteLastOutcome = await MainActor.run { () -> TextPasteOutcome in
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteLastPaster.paste(
                "synthetic unconfirmed dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                pasteConfirmed: { true },
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 20_000_000
            )
        }
        assertEqual(pasteLastOutcome, .pasted, "Paste Last should succeed")
        await pasteLastPaster.waitForPendingClipboardRestore()
        let finalClipboard = await MainActor.run { NSPasteboard(name: pasteboardName).string(forType: .string) }
        assertEqual(finalClipboard, originalClipboard, "Paste Last right after a fallback should still give the user's clipboard back")
    }

    await runSuite("ClipboardRestoringTextPaster.paste — Paste Last during another paster's delayed restore keeps the user's clipboard") {
        let originalClipboard = "synthetic clipboard before a likely paste"
        let pasteboardName = NSPasteboard.Name("TranscriptedCrossPasterRestoreTest-\(UUID().uuidString)")
        let dictationPaster = await MainActor.run { ClipboardRestoringTextPaster() }
        let pasteLastPaster = await MainActor.run { ClipboardRestoringTextPaster() }

        let (likelyOutcome, pasteLastOutcome) = await MainActor.run { () -> (TextPasteOutcome, TextPasteOutcome) in
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString(originalClipboard, forType: .string)
            let likely = dictationPaster.paste(
                "synthetic likely-pasted dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                pasteConfirmed: { false },
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 5_000_000_000,
                pasteConfirmationWait: 0.05
            )
            // Paste Last starts while the dictation paster still waits to restore.
            let pasteLast = pasteLastPaster.paste(
                "synthetic likely-pasted dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                pasteConfirmed: { true },
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 20_000_000
            )
            return (likely, pasteLast)
        }
        assertEqual(likelyOutcome, .likelyPasted, "the dictation should be a likely paste")
        assertEqual(pasteLastOutcome, .pasted, "Paste Last should succeed")
        await pasteLastPaster.waitForPendingClipboardRestore()
        await dictationPaster.waitForPendingClipboardRestore()
        let finalClipboard = await MainActor.run { NSPasteboard(name: pasteboardName).string(forType: .string) }
        assertEqual(finalClipboard, originalClipboard, "the user's clipboard should survive a Paste Last during the delayed restore")
    }

    await runSuite("ClipboardRestoringTextPaster.restorePendingClipboardsBeforeQuit — a delayed restore runs right away") {
        let originalClipboard = "synthetic clipboard before quitting"
        let pasteboardName = NSPasteboard.Name("TranscriptedQuitRestoreTest-\(UUID().uuidString)")
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }

        let (outcome, clipboardAfterQuit) = await MainActor.run { () -> (TextPasteOutcome, String?) in
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString(originalClipboard, forType: .string)
            let outcome = paster.paste(
                "synthetic dictation before quitting",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                pasteConfirmed: { false },
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 5_000_000_000,
                pasteConfirmationWait: 0.05
            )
            ClipboardRestoringTextPaster.restorePendingClipboardsBeforeQuit()
            return (outcome, pasteboard.string(forType: .string))
        }
        assertEqual(outcome, .likelyPasted, "the paste should be a likely paste with a delayed restore")
        assertEqual(clipboardAfterQuit, originalClipboard, "quitting should put the user's clipboard back without waiting")
        await paster.waitForPendingClipboardRestore()
    }

    await runSuite("ClipboardRestoringTextPaster.paste — a copy made after a fallback is never restored over") {
        let userCopy = "synthetic copy made after the fallback"
        let pasteboardName = NSPasteboard.Name("TranscriptedFallbackUserCopyTest-\(UUID().uuidString)")
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }

        await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString("synthetic clipboard before fallback", forType: .string)
            _ = paster.paste(
                "synthetic unconfirmed dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: { true },
                confirmationSource: { NeutralFocusConfirmationSource() },
                pasteConfirmationWait: 0
            )
            pasteboard.clearContents()
            pasteboard.setString(userCopy, forType: .string)
            _ = paster.paste(
                "synthetic confirmed dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                pasteConfirmed: { true },
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 20_000_000
            )
        }
        await paster.waitForPendingClipboardRestore()
        let finalClipboard = await MainActor.run { NSPasteboard(name: pasteboardName).string(forType: .string) }
        assertEqual(finalClipboard, userCopy, "a newer user copy wins over the clipboard saved before the fallback")
    }

    await runSuite("ClipboardRestoringTextPaster.paste — Accessibility-off fallback saves the clipboard for the next paste") {
        let originalClipboard = "synthetic clipboard before Accessibility fallback"
        let pasteboardName = NSPasteboard.Name("TranscriptedAccessibilityFallbackRestoreTest-\(UUID().uuidString)")
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }

        let firstOutcome = await MainActor.run { () -> TextPasteOutcome in
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString(originalClipboard, forType: .string)
            return paster.paste(
                "synthetic Accessibility fallback dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { false },
                requestAccessibilityTrust: {},
                pasteDispatcher: { true }
            )
        }
        assertEqual(firstOutcome.copyReason, .accessibilityMissing, "Accessibility off should copy instead of pasting")

        await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            _ = paster.paste(
                "synthetic dictation after Accessibility was granted",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                pasteConfirmed: { true },
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 20_000_000
            )
        }
        await paster.waitForPendingClipboardRestore()
        let finalClipboard = await MainActor.run { NSPasteboard(name: pasteboardName).string(forType: .string) }
        assertEqual(finalClipboard, originalClipboard, "the clipboard from before the Accessibility fallback should come back")
    }

    await runSuite("ClipboardRestoringTextPaster.paste — a same-text user copy during paste is never replaced later") {
        let dictationText = "synthetic shared text"
        let customType = NSPasteboard.PasteboardType("com.transcripted.same-text-rich-clipboard-later")
        let customData = Data([0xfe, 0xed])
        let pasteboardName = NSPasteboard.Name("TranscriptedSameTextLaterTest-\(UUID().uuidString)")
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }

        await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            pasteboard.clearContents()
            pasteboard.setString("synthetic original clipboard", forType: .string)
            _ = paster.paste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    let userItem = NSPasteboardItem()
                    userItem.setString(dictationText, forType: .string)
                    userItem.setData(customData, forType: customType)
                    pasteboard.clearContents()
                    pasteboard.writeObjects([userItem])
                    return true
                },
                confirmationSource: { NeutralFocusConfirmationSource() },
                pasteConfirmationWait: 0
            )
            _ = paster.paste(
                "synthetic next dictation",
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    return true
                },
                pasteConfirmed: { true },
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 20_000_000
            )
        }
        await paster.waitForPendingClipboardRestore()
        let finalData = await MainActor.run {
            NSPasteboard(name: pasteboardName).pasteboardItems?.first?.data(forType: customType)
        }
        assertEqual(finalData, customData, "a user copy is not ours to swap out for the older clipboard")
    }
}

@MainActor
/// A focus that can't observe a paste and makes no claim about taking text:
/// what a Mac with nothing focused (a CI runner) looks like. Suites that reach
/// the confirmation wait pass this; without it `paste` reads the real focused
/// element, so whatever window is in front on a busy dev Mac decides the outcome.
private final class NeutralFocusConfirmationSource: ClipboardPasteConfirmationSource {
    var canObservePaste: Bool { false }

    func confirmationMode(
        _ text: String,
        clipboardWasRead: Bool,
        clipboardReadAt: CFAbsoluteTime?,
        pasteDispatchedAt: CFAbsoluteTime
    ) -> String? { nil }

    func diagnosticsContext(clipboardReadAt: CFAbsoluteTime?, pasteDispatchedAt: CFAbsoluteTime) -> [String: String] { [:] }
}

/// A focus that never confirms but says whether it can take text.
private final class FocusClaimConfirmationSource: ClipboardPasteConfirmationSource {
    let clearlyNotTextEntry: Bool

    init(clearlyNotTextEntry: Bool) {
        self.clearlyNotTextEntry = clearlyNotTextEntry
    }

    var canObservePaste: Bool { false }
    var focusIsClearlyNotTextEntry: Bool { clearlyNotTextEntry }

    func confirmationMode(
        _ text: String,
        clipboardWasRead: Bool,
        clipboardReadAt: CFAbsoluteTime?,
        pasteDispatchedAt: CFAbsoluteTime
    ) -> String? { nil }

    func diagnosticsContext(clipboardReadAt: CFAbsoluteTime?, pasteDispatchedAt: CFAbsoluteTime) -> [String: String] { [:] }
}

/// Counts Accessibility confirmation checks and never confirms.
private final class CountingConfirmationSource: ClipboardPasteConfirmationSource {
    private(set) var asked = 0
    private(set) var askedBeforeRead = 0

    var canObservePaste: Bool { true }

    func confirmationMode(
        _ text: String,
        clipboardWasRead: Bool,
        clipboardReadAt: CFAbsoluteTime?,
        pasteDispatchedAt: CFAbsoluteTime
    ) -> String? {
        asked += 1
        if !clipboardWasRead { askedBeforeRead += 1 }
        return nil
    }

    func diagnosticsContext(
        clipboardReadAt: CFAbsoluteTime?,
        pasteDispatchedAt: CFAbsoluteTime
    ) -> [String: String] {
        [:]
    }
}

private final class SyntheticPasteTargetAdapter: ClipboardPasteConfirmationSource {
    enum EditorKind: String {
        case codex
        case notes
        case browser
    }

    let kind: EditorKind
    var isFocused = true
    var appliesPaste: Bool
    private(set) var pasteCount = 0
    private let initialText = "synthetic editor before"
    private var currentText = "synthetic editor before"
    private let initialSelection = FocusedTextPasteConfirmationPolicy.SelectionRange(location: 12, length: 0)
    private var currentSelection = FocusedTextPasteConfirmationPolicy.SelectionRange(location: 12, length: 0)
    private var clipboardWasRead = false
    private var targetChangedAt: CFAbsoluteTime?

    init(kind: EditorKind, appliesPaste: Bool = true) {
        self.kind = kind
        self.appliesPaste = appliesPaste
    }

    func receivePaste(_ text: String, clipboardRead: Bool) {
        pasteCount += 1
        guard appliesPaste, isFocused else { return }
        clipboardWasRead = clipboardWasRead || clipboardRead
        switch kind {
        case .codex:
            currentText += text
        case .notes:
            currentSelection = .init(
                location: initialSelection.location + text.utf16.count,
                length: 0
            )
        case .browser:
            targetChangedAt = CFAbsoluteTimeGetCurrent()
        }
    }

    var canObservePaste: Bool { true }

    func confirmationMode(
        _ text: String,
        clipboardWasRead: Bool,
        clipboardReadAt: CFAbsoluteTime?,
        pasteDispatchedAt: CFAbsoluteTime
    ) -> String? {
        guard isFocused else { return nil }
        switch kind {
        case .codex:
            return FocusedTextPasteConfirmationPolicy.didObservePaste(
                initialValue: initialText,
                currentValue: currentText,
                pastedText: text
            ) ? "text_value" : nil
        case .notes:
            return FocusedTextPasteConfirmationPolicy.didObserveSelectionPaste(
                initialRange: initialSelection,
                currentRange: currentSelection,
                pastedText: text,
                clipboardWasRead: self.clipboardWasRead || clipboardWasRead
            ) ? "selection_range" : nil
        case .browser:
            return FocusedTextPasteConfirmationPolicy.didObserveTargetChange(
                pasteDispatchedAt: pasteDispatchedAt,
                clipboardReadAt: clipboardReadAt,
                targetChangedAt: targetChangedAt
            ) ? "target_change_notification" : nil
        }
    }

    func diagnosticsContext(
        clipboardReadAt: CFAbsoluteTime?,
        pasteDispatchedAt: CFAbsoluteTime
    ) -> [String: String] {
        [
            "clipboard_read_after_dispatch": "\((clipboardReadAt ?? 0) >= pasteDispatchedAt)",
            "target_change_after_dispatch": "\((targetChangedAt ?? 0) >= pasteDispatchedAt)",
            "target_change_observer_available": kind == .browser ? "true" : "false",
            "target_selection_observable": kind == .notes ? "true" : "false",
            "target_value_observable": kind == .codex ? "true" : "false",
        ]
    }
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
    var onStringRead: (() -> Void)?
    var onStringWritten: (() -> Void)?
    var onPasteboardItemsRead: (() -> Void)?

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
        let result: [NSPasteboardItem]?
        if let storedString,
           let data = storedString.data(using: .utf8) {
            let item = NSPasteboardItem()
            item.setData(data, forType: .string)
            result = [item]
        } else {
            result = storedItems
        }
        onPasteboardItemsRead?()
        return result
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
        onStringWritten?()
        return true
    }

    func string(forType dataType: NSPasteboard.PasteboardType) -> String? {
        guard dataType == .string else { return nil }
        let result: String?
        if let storedString {
            result = storedString
        } else {
            result = storedItems?.compactMap { item in
                item.data(forType: .string)
                    .flatMap { String(data: $0, encoding: .utf8) }
            }.first
        }
        onStringRead?()
        return result
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
