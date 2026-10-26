// DictationSessionController+HandOff.swift
// Hand-off takes: dictation that listens for Write for Me and gives the words back instead of pasting.

import AppKit

extension DictationSessionController {
    /// Starts a hand-off take for `sourceApp`, with the island kept hidden. False, and nothing changes, when
    /// a take is already running or finishing (the person's own dictation is left alone) or the start was refused.
    func startHandOffDictation(sourceApp: NSRunningApplication?) -> Bool {
        guard DictationHandOffPolicy.mayStart(isDictating: isDictating) else { return false }
        isStartingHandOff = true
        startDictation(sourceApp: sourceApp, trigger: .menu)
        isStartingHandOff = false
        let quiet = DictationHandOffPolicy.overlayIsQuiet(afterHandOffStarted: isDictating)
        if overlayController?.quiet != quiet { overlayController?.quiet = quiet }
        guard isDictating else { return false }
        handOffSessionID = currentDictationSessionID
        return true
    }

    /// The words of the current hand-off take if it already ended before its feature asked (the dictation
    /// key or the session cap stopped it, or nothing was heard). Nil otherwise; each take's words once.
    func claimHandOffText() -> String? {
        guard DictationHandOffPolicy.canClaim(unclaimedSessionID: unclaimedHandOffSessionID, handOffSessionID: handOffSessionID),
              let text = handOffText else { return nil }
        unclaimedHandOffSessionID = nil
        return text
    }

    func publishHandOff(_ text: String, sessionID: UUID) {
        unclaimedHandOffSessionID = sessionID
        handOffText = text
    }

    /// Ends the hand-off take and throws away what was said (nothing is transcribed or saved). Does
    /// nothing if the take running now isn't the hand-off one, or if it's already finishing.
    func cancelHandOffDictation() {
        guard DictationHandOffPolicy.mayCancel(
            currentSessionID: currentDictationSessionID, handOffSessionID: handOffSessionID, isDictating: isDictating,
            isFinishing: stopFinalizationGate.admittedSessionID == currentDictationSessionID
        ) else { return }
        cancelDictation()
    }

    /// Stops the hand-off take so its words come back through `handOffText`. Does nothing if the take
    /// running now isn't the hand-off one.
    func stopHandOffDictation() {
        guard DictationHandOffPolicy.mayStop(
            currentSessionID: currentDictationSessionID, handOffSessionID: handOffSessionID, isDictating: isDictating
        ) else { return }
        stopDictationAndPaste(trigger: .menu, autoPaste: false)
    }

    /// The quiet end of a transcribed hand-off take: hand the words back, save them to Dictations, and
    /// put the overlay away. No completion analytics, session-cap events, log lines or saved notice.
    func finalizeHandOff(
        text: String,
        appState: TranscriptedAppState,
        overlayController: FloatingOverlayController,
        sessionID: UUID
    ) async {
        let recovery = stoppedAudioRecovery
        await DictationHandOffFinisher.finish(text: text, steps: DictationHandOffFinisher.Steps(
            deliver: { self.publishHandOff($0, sessionID: sessionID) },
            save: {
                let result = await self.startPersistingDictationTranscript(
                    text: text, delivery: DictationHandOffPolicy.delivery, recovery: recovery
                ).value
                guard let saved = result.saved else { return false }
                if self.stoppedAudioRecovery == recovery { self.stoppedAudioRecovery = nil }
                NotificationCenter.default.post(name: .dictationTranscriptDidSave, object: saved.url)
                return true
            },
            canPublish: {
                DictationSessionCompletionPolicy.canPublish(
                    sessionID: sessionID, currentSessionID: self.currentDictationSessionID,
                    isDictating: self.isDictating, cancelled: Task.isCancelled
                )
            },
            hideOverlay: { overlayController.hideWithCancelAnimation() },
            endSession: {
                self.isDictating = false
                appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "completed")
            }
        ))
    }
}
