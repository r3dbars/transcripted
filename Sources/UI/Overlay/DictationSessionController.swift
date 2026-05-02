// DictationSessionController.swift
// Session orchestration for dictation mode plus compatibility stubs for the
// removed draft mode.

import AppKit
import AVFoundation
import Combine

@MainActor
class DictationSessionController: ObservableObject {
    private static let removedDraftModeMessage = "This build of Transcripted supports dictation and meetings only."

    enum DictationTrigger: String {
        case rightOptionTap = "right_option_tap"
        case physicalKey = "physical_key"
        case keyboardShortcut = "keyboard_shortcut"
        case overlayButton = "overlay_button"
        case menu = "menu"
        case onboarding = "onboarding"
        case unknown = "unknown"
    }

    @Published var isInSession = false
    @Published var isDictating = false
    @Published var lastCompletedText: String?

    private var interruptionSubscription: AnyCancellable?
    private let textPaster = ClipboardRestoringTextPaster()
    private let autoSender = DictationAutoSender()

    var appState: TranscriptedAppState? {
        didSet { setupInterruptionObserver() }
    }
    var overlayController: FloatingOverlayController? {
        didSet {
            overlayController?.onEscapeDuringSession = { [weak self] in
                guard let self = self else { return }
                if self.isInSession {
                    self.cancelSession()
                } else if self.isDictating {
                    self.cancelDictation()
                }
            }
            overlayController?.onStopListening = { [weak self] in
                guard let self = self, self.isDictating else { return }
                self.stopDictationAndPaste(trigger: .overlayButton)
            }
        }
    }

    /// Unwrap both required dependencies or log a warning and return nil.
    private func readyState() -> (TranscriptedAppState, FloatingOverlayController)? {
        guard let appState = appState, let overlayController = overlayController else {
            EventReporter.shared.capture(level: .warning, engine: "overlay", event: "session_not_wired",
                message: "appState or overlayController not set")
            return nil
        }
        return (appState, overlayController)
    }

    private var sessionSourceApp: NSRunningApplication?
    private var sessionAnchorRect: NSRect?
    private var startupTask: Task<Void, Never>?
    private var streamingTask: Task<Void, Never>?
    private var recordingStartRetryTask: Task<Void, Never>?
    private var sessionTimeoutTask: Task<Void, Never>?
    private var sessionStartTime: CFAbsoluteTime = 0
    private var currentDictationTrigger: DictationTrigger = .unknown

    /// Max duration for a listening session before auto-cancel (5 minutes).
    /// Prevents stuck sessions when the user walks away from the computer.
    private static let sessionTimeoutNanos: UInt64 = 5 * 60 * 1_000_000_000

    deinit {
        startupTask?.cancel()
        streamingTask?.cancel()
        recordingStartRetryTask?.cancel()
        sessionTimeoutTask?.cancel()
    }

    private func setupInterruptionObserver() {
        guard let appState = appState else { return }
        interruptionSubscription = appState.sttRouter.$recordingInterrupted
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.isInSession {
                    self.cancelSession(message: Self.removedDraftModeMessage)
                } else if self.isDictating {
                    self.handleDictationInterruption()
                }
            }
    }

    // MARK: - Removed Draft Mode

    // `cancelSession()` is still invoked by ContextCaptureEngine on interrupt paths.
    // The `startSession` / `stopSessionAndDraft` stubs were removed — they had no callers.
    func cancelSession() {
        cancelSession(message: Self.removedDraftModeMessage)
    }

    private func cancelSession(message: String) {
        guard let (_, overlayController) = readyState() else { return }
        cancelActiveTasks(cancelRecording: false)
        isInSession = false
        overlayController.showError(message)
    }

    // MARK: - Dictation Mode (Option+Space)

    /// Start dictation — show overlay and begin voice recording (no screenshot/vision)
    func startDictation(
        sourceApp: NSRunningApplication?,
        trigger: DictationTrigger = .unknown,
        anchorRect: NSRect? = nil
    ) {
        guard let (appState, overlayController) = readyState() else { return }
        guard !isDictating, !isInSession else { return }
        isDictating = true
        sessionSourceApp = sourceApp
        sessionAnchorRect = anchorRect
        sessionStartTime = CFAbsoluteTimeGetCurrent()
        currentDictationTrigger = trigger
        lastCompletedText = nil
        appState.runtimeDiagnostics.recordSession(kind: "dictation", stage: "start_requested")

        switch TranscriptedPermissionAccess.microphoneAuthorizationStatus() {
        case .authorized:
            recordDictationStarted(appState: appState, trigger: trigger)
            continueDictationStart(
                appState: appState,
                overlayController: overlayController,
                sourceApp: sourceApp
            )
        case .notDetermined:
            overlayController.showLoadingState(
                near: sourceApp,
                presentation: microphonePermissionPresentation(),
                anchorRect: anchorRect
            )
            startupTask?.cancel()
            startupTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let granted = await TranscriptedPermissionAccess.requestMicrophoneAccessIfNeeded()
                guard !Task.isCancelled, self.isDictating else { return }
                self.startupTask = nil
                if granted {
                    self.recordDictationStarted(appState: appState, trigger: trigger)
                    self.continueDictationStart(
                        appState: appState,
                        overlayController: overlayController,
                        sourceApp: sourceApp
                    )
                } else {
                    self.presentMicrophonePermissionError(
                        TranscriptedPermissionAccess.microphoneAuthorizationStatus(),
                        sourceApp: sourceApp
                    )
                }
            }
        case .denied, .restricted:
            presentMicrophonePermissionError(
                TranscriptedPermissionAccess.microphoneAuthorizationStatus(),
                sourceApp: sourceApp
            )
        @unknown default:
            presentMicrophonePermissionError(
                TranscriptedPermissionAccess.microphoneAuthorizationStatus(),
                sourceApp: sourceApp
            )
        }
    }

    private func recordDictationStarted(
        appState: TranscriptedAppState,
        trigger: DictationTrigger
    ) {
        DiagnosticsTrail.record(
            logger: appState.logger,
            engine: "dictation",
            event: "dictation_started",
            message: "Dictation started",
            context: dictationContext(
                extra: [
                    "trigger": trigger.rawValue
                ]
            )
        )
        AnalyticsReporter.track(
            "dictation_started",
            properties: dictationAnalyticsProperties(
                extra: [
                    "trigger": trigger.rawValue,
                ]
            )
        )
    }

    private func trackDictationStartFailed(_ failureKind: String) {
        AnalyticsReporter.track(
            "dictation_start_failed",
            properties: dictationAnalyticsProperties(
                extra: [
                    "failure_kind": failureKind,
                    "trigger": currentDictationTrigger.rawValue,
                ]
            )
        )
    }

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

    private func continueDictationStart(
        appState: TranscriptedAppState,
        overlayController: FloatingOverlayController,
        sourceApp: NSRunningApplication?
    ) {
        guard isDictating else { return }
        if appState.sttRouter.isModelLoaded {
            overlayController.state = .listening
            overlayController.showPanel(near: sourceApp, anchorRect: sessionAnchorRect)
            beginDictationRecording(sourceApp: sourceApp)
            return
        }

        startDictationAfterWarmup(sourceApp: sourceApp)
    }

    /// Actually start dictation recording — called directly from startDictation
    private func beginDictationRecording(sourceApp: NSRunningApplication?) {
        guard let overlayController = overlayController else { return }
        guard isDictating else { return }

        overlayController.state = .listening

        // Fast path — engine is ready right now. The actual CoreAudio start
        // still runs asynchronously so a slow device graph never blocks UI.
        if let appState = appState,
           !appState.sttRouter.isRecovering,
           appState.sttRouter.inputFormatReady {
            recordingStartRetryTask?.cancel()
            recordingStartRetryTask = Task { @MainActor [weak self] in
                guard let self,
                      self.isDictating,
                      let appState = self.appState,
                      let overlayController = self.overlayController else { return }
                let started = await appState.sttRouter.startRecording()
                guard !Task.isCancelled, self.isDictating else {
                    if started {
                        await appState.sttRouter.stopRecording()
                    }
                    return
                }
                if started {
                    self.recordingStartRetryTask = nil
                    overlayController.state = .listening
                    self.resizePanelToCompact()
                    appState.runtimeDiagnostics.recordSession(kind: "dictation", stage: "recording")
                    appState.logger.log("DICTATION | started (parakeet, \(appState.sttRouter.inputDeviceName))")
                    AppSoundPlayer.shared.play(.dictationStart)
                    self.installSessionTimeout()
                } else {
                    await self.waitForEngineAndStart(sourceApp: sourceApp)
                }
            }
            return
        }

        // Slow path — engine is settling after a device change. Wait for it.
        recordingStartRetryTask?.cancel()
        recordingStartRetryTask = Task { @MainActor [weak self] in
            await self?.waitForEngineAndStart(sourceApp: sourceApp)
        }
    }

    private func waitForEngineAndStart(sourceApp: NSRunningApplication?) async {
        guard let appState = appState, let overlayController = overlayController else { return }
        guard isDictating else { return }

        // Permission check up front — no point waiting if the user denied mic access.
        let microphoneStatus = TranscriptedPermissionAccess.microphoneAuthorizationStatus()
        guard microphoneStatus == .authorized else {
            presentMicrophonePermissionError(microphoneStatus, sourceApp: sourceApp)
            return
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        let deadline = startedAt + TranscriptedConstants.dictationRecoveryBudget
        var startAttempts = 0
        var readinessRefreshes = 0
        var forcedReadinessRecoveries = 0
        var nextReadinessRefreshAt = startedAt

        if !appState.sttRouter.isRecovering, !appState.sttRouter.inputFormatReady {
            await appState.sttRouter.refreshInputReadiness()
            readinessRefreshes += 1
            nextReadinessRefreshAt = CFAbsoluteTimeGetCurrent() + TranscriptedConstants.dictationReadinessRefreshInterval
        }

        while CFAbsoluteTimeGetCurrent() < deadline {
            guard isDictating, !Task.isCancelled else { return }

            let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
            let isRecovering = appState.sttRouter.isRecovering
            let inputFormatReady = appState.sttRouter.inputFormatReady
            overlayController.showLoadingState(
                near: sourceApp,
                presentation: microphoneRecoveryPresentation(
                    elapsed: elapsed,
                    deviceName: appState.sttRouter.inputDeviceName,
                    isRecovering: isRecovering,
                    inputFormatReady: inputFormatReady,
                    startAttempts: startAttempts
                ),
                anchorRect: sessionAnchorRect
            )

            switch DictationReadinessWaitPolicy.action(
                isRecovering: isRecovering,
                inputFormatReady: inputFormatReady,
                readinessRefreshes: readinessRefreshes,
                forcedRecoveryAttempts: forcedReadinessRecoveries
            ) {
            case .waitForRecovery:
                break

            case .refreshInputReadiness:
                if CFAbsoluteTimeGetCurrent() >= nextReadinessRefreshAt {
                    await appState.sttRouter.refreshInputReadiness()
                    readinessRefreshes += 1
                    nextReadinessRefreshAt = CFAbsoluteTimeGetCurrent() + TranscriptedConstants.dictationReadinessRefreshInterval
                }

            case .forceInputRecovery:
                forcedReadinessRecoveries += 1
                readinessRefreshes = 0
                await appState.sttRouter.forceInputReadinessRecovery(reason: "dictation_readiness_wait_stalled")
                nextReadinessRefreshAt = CFAbsoluteTimeGetCurrent() + TranscriptedConstants.dictationReadinessRefreshInterval

            case .startRecording:
                startAttempts += 1
                let started = await appState.sttRouter.startRecording()
                guard !Task.isCancelled, isDictating else {
                    if started {
                        await appState.sttRouter.stopRecording()
                    }
                    return
                }
                if started {
                    overlayController.state = .listening
                    resizePanelToCompact()
                    appState.runtimeDiagnostics.recordSession(kind: "dictation", stage: "recording_after_wait")
                    let waited = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000)
                    appState.logger.log("DICTATION | started after \(waited)ms wait (parakeet, \(appState.sttRouter.inputDeviceName))")
                    DiagnosticsTrail.record(
                        logger: appState.logger,
                        engine: "dictation",
                        event: "dictation_started_after_wait",
                        message: "Dictation started after waiting for engine readiness",
                        context: dictationContext(
                            extra: [
                                "wait_ms": "\(waited)",
                                "audio_device": appState.sttRouter.inputDeviceName,
                                "start_attempts": "\(startAttempts)",
                                "readiness_refreshes": "\(readinessRefreshes)"
                            ]
                        )
                    )
                    AppSoundPlayer.shared.play(.dictationStart)
                    installSessionTimeout()
                    return
                }

                DiagnosticsTrail.record(
                    logger: appState.logger,
                    level: .warning,
                    engine: "dictation",
                    event: "dictation_recording_retry",
                    message: "Dictation microphone start failed; retrying",
                    context: dictationContext(
                        extra: [
                            "attempt": "\(startAttempts)",
                            "audio_device": appState.sttRouter.inputDeviceName,
                            "is_recovering": "\(appState.sttRouter.isRecovering)",
                            "format_ready": "\(appState.sttRouter.inputFormatReady)"
                        ]
                    )
                )
                if !appState.sttRouter.isRecovering {
                    await appState.sttRouter.refreshInputReadiness()
                    readinessRefreshes += 1
                    nextReadinessRefreshAt = CFAbsoluteTimeGetCurrent() + TranscriptedConstants.dictationReadinessRefreshInterval
                }
            }

            try? await Task.sleep(nanoseconds: TranscriptedConstants.dictationReadinessPollInterval)
        }

        guard isDictating, !Task.isCancelled else { return }

        let waited = Int(TranscriptedConstants.dictationRecoveryBudget * 1000)
        DiagnosticsTrail.record(
            logger: appState.logger,
            level: .error,
            engine: "dictation",
            event: "microphone_start_timeout",
            message: "Dictation recording failed to start within recovery budget",
            context: dictationContext(
                extra: [
                    "wait_ms": "\(waited)",
                    "audio_device": appState.sttRouter.inputDeviceName,
                    "is_recovering": "\(appState.sttRouter.isRecovering)",
                    "format_ready": "\(appState.sttRouter.inputFormatReady)",
                    "start_attempts": "\(startAttempts)",
                    "readiness_refreshes": "\(readinessRefreshes)",
                    "forced_readiness_recoveries": "\(forcedReadinessRecoveries)"
                ]
            )
        )
        trackDictationStartFailed("microphone_start_timeout")
        appState.runtimeDiagnostics.recordStall(
            kind: "dictation",
            stage: "microphone_start_timeout",
            durationSeconds: TranscriptedConstants.dictationRecoveryBudget,
            extra: [
                "format_ready": "\(appState.sttRouter.inputFormatReady)",
                "recovering": "\(appState.sttRouter.isRecovering)"
            ]
        )
        appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "microphone_start_timeout")
        isDictating = false
        overlayController.showError(
            microphoneTimeoutMessage(
                deviceName: appState.sttRouter.inputDeviceName,
                startAttempts: startAttempts,
                inputFormatReady: appState.sttRouter.inputFormatReady
            ),
            actionTitle: "Try Again",
            action: { [weak self] in
                guard let self else { return }
                self.startDictation(sourceApp: sourceApp, trigger: self.currentDictationTrigger)
            }
        )
    }

    private func presentMicrophonePermissionError(
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
        if !overlayController.isVisible {
            overlayController.showPanel(near: sourceApp, anchorRect: sessionAnchorRect)
        }
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
                            anchorRect: self.sessionAnchorRect
                        )
                    }
                case .denied, .restricted:
                    TranscriptedPermissionAccess.openSettings(for: .microphone)
                case .authorized:
                    self.startDictation(
                        sourceApp: sourceApp,
                        trigger: self.currentDictationTrigger,
                        anchorRect: self.sessionAnchorRect
                    )
                @unknown default:
                    TranscriptedPermissionAccess.openSettings(for: .microphone)
                }
            } : nil
        )
        isDictating = false
    }

    /// Stop dictation and paste — selected local STT batch transcription
    func stopDictationAndPaste(trigger: DictationTrigger = .unknown) {
        guard let (appState, overlayController) = readyState() else { return }
        DiagnosticsTrail.record(
            logger: appState.logger,
            engine: "dictation",
            event: "dictation_stop_requested",
            message: "Dictation stop requested",
            context: dictationContext(
                extra: [
                    "trigger": trigger.rawValue,
                    "overlay_state": overlayStateName(overlayController.state),
                    "stt_recording": "\(appState.sttRouter.isRecording)"
                ]
            )
        )
        guard isDictating else {
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
        }
        if overlayController.state == .loading && !appState.sttRouter.isRecording {
            cancelDictation()
            return
        }

        let canStopRecording = overlayController.state == .listening || appState.sttRouter.isRecording
        guard canStopRecording else {
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
        }
        sessionTimeoutTask?.cancel()
        sessionTimeoutTask = nil
        recordingStartRetryTask?.cancel()
        recordingStartRetryTask = nil

        streamingTask?.cancel()
        streamingTask = Task {
            appState.runtimeDiagnostics.recordSession(kind: "dictation", stage: "stop_requested")
            await appState.sttRouter.stopRecording()

            // Surface model warmup honestly instead of calling it "Transcribing"
            // before the local dictation model is actually ready.
            if !appState.sttRouter.isModelLoaded {
                appState.logger.log("DICTATION | waiting for voice model before transcribe…")
                self.updateLoadingOverlay(sourceApp: self.sessionSourceApp)
                for _ in 0..<TranscriptedConstants.modelLoadMaxIterations {
                    guard !Task.isCancelled else { return }
                    if appState.sttRouter.isModelLoaded { break }
                    self.updateLoadingOverlay(sourceApp: self.sessionSourceApp)
                    try? await Task.sleep(nanoseconds: TranscriptedConstants.modelLoadPollInterval)
                }
                guard appState.sttRouter.isModelLoaded else {
                    appState.logger.log("DICTATION | voice model failed to load for transcription")
                    overlayController.showError("Voice model failed to load")
                    isDictating = false
                    appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "model_unavailable")
                    return
                }
            }
            overlayController.state = .drafting
            appState.runtimeDiagnostics.recordSession(kind: "dictation", stage: "transcribing")
            let voiceText = await appState.sttRouter.transcribe()
            guard !Task.isCancelled else { return }

            guard let text = voiceText, !text.isEmpty else {
                appState.logger.log("DICTATION | no transcription, cancelling")
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "overlay",
                    event: "no_voice_input",
                    message: "Dictation transcription empty",
                    context: self.dictationContext(
                        extra: [
                            "duration_ms": "\(Int((CFAbsoluteTimeGetCurrent() - self.sessionStartTime) * 1000))",
                            "trigger": self.currentDictationTrigger.rawValue
                        ]
                    )
                )
                AnalyticsReporter.track(
                    "dictation_no_speech",
                    properties: self.dictationAnalyticsProperties(
                        extra: [
                            "duration_bucket": AnalyticsReporter.durationBucket(
                                seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime
                            ),
                            "trigger": currentDictationTrigger.rawValue,
                        ]
                    )
                )
                NotificationCenter.default.post(name: .dictationNoSpeechDetected, object: nil)
                AppSoundPlayer.shared.play(.noSpeech)
                overlayController.showNoSpeechAndDismiss()
                isDictating = false
                appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "no_speech")
                return
            }

            guard !Task.isCancelled else { return }
            appState.logger.log("DICTATION | pasting \(text.count) chars")
            lastCompletedText = text
            let pasteOutcome = self.pasteWithClipboardRestore(text)
            let autoSendOutcome = await self.performAutoEnterIfNeeded(
                text: text,
                delivery: pasteOutcome.delivery
            )
            let saveFailureMessage = self.persistDictationTranscript(text: text, delivery: pasteOutcome.delivery)
            let wordCount = text.split(whereSeparator: \.isWhitespace).count
            let deliveryLevel: EventLevel = pasteOutcome.delivery == .pasted ? .info : .warning
            DiagnosticsTrail.record(
                logger: appState.logger,
                level: deliveryLevel,
                engine: "dictation",
                event: "dictation_delivery_completed",
                message: pasteOutcome.diagnosticMessage,
                context: self.dictationContext(
                    extra: [
                        "trigger": self.currentDictationTrigger.rawValue,
                        "delivery": pasteOutcome.diagnosticName,
                        "auto_send": autoSendOutcome.diagnosticName,
                        "chars": "\(text.count)",
                        "words": "\(wordCount)",
                        "duration_ms": "\(Int((CFAbsoluteTimeGetCurrent() - self.sessionStartTime) * 1000))"
                    ]
                )
            )
            switch pasteOutcome {
            case .pasted:
                AppSoundPlayer.shared.play(.dictationDelivered)
                if let saveFailureMessage {
                    overlayController.showError(saveFailureMessage)
                } else {
                    overlayController.showSuccessAndDismiss()
                }
            case .copied(let message, reason: _), .failed(let message):
                let combinedMessage: String
                if let saveFailureMessage {
                    combinedMessage = "\(message) \(saveFailureMessage)"
                } else {
                    combinedMessage = message
                }
                overlayController.showError(combinedMessage)
            }
            isDictating = false
            appState.logger.log("DICTATION | completed with outcome \(pasteOutcome)")
            if case .failed(let message) = autoSendOutcome {
                appState.logger.log("DICTATION | auto enter failed: \(message)")
            }
            AnalyticsReporter.track(
                "dictation_completed",
                properties: self.dictationAnalyticsProperties(
                    extra: [
                        "delivery": pasteOutcome.delivery.rawValue,
                        "auto_send": autoSendOutcome.diagnosticName,
                        "duration_bucket": AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime),
                        "trigger": currentDictationTrigger.rawValue,
                        "word_count_bucket": AnalyticsReporter.wordCountBucket(wordCount),
                    ]
                )
            )
            appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "completed")
        }
    }

    /// Cancel dictation without pasting
    func cancelDictation() {
        guard let (appState, overlayController) = readyState() else { return }
        cancelActiveTasks(cancelRecording: true)
        AppSoundPlayer.shared.play(.dictationCancelled)
        overlayController.hideWithCancelAnimation()
        isDictating = false
        appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "cancelled")
        appState.logger.log("DICTATION | cancelled")
        DiagnosticsTrail.record(
            logger: appState.logger,
            level: .info,
            engine: "dictation",
            event: "dictation_cancelled",
            message: "Dictation cancelled",
            context: dictationContext(
                extra: [
                    "trigger": currentDictationTrigger.rawValue,
                    "duration_ms": "\(Int((CFAbsoluteTimeGetCurrent() - sessionStartTime) * 1000))"
                ]
            )
        )
        if currentDictationTrigger == .onboarding {
            NotificationCenter.default.post(name: .dictationNoSpeechDetected, object: nil)
        }
        AnalyticsReporter.track(
            "dictation_cancelled",
            properties: dictationAnalyticsProperties(
                extra: [
                    "duration_bucket": AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime),
                    "trigger": currentDictationTrigger.rawValue,
                ]
            )
        )
    }

    func finishDictationForTermination() async {
        if isInSession {
            cancelSession()
        }

        guard isDictating else { return }
        stopDictationAndPaste(trigger: .unknown)

        for _ in 0..<100 {
            if !isDictating { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        if isDictating {
            cancelDictation()
        }
    }

    // MARK: - Private

    private func startDictationAfterWarmup(sourceApp: NSRunningApplication?) {
        guard let appState = appState, let overlayController = overlayController else { return }

        startupTask?.cancel()
        updateLoadingOverlay(sourceApp: sourceApp)

        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }

            switch appState.sttRouter.modelDownloadState {
            case .notLoaded, .failed:
                await appState.sttRouter.initializeSelectedModel()
            case .downloading, .loading, .ready:
                break
            }

            for _ in 0..<TranscriptedConstants.modelLoadMaxIterations {
                guard !Task.isCancelled, self.isDictating else { return }

                let modelState = appState.sttRouter.modelDownloadState
                self.updateLoadingOverlay(sourceApp: sourceApp, modelState: modelState)

                switch modelState {
                case .ready:
                    self.startupTask = nil
                    guard self.isDictating else { return }
                    overlayController.state = .listening
                    self.resizePanelToCompact()
                    self.beginDictationRecording(sourceApp: sourceApp)
                    return
                case .failed(let message):
                    self.startupTask = nil
                    self.isDictating = false
                    appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "model_failed")
                    overlayController.showError(
                        "Dictation couldn't start: \(message)",
                        actionTitle: "Retry Dictation",
                        action: { [weak self] in
                            self?.startDictation(
                                sourceApp: sourceApp,
                                trigger: self?.currentDictationTrigger ?? .unknown,
                                anchorRect: self?.sessionAnchorRect
                            )
                        }
                    )
                    return
                default:
                    break
                }

                try? await Task.sleep(nanoseconds: TranscriptedConstants.modelLoadPollInterval)
            }

            guard !Task.isCancelled else { return }
            self.startupTask = nil
            self.isDictating = false
            appState.runtimeDiagnostics.recordStall(
                kind: "dictation",
                stage: "model_load_timeout",
                durationSeconds: Double(TranscriptedConstants.modelLoadMaxIterations)
                    * Double(TranscriptedConstants.modelLoadPollInterval) / 1_000_000_000
            )
            appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "model_load_timeout")
            overlayController.showError(
                "Dictation is still loading. Please try again in a moment.",
                actionTitle: "Retry Dictation",
                action: { [weak self] in
                    self?.startDictation(
                        sourceApp: sourceApp,
                        trigger: self?.currentDictationTrigger ?? .unknown,
                        anchorRect: self?.sessionAnchorRect
                    )
                }
            )
        }
    }

    private func updateLoadingOverlay(
        sourceApp: NSRunningApplication?,
        modelState: ParakeetModelState? = nil
    ) {
        guard let appState = appState else { return }
        let presentation = loadingPresentation(for: modelState ?? appState.sttRouter.modelDownloadState)
        overlayController?.showLoadingState(
            near: sourceApp,
            presentation: presentation,
            anchorRect: sessionAnchorRect
        )
    }

    private func loadingPresentation(for modelState: ParakeetModelState) -> FloatingOverlayController.LoadingPresentation {
        switch modelState {
        case .notLoaded:
            return .init(
                title: "Starting dictation",
                detail: "Transcripted is waking up the local voice model before it starts listening.",
                progress: 0.08,
                status: "Preparing local model"
            )
        case .downloading(let progress):
            return .init(
                title: "Downloading dictation model",
                detail: "Transcripted is downloading the on-device voice model needed for local dictation.",
                progress: max(0.12, min(0.84, 0.12 + progress * 0.72)),
                status: "\(Int(progress * 100))% complete"
            )
        case .loading:
            return .init(
                title: "Loading dictation",
                detail: "Transcripted has the model files and is loading them into memory. Recording starts automatically when it finishes.",
                progress: 0.92,
                status: "Almost ready"
            )
        case .ready:
            return .init(
                title: "Starting dictation",
                detail: "The local voice model is ready. Opening the microphone now.",
                progress: 1.0,
                status: "Starting microphone"
            )
        case .failed(let message):
            return .init(
                title: "Dictation couldn't start",
                detail: message,
                progress: 0,
                status: "Model load failed"
            )
        }
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
        let title = isRecovering || !inputFormatReady ? "Switching microphone" : "Starting microphone"
        let detail = isRecovering || !inputFormatReady
            ? "Connecting to the new audio device."
            : "Opening the selected audio input."
        let status: String?
        if startAttempts > 1 {
            status = "Retrying \(deviceName)"
        } else if elapsed > 1.5 {
            status = "Still connecting to \(deviceName)…"
        } else {
            status = nil
        }
        return .init(
            title: title,
            detail: detail,
            progress: progress,
            status: status
        )
    }

    private func microphonePermissionPresentation() -> FloatingOverlayController.LoadingPresentation {
        .init(
            title: "Allow microphone",
            detail: "Transcripted needs microphone access before dictation can listen.",
            progress: 0.16,
            status: "Waiting for macOS permission"
        )
    }

    private func microphoneTimeoutMessage(
        deviceName: String,
        startAttempts: Int,
        inputFormatReady: Bool
    ) -> String {
        if startAttempts > 0, inputFormatReady {
            return "Couldn't start the microphone. Try again, or choose a different input in System Settings."
        }
        return "Couldn't reach \(deviceName). Try selecting a different input in System Settings."
    }

    /// Shrink the panel to compact (header-only) height without animation.
    /// Called after loading → listening transition to undo showLoadingState()'s expansion.
    private func resizePanelToCompact() {
        overlayController?.resizePanelToCompact()
    }

    /// Install a timeout that auto-cancels the session after 5 minutes.
    /// Prevents stuck sessions if the user walks away from the computer.
    private func installSessionTimeout() {
        sessionTimeoutTask?.cancel()
        sessionTimeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.sessionTimeoutNanos)
            guard !Task.isCancelled, let self = self else { return }
            if self.isInSession {
                self.appState?.logger.log("SESSION | auto-cancelled after timeout")
                EventReporter.shared.capture(level: .warning, engine: "overlay", event: "session_timeout",
                    message: "Session auto-cancelled after 5 minutes")
                self.cancelSession()
            } else if self.isDictating {
                self.appState?.logger.log("DICTATION | auto-cancelled after timeout")
                EventReporter.shared.capture(level: .warning, engine: "overlay", event: "dictation_timeout",
                    message: "Dictation auto-cancelled after 5 minutes")
                self.cancelDictation()
            }
        }
    }

    private func overlayStateName(_ state: FloatingOverlayController.OverlayState) -> String {
        switch state {
        case .idle: return "idle"
        case .loading: return "loading"
        case .listening: return "listening"
        case .drafting: return "drafting"
        case .success: return "success"
        }
    }

    private func cancelActiveTasks(cancelRecording: Bool) {
        startupTask?.cancel()
        startupTask = nil
        streamingTask?.cancel()
        streamingTask = nil
        textPaster.cancelPendingClipboardRestore()
        recordingStartRetryTask?.cancel()
        recordingStartRetryTask = nil
        sessionTimeoutTask?.cancel()
        sessionTimeoutTask = nil

        guard cancelRecording, let appState, appState.sttRouter.isRecording else { return }
        appState.sttRouter.cancel()
    }

    private func handleDictationInterruption() {
        cancelActiveTasks(cancelRecording: true)
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
            "Recording was interrupted. Check your microphone or audio device, then try again.",
            actionTitle: "Retry Dictation",
            action: { [weak self] in
                self?.startDictation(
                    sourceApp: self?.sessionSourceApp,
                    trigger: self?.currentDictationTrigger ?? .unknown,
                    anchorRect: self?.sessionAnchorRect
                )
            }
        )
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

    private func pasteWithClipboardRestore(_ text: String) -> DictationPasteOutcome {
        let outcome = textPaster.paste(text)

        switch outcome.copyReason {
        case .accessibilityMissing:
            appState?.logger.log("DICTATION | Accessibility missing, copying text instead")
        case .pasteEventCreationFailed:
            EventReporter.shared.capture(level: .error, engine: "overlay", event: "cgevent_create_failed",
                message: "CGEvent creation returned nil — paste will not work")
            appState?.logger.log("DICTATION | CGEvent paste failed, keeping text on clipboard")
        case nil:
            break
        }

        return outcome
    }

    private func performAutoEnterIfNeeded(
        text: String,
        delivery: DictationDelivery
    ) async -> DictationAutoSendOutcome {
        let duration = CFAbsoluteTimeGetCurrent() - sessionStartTime
        guard DictationAutoSendPolicy.shouldSend(
            isEnabled: DictationAutoSendPreferences.isEnabled(),
            delivery: delivery,
            text: text,
            duration: duration,
            sourceBundleID: sessionSourceApp?.bundleIdentifier,
            allowedBundleIDs: DictationAutoSendPreferences.allowedBundleIDs()
        ) else {
            return .disabled
        }

        try? await Task.sleep(nanoseconds: TranscriptedConstants.dictationAutoEnterDelay)
        guard !Task.isCancelled else { return .disabled }
        return autoSender.send(DictationAutoSendPreferences.sendKey())
    }

    @discardableResult
    private func persistDictationTranscript(text: String, delivery: DictationDelivery) -> String? {
        do {
            let saved = try DictationTranscriptStore.save(
                text: text,
                sourceApp: sessionSourceApp,
                delivery: delivery
            )
            appState?.logger.log("DICTATION | saved markdown export at \(saved.url.lastPathComponent)")
            DiagnosticsTrail.record(
                logger: appState?.logger,
                engine: "dictation",
                event: "dictation_export_saved",
                message: "Saved dictation markdown export",
                context: dictationContext(
                    extra: [
                        "delivery": delivery.rawValue
                    ]
                )
            )
            return nil
        } catch {
            appState?.logger.log("DICTATION | failed to save markdown export: \(error.localizedDescription)")
            DiagnosticsTrail.record(
                logger: appState?.logger,
                level: .warning,
                engine: "dictation",
                event: "dictation_export_failed",
                message: "Failed to save dictation markdown export",
                context: dictationContext(extra: ["error": error.localizedDescription])
            )
            return "Transcripted couldn't save a local copy of this dictation. Check your save location and available disk space."
        }
    }

    private func dictationContext(extra: [String: String] = [:]) -> [String: String] {
        var context: [String: String] = [
            "audio_device": appState?.sttRouter.inputDeviceName ?? ""
        ]
        if let routeContext = appState?.sttRouter.dictationAudioRouteAnalyticsContext {
            for (key, value) in routeContext {
                context[key] = value
            }
        }

        for (key, value) in extra {
            context[key] = value
        }

        return context
    }

    private func dictationAnalyticsProperties(extra: [String: String] = [:]) -> [String: String] {
        var properties = appState?.sttRouter.dictationAudioRouteAnalyticsContext ?? [:]
        for (key, value) in extra {
            properties[key] = value
        }
        return properties
    }
}

private typealias DictationPasteOutcome = TextPasteOutcome

private extension TextPasteOutcome {
    var delivery: DictationDelivery {
        switch self {
        case .pasted:
            return .pasted
        case .copied:
            return .copied
        case .failed:
            return .failed
        }
    }
}

private extension AVAuthorizationStatus {
    var diagnosticName: String {
        switch self {
        case .notDetermined:
            return "not_determined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        @unknown default:
            return "unknown"
        }
    }
}
