// DictationTargetAccessibilityPrimerTests.swift
//
// Auto Enter presses Return only after a paste proven over Accessibility, and
// Electron apps hide their text fields until an assistive app asks for them.
// These suites check that Transcripted asks (AXManualAccessibility) for an app
// on the Auto Enter allow-list and for nothing else (never VS Code-family
// editors, which switch to screen-reader mode), once per process, and
// that the local logs say why Auto Enter held back. Fakes only: whether a real
// Electron app then confirms a paste needs a hands-on check.

import ApplicationServices
import Foundation

func testDictationTargetAccessibilityPrimer() async {
    await runDictationTargetAccessibilityPrimerSuites()
}

private final class ManualAccessibilityRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var pids: [pid_t] = []
    private var results: [AXError]

    init(results: [AXError] = []) {
        self.results = results
    }

    func record(_ pid: pid_t) -> AXError {
        lock.lock()
        defer { lock.unlock() }
        pids.append(pid)
        return results.isEmpty ? .success : results.removeFirst()
    }

    var requested: [pid_t] {
        lock.lock()
        defer { lock.unlock() }
        return pids
    }
}

@MainActor
private func runDictationTargetAccessibilityPrimerSuites() async {
    let chat = "com.example.ChatDesktop"
    let notes = "com.example.Notes"
    let ownPID: pid_t = 900

    func makePrimer(_ requests: ManualAccessibilityRequests) -> DictationTargetAccessibilityPrimer {
        DictationTargetAccessibilityPrimer(
            enableManualAccessibility: { requests.record($0) },
            ownProcessIdentifier: ownPID
        )
    }

    await runSuite("An Auto Enter app is asked to expose its Accessibility tree, once per process") {
        let requests = ManualAccessibilityRequests()
        let primer = makePrimer(requests)
        let target = DictationPasteTarget(processIdentifier: 412, bundleIdentifier: chat)

        await primer.prime(target, autoEnterEnabled: true, allowedBundleIDs: [chat])?.value
        let second = primer.prime(target, autoEnterEnabled: true, allowedBundleIDs: [chat])
        await second?.value

        assertNil(second, "a process that already answered is not asked again")
        assertEqual(requests.requested, [412], "the allow-listed app is asked exactly once")

        let relaunched = DictationPasteTarget(processIdentifier: 518, bundleIdentifier: chat)
        await primer.prime(relaunched, autoEnterEnabled: true, allowedBundleIDs: [chat])?.value
        assertEqual(requests.requested, [412, 518], "a new process of the same app is asked too")
    }

    await runSuite("Apps off the Auto Enter allow-list are never asked") {
        let requests = ManualAccessibilityRequests()
        let primer = makePrimer(requests)

        let cases: [(DictationPasteTarget?, Bool, String)] = [
            (DictationPasteTarget(processIdentifier: 412, bundleIdentifier: notes), true, "an app not on the allow-list"),
            (DictationPasteTarget(processIdentifier: 412, bundleIdentifier: chat), false, "Auto Enter switched off"),
            (DictationPasteTarget(processIdentifier: 412, bundleIdentifier: nil), true, "an app with no bundle id"),
            (DictationPasteTarget(processIdentifier: nil, bundleIdentifier: chat), true, "a target with no process"),
            (DictationPasteTarget(processIdentifier: ownPID, bundleIdentifier: chat), true, "Transcripted itself"),
            (nil, true, "no target at all"),
            (DictationPasteTarget(processIdentifier: 412, bundleIdentifier: "com.microsoft.VSCode"), true, "VS Code on the allow-list"),
            (DictationPasteTarget(processIdentifier: 412, bundleIdentifier: "com.todesktop.230313mzl4w4u92"), true, "Cursor on the allow-list"),
        ]
        let allowed: Set<String> = [chat, "com.microsoft.VSCode", "com.todesktop.230313mzl4w4u92"]
        for (target, enabled, label) in cases {
            let task = primer.prime(target, autoEnterEnabled: enabled, allowedBundleIDs: allowed)
            await task?.value
            assertNil(task, "nothing is asked for \(label)")
        }
        assertEqual(requests.requested, [], "only Auto Enter apps pay for a tree, and editors that would flip to screen-reader mode never do")
    }

    await runSuite("An app that didn't answer in time is asked again on the next take") {
        let requests = ManualAccessibilityRequests(results: [.cannotComplete, .success])
        let primer = makePrimer(requests)
        let target = DictationPasteTarget(processIdentifier: 412, bundleIdentifier: chat)

        await primer.prime(target, autoEnterEnabled: true, allowedBundleIDs: [chat])?.value
        await primer.prime(target, autoEnterEnabled: true, allowedBundleIDs: [chat])?.value
        await primer.prime(target, autoEnterEnabled: true, allowedBundleIDs: [chat])?.value

        assertEqual(requests.requested, [412, 412], "a timeout retries once, then the answer sticks")
    }

    await runSuite("An app that doesn't know the attribute is not asked again") {
        let requests = ManualAccessibilityRequests(results: [.attributeUnsupported])
        let primer = makePrimer(requests)
        let target = DictationPasteTarget(processIdentifier: 77, bundleIdentifier: notes)

        await primer.prime(target, autoEnterEnabled: true, allowedBundleIDs: [notes])?.value
        await primer.prime(target, autoEnterEnabled: true, allowedBundleIDs: [notes])?.value

        assertEqual(requests.requested, [77], "native apps answer unsupported once and are left alone")
    }

    runSuite("A paste Auto Enter couldn't prove says so in the local delivery log") {
        let request = DictationAutoSendPolicy.requestDecision(
            isEnabled: true,
            key: .enter,
            text: "ship it",
            duration: TranscriptedConstants.dictationAutoEnterMinimumDuration + 1,
            sourceBundleID: chat,
            allowedBundleIDs: [chat]
        )
        assertFalse(TextPasteOutcome.likelyPasted.allowsAutoSend, "an unproven paste never presses Return")

        let telemetry = DictationAutoSendTelemetry.snapshot(
            request: request,
            pasteOutcome: .likelyPasted,
            sendOutcome: .disabled
        )
        let context = telemetry.localDiagnosticContext(
            targetConfirmationMode: .resolve(outcome: .likelyPasted, diagnostic: nil)
        )
        assertEqual(context["auto_send_block_reason"], "paste_unverified", "the log names the real reason")
        assertEqual(context["auto_send_expected"], "true", "the log shows Auto Enter wanted to fire")
        assertEqual(context["target_confirmation_mode"], "clipboard_read", "the log shows only a clipboard read backed the paste")

        var eventContext = TextPasteOutcome.likelyPasted.deliveryProperties
        eventContext["auto_send"] = DictationAutoSendOutcome.disabled.diagnosticName
        eventContext.merge(context) { _, new in new }
        let packet = ReliabilityPacketRecorder.packet(from: ObservabilityEvent(
            timestamp: "2026-10-21T12:00:00Z", level: "info", engine: "dictation",
            event: "dictation_delivery_completed", message: "Dictation most likely pasted",
            context: eventContext,
            appVersion: "1.1.73", osVersion: "Version 26.6.0"
        ))
        assertEqual(packet?.context["delivery"], "pasted", "a likely paste still counts as delivered")
        assertEqual(packet?.context["auto_send_block_reason"], "paste_unverified", "the support packet keeps the block reason")
        assertEqual(packet?.context["auto_send_expected"], "true", "the support packet keeps whether Auto Enter was expected")
        assertEqual(packet?.context["target_confirmation_mode"], "clipboard_read", "the support packet keeps the confirmation mode")
    }

    runSuite("A proven paste logs no block reason and how it was confirmed") {
        let request = DictationAutoSendPolicy.requestDecision(
            isEnabled: true,
            key: .commandEnter,
            text: "ship it",
            duration: TranscriptedConstants.dictationAutoEnterMinimumDuration + 1,
            sourceBundleID: chat,
            allowedBundleIDs: [chat]
        )
        let telemetry = DictationAutoSendTelemetry.snapshot(
            request: request,
            pasteOutcome: .pasted,
            sendOutcome: .sent(.commandEnter)
        )
        let confirmed = ClipboardPasteConfirmationDiagnostic(
            event: "dictation_paste_confirmed",
            context: ["confirmation_mode": "text_value"]
        )
        let context = telemetry.localDiagnosticContext(
            targetConfirmationMode: .resolve(outcome: .pasted, diagnostic: confirmed)
        )
        assertEqual(context["auto_send_block_reason"], "none", "nothing held Auto Enter back")
        assertEqual(context["auto_send_key"], "command_enter", "the log names the key it pressed")
        assertEqual(context["target_confirmation_mode"], "text_value", "the paste was proven from the text field")
    }
}
