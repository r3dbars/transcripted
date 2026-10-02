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
            endStopBeforeCaptureStarted(
                inputFormatReady: appState.sttRouter.inputFormatReady,
                cancelSpeechEngine: { appState.sttRouter.cancel() },
                report: { failureKind in
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
                },
                showTimeout: { retry in
                    overlayController.showError(
                        microphoneTimeoutMessage(
                            deviceName: appState.sttRouter.inputDeviceName,
                            startAttempts: 0,
                            inputFormatReady: appState.sttRouter.inputFormatReady,
                            routeContext: appState.sttRouter.dictationAudioRouteAnalyticsContext
                        ),
                        actionTitle: "Try Again",
                        action: retry
                    )
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
            // runStopUntilTranscribed (DictationSessionPipeline.swift) owns the
            // order: the stale-task fence, then DictationStopCheckpoint (stop
            // the mic, play the stop click, save the take to a private WAV),
            // then the model wait, then transcription of that same snapshot.
            let stop = await self.runStopUntilTranscribed(
                taskSessionID: taskSessionID,
                DictationStopTranscriptionSteps<RecordedSpeechSamples>(
                    markStopRequested: {
                        appState.runtimeDiagnostics.recordSession(kind: "dictation", stage: "stop_requested")
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
                    hasRecoverableRecording: { appState.sttRouter.hasRecoverableRecording },
                    checkpointSettled: { await checkpointSignal.complete() },
                    reportCheckpointFailure: { error in
                        appState.logger.log("DICTATION | failed to preserve stopped audio: \(error.localizedDescription)")
                        EventReporter.shared.capture(
                            level: .error,
                            engine: "dictation",
                            event: "dictation_stopped_audio_persistence_failed",
                            message: error.localizedDescription
                        )
                    },
                    clearSession: { outcome in
                        appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: outcome)
                    },
                    waitForModel: { isCurrent in
                        await DictationPostStopModelWait.run(
                            DictationPostStopModelWait.Steps(
                                isCurrent: isCurrent,
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
                    },
                    reportModelUnavailable: {
                        appState.logger.log("DICTATION | voice model failed to load for transcription")
                        ProductFrictionTelemetry.track(
                            surface: .dictation,
                            stage: "dictation_transcribe",
                            result: .blocked,
                            failureKind: "model_not_ready",
                            elapsedBucket: AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - self.sessionStartTime),
                            routeShape: self.dictationAnalyticsProperties()["route_shape"],
                            modelState: "not_ready"
                        )
                    },
                    showMessage: { message, actionTitle, action in
                        overlayController.showError(message, actionTitle: actionTitle, action: action)
                    },
                    startTranscribing: {
                        overlayController.state = .drafting
                        overlayController.resizePanelToCompact()
                        appState.runtimeDiagnostics.recordSession(kind: "dictation", stage: "transcribing")
                    },
                    transcribe: { preparedRecording in
                        await appState.sttRouter.transcribe(preparedRecording: preparedRecording)
                    },
                    now: { CFAbsoluteTimeGetCurrent() }
                )
            )
            stopTiming.micStoppedAt = stop.marks.checkpoint.micStoppedAt
            stopTiming.snapshotStartedAt = stop.marks.checkpoint.snapshotStartedAt
            stopTiming.snapshotFinishedAt = stop.marks.checkpoint.snapshotFinishedAt
            stopTiming.recoveryCheckpointStartedAt = stop.marks.checkpoint.checkpointStartedAt
            stopTiming.recoveryCheckpointFinishedAt = stop.marks.checkpoint.checkpointFinishedAt
            stopTiming.modelWaitStartedAt = stop.marks.modelWaitStartedAt
            stopTiming.modelReadyAt = stop.marks.modelReadyAt
            stopTiming.transcriptionStartedAt = stop.marks.transcriptionStartedAt
            stopTiming.transcribedAt = stop.marks.transcribedAt
            guard case .transcribed(let voiceText) = stop.outcome else { return }

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
                // finishEmptyTake (DictationSessionPipeline.swift) runs
                // DictationEmptyTranscriptPolicy and the matching message.
                self.finishEmptyTake(
                    taskSessionID: taskSessionID,
                    DictationEmptyTakeSteps(
                        reason: emptyReason,
                        stopRequestedAt: stopTiming.requestedAt,
                        sessionStartedAt: sessionStartTime,
                        heldBackText: { appState.sttRouter.heldBackDictationText },
                        report: { emptyDecision in
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
                                            seconds: CFAbsoluteTimeGetCurrent() - self.sessionStartTime
                                        ),
                                        "trigger": self.currentDictationTrigger.rawValue,
                                    ]
                                )
                            )
                            ProductFrictionTelemetry.track(
                                surface: .dictation,
                                stage: "dictation_transcribe",
                                result: emptyDecision.countsAsCancelled ? .cancelled : .giveUp,
                                failureKind: emptyReason.frictionFailureKind,
                                elapsedBucket: AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - self.sessionStartTime),
                                routeShape: self.dictationAnalyticsProperties()["route_shape"],
                                modelState: ProductFrictionTelemetry.modelState(isReady: appState.sttRouter.isModelLoaded)
                            )
                        },
                        closeLikeCancel: {
                            NotificationCenter.default.post(name: .dictationNoSpeechDetected, object: nil)
                            AppSoundPlayer.shared.play(.dictationCancelled)
                            overlayController.hideWithCancelAnimation()
                        },
                        showNoSpeechAndDismiss: {
                            NotificationCenter.default.post(name: .dictationNoSpeechDetected, object: nil)
                            AppSoundPlayer.shared.play(.noSpeech)
                            overlayController.showNoSpeechAndDismiss(
                                trigger: self.currentDictationTrigger.rawValue,
                                reason: emptyReason,
                                shortcutMode: self.currentDictationShortcutMode,
                                silentMicName: appState.sttRouter.lastRecordingWasDigitalSilence
                                    ? appState.sttRouter.inputDeviceName
                                    : nil
                            )
                        },
                        showMessage: { message, actionTitle, action in
                            overlayController.showError(message, actionTitle: actionTitle, action: action)
                        },
                        showPasted: { overlayController.showSuccessAndDismiss(title: "Pasted") },
                        clearSession: { outcome in
                            appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: outcome)
                        }
                    )
                )
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
                    DictationStoppedAudioRecoveryStore.retire(recovery, afterSaving: result)
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
