// DictationSessionController+PasteBack.swift
// Paste-back: the Not pasted / clipboard-busy notices, the paste itself, and Auto Enter.

import AppKit

extension DictationSessionController {
    /// A clipboard too big to set aside kept paste-back from running. Copy
    /// replaces it with the words, at the user's request, and then the usual
    /// "Not pasted" notice takes over (Paste, or ⌘V where they go).
    func showClipboardBusy(_ text: String, message: String, overlayController: FloatingOverlayController) {
        overlayController.showClipboardBusyNotice(text, fallbackMessage: message) { [weak self, weak overlayController] in
            guard let self, let overlayController else { return }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setString(text, forType: .string) else {
                overlayController.showError("Couldn't copy your words. They're saved in Dictations.")
                return
            }
            self.showNotPasted(
                text,
                message: "Your words are on the clipboard. Press ⌘V to paste them.",
                overlayController: overlayController
            )
        }
    }

    /// The "Not pasted" notice, whose Paste button pastes into whatever app
    /// is in front now (the user clicks where the words go first).
    func showNotPasted(
        _ text: String,
        message: String,
        unconfirmed: Bool = false,
        overlayController: FloatingOverlayController
    ) {
        overlayController.showNotPastedNotice(
            text,
            fallbackMessage: message,
            unconfirmed: unconfirmed
        ) { [weak self, weak overlayController] in
            guard let self, let overlayController else { return }
            let frontmost = NSWorkspace.shared.frontmostApplication
            guard frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
            switch self.textPaster.paste(text, target: DictationPasteTarget.capture(sourceApp: frontmost)) {
            case .pasted, .likelyPasted:
                overlayController.showSuccessAndDismiss(title: "Pasted")
            case .copied(let retryMessage, reason: _):
                self.showNotPasted(text, message: retryMessage, overlayController: overlayController)
            case .failed(let failure, reason: _):
                overlayController.showError(failure)
            }
        }
    }

    func pasteWithClipboardRestore(
        _ text: String,
        followCurrentFocus: Bool = true
    ) -> DictationPasteOutcome {
        if followCurrentFocus {
            retargetPasteToCurrentFocus()
        } else {
            appState?.logger.log("DICTATION | long model wait, keeping the original paste target")
        }
        autoSendRequestDecision = DictationAutoSendPolicy.requestDecision(
            isEnabled: DictationAutoSendPreferences.isEnabled(),
            key: DictationAutoSendPreferences.sendKey(),
            text: text,
            duration: CFAbsoluteTimeGetCurrent() - sessionStartTime,
            sourceBundleID: sessionSourceApp?.bundleIdentifier,
            allowedBundleIDs: DictationAutoSendPreferences.allowedBundleIDs()
        )
        let outcome = textPaster.paste(
            text,
            target: sessionPasteTarget
        )
        recordPasteAttemptOutcome(outcome, attempt: "initial")
        return outcome
    }

    private func recordPasteAttemptOutcome(
        _ outcome: DictationPasteOutcome,
        attempt: String
    ) {
        if let diagnostic = textPaster.lastConfirmationDiagnostic {
            var context = diagnostic.context
            context["attempt"] = attempt
            EventReporter.shared.capture(
                level: diagnostic.event == "dictation_paste_confirmed" ? .info : outcome.diagnosticLevel,
                engine: "overlay",
                event: diagnostic.event,
                message: diagnostic.event == "dictation_paste_confirmed"
                    ? "Paste delivery confirmed from privacy-safe target signals"
                    : outcome == .likelyPasted
                        ? "Paste most likely delivered: the target read the clipboard right after Cmd+V"
                        : "Paste delivery could not be confirmed from privacy-safe target signals",
                context: context
            )
        }

        let context = ["attempt": attempt]
        if outcome == .likelyPasted {
            appState?.logger.log("DICTATION | target read the clipboard right after paste; treating as pasted and restoring the clipboard")
        }
        switch outcome.copyReason {
        case .accessibilityMissing:
            appState?.logger.log("DICTATION | Accessibility missing, copying text instead")
        case .pasteEventCreationFailed:
            EventReporter.shared.capture(level: .error, engine: "overlay", event: "cgevent_create_failed",
                message: "CGEvent creation returned nil — paste will not work", context: context)
            appState?.logger.log("DICTATION | CGEvent paste failed, keeping text on clipboard")
        case .focusChanged:
            EventReporter.shared.capture(level: .warning, engine: "overlay", event: "dictation_paste_target_changed",
                message: "Focus changed before dictation paste", context: context)
            appState?.logger.log("DICTATION | focus changed, copying text instead")
        case .pasteNotConfirmed:
            EventReporter.shared.capture(level: .warning, engine: "overlay", event: "dictation_paste_not_confirmed",
                message: "Paste-back was dispatched but the target did not confirm reading the borrowed clipboard", context: context)
            appState?.logger.log("DICTATION | paste not confirmed, keeping text on clipboard")
        case nil:
            break
        }
    }

    private func retargetPasteToCurrentFocus() {
        let previousTarget = sessionPasteTarget
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostTarget = DictationPasteTarget.capture(sourceApp: frontmostApp)
        let resolvedTarget = DictationPasteTarget.preferredDestination(
            frontmostProcessIdentifier: frontmostApp?.processIdentifier,
            frontmostBundleIdentifier: frontmostApp?.bundleIdentifier,
            transcriptedBundleIdentifier: Bundle.main.bundleIdentifier,
            fallback: previousTarget
        )

        sessionPasteTarget = resolvedTarget
        if resolvedTarget == frontmostTarget,
           frontmostApp?.bundleIdentifier != Bundle.main.bundleIdentifier {
            sessionSourceApp = frontmostApp
        }

        if resolvedTarget != previousTarget {
            appState?.logger.log("DICTATION | paste target updated to current focus")
            EventReporter.shared.capture(
                level: .info,
                engine: "overlay",
                event: "dictation_paste_target_updated",
                message: "Paste target followed current focus",
                context: ["target_changed": "true"]
            )
        }
    }

    func performAutoEnterIfNeeded(
        pasteOutcome: DictationPasteOutcome,
        sessionID: UUID
    ) async -> DictationAutoSendOutcome {
        guard autoSendRequestDecision.expected,
              pasteOutcome.allowsAutoSend else {
            return .disabled
        }

        try? await Task.sleep(nanoseconds: TranscriptedConstants.dictationAutoEnterDelay)
        guard DictationSessionCompletionPolicy.canPublish(
            sessionID: sessionID, currentSessionID: currentDictationSessionID,
            isDictating: isDictating, cancelled: Task.isCancelled
        ) else { return .disabled }
        if pasteOutcome.requiresClipboardReadinessBeforeAutoSend {
            await textPaster.waitForClipboardReadyForAutoEnter()
        }
        guard DictationSessionCompletionPolicy.canPublish(
            sessionID: sessionID, currentSessionID: currentDictationSessionID,
            isDictating: isDictating, cancelled: Task.isCancelled
        ) else { return .disabled }
        return autoSender.send(autoSendRequestDecision.key, target: sessionPasteTarget)
    }
}
