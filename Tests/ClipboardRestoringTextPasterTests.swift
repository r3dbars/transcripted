// ClipboardRestoringTextPasterTests.swift
// Tests for safe clipboard restore behavior.

import AppKit
import Foundation

func testClipboardRestoringTextPaster() async {
    await MainActor.run {
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
                    outcome: .copied("read only", reason: .pasteConfirmationUnavailableAutoSendEligible),
                    diagnostic: nil
                ),
                .clipboardReadOnly,
                "selected target clipboard reads should be distinguishable without naming the app"
            )
            assertEqual(
                DictationTargetConfirmationMode.resolve(
                    outcome: .copied("unconfirmed", reason: .pasteConfirmationUnavailable),
                    diagnostic: ClipboardPasteConfirmationDiagnostic(
                        event: "dictation_paste_confirmation_diagnostics",
                        context: ["clipboard_read_after_dispatch": "false"]
                    )
                ),
                .none,
                "unconfirmed targets should not claim a confirmation mode"
            )
        }
    }

    await MainActor.run {
        runSuite("ClipboardRestoringTextPaster confirmation bounds synchronous AX reads") {
            let source = try! String(
                contentsOfFile: "Sources/Support/ClipboardRestoringTextPaster.swift",
                encoding: .utf8
            )
            assertTrue(
                source.contains("AXUIElementSetMessagingTimeout(element, messagingTimeout)"),
                "paste confirmation must bound synchronous AX reads so busy editors cannot stall delivery"
            )
            assertTrue(
                source.contains("private static let messagingTimeout: Float = 0.05"),
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

        runSuite("ClipboardRestoringTextPaster.capture — focused element cast is crash-proof") {
            // Regression: kAXFocusedUIElementAttribute's CFTypeRef was force-cast
            // straight to AXUIElement with no type check. AXUIElement is a toll-free
            // CF opaque type, so Swift can't verify `as?`/`as!` against it at runtime
            // (the compiler treats the downcast as unconditionally successful) — the
            // real guard has to be an explicit CFGetTypeID comparison before the cast,
            // matching the existing AXValue-cast pattern in this file. A live
            // AXUIElement isn't constructible in a unit test, so this asserts on
            // source shape like the sibling test above.
            let source = try! String(
                contentsOfFile: "Sources/Support/ClipboardRestoringTextPaster.swift",
                encoding: .utf8
            )
            assertTrue(
                source.contains("CFGetTypeID(focusedElement) == AXUIElementGetTypeID()"),
                "the focused UI element must be type-checked before use, since AXUIElement casts can't fail at runtime on their own"
            )
            assertTrue(
                source.contains("focused UI element attribute returned an unexpected CF type"),
                "a mismatched CF type should log and degrade to no confirmation instead of misusing the wrong object with AX APIs"
            )
            assertFalse(
                source.contains("import TranscriptedCore"),
                "this file is compiled directly into the fast-test binary without the TranscriptedCore module search path"
            )
        }

        runSuite("DictationSessionController — Paste Again is paste-only and single-owner") {
            let source = try! String(
                contentsOfFile: "Sources/UI/Overlay/DictationSessionController.swift",
                encoding: .utf8
            )
            let pasterSource = try! String(
                contentsOfFile: "Sources/Support/ClipboardRestoringTextPaster.swift",
                encoding: .utf8
            )
            assertTrue(
                source.contains("case .copied(let message, reason: .pasteNotConfirmed):")
                    && source.contains("actionTitle: \"Paste Again\""),
                "observable confirmation failures should offer Paste Again"
            )
            assertTrue(
                pasterSource.contains("prepareForAutoSend: false")
                    && pasterSource.contains("retainClipboardForPasteRetry: false"),
                "Paste Again must not submit Auto Enter or arm another retry"
            )
            let retryStart = source.range(of: "private func retryPasteWithoutAutoEnter(")
            let retryEnd = retryStart.flatMap { start in
                source.range(of: "private func recordPasteAttemptOutcome(", range: start.upperBound..<source.endIndex)
            }
            let retryBody = retryStart.flatMap { start -> String? in
                guard let retryEnd else { return nil }
                return String(source[start.lowerBound..<retryEnd.lowerBound])
            } ?? ""
            assertFalse(retryBody.contains("performAutoEnterIfNeeded"), "Paste Again must not call the Auto Enter path")
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
                .failed("Couldn't paste automatically without risking your current clipboard. The dictation was saved, but paste-back did not run."),
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
                }
            )

            assertEqual(
                outcome,
                .copied(
                    "Transcripted sent paste, but this target did not expose paste confirmation. The text stays copied.",
                    reason: .pasteConfirmationUnavailable
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
                pasteConfirmationWait: 0.01
            )

            assertEqual(
                outcome,
                .copied(
                    "Transcripted sent paste, but this target did not expose paste confirmation. The text stays copied.",
                    reason: .pasteConfirmationUnavailable
                ),
                "unconfirmed paste should leave the dictation available for manual recovery"
            )
            assertEqual(
                pasteboard.string(forType: .string),
                dictationText,
                "unconfirmed lazy clipboard content should be materialized before provider cleanup"
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
                pasteConfirmationWait: 0.01
            )

            assertEqual(
                outcome,
                .copied(
                    "Transcripted sent paste, but this target did not expose paste confirmation. The text stays copied.",
                    reason: .pasteConfirmationUnavailable
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
                }
            )

            assertEqual(
                outcome,
                .failed("Couldn't paste or copy the text automatically. It's still saved in your dictation history."),
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

    await runSuite("ClipboardRestoringTextPaster.retryPaste — restores snapshot and cannot auto-submit") {
        let originalClipboard = "synthetic original clipboard"
        let dictationText = "synthetic retry dictation"
        let pasteboard = await MainActor.run {
            FakeClipboardPasteboard(initialString: originalClipboard)
        }
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }
        let adapter = await MainActor.run {
            SyntheticPasteTargetAdapter(kind: .codex, appliesPaste: false)
        }

        let firstOutcome = await MainActor.run {
            paster.paste(
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
        }

        await MainActor.run {
            adapter.appliesPaste = true
        }
        let retryOutcome = await MainActor.run {
            paster.retryPaste(
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
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 20_000_000,
                pasteConfirmationWait: 0
            )
        }

        assertEqual(
            firstOutcome,
            .copied(
                "Transcripted tried to paste, but could not confirm the target received it. The text stays copied.",
                reason: .pasteNotConfirmed
            ),
            "an AX-observable but unchanged editor should offer retry"
        )
        assertEqual(retryOutcome, .pasted, "Paste Again should confirm through the real adapter path")
        let pasteCount = await MainActor.run { adapter.pasteCount }
        assertEqual(pasteCount, 2, "Paste Again should dispatch exactly one additional paste")
        await paster.waitForPendingClipboardRestore()
        let restoredClipboard = await MainActor.run {
            pasteboard.string(forType: .string)
        }
        assertEqual(restoredClipboard, originalClipboard, "Paste Again should restore the pre-dictation clipboard")

        let source = try! String(
            contentsOfFile: "Sources/UI/Overlay/DictationSessionController.swift",
            encoding: .utf8
        )
        let retryStart = source.range(of: "private func retryPasteWithoutAutoEnter(")
        let retryEnd = retryStart.flatMap { start in
            source.range(of: "private func recordPasteAttemptOutcome(", range: start.upperBound..<source.endIndex)
        }
        let retryBody = retryStart.flatMap { start -> String? in
            guard let retryEnd else { return nil }
            return String(source[start.lowerBound..<retryEnd.lowerBound])
        } ?? ""
        assertFalse(retryBody.contains("performAutoEnterIfNeeded"), "Paste Again must not run Auto Enter")
        assertFalse(retryBody.contains("persistDictationTranscript"), "Paste Again must not save the dictation twice")
        assertFalse(retryBody.contains("dictation_completed"), "Paste Again must not emit duplicate completion telemetry")
    }

    await runSuite("ClipboardRestoringTextPaster.cancelPendingClipboardRestore — restores retry snapshot") {
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
                "Transcripted tried to paste, but could not confirm the target received it. The text stays copied.",
                reason: .pasteNotConfirmed
            ),
            "an unconfirmed retry source should retain ownership until cancellation"
        )
        let restoredClipboard = await MainActor.run {
            pasteboard.string(forType: .string)
        }
        assertEqual(restoredClipboard, originalClipboard, "cancellation should restore the owned clipboard snapshot")
    }

    await runSuite("ClipboardRestoringTextPaster.discardPasteRetry — restores superseded retry snapshot") {
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
            originalClipboard,
            "superseding Paste Again must restore the owned clipboard snapshot"
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

    await runSuite("ClipboardRestoringTextPaster.paste — unattributed clipboard reads never confirm paste") {
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
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 120_000_000,
                pasteConfirmationWait: 0.2
            )
        }

        assertEqual(
            outcome,
            .copied(
                "Transcripted sent paste, but this target did not expose paste confirmation. The text stays copied.",
                reason: .pasteConfirmationUnavailable
            ),
            "a clipboard manager read must not masquerade as target-specific paste confirmation"
        )
        await paster.waitForPendingClipboardRestore()
        let retainedClipboard = await MainActor.run {
            NSPasteboard(name: pasteboardName).string(forType: .string)
        }
        assertEqual(retainedClipboard, dictationText, "unconfirmed paste must keep recovery text available")
    }

    await runSuite("ClipboardRestoringTextPaster.paste — selected Auto Enter target requires a clipboard read and restores the original") {
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
                prepareForAutoSend: true,
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 120_000_000,
                pasteConfirmationWait: 0.02
            )
        }

        assertEqual(
            outcome,
            .copied(
                "Transcripted sent paste and the selected target read it, but the target exposed no text confirmation.",
                reason: .pasteConfirmationUnavailableAutoSendEligible
            ),
            "Auto Enter eligibility should require the selected target to remain focused and read after Cmd+V"
        )
        await paster.waitForClipboardReadyForAutoEnter()
        let restoredClipboard = await MainActor.run {
            NSPasteboard(name: pasteboardName).string(forType: .string)
        }
        assertEqual(restoredClipboard, existingClipboard, "Auto Enter should wait until the original clipboard is restored")
    }

    runSuite("ClipboardRestoringTextPaster.paste — provider reads are not an Auto Enter confirmation API") {
        let source = try! String(
            contentsOfFile: "Sources/Support/ClipboardRestoringTextPaster.swift",
            encoding: .utf8
        )
        assertFalse(
            source.contains("allowClipboardReadConfirmation")
                || source.contains("selectedTargetStillFrontmost"),
            "an unattributed pasteboard provider read must never restore the clipboard or enable Auto Enter"
        )
    }

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
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: TranscriptedConstants.clipboardRestoreFallbackDelay
            )
        }

        assertEqual(
            outcome,
            .copied(
                "Transcripted sent paste, but this target did not expose paste confirmation. The text stays copied.",
                reason: .pasteConfirmationUnavailable
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
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 140_000_000
            )
        }

        assertEqual(
            outcome,
            .copied(
                "Transcripted sent paste, but this target did not expose paste confirmation. The text stays copied.",
                reason: .pasteConfirmationUnavailable
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

    await runSuite("ClipboardRestoringTextPaster.paste — observer reads do not confirm target paste") {
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
            .copied(
                "Transcripted tried to paste, but could not confirm the target received it. The text stays copied.",
                reason: .pasteNotConfirmed
            ),
            "a pasteboard read alone should not prove the target received Cmd+V"
        )
        let clipboardAfterUnconfirmedRead = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteboard.string(forType: .string)
        }
        assertEqual(
            clipboardAfterUnconfirmedRead,
            dictationText,
            "observer reads should leave the dictation available for manual recovery"
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
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 300_000_000
            )
        }

        assertEqual(
            outcome,
            .copied(
                "Transcripted sent paste, but this target did not expose paste confirmation. The text stays copied.",
                reason: .pasteConfirmationUnavailable
            ),
            "unconfirmed pasteback should not claim automatic paste success"
        )
        try? await Task.sleep(nanoseconds: 20_000_000)
        let observerRead = await MainActor.run {
            let pasteboard = NSPasteboard(name: pasteboardName)
            return pasteboard.string(forType: .string)
        }
        assertEqual(observerRead, dictationText, "unconfirmed pasteback should keep the text copied")

        let started = Date()
        let readyTask = Task { @MainActor in
            await paster.waitForClipboardReadyForAutoEnter()
        }
        await readyTask.value
        let elapsed = Date().timeIntervalSince(started)
        assertTrue(elapsed < 0.15, "unconfirmed pasteback should have no pending auto-enter readiness wait")

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
        if ProcessInfo.processInfo.environment["TRANSCRIPTED_SKIP_TIMING_SENSITIVE_TESTS"] == "1" {
            print("    SKIPPED: wall-clock timing proof — the elapsed-time floor is unprovable under shared-runner scheduler jitter; covered by local runs")
            return
        }
        let existingClipboard = "synthetic existing clipboard"
        let pasteText = "synthetic unread paste text"
        let fallbackRestoreDelay: UInt64 = 40_000_000
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
                fallbackRestoreDelay: fallbackRestoreDelay
            )
        }

        assertEqual(
            outcome,
            .copied(
                "Transcripted sent paste, but this target did not expose paste confirmation. The text stays copied.",
                reason: .pasteConfirmationUnavailable
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

        let started = Date()
        let readyTask = Task { @MainActor in
            await paster.waitForClipboardReadyForAutoEnter()
        }
        await readyTask.value
        let elapsed = Date().timeIntervalSince(started)
        assertTrue(elapsed < 0.15, "without confirmed paste, auto-enter should have no pending readiness wait")
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
            .failed("Couldn't paste or copy the text automatically. It's still saved in your dictation history."),
            "paste dispatch fallback should report failure when the copied fallback cannot be written"
        )
        let clipboardAfterFailure = await MainActor.run {
            pasteboard.string(forType: .string)
        }
        assertNil(clipboardAfterFailure, "failed copied fallback should not restore stale clipboard content")
    }
}

@MainActor
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
            "target_text_observable": kind == .codex ? "true" : "false",
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
