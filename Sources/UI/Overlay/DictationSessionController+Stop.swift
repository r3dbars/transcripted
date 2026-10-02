// DictationSessionController+Stop.swift
// Stopping a dictation: checkpoint, transcribe, and paste or save the take.

import AppKit

extension DictationSessionController {
    /// Stop dictation and paste — selected local STT batch transcription.
    ///
    /// When `autoPaste` is `false` the transcript is still transcribed and saved
    /// to the daily Markdown file, but it is not pasted into the focused app and
    /// auto-send is suppressed. The 5-minute session cap uses this to recover a
    /// walked-away dictation instead of discarding it, without injecting text
    /// into whatever app now happens to hold focus.
    func stopDictationAndPaste(
        trigger: DictationTrigger = .unknown,
        shortcutMode: DictationShortcutMode? = nil,
        autoPaste: Bool = true
    ) {
        guard let (appState, overlayController) = readyState() else { return }
        let stopRequestedAt = CFAbsoluteTimeGetCurrent()
        DiagnosticsTrail.record(
            logger: appState.logger,
            engine: "dictation",
            event: "dictation_stop_requested",
            message: "Dictation stop requested",
            context: dictationContext(
                extra: [
                    "dictation_session_id": currentDictationSessionID.uuidString,
                    "trigger": trigger.rawValue,
                    "overlay_state": overlayStateName(overlayController.state),
                    "stt_recording": "\(appState.sttRouter.isRecording)"
                ]
            )
        )
        // DictationStopRequestRouting orders the first decisions: no
        // session, a hands-free press asking for the next take, then a repeat
        // stop for the session already finalizing. That fence runs before the
        // loading-state decision below, which could misread a repeat as
        // cancelPendingStart and discard its WAV.
        switch DictationStopRequestRouting.route(
            trigger: trigger,
            shortcutMode: shortcutMode,
            DictationStopRequestRouting.Steps(
                isDictating: { self.isDictating },
                rememberHandsFreePressAsNextStart: {
                    self.rememberStartPressIfFinishing(
                        sourceApp: NSWorkspace.shared.frontmostApplication,
                        trigger: trigger,
                        shortcutMode: shortcutMode
                    )
                },
                isAlreadyFinalizing: {
                    self.stopFinalizationGate.admittedSessionID == self.currentDictationSessionID
                }
            )
        ) {
        case .proceed:
            break
        case .rememberedAsNextStart:
            return
        case .ignoreNotDictating:
            DiagnosticsTrail.record(
                logger: appState.logger,
                level: .info,
                engine: "dictation",
                event: "dictation_stop_ignored",
                message: "Ignored dictation stop because no dictation session was active",
                context: dictationContext(
                    extra: [
                        "trigger": trigger.rawValue,
                        "overlay_state": overlayStateName(overlayController.state),
                        "stt_recording": "\(appState.sttRouter.isRecording)"
                    ]
                )
            )
            return
        case .ignoreAlreadyFinalizing:
            DiagnosticsTrail.record(
                logger: appState.logger,
                level: .info,
                engine: "dictation",
                event: "dictation_stop_ignored",
                message: "Ignored repeated stop while this session is already finalizing",
                context: dictationContext(extra: [
                    "trigger": trigger.rawValue,
                    "dictation_session_id": currentDictationSessionID.uuidString,
                    "reason": "already_finalizing"
                ])
            )
            return
        }
        let stopDecision = DictationRecordingStartLifecyclePolicy.stopDecision(
            isLoadingOverlay: overlayController.state == .loading,
            isListeningOverlay: overlayController.state == .listening,
            hasStartupTask: startupTask != nil,
            hasRecordingStartTask: recordingStartRetryTask != nil,
            sttIsRecording: appState.sttRouter.isRecording
        )

        switch DictationStopRoute.route(
            stopDecision: stopDecision,
            trigger: trigger,
            isFinishingPreviousTake: overlayController.state == .drafting || appState.sttRouter.isTranscribing,
            isRecording: appState.sttRouter.isRecording,
            hasRecoverableRecording: appState.sttRouter.hasRecoverableRecording
        ) {
        case .cancelPendingStartAfterEarlyRelease:
            cancelPendingDictationStartAfterEarlyRelease(
                appState: appState,
                overlayController: overlayController,
                shortcutMode: shortcutMode
            )
            return
        case .cancelPendingStart:
            cancelDictation()
            return
        case .ignore(let showStillFinishing):
            if showStillFinishing {
                overlayController.showError(DictationStopRoute.stillFinishingMessage)
            }
            DiagnosticsTrail.record(
                logger: appState.logger,
                level: .warning,
                engine: "dictation",
                event: "dictation_stop_ignored",
                message: "Ignored dictation stop because recording was no longer active",
                context: dictationContext(
                    extra: [
                        "trigger": trigger.rawValue,
                        "overlay_state": overlayStateName(overlayController.state),
                        "stt_recording": "\(appState.sttRouter.isRecording)"
                    ]
                )
            )
            return
        case .captureNotStarted:
            recordingStartRetryTask?.cancel()
            recordingStartRetryTask = nil
            appState.sttRouter.cancel()
            let failureKind = appState.sttRouter.inputFormatReady
                ? "microphone_start_failed"
                : "microphone_route_not_ready"
            DiagnosticsTrail.record(
                logger: appState.logger,
                level: .error,
                engine: "dictation",
                event: "dictation_capture_not_started",
                message: "Dictation stop requested before audio capture started",
                context: dictationContext(
                    extra: [
                        "trigger": trigger.rawValue,
                        "overlay_state": overlayStateName(overlayController.state),
                        "failure_kind": failureKind
                    ]
                )
            )
            trackDictationStartFailed(failureKind)
            appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: failureKind)
            isDictating = false
            overlayController.showError(
                microphoneTimeoutMessage(
                    deviceName: appState.sttRouter.inputDeviceName,
                    startAttempts: 0,
                    inputFormatReady: appState.sttRouter.inputFormatReady,
                    routeContext: appState.sttRouter.dictationAudioRouteAnalyticsContext
                ),
                actionTitle: "Try Again",
                action: { [weak self] in
                    guard let self else { return }
                    self.startDictation(sourceApp: self.sessionSourceApp, trigger: self.currentDictationTrigger, isRetry: true)
                }
            )
            return
        case .stopRecording:
            break
        }
        guard stopFinalizationGate.admit(sessionID: currentDictationSessionID) else {
            // @MainActor callers cannot interleave between the early fence and
            // admission, but keep the policy as the final ownership check.
            return
        }
        sessionTimeoutTask?.cancel()
        sessionTimeoutTask = nil
        clearSessionCapCountdown()
        recordingStartRetryTask?.cancel()
        recordingStartRetryTask = nil

        streamingTask?.cancel()
        let taskSessionID = currentDictationSessionID
        let taskRecordingModelLease = appState.sttRouter.recordingModelLease
        let checkpointSignal = DictationStoppedAudioCheckpointSignal()
        stoppedAudioCheckpointSignal = checkpointSignal
        streamingTask = Task {
            defer {
                appState.sttRouter.finishRecordingModelUse(taskRecordingModelLease)
                Task { await checkpointSignal.complete() }
            }
            var stopTiming = DictationStopTiming(requestedAt: stopRequestedAt)
            var stoppedRecordingSnapshot: RecordedSpeechSamples?
            guard !Task.isCancelled,
                  self.isDictating,
                  self.currentDictationSessionID == taskSessionID else { return }
            appState.runtimeDiagnostics.recordSession(kind: "dictation", stage: "stop_requested")
            // The accepted stop request owns cancellation even if recovery
            // publishes a brief idle state before this task begins. The engine's
            // idle stop path invalidates any pending recovery restart.
            // DictationStopCheckpoint stops the mic, plays the stop click, and
            // saves the take to a private WAV checkpoint before anything waits
            // on the model.
            let checkpoint = await DictationStopCheckpoint.run(
                DictationStopCheckpoint.Steps<RecordedSpeechSamples, DictationStoppedAudioRecovery?>(
                    isCurrent: {
                        DictationStoppedAudioRecoveryCommitPolicy.shouldPersist(
                            taskCancelled: Task.isCancelled,
                            isDictating: self.isDictating,
                            taskSessionID: taskSessionID,
                            currentSessionID: self.currentDictationSessionID
                        )
                    },
                    stopMicrophone: { await appState.sttRouter.stopRecording() },
                    playStopCue: { AppSoundPlayer.shared.play(.dictationStop) },
                    snapshot: { await appState.sttRouter.snapshotRecordedSamplesForPersistence() },
                    checkpointWork: { recording in
                        let samples16k = recording.samples16k
                        return {
                            try DictationStoppedAudioRecoveryStore.persist(
                                samples16k: samples16k,
                                sessionID: taskSessionID
                            )
                        }
                    },
                    discardWork: { recovery in
                        {
                            _ = DictationStoppedAudioRecoveryStore.cleanup(
                                recovery,
                                explicitDiscard: true
                            )
                        }
                    },
                    keepAbandonedCheckpoint: {
                        DictationStoppedAudioRecoveryCommitPolicy.shouldRetainPersistedRecovery(
                            taskSessionID: taskSessionID,
                            preservationSessionID: self.stoppedAudioRecoveryPreservationSessionID
                        )
                    },
                    hasRecoverableRecording: { appState.sttRouter.hasRecoverableRecording },
                    now: { CFAbsoluteTimeGetCurrent() }
                )
            )
            stopTiming.micStoppedAt = checkpoint.marks.micStoppedAt
            stopTiming.snapshotStartedAt = checkpoint.marks.snapshotStartedAt
            stopTiming.snapshotFinishedAt = checkpoint.marks.snapshotFinishedAt
            stopTiming.recoveryCheckpointStartedAt = checkpoint.marks.checkpointStartedAt
            stopTiming.recoveryCheckpointFinishedAt = checkpoint.marks.checkpointFinishedAt
            switch checkpoint.outcome {
            case .abandoned:
                return
            case .checkpointed(let recording, let recovery):
                self.stoppedAudioRecovery = recovery
                stoppedRecordingSnapshot = recording
            case .noSnapshot:
                break
            case .checkpointUnavailable:
                self.isDictating = false
                appState.runtimeDiagnostics.clearSession(
                    kind: "dictation", outcome: "audio_checkpoint_unavailable"
                )
                self.showFailedCheckpointRecoveryError()
                return
            case .checkpointFailed(let error):
                appState.logger.log("DICTATION | failed to preserve stopped audio: \(error.localizedDescription)")
                EventReporter.shared.capture(
                    level: .error,
                    engine: "dictation",
                    event: "dictation_stopped_audio_persistence_failed",
                    message: error.localizedDescription
                )
                self.isDictating = false
                appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "audio_persistence_failed")
                self.showFailedCheckpointRecoveryError()
                return
            }

            await checkpointSignal.complete()
            guard !Task.isCancelled, self.isDictating,
                  self.currentDictationSessionID == taskSessionID else { return }

            // Surface model warmup honestly instead of calling it "Transcribing"
            // before the local dictation model is actually ready.
            let modelWait = await DictationPostStopModelWait.run(
                DictationPostStopModelWait.Steps(
                    isCurrent: {
                        !Task.isCancelled
                            && self.isDictating
                            && self.currentDictationSessionID == taskSessionID
                    },
                    isModelLoaded: { appState.sttRouter.isRecordingModelLoaded },
                    modelState: { appState.sttRouter.recordingModelDownloadState },
                    requestModelInitialization: { appState.sttRouter.requestRecordingModelInitialization() },
                    waitForProgress: { deadline in
                        await appState.sttRouter.waitForRecordingModelLoadProgress(until: deadline)
                    },
                    waitStarted: {
                        appState.logger.log("DICTATION | waiting for voice model before transcribe…")
                        self.updateLoadingOverlay(sourceApp: self.sessionSourceApp, phase: .afterRecording)
                    },
                    stillWaiting: {
                        self.updateLoadingOverlay(sourceApp: self.sessionSourceApp, phase: .afterRecording)
                    },
                    uptime: { ProcessInfo.processInfo.systemUptime },
                    now: { CFAbsoluteTimeGetCurrent() },
                    budget: TranscriptedConstants.modelLoadWaitBudget
                )
            )
            switch modelWait.outcome {
            case .alreadyLoaded:
                stopTiming.modelWaitStartedAt = stopTiming.micStoppedAt
                stopTiming.modelReadyAt = stopTiming.micStoppedAt
            case .ready:
                stopTiming.modelWaitStartedAt = modelWait.marks.waitStartedAt
                stopTiming.modelReadyAt = modelWait.marks.readyAt
            case .abandoned:
                return
            case .unavailable:
                stopTiming.modelWaitStartedAt = modelWait.marks.waitStartedAt
                appState.logger.log("DICTATION | voice model failed to load for transcription")
                if let recovery = self.stoppedAudioRecovery, recovery.sessionID == taskSessionID {
                    let savedAudioAction = self.savedDictationAudioAction(for: recovery.url)
                    overlayController.showError(
                        DictationPostStopModelWaitPolicy.modelUnavailableMessage(recordingSaved: true),
                        actionTitle: savedAudioAction.title,
                        action: savedAudioAction.action
                    )
                } else {
                    overlayController.showError(
                        DictationPostStopModelWaitPolicy.modelUnavailableMessage(recordingSaved: false)
                    )
                }
                ProductFrictionTelemetry.track(
                    surface: .dictation,
                    stage: "dictation_transcribe",
                    result: .blocked,
                    failureKind: "model_not_ready",
                    elapsedBucket: AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime),
                    routeShape: self.dictationAnalyticsProperties()["route_shape"],
                    modelState: "not_ready"
                )
                isDictating = false
                appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "model_unavailable")
                return
            }
            overlayController.state = .drafting
            overlayController.resizePanelToCompact()
            appState.runtimeDiagnostics.recordSession(kind: "dictation", stage: "transcribing")
            stopTiming.transcriptionStartedAt = CFAbsoluteTimeGetCurrent()
            let voiceText = await appState.sttRouter.transcribe(
                preparedRecording: stoppedRecordingSnapshot
            )
            stopTiming.transcribedAt = CFAbsoluteTimeGetCurrent()
            guard !Task.isCancelled,
                  self.isDictating,
                  self.currentDictationSessionID == taskSessionID else { return }

            let cleanupEnabled = DictationCleanupPreferences.isEnabled()
            let cleanupResult = voiceText.map { rawText in
                if cleanupEnabled {
                    return DictationFillerCleanupPolicy.clean(rawText)
                }
                let trimmedText = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
                return DictationFillerCleanupResult(text: trimmedText, removedCount: 0, changed: trimmedText != rawText)
            }
            stopTiming.cleanedAt = CFAbsoluteTimeGetCurrent()
            guard let text = cleanupResult?.text, !text.isEmpty else {
                let emptyReason = appState.sttRouter.lastEmptyTranscriptionReason ?? .noSpeech
                let emptyDecision = DictationEmptyTranscriptPolicy.decide(
                    reason: emptyReason,
                    pressDuration: stopTiming.requestedAt - sessionStartTime,
                    hasHeldBackText: appState.sttRouter.heldBackDictationText != nil,
                    hasSavedRecording: self.stoppedAudioRecovery != nil
                )
                appState.logger.log("DICTATION | no transcription (\(emptyReason.rawValue)), cancelling")
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "overlay",
                    event: emptyReason.localEventName,
                    message: emptyReason.localEventMessage,
                    context: self.dictationContext(
                        extra: [
                            "duration_ms": "\(Int((CFAbsoluteTimeGetCurrent() - self.sessionStartTime) * 1000))",
                            "trigger": self.currentDictationTrigger.rawValue,
                            "reason": emptyReason.rawValue
                        ]
                    )
                )
                AnalyticsReporter.track(
                    emptyReason.analyticsEventName,
                    properties: self.dictationAnalyticsProperties(
                        extra: [
                            "duration_bucket": AnalyticsReporter.durationBucket(
                                seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime
                            ),
                            "trigger": currentDictationTrigger.rawValue,
                        ]
                    )
                )
                ProductFrictionTelemetry.track(
                    surface: .dictation,
                    stage: "dictation_transcribe",
                    result: emptyDecision.countsAsCancelled ? .cancelled : .giveUp,
                    failureKind: emptyReason.frictionFailureKind,
                    elapsedBucket: AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime),
                    routeShape: self.dictationAnalyticsProperties()["route_shape"],
                    modelState: ProductFrictionTelemetry.modelState(isReady: appState.sttRouter.isModelLoaded)
                )
                switch emptyDecision.action {
                case .closeLikeCancel:
                    // A mis-tap: close the overlay the same way a cancel does,
                    // with no "Recording ended too soon" error to dismiss.
                    NotificationCenter.default.post(name: .dictationNoSpeechDetected, object: nil)
                    AppSoundPlayer.shared.play(.dictationCancelled)
                    overlayController.hideWithCancelAnimation()
                case .showNoSpeechAndDismiss:
                    NotificationCenter.default.post(name: .dictationNoSpeechDetected, object: nil)
                    AppSoundPlayer.shared.play(.noSpeech)
                    overlayController.showNoSpeechAndDismiss(
                        trigger: currentDictationTrigger.rawValue,
                        reason: emptyReason,
                        shortcutMode: currentDictationShortcutMode,
                        silentMicName: appState.sttRouter.lastRecordingWasDigitalSilence
                            ? appState.sttRouter.inputDeviceName
                            : nil
                    )
                case .offerPasteAnyway:
                    // Probably a wrong-language guess, but the check can be
                    // wrong, so the text is one press away and the audio stays.
                    // Unreachable: decide() saw this text, and nothing between
                    // it and here (all synchronous, on the main actor) clears it.
                    guard let heldText = appState.sttRouter.heldBackDictationText else { break }
                    let heldRecovery = self.stoppedAudioRecovery
                    let heldSaveContext = self.dictationContext()
                    overlayController.showError(
                        DictationNoSpeechPresentationPolicy.message(
                            trigger: currentDictationTrigger.rawValue,
                            reason: emptyReason,
                            shortcutMode: currentDictationShortcutMode
                        ),
                        actionTitle: DictationHeldTextActionCopy.pasteAnywayTitle,
                        action: { [weak self] in
                            guard let self else { return }
                            let outcome = self.pasteWithClipboardRestore(heldText)
                            // Save it like any finished take: dictation history,
                            // Paste Last Dictation, and the kept audio cleaned up.
                            self.lastCompletedText = heldText
                            let saveTask = self.startPersistingDictationTranscript(
                                text: heldText,
                                delivery: outcome.delivery,
                                recovery: heldRecovery
                            )
                            Task { @MainActor [weak self] in
                                let result = await saveTask.value
                                self?.publishDictationTranscriptPersistence(
                                    result,
                                    delivery: outcome.delivery,
                                    context: heldSaveContext
                                )
                            }
                            // Pasting pumps the run loop; a take started meanwhile owns the pill.
                            guard self.currentDictationSessionID == taskSessionID, !self.isDictating else { return }
                            switch outcome {
                            case .pasted, .likelyPasted:
                                overlayController.showSuccessAndDismiss(title: "Pasted")
                            case .copied(let message, reason: _), .failed(let message, reason: _):
                                overlayController.showError(message)
                            }
                        }
                    )
                case .offerSavedRecording(let remindAtLaunch):
                    guard let recovery = self.stoppedAudioRecovery else { break }
                    let savedAudioAction = self.savedDictationAudioAction(for: recovery.url)
                    overlayController.showError(
                        DictationNoSpeechPresentationPolicy.message(
                            trigger: currentDictationTrigger.rawValue,
                            reason: emptyReason,
                            shortcutMode: currentDictationShortcutMode
                        ),
                        actionTitle: savedAudioAction.title,
                        action: savedAudioAction.action
                    )
                    // Only for audio the model heard nothing in. A model
                    // failure keeps its launch reminder even if closed.
                    if remindAtLaunch {
                        self.savedAudioPromptURL = recovery.url
                    }
                case .offerCheckpointRetry:
                    // The captured audio has no durable WAV. If native RAM
                    // remains, offer the guarded no-paste checkpoint retry
                    // rather than mislabeling this as model-empty speech.
                    isDictating = false
                    showFailedCheckpointRecoveryError()
                case .showMessage:
                    overlayController.showError(
                        DictationNoSpeechPresentationPolicy.message(
                            trigger: currentDictationTrigger.rawValue,
                            reason: emptyReason,
                            shortcutMode: currentDictationShortcutMode
                        )
                    )
                }
                isDictating = false
                appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: emptyReason.runtimeOutcome)
                if emptyDecision.discardsSavedRecording {
                    self.discardStoppedAudioRecovery(explicitDiscard: true)
                }
                return
            }

            guard !Task.isCancelled else { return }
            if (cleanupResult?.removedCount ?? 0) > 0 {
                appState.logger.log("DICTATION | filler cleanup removed \(cleanupResult?.removedCount ?? 0) items")
            }

            if !autoPaste {
                // Session cap reached (the user walked away mid-dictation).
                // Recover the transcript by saving it to the daily Markdown file,
                // but do NOT paste it into whatever app now holds focus and do
                // NOT auto-send — the cap exists to rescue abandoned sessions,
                // not to inject text into an unattended app.
                await self.finalizeWithoutPaste(
                    text: text,
                    appState: appState,
                    overlayController: overlayController,
                    sessionID: taskSessionID
                )
                return
            }

            appState.logger.log("DICTATION | pasting \(text.count) chars")
            lastCompletedText = text
            stopTiming.pasteStartedAt = CFAbsoluteTimeGetCurrent()
            let modelWaitSeconds = (stopTiming.modelReadyAt ?? 0) - (stopTiming.modelWaitStartedAt ?? 0)
            let pasteOutcome = self.pasteWithClipboardRestore(
                text,
                followCurrentFocus: DictationPostStopModelWaitPolicy.pasteFollowsCurrentFocus(
                    modelWaitSeconds: modelWaitSeconds
                )
            )
            stopTiming.pastedAt = CFAbsoluteTimeGetCurrent()
            // Paste confirmation pumps the run loop, so cancellation/restart can occur here too.
            guard DictationSessionCompletionPolicy.canPublish(
                sessionID: taskSessionID, currentSessionID: self.currentDictationSessionID,
                isDictating: self.isDictating, cancelled: Task.isCancelled
            ) else { return }
            stopTiming.pasteBreakdown = self.textPaster.lastPasteTiming
            // Capture ownership before suspending. The writer may outlive cancellation.
            let recovery = self.stoppedAudioRecovery
            let saveContext = self.dictationContext()
            stopTiming.finalizationStartedAt = CFAbsoluteTimeGetCurrent()
            let finalization = await DictationStopFinalizer.finalize(
                order: DictationStopFinalizationPolicy.order,
                startSaving: {
                    return self.startPersistingDictationTranscript(
                        text: text,
                        delivery: pasteOutcome.delivery,
                        recovery: recovery
                    )
                },
                finishSaving: { saveTask in
                    let result = await saveTask.value
                    self.publishDictationTranscriptPersistence(result, delivery: pasteOutcome.delivery, context: saveContext)
                    return result
                },
                saveSynchronously: {
                    let result = self.persistDictationTranscript(text: text, delivery: pasteOutcome.delivery)
                    _ = DictationStoppedAudioRecoveryStore.cleanup(recovery, transcriptPersisted: result.saved != nil)
                    return result
                },
                performAutoEnter: {
                    stopTiming.autoEnterStartedAt = CFAbsoluteTimeGetCurrent()
                    let outcome = await self.performAutoEnterIfNeeded(
                        pasteOutcome: pasteOutcome,
                        sessionID: taskSessionID
                    )
                    stopTiming.autoEnterFinishedAt = CFAbsoluteTimeGetCurrent()
                    return outcome
                }
            )
            let autoSendOutcome = finalization.autoEnterOutcome
            let saveResult = finalization.saveResult
            guard DictationSessionCompletionPolicy.canPublish(
                sessionID: taskSessionID, currentSessionID: self.currentDictationSessionID,
                isDictating: self.isDictating, cancelled: Task.isCancelled
            ) else { return }
            if saveResult.saved != nil, self.stoppedAudioRecovery == recovery {
                self.stoppedAudioRecovery = nil
            }
            stopTiming.saveStartedAt = saveResult.startedAt
            stopTiming.savedAt = saveResult.finishedAt
            stopTiming.savePublishedAt = CFAbsoluteTimeGetCurrent()
            let saveFailureMessage = saveResult.failureMessage
            let wordCount = text.split(whereSeparator: \.isWhitespace).count
            stopTiming.completedAt = CFAbsoluteTimeGetCurrent()
            var deliveryContext: [String: String] = [
                "dictation_session_id": taskSessionID.uuidString,
                "trigger": self.currentDictationTrigger.rawValue,
                "auto_send": autoSendOutcome.diagnosticName,
                "chars": "\(text.count)",
                "words": "\(wordCount)",
                "duration_ms": "\(Int((CFAbsoluteTimeGetCurrent() - self.sessionStartTime) * 1000))",
            ]
            deliveryContext.merge(pasteOutcome.deliveryProperties) { _, delivery in delivery }
            DiagnosticsTrail.record(
                logger: appState.logger,
                level: pasteOutcome.diagnosticLevel,
                engine: "dictation",
                event: "dictation_delivery_completed",
                message: pasteOutcome.diagnosticMessage,
                context: self.dictationContext(extra: deliveryContext)
            )
            self.recordDictationStopLatency(
                appState: appState,
                timing: stopTiming,
                sessionID: taskSessionID,
                stopTrigger: trigger,
                startTrigger: self.currentDictationTrigger,
                pasteOutcome: pasteOutcome,
                autoSendOutcome: autoSendOutcome,
                wordCount: wordCount,
                charCount: text.count,
                cleanupEnabled: cleanupEnabled,
                cleanupChanged: cleanupResult?.changed ?? false,
                saveSucceeded: saveFailureMessage == nil
            )
            trackDictationDeliveryFriction(
                pasteOutcome: pasteOutcome,
                saveSucceeded: saveFailureMessage == nil,
                elapsedSeconds: CFAbsoluteTimeGetCurrent() - sessionStartTime
            )
            switch DictationDeliveryPresentation.resolve(
                outcome: pasteOutcome,
                saveFailureMessage: saveFailureMessage,
                autoSend: autoSendOutcome,
                autoSendExpected: self.autoSendRequestDecision.expected
            ) {
            case .success(let title):
                overlayController.showSuccessAndDismiss(title: title)
            case .clipboardNotice(let message):
                overlayController.showClipboardNotice(message)
                // The text landed; a press for the next take can replace this.
                overlayController.messageCanGiveWayToNextStart = true
            case .notPasted(let message, let unconfirmed):
                // The island also shows the words and a Paste button.
                self.showNotPasted(
                    text,
                    message: message,
                    unconfirmed: unconfirmed,
                    overlayController: overlayController
                )
            case .clipboardBusy(let message):
                // The words never went on the clipboard; offer them back.
                self.showClipboardBusy(text, message: message, overlayController: overlayController)
            case .error(let message):
                overlayController.showError(message)
            }
            isDictating = false
            appState.logger.log("DICTATION | completed with outcome \(pasteOutcome)")
            if case .failed(let failure) = autoSendOutcome {
                appState.logger.log("DICTATION | auto enter failed: \(failure.message)")
            }
            let autoSendTelemetry = DictationAutoSendTelemetry.snapshot(
                request: self.autoSendRequestDecision,
                pasteOutcome: pasteOutcome,
                sendOutcome: autoSendOutcome
            )
            let targetConfirmationMode = DictationTargetConfirmationMode.resolve(
                outcome: pasteOutcome,
                diagnostic: self.textPaster.lastConfirmationDiagnostic
            )
            var dictationCompletedExtra: [String: String] = [
                "auto_send": autoSendOutcome.diagnosticName,
                "duration_bucket": AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime),
                "trigger": currentDictationTrigger.rawValue,
                "word_count_bucket": AnalyticsReporter.wordCountBucket(wordCount),
                "target_confirmation_mode": targetConfirmationMode.rawValue,
            ]
            dictationCompletedExtra.merge(pasteOutcome.deliveryProperties) { _, delivery in delivery }
            dictationCompletedExtra.merge(autoSendTelemetry.analyticsProperties) { _, new in new }
            AnalyticsReporter.track(
                "dictation_completed",
                properties: self.dictationAnalyticsProperties(
                    extra: dictationCompletedExtra
                )
            )
            if let saved = saveResult.saved {
                ActivationTelemetry.trackDictationArtifactSaved(
                    saved: saved,
                    delivery: pasteOutcome.delivery.rawValue,
                    durationBucket: AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime),
                    trigger: currentDictationTrigger.rawValue,
                    wordCountBucket: AnalyticsReporter.wordCountBucket(wordCount)
                )
                ActivationTelemetry.trackFirstArtifactSavedIfNeeded(
                    artifactKind: .dictation,
                    surface: .dictationSave,
                    trigger: currentDictationTrigger.rawValue,
                    wordCountBucket: AnalyticsReporter.wordCountBucket(wordCount),
                    durationBucket: AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime)
                )
                self.trackOnboardingFirstDictationSavedIfNeeded(
                    delivery: pasteOutcome.delivery,
                    wordCount: wordCount
                )
            }
            appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "completed")
        }
    }

    private func overlayStateName(_ state: FloatingOverlayController.OverlayState) -> String {
        switch state {
        case .idle: return "idle"
        case .starting: return "starting"
        case .loading: return "loading"
        case .listening: return "listening"
        case .drafting: return "drafting"
        case .success: return "success"
        }
    }
}
