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

        runSuite("DictationSessionController — unconfirmed paste retry stays paste-only") {
            let source = try! String(
                contentsOfFile: "Sources/UI/Overlay/DictationSessionController.swift",
                encoding: .utf8
            )
            let pasterSource = try! String(
                contentsOfFile: "Sources/Support/ClipboardRestoringTextPaster.swift",
                encoding: .utf8
            )
            let overlaySource = try! String(
                contentsOfFile: "Sources/UI/Overlay/FloatingOverlayController.swift",
                encoding: .utf8
            )
            assertTrue(
                source.contains("case .copied(let message, reason: .pasteNotConfirmed):")
                    && source.contains("actionTitle: \"Paste Again\"")
                    && source.contains("showSuccessAndDismiss(title: autoSendOutcome.confirmationTitle ?? \"Paste sent\")"),
                "observable failures should offer Paste Again while confirmation-unavailable targets stay neutral"
            )

            let retryStart = source.range(of: "private func retryPasteWithoutAutoEnter(")
            let retryEnd = retryStart.flatMap { start in
                source.range(
                    of: "private func recordPasteAttemptOutcome(",
                    range: start.upperBound..<source.endIndex
                )
            }
            let retryBody: Substring
            if let retryStart, let retryEnd {
                retryBody = source[retryStart.lowerBound..<retryEnd.lowerBound]
            } else {
                retryBody = ""
            }
            assertTrue(
                retryBody.contains("textPaster.retryPaste("),
                "Paste Again should use the dedicated clipboard-preserving retry API"
            )
            let retryTelemetryCallCount = String(retryBody)
                .components(separatedBy: "DictationPasteRetryTelemetry.performUserRetry")
                .count - 1
            assertEqual(
                retryTelemetryCallCount,
                1,
                "each visible Paste Again action should pass through the one canonical terminal telemetry wrapper"
            )
            assertFalse(
                retryBody.contains("performAutoEnterIfNeeded")
                    || retryBody.contains("autoSender.send")
                    || retryBody.contains("persistDictationTranscript")
                    || retryBody.contains("dictation_completed"),
                "Paste Again must not submit Auto Enter, save twice, or re-emit dictation_completed"
            )
            let pasterRetryStart = pasterSource.range(of: "func retryPaste(")
            let pasterRetryEnd = pasterRetryStart.flatMap { start in
                pasterSource.range(
                    of: "func paste(",
                    range: start.upperBound..<pasterSource.endIndex
                )
            }
            let pasterRetryBody: Substring
            if let pasterRetryStart, let pasterRetryEnd {
                pasterRetryBody = pasterSource[pasterRetryStart.lowerBound..<pasterRetryEnd.lowerBound]
            } else {
                pasterRetryBody = ""
            }
            assertTrue(
                pasterRetryBody.contains("prepareForAutoSend: false")
                    && pasterRetryBody.contains("retainClipboardForPasteRetry: false"),
                "the dedicated retry API should make Auto Enter and a second retained retry impossible by construction"
            )
            assertTrue(
                source.contains("overlayController?.onActionableMessageDiscarded = { [weak self] in")
                    && source.contains("self?.textPaster.discardPasteRetry()"),
                "discarding the visible Paste Again action should clear its retained clipboard snapshot"
            )
            assertTrue(
                overlaySource.contains("private func discardActionableMessageIfNeeded()")
                    && overlaySource.contains("onActionableMessageDiscarded?()")
                    && overlaySource.contains("discardActionableMessageIfNeeded()\n        errorMessage = message")
                    && overlaySource.contains("errorMessage = \"\"\n        discardActionableMessageIfNeeded()\n        hideWithCancelAnimation()"),
                "dismissing or superseding an actionable overlay message should notify its owner"
            )
            assertTrue(
                source.contains("level: diagnostic.event == \"dictation_paste_confirmed\" ? .info : outcome.diagnosticLevel"),
                "confirmation diagnostics should be informational only for neutral outcomes"
            )
        }

        runSuite("DictationPasteRetryTelemetry — emits one aggregate terminal event per user retry") {
            let cases: [(name: String, outcome: TextPasteOutcome, properties: [String: String])] = [
                (
                    "success",
                    .pasted,
                    ["result": "pasted"]
                ),
                (
                    "confirmation unavailable",
                    .copied("synthetic unavailable detail", reason: .pasteConfirmationUnavailable),
                    ["reason": "confirmation_unavailable", "result": "copied"]
                ),
                (
                    "focus changed",
                    .copied("synthetic focus detail", reason: .focusChanged),
                    ["reason": "focus_changed", "result": "copied"]
                ),
                (
                    "still unconfirmed",
                    .copied("synthetic unconfirmed detail", reason: .pasteNotConfirmed),
                    ["reason": "paste_not_confirmed", "result": "copied"]
                ),
                (
                    "failure",
                    .failed("synthetic private-looking /Users/test/secret.txt"),
                    ["reason": "clipboard_unavailable", "result": "failed"]
                ),
            ]

            for testCase in cases {
                var retryCount = 0
                var captures: [(event: String, properties: [String: String])] = []
                let returnedOutcome = DictationPasteRetryTelemetry.performUserRetry(
                    track: { event, properties in
                        captures.append((event, properties))
                    },
                    retry: {
                        retryCount += 1
                        return testCase.outcome
                    }
                )

                assertEqual(returnedOutcome, testCase.outcome, "\(testCase.name) should preserve the actual retry outcome")
                assertEqual(retryCount, 1, "\(testCase.name) should perform the retry exactly once")
                assertEqual(captures.count, 1, "\(testCase.name) should emit one terminal event without double emission")
                if let capture = captures.first {
                    assertEqual(capture.event, "dictation_paste_retry_completed", "\(testCase.name) should use the canonical retry event")
                    assertEqual(capture.properties, testCase.properties, "\(testCase.name) should expose only stable aggregate properties")
                }
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
                }
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

        runSuite("ClipboardRestoringTextPaster.paste — focus loss is not confirmation-unavailable") {
            let originalClipboard = "synthetic original clipboard"
            let dictationText = "synthetic focus-loss dictation"
            let pasteboard = FakeClipboardPasteboard(initialString: originalClipboard)
            let paster = ClipboardRestoringTextPaster()
            let targetAdapter = DeterministicPastebackTargetAdapter(
                application: .codex,
                confirmsPaste: false,
                frontmostStates: [true, false]
            )

            let outcome = paster.paste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    targetAdapter.markPasteDispatched()
                    return true
                },
                targetAdapter: targetAdapter,
                pasteConfirmationWait: 0
            )

            assertEqual(
                outcome,
                .copied(
                    "Focus moved before Transcripted could confirm paste. The text is on your clipboard — press ⌘V.",
                    reason: .focusChanged
                ),
                "losing the target during confirmation should stay visible and count as focus-loss friction"
            )
            assertEqual(
                paster.lastConfirmationDiagnostic?.context["target_still_frontmost"],
                "false",
                "focus-loss diagnostics should not be logged as a neutral unobservable target"
            )
            assertEqual(
                pasteboard.string(forType: .string),
                dictationText,
                "focus loss should keep the dictation copied for visible manual recovery"
            )
        }

        runSuite("ClipboardRestoringTextPaster.paste — a frontmost bounce stays focusChanged") {
            let originalClipboard = "synthetic bounce original"
            let dictationText = "synthetic bounce dictation"
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("TranscriptedFocusBounceTest-\(UUID().uuidString)"))
            let paster = ClipboardRestoringTextPaster()
            let targetAdapter = DeterministicPastebackTargetAdapter(
                application: .codex,
                confirmsPaste: false,
                frontmostStates: [true, false, true]
            )

            pasteboard.clearContents()
            pasteboard.setString(originalClipboard, forType: .string)
            let outcome = paster.paste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    _ = pasteboard.string(forType: .string)
                    targetAdapter.markPasteDispatched()
                    return true
                },
                targetAdapter: targetAdapter,
                prepareForAutoSend: true,
                pasteConfirmationWait: 0.02
            )

            assertEqual(
                outcome,
                .copied(
                    "Focus moved before Transcripted could confirm paste. The text is on your clipboard — press ⌘V.",
                    reason: .focusChanged
                ),
                "a true-false-true focus bounce must remain terminal focus-loss friction"
            )
            assertEqual(
                targetAdapter.frontmostCheckCount,
                2,
                "the caller must not re-query focus and regain eligibility after the wait reports focus loss"
            )
            assertEqual(
                paster.lastConfirmationDiagnostic?.context["target_still_frontmost"],
                "false",
                "focus-bounce diagnostics should preserve the observed focus loss"
            )
            assertEqual(
                pasteboard.string(forType: .string),
                dictationText,
                "a focus bounce must keep manual recovery visible instead of restoring for Auto Enter"
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

    await runSuite("ClipboardRestoringTextPaster.paste — deterministic Codex, Notes, and browser adapters keep UI truth") {
        for application in DeterministicPastebackTargetAdapter.Application.allCases {
            let originalClipboard = "synthetic \(application.rawValue) original"
            let dictationText = "synthetic \(application.rawValue) dictation"
            let pasteboard = await MainActor.run {
                FakeClipboardPasteboard(initialString: originalClipboard)
            }
            let paster = await MainActor.run { ClipboardRestoringTextPaster() }
            let targetAdapter = await MainActor.run {
                DeterministicPastebackTargetAdapter(application: application)
            }
            let outcome = await MainActor.run {
                paster.paste(
                    dictationText,
                    pasteboard: pasteboard,
                    accessibilityTrusted: { true },
                    requestAccessibilityTrust: {},
                    pasteDispatcher: {
                        targetAdapter.markPasteDispatched()
                        // Deliberately do not read the provider. Codex and Notes
                        // prove delivery from AX-observable state alone.
                        return true
                    },
                    targetAdapter: targetAdapter,
                    restoreDelay: 5_000_000,
                    fallbackRestoreDelay: 5_000_000,
                    pasteConfirmationWait: 0
                )
            }

            switch application {
            case .codex, .notes:
                assertEqual(outcome, .pasted, "\(application.rawValue) AX-observable paste should be confirmed")
                let observedClipboardWasRead = await MainActor.run {
                    targetAdapter.observedClipboardWasRead
                }
                assertEqual(
                    observedClipboardWasRead,
                    false,
                    "\(application.rawValue) should not need an attributable provider read when AX proves the edit"
                )
                await paster.waitForPendingClipboardRestore()
                let restoredClipboard = await MainActor.run { pasteboard.string(forType: .string) }
                assertEqual(restoredClipboard, originalClipboard, "\(application.rawValue) should restore the original clipboard")
            case .browser:
                assertEqual(
                    outcome,
                    .copied(
                        "Transcripted sent paste, but this target did not expose paste confirmation. The text stays copied.",
                        reason: .pasteConfirmationUnavailable
                    ),
                    "browser targets without AX confirmation must stay neutral and copied"
                )
                let copiedClipboard = await MainActor.run { pasteboard.string(forType: .string) }
                assertEqual(
                    copiedClipboard,
                    dictationText,
                    "browser fallback should leave the dictation available for manual paste"
                )
            }
        }
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
        let targetAdapter = await MainActor.run {
            DeterministicPastebackTargetAdapter(application: .codex)
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
                    targetAdapter.markPasteDispatched()
                    return true
                },
                targetAdapter: targetAdapter,
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
        let targetAdapter = await MainActor.run {
            DeterministicPastebackTargetAdapter(application: .browser)
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
                targetAdapter: targetAdapter,
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
        let targetAdapter = await MainActor.run {
            DeterministicPastebackTargetAdapter(application: .codex, confirmsPaste: false)
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
                    targetAdapter.markPasteDispatched()
                    return true
                },
                targetAdapter: targetAdapter,
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
        let targetAdapter = await MainActor.run {
            DeterministicPastebackTargetAdapter(application: .codex)
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
                    targetAdapter.markPasteDispatched()
                    return true
                },
                targetAdapter: targetAdapter,
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
        let targetAdapter = await MainActor.run {
            DeterministicPastebackTargetAdapter(application: .codex)
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
                    targetAdapter.markPasteDispatched()
                    return true
                },
                targetAdapter: targetAdapter,
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
        let targetAdapter = await MainActor.run {
            DeterministicPastebackTargetAdapter(application: .codex)
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
                    targetAdapter.markPasteDispatched()
                    return true
                },
                targetAdapter: targetAdapter,
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
                    targetAdapter.markPasteDispatched()
                    return true
                },
                targetAdapter: targetAdapter,
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

    await runSuite("ClipboardRestoringTextPaster.retryPaste — restores the pre-dictation clipboard") {
        let originalClipboard = "synthetic original clipboard"
        let dictationText = "synthetic unconfirmed dictation"
        let pasteboard = await MainActor.run {
            FakeClipboardPasteboard(initialString: originalClipboard)
        }
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }
        let targetAdapter = await MainActor.run {
            DeterministicPastebackTargetAdapter(application: .codex, confirmsPaste: false)
        }

        let firstOutcome = await MainActor.run {
            paster.paste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    targetAdapter.markPasteDispatched()
                    return true
                },
                targetAdapter: targetAdapter,
                pasteConfirmationWait: 0
            )
        }
        let retryOutcome = await MainActor.run {
            targetAdapter.confirmsPaste = true
            return paster.retryPaste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    targetAdapter.markPasteDispatched()
                    return true
                },
                targetAdapter: targetAdapter,
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
            "the explicit retry should only be armed by a genuinely unconfirmed first attempt"
        )
        assertEqual(retryOutcome, .pasted, "the explicit retry should report its own confirmed paste")
        await paster.waitForPendingClipboardRestore()
        let restoredClipboard = await MainActor.run {
            pasteboard.string(forType: .string)
        }
        assertEqual(
            restoredClipboard,
            originalClipboard,
            "a successful explicit retry should restore the clipboard from before dictation"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.retryPaste — preserves a user copy made before retry") {
        let originalClipboard = "synthetic original clipboard"
        let userCopy = "synthetic newer user copy"
        let dictationText = "synthetic unconfirmed dictation"
        let pasteboard = await MainActor.run {
            FakeClipboardPasteboard(initialString: originalClipboard)
        }
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }
        let targetAdapter = await MainActor.run {
            DeterministicPastebackTargetAdapter(application: .codex, confirmsPaste: false)
        }

        _ = await MainActor.run {
            paster.paste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    targetAdapter.markPasteDispatched()
                    return true
                },
                targetAdapter: targetAdapter,
                pasteConfirmationWait: 0
            )
        }
        await MainActor.run {
            pasteboard.clearContents()
            pasteboard.setString(userCopy, forType: .string)
        }
        let retryOutcome = await MainActor.run {
            targetAdapter.confirmsPaste = true
            return paster.retryPaste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    targetAdapter.markPasteDispatched()
                    return true
                },
                targetAdapter: targetAdapter,
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 20_000_000,
                pasteConfirmationWait: 0
            )
        }

        assertEqual(retryOutcome, .pasted, "Paste Again should still work after the user copies something")
        await paster.waitForPendingClipboardRestore()
        let restoredClipboard = await MainActor.run {
            pasteboard.string(forType: .string)
        }
        assertEqual(
            restoredClipboard,
            userCopy,
            "Paste Again must preserve the user's newer clipboard instead of restoring stale pre-dictation data"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.discardPasteRetry — dismissal drops the retained snapshot") {
        let originalClipboard = "synthetic original clipboard"
        let dictationText = "synthetic dismissed retry dictation"
        let pasteboard = await MainActor.run {
            FakeClipboardPasteboard(initialString: originalClipboard)
        }
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }
        let targetAdapter = await MainActor.run {
            DeterministicPastebackTargetAdapter(application: .codex, confirmsPaste: false)
        }

        _ = await MainActor.run {
            let outcome = paster.paste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    targetAdapter.markPasteDispatched()
                    return true
                },
                targetAdapter: targetAdapter,
                pasteConfirmationWait: 0
            )
            paster.discardPasteRetry()
            return outcome
        }
        let retryOutcome = await MainActor.run {
            targetAdapter.confirmsPaste = true
            return paster.retryPaste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    targetAdapter.markPasteDispatched()
                    return true
                },
                targetAdapter: targetAdapter,
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 20_000_000,
                pasteConfirmationWait: 0
            )
        }

        assertEqual(retryOutcome, .pasted, "a stale programmatic retry should still paste safely")
        await paster.waitForPendingClipboardRestore()
        let clipboardAfterRetry = await MainActor.run {
            pasteboard.string(forType: .string)
        }
        assertEqual(
            clipboardAfterRetry,
            dictationText,
            "after dismissal, retry must not restore clipboard data retained from before dictation"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.retryPaste — an unconfirmed retry does not re-arm") {
        let originalClipboard = "synthetic original clipboard"
        let dictationText = "synthetic one-shot retry dictation"
        let pasteboard = await MainActor.run {
            FakeClipboardPasteboard(initialString: originalClipboard)
        }
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }
        let targetAdapter = await MainActor.run {
            DeterministicPastebackTargetAdapter(application: .codex, confirmsPaste: false)
        }

        _ = await MainActor.run {
            paster.paste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    targetAdapter.markPasteDispatched()
                    return true
                },
                targetAdapter: targetAdapter,
                pasteConfirmationWait: 0
            )
        }
        let unconfirmedRetry = await MainActor.run {
            paster.retryPaste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    targetAdapter.markPasteDispatched()
                    return true
                },
                targetAdapter: targetAdapter,
                pasteConfirmationWait: 0
            )
        }
        let laterProgrammaticRetry = await MainActor.run {
            targetAdapter.confirmsPaste = true
            return paster.retryPaste(
                dictationText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    targetAdapter.markPasteDispatched()
                    return true
                },
                targetAdapter: targetAdapter,
                restoreDelay: 5_000_000,
                fallbackRestoreDelay: 20_000_000,
                pasteConfirmationWait: 0
            )
        }

        assertEqual(
            unconfirmedRetry,
            .copied(
                "Transcripted tried to paste, but could not confirm the target received it. The text stays copied.",
                reason: .pasteNotConfirmed
            ),
            "the one visible retry may still end unconfirmed"
        )
        assertEqual(laterProgrammaticRetry, .pasted, "a later direct call should remain safe")
        await paster.waitForPendingClipboardRestore()
        let clipboardAfterRetry = await MainActor.run {
            pasteboard.string(forType: .string)
        }
        assertEqual(
            clipboardAfterRetry,
            dictationText,
            "an unconfirmed retry must consume, not re-arm, the pre-dictation clipboard snapshot"
        )
    }

    await runSuite("ClipboardRestoringTextPaster.cancelPendingClipboardRestore — restores scheduled clipboard") {
        let pasteText = "synthetic paste text"
        let existingClipboard = "synthetic existing clipboard"
        let pasteboardName = NSPasteboard.Name("TranscriptedCancelRestoreTest-\(UUID().uuidString)")
        let paster = await MainActor.run {
            ClipboardRestoringTextPaster()
        }
        let targetAdapter = await MainActor.run {
            DeterministicPastebackTargetAdapter(application: .codex)
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
                    targetAdapter.markPasteDispatched()
                    return true
                },
                targetAdapter: targetAdapter,
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

    await runSuite("ClipboardRestoringTextPaster.cancelPendingClipboardRestore — restores retry-retained clipboard") {
        let existingClipboard = "synthetic existing clipboard"
        let pasteText = "synthetic unconfirmed paste"
        let pasteboard = await MainActor.run {
            FakeClipboardPasteboard(initialString: existingClipboard)
        }
        let paster = await MainActor.run { ClipboardRestoringTextPaster() }
        let targetAdapter = await MainActor.run {
            DeterministicPastebackTargetAdapter(application: .codex, confirmsPaste: false)
        }

        let outcome = await MainActor.run {
            let outcome = paster.paste(
                pasteText,
                pasteboard: pasteboard,
                accessibilityTrusted: { true },
                requestAccessibilityTrust: {},
                pasteDispatcher: {
                    targetAdapter.markPasteDispatched()
                    return true
                },
                targetAdapter: targetAdapter,
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
            "the first paste should retain its restore snapshot for Paste Again"
        )
        let clipboardAfterCancel = await MainActor.run {
            pasteboard.string(forType: .string)
        }
        assertEqual(
            clipboardAfterCancel,
            existingClipboard,
            "canceling should restore the user's clipboard even after the snapshot moved into retry retention"
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
private final class DeterministicPastebackTargetAdapter: ClipboardPasteTargetAdapter, ClipboardPasteConfirmationSource {
    enum Application: String, CaseIterable {
        case codex
        case notes
        case browser
    }

    let application: Application
    var confirmsPaste: Bool
    private var frontmostStates: [Bool]
    private(set) var frontmostCheckCount = 0
    private var pasteWasDispatched = false
    private(set) var observedClipboardWasRead: Bool?

    init(
        application: Application,
        confirmsPaste: Bool = true,
        frontmostStates: [Bool] = [true]
    ) {
        self.application = application
        self.confirmsPaste = confirmsPaste
        self.frontmostStates = frontmostStates.isEmpty ? [true] : frontmostStates
    }

    var confirmationSource: (any ClipboardPasteConfirmationSource)? {
        application == .browser ? nil : self
    }

    var canObservePaste: Bool {
        application != .browser
    }

    func isFrontmost() -> Bool {
        let index = min(frontmostCheckCount, frontmostStates.count - 1)
        frontmostCheckCount += 1
        return frontmostStates[index]
    }

    func markPasteDispatched() {
        pasteWasDispatched = true
    }

    func confirmationMode(
        _ text: String,
        clipboardWasRead: Bool,
        clipboardReadAt: CFAbsoluteTime?,
        pasteDispatchedAt: CFAbsoluteTime
    ) -> String? {
        observedClipboardWasRead = clipboardWasRead
        guard pasteWasDispatched, confirmsPaste else { return nil }
        switch application {
        case .codex:
            return "text_value"
        case .notes:
            // Notes can expose the edited AX value even when its pasteboard
            // provider read is not attributable to the target.
            return "text_value"
        case .browser:
            return nil
        }
    }

    func diagnosticsContext(
        clipboardReadAt: CFAbsoluteTime?,
        pasteDispatchedAt: CFAbsoluteTime
    ) -> [String: String] {
        [
            "clipboard_read_after_dispatch": "\((clipboardReadAt ?? 0) >= pasteDispatchedAt)",
            "target_change_after_dispatch": "false",
            "target_change_observer_available": "false",
            "target_selection_observable": application == .notes ? "true" : "false",
            "target_text_observable": application == .codex || application == .notes ? "true" : "false",
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
