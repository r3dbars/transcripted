// ClipboardRestoringTextPaster.swift
// Pastes text into the current target app by borrowing the clipboard briefly
// and restoring the prior clipboard contents after the target reads the text.

import AppKit
import ApplicationServices
import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

@MainActor
final class ClipboardRestoringTextPaster {
    struct PendingClipboardRestore {
        let savedItems: PasteboardSnapshot
        let temporaryString: String
        let temporaryChangeCount: Int
        let pasteboard: any ClipboardPasteboard
    }

    private enum ClipboardFallbackState: String {
        case dictationPresent = "dictation_present"
        case clipboardChanged = "clipboard_changed"
        case clipboardEmpty = "clipboard_empty"
        case unavailable

        var hasVerifiedDictation: Bool {
            self == .dictationPresent
        }
    }

    private static let unverifiedClipboardRecoveryFailure =
        "Transcripted sent paste, but could not confirm it or place a recovery copy on the clipboard. Check your dictation history."

    /// Shown when nothing suggested the paste landed. A slow target can still
    /// paste after the wait (the text stays on the clipboard), so this must not
    /// claim the paste failed: pressing ⌘V after a paste that did land would
    /// paste the text twice.
    nonisolated static let pasteNotConfirmedMessage =
        "Couldn't confirm the paste. If the text isn't there, press ⌘V."

    private var clipboardRestoreTask: Task<Void, Never>?
    private var clipboardAutoEnterReadinessTask: Task<Void, Never>?
    private var clipboardAutoEnterReadyToken: SupersessionEpoch.Token?
    private var pendingClipboardRestore = ClaimSlot<PendingClipboardRestore>()
    private var retainedClipboardRestoreForPasteRetry: PendingClipboardRestore?
    private var temporaryPasteboardDataProvider: TemporaryPasteboardStringProvider?
    /// Every paster that has run a paste, so one can put back another's
    /// clipboard (dictation, Paste Last and the menu bar all borrow the same
    /// one) and so quitting can put back all of them.
    private static var registeredPasters: [WeakPasterReference] = []
    /// Non-zero while `paste()` is running on this paster, including a nested
    /// paste started while it waits. Another paster never touches a restore
    /// that belongs to a paste still in flight.
    private var activePasteCount = 0
    /// Epoch — begun per paste attempt, invalidated whenever the pending restore
    /// is cleared, superseded when a scheduled restore completes
    private var pasteEpoch = SupersessionEpoch()
    private var operationEpoch = SupersessionEpoch()
    private var latestStartedOperation: SupersessionEpoch.Token?
    private(set) var lastConfirmationDiagnostic: ClipboardPasteConfirmationDiagnostic?
    private(set) var lastPasteTiming: ClipboardPasteTiming?
    /// The delay the latest scheduled restore of the user's clipboard waits.
    private(set) var scheduledClipboardRestoreDelay: UInt64?
    private lazy var lateConfirmationWatch = ClipboardLateConfirmationWatch()

    deinit {
        clipboardRestoreTask?.cancel()
        clipboardAutoEnterReadinessTask?.cancel()
    }

    func cancelPendingClipboardRestore() {
        restorePendingClipboardNow()
        restoreRetainedClipboardNow()
    }

    func discardPasteRetry() {
        restoreRetainedClipboardNow()
    }

    func restorePendingClipboardNow() {
        operationEpoch.invalidate()
        restorePendingClipboard()
    }

    private func restorePendingClipboard() {
        guard let pending = clearPendingClipboardRestore() else { return }
        restorePasteboardItems(
            pending.savedItems,
            temporaryString: pending.temporaryString,
            temporaryChangeCount: pending.temporaryChangeCount,
            to: pending.pasteboard
        )
    }

    /// Puts back the clipboard every paster borrowed, right now. Called when
    /// the app quits so a restore still waiting on its delay isn't lost and
    /// the dictation isn't left in place of the user's own clipboard.
    static func restorePendingClipboardsBeforeQuit() {
        for paster in livePasters() {
            paster.restorePendingClipboardNow()
        }
    }

    private static func livePasters() -> [ClipboardRestoringTextPaster] {
        registeredPasters.removeAll { $0.paster == nil }
        return registeredPasters.compactMap(\.paster)
    }

    private func registerForSharedClipboardRestores() {
        guard !Self.livePasters().contains(where: { $0 === self }) else { return }
        Self.registeredPasters.append(WeakPasterReference(self))
    }

    /// A restore another paster is still waiting to run (after a likely
    /// paste it waits the longer fallback delay) would otherwise be snapshotted
    /// by this paste as if it were the user's clipboard, and the user's real
    /// clipboard would be lost when that restore then sees a changed clipboard.
    private func restoreOtherPastersPendingClipboards() {
        for paster in Self.livePasters() where paster !== self && paster.activePasteCount == 0 {
            paster.restorePendingClipboard()
        }
    }

    func waitForPendingClipboardRestore() async {
        while let clipboardRestoreTask {
            await clipboardRestoreTask.value
        }
    }

    func waitForClipboardReadyForAutoEnter() async {
        while let readinessTask = clipboardAutoEnterReadinessTask {
            await readinessTask.value
        }
        if false, let readyToken = clipboardAutoEnterReadyToken, pasteEpoch.isCurrent(readyToken) {
            return
        }
        await waitForPendingClipboardRestore()
    }

    func waitForLateConfirmationWatch() async {
        await lateConfirmationWatch.waitUntilFinished()
    }

    /// `endWaitOnLikelyPaste`: the caller needs no confirmed paste (a dictation with Auto Enter not
    /// expected), so a quick read by a target that could still confirm may end the wait as a likely
    /// paste (`FocusedTextPasteConfirmationPolicy.endsWaitOnLikelyPaste`). `onLateConfirmation`
    /// hears if that target confirms before the full wait would have ended.
    func paste(
        _ text: String,
        target: DictationPasteTarget? = nil,
        activationWait: TimeInterval = TranscriptedConstants.clipboardTargetActivationWait,
        pasteboard: any ClipboardPasteboard = NSPasteboard.general,
        accessibilityTrusted: () -> Bool = { AXIsProcessTrusted() },
        requestAccessibilityTrust: () -> Void = {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        },
        pasteDispatcher: @MainActor () -> Bool = postClipboardPasteShortcut,
        confirmationSource: (@MainActor () -> (any ClipboardPasteConfirmationSource)?)? = nil,
        pasteConfirmed: (@MainActor () -> Bool)? = nil,
        targetIsFrontmost: (@MainActor () -> Bool)? = nil,
        retainClipboardForPasteRetry: Bool = true,
        restoreDelay: UInt64 = TranscriptedConstants.clipboardRestoreDelay,
        fallbackRestoreDelay: UInt64 = TranscriptedConstants.clipboardRestoreFallbackDelay,
        pasteConfirmationWait: TimeInterval = TranscriptedConstants.clipboardPasteConfirmationWait,
        endWaitOnLikelyPaste: Bool = false,
        onLateConfirmation: (@MainActor (ClipboardPasteConfirmationDiagnostic) -> Void)? = nil
    ) -> TextPasteOutcome {
        let operation = operationEpoch.begin()
        latestStartedOperation = operation
        let isCurrentOperation = { self.operationEpoch.isCurrent(operation) }
        let cancelledOutcome = TextPasteOutcome.failed("Paste was cancelled.", reason: .cancelled)
        lastConfirmationDiagnostic = nil
        lastPasteTiming = nil
        let timingStartedAt = CFAbsoluteTimeGetCurrent()
        var timingDispatchStartedAt: CFAbsoluteTime?
        var timingDispatchFinishedAt: CFAbsoluteTime?
        var timingConfirmationStartedAt: CFAbsoluteTime?
        var timingConfirmationFinishedAt: CFAbsoluteTime?
        var timingProvider: TemporaryPasteboardStringProvider?
        var accessibilityCaptureMS: Int?
        var clipboardSnapshotMS: Int?
        defer {
            if isCurrentOperation() {
                lastPasteTiming = ClipboardPasteTiming(
                    startedAt: timingStartedAt,
                    dispatchStartedAt: timingDispatchStartedAt,
                    dispatchFinishedAt: timingDispatchFinishedAt,
                    clipboardReadAt: timingProvider?.firstReadAt,
                    confirmationStartedAt: timingConfirmationStartedAt,
                    confirmationFinishedAt: timingConfirmationFinishedAt,
                    accessibilityCaptureMS: accessibilityCaptureMS,
                    clipboardSnapshotMS: clipboardSnapshotMS
                )
            }
        }
        activePasteCount += 1
        defer { activePasteCount -= 1 }
        registerForSharedClipboardRestores()
        discardPasteRetry()
        guard isCurrentOperation() else { return cancelledOutcome }
        restorePendingClipboard()
        guard isCurrentOperation() else { return cancelledOutcome }
        restoreOtherPastersPendingClipboards()
        guard isCurrentOperation() else { return cancelledOutcome }
        // Starting another paste means the user moved on from the last
        // fallback copy, so give them their own clipboard back first. This
        // paste then snapshots and restores it like any other clipboard. The
        // dictated text from the fallback stays in dictation history.
        restoreClipboardSavedBeforeFallback(on: pasteboard)
        guard isCurrentOperation() else { return cancelledOutcome }

        if let target,
           !target.matchesCurrentFrontmostApp(),
           !waitForTargetActivation(target, timeout: activationWait, isCurrentOperation: isCurrentOperation) {
            guard isCurrentOperation() else { return cancelledOutcome }
            let copied = copyTextForManualPaste(text, to: pasteboard, isCurrentOperation: isCurrentOperation)
            guard isCurrentOperation() else { return cancelledOutcome }
            guard copied else {
                return .failed(
                    "Focus moved, and Transcripted couldn't put the text on your clipboard. It's still saved in your dictation history.",
                    reason: .focusChangeClipboardWriteFailed
                )
            }
            guard isCurrentOperation() else { return cancelledOutcome }
            return .copied(
                "Focus moved before the text could paste. It's on your clipboard — press ⌘V to paste it.",
                reason: .focusChanged
            )
        }

        guard isCurrentOperation() else { return cancelledOutcome }
        let trusted = accessibilityTrusted()
        guard isCurrentOperation() else { return cancelledOutcome }
        guard trusted else {
            requestAccessibilityTrust()
            guard isCurrentOperation() else { return cancelledOutcome }
            let copied = copyTextForManualPaste(text, to: pasteboard, isCurrentOperation: isCurrentOperation)
            guard isCurrentOperation() else { return cancelledOutcome }
            guard copied else {
                return .failed(
                    "Accessibility is off, and Transcripted couldn't put the text on your clipboard. It's still saved in your dictation history.",
                    reason: .accessibilityFallbackClipboardWriteFailed
                )
            }
            guard isCurrentOperation() else { return cancelledOutcome }
            return .copied(
                "Accessibility is off, so Transcripted can't paste for you. Your text is on the clipboard — press ⌘V.",
                reason: .accessibilityMissing
            )
        }

        let accessibilityStartedAt = CFAbsoluteTimeGetCurrent()
        let accessibilityConfirmation = confirmationSource?() ?? FocusedTextPasteConfirmation.capture()
        accessibilityCaptureMS = max(0, Int(((CFAbsoluteTimeGetCurrent() - accessibilityStartedAt) * 1_000).rounded()))
        guard isCurrentOperation() else { return cancelledOutcome }
        let snapshotStartedAt = CFAbsoluteTimeGetCurrent()
        let snapshotChangeCount = pasteboard.changeCount
        let savedItems = snapshotPasteboardItems(from: pasteboard)
        clipboardSnapshotMS = max(0, Int(((CFAbsoluteTimeGetCurrent() - snapshotStartedAt) * 1_000).rounded()))
        // Lazy clipboard providers can run while materializing a snapshot. Do
        // not overwrite a newer clipboard with an older restore snapshot.
        guard isCurrentOperation() else { return cancelledOutcome }
        guard savedItems.isComplete, pasteboard.changeCount == snapshotChangeCount else {
            return .failed(
                "Couldn't paste automatically without risking your current clipboard. The dictation was saved, but paste-back did not run.",
                reason: .clipboardSnapshotIncomplete
            )
        }
        let pasteToken = pasteEpoch.begin()
        var temporaryChangeCount = 0
        var restoreInstalled = false
        var clearedChangeCount: Int?
        defer {
            // Cancellation can arrive from a provider while the initial write
            // is still in progress, before a pending restore can be installed.
            // Roll back that borrowed clipboard, never a newer paste attempt.
            if !restoreInstalled, latestStartedOperation == operation {
                let observedCount = pasteboard.changeCount
                let currentString = pasteboard.string(forType: .string)
                if currentString == text || (currentString == nil && observedCount == clearedChangeCount) {
                    restoreClipboardSnapshot(savedItems, matching: currentString,
                        changeCount: observedCount, to: pasteboard)
                }
                if latestStartedOperation == operation {
                    temporaryPasteboardDataProvider = nil
                }
            }
        }

        clearedChangeCount = pasteboard.clearContents()
        guard isCurrentOperation() else { return cancelledOutcome }
        let wroteTemporaryString = writeTemporaryString(text, to: pasteboard)
        guard isCurrentOperation() else { return cancelledOutcome }
        if !wroteTemporaryString {
            clearedChangeCount = pasteboard.clearContents()
            guard isCurrentOperation() else { return cancelledOutcome }
            let wroteFallback = pasteboard.setString(text, forType: .string)
            guard isCurrentOperation() else { return cancelledOutcome }
            guard wroteFallback, pasteboard.string(forType: .string) == text else {
                return .failed(
                    "Couldn't paste or copy the text automatically. It's still saved in your dictation history.",
                    reason: .temporaryClipboardWriteFailed
                )
            }
        }
        guard isCurrentOperation() else { return cancelledOutcome }
        temporaryChangeCount = pasteboard.changeCount
        let temporaryProvider = temporaryPasteboardDataProvider
        timingProvider = temporaryProvider

        scheduleClipboardRestore(
            savedItems,
            temporaryString: text,
            temporaryChangeCount: temporaryChangeCount,
            to: pasteboard,
            token: pasteToken,
            delay: fallbackRestoreDelay
        )
        restoreInstalled = true

        let pasteDispatchedAt = CFAbsoluteTimeGetCurrent()
        timingDispatchStartedAt = pasteDispatchedAt
        guard isCurrentOperation() else { return cancelledOutcome }
        let dispatched = pasteDispatcher()
        guard isCurrentOperation() else { return cancelledOutcome }
        guard dispatched else {
            timingDispatchFinishedAt = CFAbsoluteTimeGetCurrent()
            restorePendingClipboard()
            guard copyTextToClipboard(text, to: pasteboard) else {
                return .failed(
                    "Couldn't paste or copy the text automatically. It's still saved in your dictation history.",
                    reason: .pasteDispatchClipboardRecoveryFailed
                )
            }
            saveClipboardForNextPaste(savedItems, fallbackText: text, fallbackChangeCount: pasteboard.changeCount, pasteboard: pasteboard)
            guard isCurrentOperation() else { return cancelledOutcome }
            return .copied(
                "Couldn't paste automatically. Your text is on the clipboard — press ⌘V.",
                reason: .pasteEventCreationFailed
            )
        }
        timingDispatchFinishedAt = CFAbsoluteTimeGetCurrent()

        let confirmationUnavailable = pasteConfirmed == nil && accessibilityConfirmation?.canObservePaste != true
        let targetRemainsFrontmost = targetIsFrontmost ?? { target?.matchesCurrentFrontmostApp() != false }
        var accessibilityConfirmedMode: String?
        let confirmPasteReceived = pasteConfirmed ?? {
            // The text cannot have landed before the target read the borrowed
            // clipboard, so don't ask over Accessibility until it has. Asking
            // earlier can catch the target mid-paste, blocked on this main
            // thread for the string: the AX call then blocks on the target
            // until its timeouts expire (~100 ms) before the read can run.
            if let temporaryProvider, !temporaryProvider.didProvideData {
                return false
            }
            guard let mode = accessibilityConfirmation?.confirmationMode(
                text,
                clipboardWasRead: temporaryProvider?.didProvideData == true,
                clipboardReadAt: temporaryProvider?.firstReadAt,
                pasteDispatchedAt: pasteDispatchedAt
            ) else { return false }
            accessibilityConfirmedMode = mode
            return true
        }
        // A target with no observable confirmation surface can never upgrade to a
        // confirmed paste inside this wait (no AX value, selection, or change
        // observer exists to fire), so once the target reads the borrowed
        // clipboard after Cmd+V the rest of the window is dead time. The read is
        // not process-attributed, so it may shorten the wait but can never prove
        // delivery or authorize Auto Enter. A target that can confirm keeps the
        // full wait unless the caller opted out of needing a confirmed paste.
        let focusRefutesPaste = pasteConfirmed == nil
            && accessibilityConfirmation?.focusIsClearlyNotTextEntry == true
        var waitEndedOnLikelyPaste = false, waitEndedOnReadWithoutSurface = false
        let stopWaitingAfterClipboardRead = {
            guard let clipboardReadAt = temporaryProvider?.firstReadAt else { return false }
            waitEndedOnReadWithoutSurface = confirmationUnavailable && clipboardReadAt >= pasteDispatchedAt
            if confirmationUnavailable { return waitEndedOnReadWithoutSurface }
            waitEndedOnLikelyPaste = pasteConfirmed == nil && FocusedTextPasteConfirmationPolicy.endsWaitOnLikelyPaste(
                callerAllows: endWaitOnLikelyPaste,
                focusRefutesPaste: focusRefutesPaste,
                pasteDispatchedAt: pasteDispatchedAt,
                clipboardReadAt: clipboardReadAt
            )
            return waitEndedOnLikelyPaste
        }

        timingConfirmationStartedAt = CFAbsoluteTimeGetCurrent()
        var confirmationDeadline: TimeInterval = 0
        let pasteConfirmationResult = ClipboardPasteConfirmationWait.run(
            targetIsFrontmost: targetRemainsFrontmost,
            pasteConfirmed: confirmPasteReceived,
            stopWaitingUnconfirmed: stopWaitingAfterClipboardRead,
            isCurrentOperation: isCurrentOperation,
            timeout: pasteConfirmationWait,
            deadline: &confirmationDeadline
        )
        timingConfirmationFinishedAt = CFAbsoluteTimeGetCurrent()
        guard isCurrentOperation(), pasteConfirmationResult != .cancelled else { return cancelledOutcome }
        guard pasteConfirmationResult == .confirmed else {
            var diagnostics = accessibilityConfirmation?.diagnosticsContext(
                clipboardReadAt: temporaryProvider?.firstReadAt,
                pasteDispatchedAt: pasteDispatchedAt
            ) ?? [
                "clipboard_read_after_dispatch": "\((temporaryProvider?.firstReadAt ?? 0) >= pasteDispatchedAt)",
                "target_change_after_dispatch": "false",
                "target_change_observer_available": "false",
                "target_selection_observable": "false",
                "target_value_observable": "false",
            ]
            guard isCurrentOperation() else { return cancelledOutcome }
            let targetStillFrontmost = pasteConfirmationResult == .unconfirmed
            let clipboardReadSuggestsPaste = FocusedTextPasteConfirmationPolicy.didObserveLikelyPaste(
                pasteDispatchedAt: pasteDispatchedAt,
                clipboardReadAt: temporaryProvider?.firstReadAt
            )
            // Diagnostics only: the provider records just the first read, so a
            // read outside the window hides whether the target read it later.
            let clipboardReadOutsideWindow = !clipboardReadSuggestsPaste
                && temporaryProvider?.firstReadAt != nil
            diagnostics["target_still_frontmost"] = "\(targetStillFrontmost)"
            diagnostics["likely_paste_ended_wait"] = "\(waitEndedOnLikelyPaste || (waitEndedOnReadWithoutSurface && clipboardReadSuggestsPaste))"
            diagnostics["paste_evidence"] = targetStillFrontmost && clipboardReadSuggestsPaste
                ? "clipboard_read"
                : clipboardReadOutsideWindow ? "read_outside_window" : "none"
            lastConfirmationDiagnostic = ClipboardPasteConfirmationDiagnostic(
                event: "dictation_paste_confirmation_diagnostics",
                context: diagnostics
            )
            if !targetStillFrontmost {
                let clipboardFallbackState = leaveTemporaryClipboardAvailable(
                    savingClipboardForNextPaste: true
                )
                diagnostics["clipboard_fallback_state"] = clipboardFallbackState.rawValue
                lastConfirmationDiagnostic = ClipboardPasteConfirmationDiagnostic(
                    event: "dictation_paste_confirmation_diagnostics",
                    context: diagnostics
                )
                guard clipboardFallbackState.hasVerifiedDictation else {
                    return .failed(
                        Self.unverifiedClipboardRecoveryFailure,
                        reason: .fallbackClipboardRecoveryUnverified
                    )
                }
                guard isCurrentOperation() else { return cancelledOutcome }
                return .copied(
                    "Focus moved before Transcripted could confirm paste. The text is on your clipboard — press ⌘V.",
                    reason: .focusChanged
                )
            }

            // AX confirmation is positive-only, and Electron apps, Chrome text
            // areas, and GPU terminals never give it. When the target stayed in
            // front and the borrowed clipboard was read right after Cmd+V, the
            // paste almost certainly landed (#1703 measured 66 of 69 such
            // outcomes as real pastes), so treat it like one: no warning, and
            // the user's clipboard comes back. The read is not tied to a process,
            // so if something else read first, the target may still be reading:
            // wait the longer fallback delay, not the short one used after a
            // proven paste, before the old clipboard replaces the dictation.
            // Some apps (Claude, other Electron apps) read the clipboard on
            // Cmd+V even with no text box focused, so a quick read only counts
            // as a paste when the focus could take text. A caller that decides
            // confirmation itself (`pasteConfirmed`) also owns this call.
            diagnostics["focus_refutes_paste"] = "\(focusRefutesPaste)"
            lastConfirmationDiagnostic = ClipboardPasteConfirmationDiagnostic(
                event: "dictation_paste_confirmation_diagnostics",
                context: diagnostics
            )
            if clipboardReadSuggestsPaste && !focusRefutesPaste {
                guard isCurrentOperation() else { return cancelledOutcome }
                // Ending early adds the skipped wait back, so the clipboard returns about
                // when a full wait's would: a few ms sooner, ~300 ms when AX stalls the
                // full wait's last checks. A late confirmation still gets the short restore.
                let unusedWait = waitEndedOnLikelyPaste
                    ? confirmationDeadline - ProcessInfo.processInfo.systemUptime : 0
                scheduleClipboardRestore(
                    savedItems,
                    temporaryString: text,
                    temporaryChangeCount: temporaryChangeCount,
                    to: pasteboard,
                    token: pasteToken,
                    delay: FocusedTextPasteConfirmationPolicy.likelyPasteRestoreDelay(
                        fallbackDelay: fallbackRestoreDelay, unusedWait: unusedWait
                    )
                )
                if waitEndedOnLikelyPaste {
                    lateConfirmationWatch.start(
                        until: confirmationDeadline,
                        isCurrent: { [weak self] in self?.pasteEpoch.isCurrent(pasteToken) == true },
                        targetIsFrontmost: targetRemainsFrontmost,
                        pasteConfirmed: confirmPasteReceived,
                        onConfirmed: { [weak self, temporaryChangeCount] in
                            self?.scheduleClipboardRestore(savedItems, temporaryString: text,
                                temporaryChangeCount: temporaryChangeCount, to: pasteboard,
                                token: pasteToken, delay: restoreDelay)
                            onLateConfirmation?(.lateConfirmed(mode: accessibilityConfirmedMode))
                        }
                    )
                }
                return .likelyPasted
            }

            // No AX signal fired and nothing read the clipboard right after
            // Cmd+V. That is not proof either way: a slow target can still read
            // the plain copy after the wait. Keep the text copied for a manual
            // paste, word the notice so it doesn't invite a double paste, and
            // hold on to the user's clipboard so the next paste can put it back.
            let clipboardFallbackState = leaveTemporaryClipboardAvailable(
                savingClipboardForNextPaste: true
            )
            diagnostics["clipboard_fallback_state"] = clipboardFallbackState.rawValue
            lastConfirmationDiagnostic = ClipboardPasteConfirmationDiagnostic(
                event: "dictation_paste_confirmation_diagnostics",
                context: diagnostics
            )
            guard clipboardFallbackState.hasVerifiedDictation else {
                return .failed(
                    Self.unverifiedClipboardRecoveryFailure,
                    reason: .fallbackClipboardRecoveryUnverified
                )
            }
            guard isCurrentOperation() else { return cancelledOutcome }
            return .copied(Self.pasteNotConfirmedMessage, reason: .pasteNotConfirmed)
        }

        let confirmationMode: String
        if pasteConfirmed != nil {
            confirmationMode = "injected_confirmation"
        } else {
            confirmationMode = accessibilityConfirmation?.confirmationMode(
                text,
                clipboardWasRead: temporaryProvider?.didProvideData == true,
                clipboardReadAt: temporaryProvider?.firstReadAt,
                pasteDispatchedAt: pasteDispatchedAt
            ) ?? "unknown"
        }
        guard isCurrentOperation() else { return cancelledOutcome }
        lastConfirmationDiagnostic = ClipboardPasteConfirmationDiagnostic(
            event: "dictation_paste_confirmed",
            context: ["confirmation_mode": confirmationMode]
        )

        scheduleClipboardRestore(
            savedItems,
            temporaryString: text,
            temporaryChangeCount: temporaryChangeCount,
            to: pasteboard,
            token: pasteToken,
            delay: restoreDelay
        )
        return .pasted
    }

    /// Fences out every in-flight restore/readiness task, empties the pending
    /// slot, and returns whatever restore payload was stored so the caller can
    /// decide what to do with it.
    @discardableResult
    private func clearPendingClipboardRestore() -> PendingClipboardRestore? {
        pasteEpoch.invalidate()
        clipboardRestoreTask?.cancel()
        clipboardRestoreTask = nil
        clipboardAutoEnterReadinessTask?.cancel()
        clipboardAutoEnterReadinessTask = nil
        clipboardAutoEnterReadyToken = nil
        lateConfirmationWatch.cancel()
        temporaryPasteboardDataProvider = nil
        return pendingClipboardRestore.clear()
    }

    private func leaveTemporaryClipboardAvailable(
        retainingRestoreForPasteRetry: Bool = false,
        savingClipboardForNextPaste: Bool = false
    ) -> ClipboardFallbackState {
        guard let pending = clearPendingClipboardRestore() else { return .unavailable }

        // A user copy with the same plain text can still carry rich data. Keep it
        // intact when the pasteboard changed after paste started, but only count
        // that as recovery when the dictation text is actually still present.
        // An unchanged pasteboard may still hold our lazy provider, so materialize
        // it before returning the text for manual recovery.
        if pending.pasteboard.changeCount != pending.temporaryChangeCount {
            let observedChangeCount = pending.pasteboard.changeCount
            let currentString = pending.pasteboard.string(forType: .string)
            // Clipboard managers may rewrite a lazy pasteboard while it is read.
            // Never classify text from one generation as belonging to another.
            guard pending.pasteboard.changeCount == observedChangeCount else {
                return .clipboardChanged
            }
            if let currentString {
                return currentString == pending.temporaryString
                    ? .dictationPresent
                    : .clipboardChanged
            }
            let currentItems = pending.pasteboard.pasteboardItems
            guard pending.pasteboard.changeCount == observedChangeCount else {
                return .clipboardChanged
            }
            guard currentItems?.isEmpty != false else {
                return .clipboardChanged
            }

            // A failed paste consumer can clear the temporary pasteboard without
            // replacing it. Recover only from that truly-empty state; never
            // overwrite a non-empty user or clipboard-manager change.
            guard copyTextToClipboard(pending.temporaryString, to: pending.pasteboard) else {
                return .clipboardEmpty
            }
            if savingClipboardForNextPaste {
                saveClipboardForNextPaste(pending)
            }
            return .dictationPresent
        }
        guard copyTextToClipboard(pending.temporaryString, to: pending.pasteboard) else {
            return .unavailable
        }
        if savingClipboardForNextPaste {
            saveClipboardForNextPaste(pending)
        }
        if retainingRestoreForPasteRetry {
            retainedClipboardRestoreForPasteRetry = PendingClipboardRestore(
                savedItems: pending.savedItems,
                temporaryString: pending.temporaryString,
                temporaryChangeCount: pending.pasteboard.changeCount,
                pasteboard: pending.pasteboard
            )
        }
        return .dictationPresent
    }

    private func restoreRetainedClipboardNow() {
        guard let retained = retainedClipboardRestoreForPasteRetry else { return }
        retainedClipboardRestoreForPasteRetry = nil
        let pasteboard = retained.pasteboard
        guard pasteboard.changeCount == retained.temporaryChangeCount,
              pasteboard.string(forType: .string) == retained.temporaryString else {
            return
        }
        restorePasteboardItems(
            retained.savedItems,
            temporaryString: retained.temporaryString,
            temporaryChangeCount: retained.temporaryChangeCount,
            to: pasteboard
        )
    }

    private func scheduleClipboardRestore(
        _ savedItems: PasteboardSnapshot,
        temporaryString: String,
        temporaryChangeCount: Int,
        to pasteboard: any ClipboardPasteboard,
        token: SupersessionEpoch.Token,
        delay: UInt64
    ) {
        guard pasteEpoch.isCurrent(token) else { return }
        clipboardRestoreTask?.cancel()
        scheduledClipboardRestoreDelay = delay
        pendingClipboardRestore.install(
            PendingClipboardRestore(
                savedItems: savedItems,
                temporaryString: temporaryString,
                temporaryChangeCount: temporaryChangeCount,
                pasteboard: pasteboard
            ),
            ownedBy: token
        )
        clipboardRestoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self,
                  !Task.isCancelled,
                  self.pasteEpoch.isCurrent(token) else { return }
            self.restorePasteboardItems(
                savedItems,
                temporaryString: temporaryString,
                temporaryChangeCount: temporaryChangeCount,
                to: pasteboard
            )
            self.temporaryPasteboardDataProvider = nil
            self.pendingClipboardRestore.clearIfOwned(by: token)
            self.clipboardRestoreTask = nil
            self.clipboardAutoEnterReadinessTask?.cancel()
            self.clipboardAutoEnterReadinessTask = nil
            // Deliberately fused: publish this attempt as the Auto Enter ready
            // marker, then close its epoch so no later restore/readiness work
            // can still act on the finished attempt.
            self.clipboardAutoEnterReadyToken = token
            self.pasteEpoch.supersedeIfCurrent(token)
        }
    }

    private func waitForTargetActivation(
        _ target: DictationPasteTarget, timeout: TimeInterval,
        isCurrentOperation: () -> Bool
    ) -> Bool {
        guard timeout > 0 else { return false }

        let start = Date()
        while ClipboardTargetActivationPolicy.shouldWait(
            targetIsFrontmost: false,
            elapsed: Date().timeIntervalSince(start),
            timeout: timeout
        ) {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            guard isCurrentOperation() else { return false }
            if target.matchesCurrentFrontmostApp() {
                return true
            }
        }
        return target.matchesCurrentFrontmostApp()
    }

    @discardableResult
    private func writeTemporaryString(
        _ text: String,
        to pasteboard: any ClipboardPasteboard
    ) -> Bool {
        guard pasteboard is NSPasteboard else { return false }

        let provider = TemporaryPasteboardStringProvider(
            text: text,
            onTemporaryStringRead: {}
        )
        let item = NSPasteboardItem()
        guard item.setDataProvider(provider, forTypes: [.string]) else {
            return false
        }
        // Best effort: without the marker the paste still works, clipboard
        // managers just record the borrowed text as they always did.
        _ = item.setData(Data(), forType: Self.transientPasteboardType)

        guard pasteboard.writePasteboardItems([item]) else {
            temporaryPasteboardDataProvider = nil
            return false
        }

        temporaryPasteboardDataProvider = provider
        return true
    }
}

private final class WeakPasterReference {
    weak var paster: ClipboardRestoringTextPaster?

    init(_ paster: ClipboardRestoringTextPaster) {
        self.paster = paster
    }
}

private final class TemporaryPasteboardStringProvider: NSObject, NSPasteboardItemDataProvider {
    private let text: String
    private let onTemporaryStringRead: () -> Void
    private let lock = NSLock()
    private var didNotifyRead = false
    private var firstReadTimestamp: CFAbsoluteTime?

    var didProvideData: Bool {
        lock.lock()
        let value = didNotifyRead
        lock.unlock()
        return value
    }

    var firstReadAt: CFAbsoluteTime? {
        lock.lock()
        let value = firstReadTimestamp
        lock.unlock()
        return value
    }

    init(text: String, onTemporaryStringRead: @escaping () -> Void) {
        self.text = text
        self.onTemporaryStringRead = onTemporaryStringRead
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .string else { return }
        item.setString(text, forType: .string)
        notifyReadOnce()
    }

    private func notifyReadOnce() {
        lock.lock()
        let shouldNotify = !didNotifyRead
        didNotifyRead = true
        if firstReadTimestamp == nil {
            firstReadTimestamp = CFAbsoluteTimeGetCurrent()
        }
        lock.unlock()

        if shouldNotify {
            onTemporaryStringRead()
        }
    }
}
