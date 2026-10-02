// DictationSessionController+RecordingStart.swift
// Opening the microphone: start paths, model warmup, recovery wait, permission errors, and the loading copy.

import AppKit
import AVFoundation

extension DictationSessionController {
    private func dictationStartFailureKind(for status: AVAuthorizationStatus) -> String {
        switch status {
        case .denied:
            return "microphone_permission_denied"
        case .restricted:
            return "microphone_permission_restricted"
        case .notDetermined:
            return "microphone_permission_not_determined"
        case .authorized:
            return "microphone_unavailable"
        @unknown default:
            return "microphone_permission_unknown"
        }
    }

    func continueDictationStart(
        appState: TranscriptedAppState,
        sourceApp: NSRunningApplication?
    ) {
        guard isDictating else { return }
        switch dictationSession.startPathDecision(appState: appState) {
        case .immediate:
            beginDictationRecording(sourceApp: sourceApp)

        case .concurrentWarmupThenImmediate:
            // The model isn't loaded yet (cached, loading, or still
            // downloading on a first run) — open the microphone now and load
            // the model concurrently so dictation never stares at "Warming
            // up" before it can listen. The stop path checkpoints the audio
            // and waits for the model before transcribing (and surfaces a
            // load failure gracefully), so a stop that beats the load is
            // covered.
            //
            // Deliberately untracked: cancelling this dictation must not
            // abandon a model load the next session will need, and the
            // engine dedupes concurrent initialization internally.
            Task { @MainActor in
                await appState.sttRouter.initializeRecordingModel()
            }
            beginDictationRecording(sourceApp: sourceApp)

        case .fullWarmupRequired:
            startDictationAfterWarmup(sourceApp: sourceApp)
        }
    }

    // dictationStartUnavailableReason, canUseActiveMeetingMicForDictation, and
    // startDictationAudioRecording moved to Sources/Speech/DictationSession.swift
    // — they are pure STTRouter/meeting-mic decisions with no overlay
    // involvement. Kept as thin forwarding wrappers here so every existing
    // call site in this file keeps working unchanged.
    func dictationStartUnavailableReason(appState: TranscriptedAppState) -> String? {
        dictationSession.dictationStartUnavailableReason(appState: appState)
    }

    private func canUseActiveMeetingMicForDictation(appState: TranscriptedAppState) -> Bool {
        dictationSession.canUseActiveMeetingMicForDictation(appState: appState)
    }

    private func startDictationAudioRecording(
        appState: TranscriptedAppState,
        isRecoveryAttempt: Bool = false
    ) async -> Bool {
        let sessionID = currentDictationSessionID
        return await dictationSession.startDictationAudioRecording(
            appState: appState,
            isRecoveryAttempt: isRecoveryAttempt,
            // The fast path marks `opening_microphone` itself before the
            // open, and `waiting_for_audio_route` when it falls back.
            isCurrentSession: { true },
            onStartStageChanged: nil,
            onStartFailed: { [weak self] in
                await self?.recoverBackgroundHotkeyStart(sessionID: sessionID)
            }
        )
    }

    /// A successful ordinary start never changes focus. Only a real native
    /// start failure can request this one recovery step for the current session.
    ///
    /// This is now the second line of defence, not the first: issue #1743's
    /// front-loaded preparation — the App Nap suppression assertion, taken
    /// before the first microphone open — is what a background start relies
    /// on. This stays for the case where the process was prepared and the
    /// open still failed.
    ///
    /// The guard reads `allowsForegroundActivationEscalation` rather than
    /// listing triggers inline as PR #1744 did. That list named
    /// `keyboardShortcut` and `rightOptionTap`, neither of which anything in
    /// the tree constructs, so it read as coverage it did not have.
    private func recoverBackgroundHotkeyStart(sessionID: UUID) async {
        guard let appState,
              startActivationRecoveryGate.admit(
                  sessionID: sessionID,
                  currentSessionID: currentDictationSessionID,
                  isDictating: isDictating,
                  isCancelled: Task.isCancelled,
                  appIsActive: NSApp.isActive,
                  allowsEscalation: currentStartReadinessProfile.allowsForegroundActivationEscalation,
                  usesMeetingMic: { self.canUseActiveMeetingMicForDictation(appState: appState) }
              ) else { return }
        _ = await startActivation.prepare(
            sourceApp: sessionSourceApp,
            isCurrent: { self.isDictating && self.currentDictationSessionID == sessionID }
        )
    }

    /// Actually start dictation recording — called directly from startDictation
    private func beginDictationRecording(sourceApp: NSRunningApplication?) {
        guard let overlayController = overlayController else { return }
        guard isDictating else { return }

        guard let appState = appState else { return }

        let canUseMeetingMic = canUseActiveMeetingMicForDictation(appState: appState)
        switch dictationSession.recordingStartPlan(appState: appState, canUseMeetingMic: canUseMeetingMic) {
        case .skipLoadingAndStartRecording:
            // Fast path — engine is ready right now. The actual CoreAudio start
            // still runs asynchronously so a slow device graph never blocks UI.
            enterPendingStartStage(.openingMicrophone)
            overlayController.showStartingState(near: sourceApp, anchorRect: sessionAnchorRect)
            if DictationStartCuePolicy.playsOnKeyPress(
                recordedInput: appState.sttRouter.parakeetEngine.cachedInputDeviceSelection?.selectedInput
            ) {
                playStartCueOnce()
            }
            recordingStartRetryTask?.cancel()
            recordingStartRetryTask = Task { @MainActor [weak self] in
                guard let self,
                      self.isDictating,
                      let appState = self.appState,
                      let overlayController = self.overlayController else { return }
                let startAttemptedAt = CFAbsoluteTimeGetCurrent()
                var startMs = 0
                _ = await DictationFastStart.run(DictationFastStart.Steps(
                    openMicrophone: {
                        let started = await self.startDictationAudioRecording(appState: appState)
                        startMs = Int((CFAbsoluteTimeGetCurrent() - startAttemptedAt) * 1000)
                        return started
                    },
                    isStillWanted: { self.isDictating },
                    stopLateRecording: { await appState.sttRouter.stopRecording() },
                    started: {
                        let requestToRecordingMs = Int((CFAbsoluteTimeGetCurrent() - self.sessionStartTime) * 1000)
                        overlayController.state = .listening
                        if !overlayController.isVisible {
                            overlayController.showPanel(near: sourceApp, anchorRect: self.sessionAnchorRect)
                        }
                        self.resizePanelToCompact()
                        self.finishRecordingStart(appState: appState) {
                            appState.runtimeDiagnostics.recordSession(kind: "dictation", stage: "recording")
                            appState.logger.log("DICTATION | started (parakeet, \(appState.sttRouter.inputDeviceName))")
                            DiagnosticsTrail.record(
                                logger: appState.logger,
                                engine: "dictation",
                                event: "dictation_recording_fast_start",
                                message: "Dictation recording started through the ready-engine fast path",
                                context: self.dictationContext(
                                    extra: [
                                        "pre_recording_overhead_ms": "\(max(0, requestToRecordingMs - startMs))",
                                        "request_to_recording_ms": "\(requestToRecordingMs)",
                                        "start_ms": "\(startMs)",
                                        "audio_device": appState.sttRouter.inputDeviceName,
                                        "trigger": self.currentDictationTrigger.rawValue
                                    ]
                                )
                            )
                        }
                    },
                    fallBackToWait: {
                        let requestToFallbackMs = Int((CFAbsoluteTimeGetCurrent() - self.sessionStartTime) * 1000)
                        DiagnosticsTrail.record(
                            logger: appState.logger,
                            level: .warning,
                            engine: "dictation",
                            event: "dictation_fast_start_fell_back_to_wait",
                            message: "Ready-engine dictation fast start failed and fell back to recovery wait",
                            context: self.dictationContext(
                                extra: [
                                    "pre_recording_overhead_ms": "\(max(0, requestToFallbackMs - startMs))",
                                    "request_to_fallback_ms": "\(requestToFallbackMs)",
                                    "start_ms": "\(startMs)",
                                    "audio_device": appState.sttRouter.inputDeviceName,
                                    "trigger": self.currentDictationTrigger.rawValue,
                                    "start_plan": self.currentStartReadinessProfile.name,
                                    "app_active": "\(NSApp.isActive)",
                                    "is_recovering": "\(appState.sttRouter.isRecovering)",
                                    "format_ready": "\(appState.sttRouter.inputFormatReady)"
                                ]
                            )
                        )
                        self.enterPendingStartStage(.waitingForAudioRoute)
                        await self.waitForEngineAndStart(sourceApp: sourceApp)
                    }
                ))
            }
            return
        case .showLoadingWhileWaiting:
            // Slow path — engine is settling after a device change. Wait for it.
            enterPendingStartStage(.waitingForAudioRoute)
            overlayController.showMiniCursorStartingStateIfNeeded(
                near: sourceApp,
                anchorRect: sessionAnchorRect
            )
            overlayController.showLoadingState(
                near: sourceApp,
                presentation: microphoneRecoveryPresentation(
                    elapsed: 0,
                    deviceName: appState.sttRouter.inputDeviceName,
                    isRecovering: appState.sttRouter.isRecovering,
                    inputFormatReady: appState.sttRouter.inputFormatReady,
                    startAttempts: 0
                ),
                anchorRect: sessionAnchorRect
            )
        }
        recordingStartRetryTask?.cancel()
        recordingStartRetryTask = Task { @MainActor [weak self] in
            await self?.waitForEngineAndStart(sourceApp: sourceApp)
        }
    }

    // The recovery wait-loop state machine (deadline, readiness-refresh
    // bookkeeping, the merged start-attempt path) now lives in
    // DictationSession.waitForEngineAndStart. This wrapper keeps the
    // permission gate (a permission concern, not an STTRouter one) and turns
    // wait-status snapshots and the final outcome into overlay presentation,
    // sound, and session-timeout installation — the presentational half that
    // stays here.
    private func waitForEngineAndStart(sourceApp: NSRunningApplication?) async {
        guard let appState = appState, let overlayController = overlayController else { return }
        guard isDictating else { return }

        // Permission check up front — no point waiting if the user denied mic access.
        let microphoneStatus = TranscriptedPermissionAccess.microphoneAuthorizationStatus()
        guard microphoneStatus == .authorized else {
            presentMicrophonePermissionError(microphoneStatus, sourceApp: sourceApp)
            return
        }

        let sessionID = currentDictationSessionID
        let outcome = await dictationSession.waitForEngineAndStart(
            appState: appState,
            sessionStartTime: sessionStartTime,
            isDictating: { [weak self] in
                self?.isDictating == true && self?.currentDictationSessionID == sessionID
            },
            onStartFailed: { [weak self] in
                await self?.recoverBackgroundHotkeyStart(sessionID: sessionID)
            },
            onStartStageChanged: { [weak self] stage in
                guard let self else { return }
                self.pendingStartStage.enterReported(
                    stage,
                    requestingSessionID: sessionID,
                    currentSessionID: self.currentDictationSessionID,
                    isDictating: self.isDictating,
                    isCancelled: Task.isCancelled,
                    now: CFAbsoluteTimeGetCurrent()
                )
            },
            onWaitUpdate: { [weak self] status in
                guard let self, let overlayController = self.overlayController else { return }
                overlayController.showLoadingState(
                    near: sourceApp,
                    presentation: self.microphoneRecoveryPresentation(
                        elapsed: status.elapsed,
                        deviceName: status.deviceName,
                        isRecovering: status.isRecovering,
                        inputFormatReady: status.inputFormatReady,
                        startAttempts: status.startAttempts
                    ),
                    anchorRect: self.sessionAnchorRect
                )
            },
            onRecordingStarted: { [weak self] in
                // Fires the instant a start attempt succeeds, BEFORE
                // DictationSession's own stage-record/log calls — matches
                // both original inline branches, which flipped the overlay
                // to .listening first and only logged afterward.
                guard let self else { return }
                self.overlayController?.state = .listening
                self.resizePanelToCompact()
            }
        )

        // DictationSession already re-checks isDictating/Task.isCancelled at
        // every point the original inline loop did before it hands back an
        // outcome, so `.aborted` is the only outcome for those cases.
        switch outcome {
        case .aborted:
            return

        case .started:
            // overlayController.state/resizePanelToCompact() already ran via
            // onRecordingStarted above, before DictationSession's telemetry.
            // Drops the finished start handle like the fast path does.
            finishRecordingStart(appState: appState)

        case .timedOut(let info):
            let cleanupPlan = info.cleanupPlan
            if !cleanupPlan.reportBeforeCleanup {
                await finishFailedDictationStart(appState: appState, cleanupPlan: cleanupPlan)
            }
            trackDictationStartFailed(
                cleanupPlan.outcome,
                extra: [
                    "start_attempt_bucket": AnalyticsReporter.countBucket(info.startAttempts)
                ]
            )
            if cleanupPlan.reportRuntimeStall {
                appState.runtimeDiagnostics.recordStall(
                    kind: "dictation",
                    stage: cleanupPlan.outcome,
                    durationSeconds: TranscriptedConstants.dictationRecoveryBudget,
                    extra: dictationAnalyticsProperties(extra: [
                        "failure_kind": cleanupPlan.outcome,
                        "format_ready": "\(appState.sttRouter.inputFormatReady)",
                        "forced_readiness_recoveries": "\(info.forcedReadinessRecoveries)",
                        "readiness_refreshes": "\(info.readinessRefreshes)",
                        "recovering": "\(appState.sttRouter.isRecovering)",
                        "recovery_start_attempts": "\(info.recoveryStartAttempts)",
                        "start_attempts": "\(info.startAttempts)",
                        "trigger": currentDictationTrigger.rawValue,
                    ])
                )
            }
            if cleanupPlan.reportBeforeCleanup {
                await finishFailedDictationStart(appState: appState, cleanupPlan: cleanupPlan)
            }
            overlayController.showError(
                microphoneTimeoutMessage(
                    deviceName: appState.sttRouter.inputDeviceName,
                    startAttempts: info.startAttempts,
                    inputFormatReady: appState.sttRouter.inputFormatReady,
                    routeContext: appState.sttRouter.dictationAudioRouteAnalyticsContext
                ),
                actionTitle: "Try Again",
                action: { [weak self] in
                    guard let self else { return }
                    self.startDictation(sourceApp: sourceApp, trigger: self.currentDictationTrigger, isRetry: true)
                }
            )
        }
    }

    private func finishFailedDictationStart(
        appState: TranscriptedAppState,
        cleanupPlan: DictationRecordingStartFailureCleanupPlan
    ) async {
        recordingStartRetryTask = nil
        sessionTimeoutTask?.cancel()
        sessionTimeoutTask = nil
        clearSessionCapCountdown()
        if cleanupPlan.resetSpeechEngine {
            await dictationSession.resetEngineAfterFailedStart(
                appState: appState,
                hardReset: cleanupPlan.hardResetSpeechEngine,
                reason: cleanupPlan.outcome
            )
        }
        appState.runtimeDiagnostics.clearSession(
            kind: "dictation",
            outcome: cleanupPlan.outcome,
            resetToIdle: cleanupPlan.resetRuntimeSessionToIdle
        )
        isDictating = false
    }

    func presentMicrophonePermissionError(
        _ status: AVAuthorizationStatus,
        sourceApp: NSRunningApplication? = nil
    ) {
        guard let appState = appState, let overlayController = overlayController else { return }
        let shouldOfferRecoveryAction = shouldOfferMicrophoneRecoveryAction(for: status)
        DiagnosticsTrail.record(
            logger: appState.logger,
            level: .error,
            engine: "dictation",
            event: "dictation_recording_failed",
            message: "Dictation recording failed to start",
            context: dictationContext(
                extra: [
                    "audio_device": appState.sttRouter.inputDeviceName,
                    "mic_status": status.diagnosticName
                ]
            )
        )
        trackDictationStartFailed(dictationStartFailureKind(for: status))
        appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "start_failed")
        overlayController.showError(
            microphoneUnavailableMessage(for: status, openedSettings: false),
            actionTitle: shouldOfferRecoveryAction ? TranscriptedPermissionKind.microphoneActionTitle(for: status) : nil,
            action: shouldOfferRecoveryAction ? { [weak self] in
                guard let self else { return }
                switch status {
                case .notDetermined:
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        let granted = await TranscriptedPermissionAccess.requestMicrophoneAccessIfNeeded()
                        guard granted else {
                            self.presentMicrophonePermissionError(
                                TranscriptedPermissionAccess.microphoneAuthorizationStatus(),
                                sourceApp: sourceApp
                            )
                            return
                        }
                        self.startDictation(
                            sourceApp: sourceApp,
                            trigger: self.currentDictationTrigger,
                            anchorRect: self.sessionAnchorRect,
                            isRetry: true
                        )
                    }
                case .denied, .restricted:
                    overlayController.dismissError()
                    TranscriptedPermissionAccess.openSettings(for: .microphone)
                case .authorized:
                    self.startDictation(
                        sourceApp: sourceApp,
                        trigger: self.currentDictationTrigger,
                        anchorRect: self.sessionAnchorRect,
                        isRetry: true
                    )
                @unknown default:
                    overlayController.dismissError()
                    TranscriptedPermissionAccess.openSettings(for: .microphone)
                }
            } : nil
        )
        isDictating = false
    }

    // The model-warmup wait loop (deadline, download-state polling, join vs.
    // kick decisions) now lives in DictationSession.waitForModelAndStart —
    // it is an STTRouter control-flow decision like the recovery wait loop.
    // This wrapper keeps the loading-overlay presentation and the
    // retry/error UI, which the outcome cases below trigger.
    private func startDictationAfterWarmup(sourceApp: NSRunningApplication?) {
        guard let appState = appState, let overlayController = overlayController else { return }

        startupTask?.cancel()
        enterPendingStartStage(.awaitingModelWarmup)
        overlayController.showMiniCursorStartingStateIfNeeded(
            near: sourceApp,
            anchorRect: sessionAnchorRect
        )
        updateLoadingOverlay(sourceApp: sourceApp)

        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }

            let outcome = await self.dictationSession.waitForModelAndStart(
                appState: appState,
                isDictating: { [weak self] in self?.isDictating ?? false },
                onModelStateUpdate: { [weak self] modelState in
                    self?.updateLoadingOverlay(sourceApp: sourceApp, modelState: modelState)
                }
            )

            switch outcome {
            case .ready:
                self.startupTask = nil
                guard self.isDictating else { return }
                self.beginDictationRecording(sourceApp: sourceApp)
            case .failed(let message):
                self.startupTask = nil
                self.isDictating = false
                outcome.startFailureKind.map { self.trackDictationStartFailed($0) }
                appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "model_failed")
                overlayController.showError(
                    "Dictation couldn't start: \(message)",
                    actionTitle: "Retry Dictation",
                    action: { [weak self] in
                        self?.startDictation(
                            sourceApp: sourceApp,
                            trigger: self?.currentDictationTrigger ?? .unknown,
                            anchorRect: self?.sessionAnchorRect,
                            isRetry: true
                        )
                    }
                )
            case .timedOut:
                self.startupTask = nil
                self.isDictating = false
                outcome.startFailureKind.map { self.trackDictationStartFailed($0) }
                appState.runtimeDiagnostics.recordStall(
                    kind: "dictation",
                    stage: "model_load_timeout",
                    durationSeconds: TranscriptedConstants.modelLoadWaitBudget
                )
                appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "model_load_timeout")
                overlayController.showError(
                    "The voice model is still warming up. Try again in a moment.",
                    actionTitle: "Retry Dictation",
                    action: { [weak self] in
                        self?.startDictation(
                            sourceApp: sourceApp,
                            trigger: self?.currentDictationTrigger ?? .unknown,
                            anchorRect: self?.sessionAnchorRect,
                            isRetry: true
                        )
                    }
                )
            case .aborted:
                // Matches the original loop's early-return guard: the task
                // was cancelled or the session already ended elsewhere
                // (which already owns clearing `startupTask`), so this must
                // not touch it — a superseding startDictation call may have
                // already installed a new one.
                break
            }
        }
    }

    func updateLoadingOverlay(
        sourceApp: NSRunningApplication?,
        modelState: ParakeetModelState? = nil,
        phase: DictationWarmupPresentationPolicy.Phase = .beforeRecording
    ) {
        guard let appState = appState else { return }
        let presentation = loadingPresentation(
            for: modelState ?? appState.sttRouter.recordingModelDownloadState,
            phase: phase
        )
        overlayController?.showLoadingState(
            near: sourceApp,
            presentation: presentation,
            anchorRect: sessionAnchorRect
        )
    }

    private func loadingPresentation(
        for modelState: ParakeetModelState,
        phase: DictationWarmupPresentationPolicy.Phase = .beforeRecording
    ) -> FloatingOverlayController.LoadingPresentation {
        let copy = DictationWarmupPresentationPolicy.copy(
            modelState: modelState,
            phase: phase
        )
        return .init(
            title: copy.title,
            detail: copy.detail,
            progress: copy.progress,
            status: copy.status
        )
    }

    private func microphoneRecoveryPresentation(
        elapsed: TimeInterval,
        deviceName: String,
        isRecovering: Bool,
        inputFormatReady: Bool,
        startAttempts: Int
    ) -> FloatingOverlayController.LoadingPresentation {
        let budget = TranscriptedConstants.dictationRecoveryBudget
        let progress = min(0.85, 0.1 + (elapsed / budget) * 0.75)
        let copy = DictationMicrophoneLoadingPresentationPolicy.copy(
            elapsed: elapsed,
            deviceName: deviceName,
            isRecovering: isRecovering,
            inputFormatReady: inputFormatReady,
            startAttempts: startAttempts
        )
        return .init(
            title: copy.title,
            detail: copy.detail,
            progress: progress,
            status: copy.status
        )
    }

    func microphonePermissionPresentation() -> FloatingOverlayController.LoadingPresentation {
        .init(
            title: "Allow microphone",
            detail: "Transcripted needs microphone access before dictation can listen.",
            progress: 0.16,
            status: "Waiting for macOS permission"
        )
    }

    func microphoneTimeoutMessage(
        deviceName: String,
        startAttempts: Int,
        inputFormatReady: Bool,
        routeContext: [String: String]
    ) -> String {
        DictationMicrophoneTimeoutPresentationPolicy.message(
            deviceName: deviceName,
            startAttempts: startAttempts,
            inputFormatReady: inputFormatReady,
            routeContext: routeContext
        )
    }

    /// Shrink the panel to compact (header-only) height without animation.
    /// Called after loading → listening transition to undo showLoadingState()'s expansion.
    func resizePanelToCompact() {
        overlayController?.resizePanelToCompact()
    }

    private func shouldOfferMicrophoneRecoveryAction(for status: AVAuthorizationStatus) -> Bool {
        switch status {
        case .notDetermined, .denied, .restricted:
            return true
        case .authorized:
            return false
        @unknown default:
            return true
        }
    }

    private func microphoneUnavailableMessage(
        for status: AVAuthorizationStatus,
        openedSettings: Bool = false
    ) -> String {
        switch status {
        case .notDetermined:
            return "Transcripted needs microphone access before dictation can listen."
        case .denied, .restricted:
            if openedSettings {
                return "Microphone access is off. Transcripted opened the Microphone pane in System Settings."
            }
            return "Microphone access is off. Turn it on in System Settings."
        case .authorized:
            return "Microphone unavailable. Check your audio input and try again."
        @unknown default:
            return "Microphone unavailable. Check your audio input and try again."
        }
    }

// AVAuthorizationStatus.diagnosticName is defined once in
// Sources/Support/TranscriptedPermissionAccess.swift and reused here.
}
