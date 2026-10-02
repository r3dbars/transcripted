// DictationSessionController+Recovery.swift
// Saved-audio prompts, Quit admission, Retry Saving, and recording interruptions.

import AppKit

extension DictationSessionController {
    func presentPendingStoppedAudioRecoveryIfNeeded() {
        guard !isDictating,
              let overlayController,
              let recovery = DictationStoppedAudioRecoveryStore.pendingRecoveries(limit: 1, excludingDismissed: true).first else { return }
        let savedAudioAction = savedDictationAudioAction(for: recovery.url)
        overlayController.showError(
            "A saved dictation recording never became text. Transcribe it now, and it shows up in Meetings.",
            actionTitle: savedAudioAction.title,
            action: savedAudioAction.action
        )
        savedAudioPromptURL = recovery.url
    }

    /// The user closed a "Transcribe It" message (X or Esc) without pressing
    /// it. Launch stops asking about that recording, so an empty take doesn't
    /// come back every time. Nothing is deleted.
    func stopRemindingAboutSavedAudioPrompt() {
        guard let url = savedAudioPromptURL else { return }
        savedAudioPromptURL = nil
        let marked = DictationStoppedAudioRecoveryStore.markDismissed(audioURL: url)
        appState?.logger.log("DICTATION | saved recording prompt closed; launch reminder \(marked ? "off" : "unchanged"), audio kept")
    }

    /// The button on a message about a saved dictation recording. The
    /// messages used to point at Capture → Transcribe Audio File, a menu that
    /// only shows while Transcripted is frontmost. Transcribe It runs that
    /// same import on the saved file, and the meeting importer cleans the
    /// recording up once its transcript is saved.
    func savedDictationAudioAction(for url: URL) -> (title: String, action: () -> Void) {
        guard let onTranscribeSavedAudio else {
            return ("Show Audio", { [weak self] in
                self?.savedAudioPromptURL = nil
                NSWorkspace.shared.activateFileViewerSelecting([url])
            })
        }
        return (DictationSavedAudioActionCopy.transcribeTitle, { [weak self] in
            self?.savedAudioPromptURL = nil
            self?.overlayController?.hideWithConfirmAnimation()
            onTranscribeSavedAudio(url)
        })
    }

    // finishDictationForTermination (Quit) lives in
    // DictationSessionPipeline.swift, where tests run it on a fake controller.

    var currentStoppedAudioRecoveryWAVExists: Bool {
        guard let stoppedAudioRecovery,
              stoppedAudioRecovery.sessionID == currentDictationSessionID else { return false }
        return FileManager.default.fileExists(atPath: stoppedAudioRecovery.url.path)
    }

    func showFailedCheckpointRecoveryError() {
        guard let overlayController else { return }
        let message = "Audio is only in memory. Keep Transcripted open; check storage, then Retry Saving."
        guard !isDictating,
              appState?.sttRouter.hasRecoverableRecording == true,
              stoppedAudioCheckpointSignal != nil,
              !currentStoppedAudioRecoveryWAVExists else {
            overlayController.showError(
                "Audio couldn't be saved safely. Keep Transcripted open and contact support."
            )
            return
        }
        overlayController.showError(
            message,
            actionTitle: "Retry Saving",
            action: { [weak self] in self?.retrySavingRetainedDictationAudio() }
        )
    }

    private func retrySavingRetainedDictationAudio() {
        let sessionID = currentDictationSessionID
        guard let checkpointSignal = stoppedAudioCheckpointSignal else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await DictationRetainedAudioRetry.run(
                DictationRetainedAudioRetry.Steps(
                    waitForCheckpoint: {
                        await checkpointSignal.waitForCompletion(timeoutNanoseconds: 2_000_000_000)
                    },
                    onCheckpointTimeout: {
                        if self.currentDictationSessionID == sessionID && !self.isDictating {
                            self.showFailedCheckpointRecoveryError()
                        }
                    },
                    canRetry: {
                        guard let (appState, _) = self.readyState() else { return false }
                        return DictationTerminationAdmissionPolicy.canRetrySaving(
                            isDictating: self.isDictating,
                            checkpointSettled: true,
                            hasRecoverableRecording: appState.sttRouter.hasRecoverableRecording,
                            recoveryWAVExists: self.currentStoppedAudioRecoveryWAVExists,
                            isCurrentSession: self.currentDictationSessionID == sessionID,
                            hasPendingStart: self.startupTask != nil || self.recordingStartRetryTask != nil
                        )
                    },
                    // The previous stop has released its model lease and
                    // completed its checkpoint signal. Readmit this same
                    // retained recording only.
                    resetStopGate: { self.stopFinalizationGate.reset() },
                    readmit: {
                        // Not a microphone start: the App Nap label already
                        // says "stop finalization" (see `processActivityLabel`).
                        // The listening state is an admission input, not a new mic start.
                        self.isDictating = true
                        self.overlayController?.state = .listening
                        self.overlayController?.markRetainedRecordingForEscape()
                    },
                    stopWithoutPaste: { self.stopDictationAndPaste(trigger: .unknown, autoPaste: false) },
                    afterStop: {
                        guard let overlayController = self.overlayController,
                              self.isDictating,
                              self.stopFinalizationGate.admittedSessionID == sessionID else { return }
                        // The listening state above is only the stop-policy admission
                        // input. Present Saving immediately, including in mini mode.
                        overlayController.state = .drafting
                        overlayController.showLoadingState(
                            near: self.sessionSourceApp,
                            presentation: .init(
                                title: "Saving audio",
                                detail: "Retrying the recording already captured.",
                                progress: 0.2,
                                status: "Saving"
                            ),
                            anchorRect: self.sessionAnchorRect
                        )
                    }
                )
            )
        }
    }

    func handleDictationInterruption() {
        let plan = DictationInterruptionPlan.make(
            hasRecoverableRecording: appState?.sttRouter.hasRecoverableRecording ?? false
        )
        let interruptedSessionID = currentDictationSessionID
        let interruptedCheckpointSignal = stoppedAudioCheckpointSignal
        cancelActiveTasks(cancelRecording: plan.cancelRecording)
        isDictating = false
        appState?.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "interrupted")
        appState?.logger.log("DICTATION | interrupted")
        DiagnosticsTrail.record(
            logger: appState?.logger,
            level: .warning,
            engine: "dictation",
            event: "dictation_recording_interrupted",
            message: "Dictation recording was interrupted",
            context: dictationContext(
                extra: [
                    "trigger": currentDictationTrigger.rawValue,
                    "duration_ms": "\(Int((CFAbsoluteTimeGetCurrent() - sessionStartTime) * 1000))"
                ]
            )
        )
        overlayController?.showError(
            plan.message,
            actionTitle: plan.actionTitle,
            action: { [weak self] in
                guard let self else { return }
                switch plan.action {
                case .transcribeCapturedAudio(let autoPaste):
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        // An interrupted stop may still be awaiting a detached
                        // WAV write/cleanup. Readmit only after its owner exits,
                        // so an explicit retry cannot share that file mid-write.
                        _ = await DictationInterruptedAudioReadmission.run(DictationInterruptedAudioReadmission.Steps(
                            waitForInterruptedCheckpoint: { await interruptedCheckpointSignal?.wait() },
                            stillOwnsRecording: {
                                self.currentDictationSessionID == interruptedSessionID && !self.isDictating
                            },
                            hasRecoverableRecording: { self.appState?.sttRouter.hasRecoverableRecording == true },
                            audioGone: {
                                self.presentPendingStoppedAudioRecoveryIfNeeded()
                                if DictationStoppedAudioRecoveryStore.pendingRecoveries(limit: 1).isEmpty {
                                    self.overlayController?.showError(
                                        "The captured audio is no longer available. Start a new dictation.",
                                        actionTitle: "Try Again",
                                        action: { [weak self] in
                                            guard let self else { return }
                                            self.retryDictation(
                                                sourceApp: self.sessionSourceApp,
                                                anchorRect: self.sessionAnchorRect
                                            )
                                        }
                                    )
                                }
                            },
                            resetStopFence: { self.stopFinalizationGate.reset() },
                            readmit: {
                                // Not a microphone start: the App Nap label
                                // already says "stop finalization".
                                self.isDictating = true
                                self.overlayController?.state = .listening
                                self.overlayController?.markRetainedRecordingForEscape()
                                self.stopDictationAndPaste(trigger: .unknown, autoPaste: autoPaste)
                            }
                        ))
                    }
                case .retryDictation:
                    self.retryDictation(sourceApp: self.sessionSourceApp, anchorRect: self.sessionAnchorRect)
                }
            }
        )
    }
}
