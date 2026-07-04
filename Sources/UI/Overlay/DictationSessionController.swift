// DictationSessionController.swift
// Session orchestration for dictation mode.

import AppKit
import AVFoundation
import Combine

@MainActor
class DictationSessionController: ObservableObject {
    enum DictationTrigger: String {
        case rightOptionTap = "right_option_tap"
        case physicalKey = "physical_key"
        case keyboardShortcut = "keyboard_shortcut"
        case overlayButton = "overlay_button"
        case menu = "menu"
        case onboarding = "onboarding"
        case sessionCap = "session_cap"
        case unknown = "unknown"
    }

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
                guard let self else { return }
                guard self.isDictating else {
                    self.overlayController?.dismissError()
                    return
                }
                self.cancelDictation()
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
    private var sessionPasteTarget: DictationPasteTarget?
    private var sessionAnchorRect: NSRect?
    private var startupTask: Task<Void, Never>?
    private var streamingTask: Task<Void, Never>?
    private var recordingStartRetryTask: Task<Void, Never>?
    private var sessionTimeoutTask: Task<Void, Never>?
    private var sessionStartTime: CFAbsoluteTime = 0
    private var currentDictationTrigger: DictationTrigger = .unknown
    private var currentDictationSessionID = UUID()

    /// Max duration for a listening session before auto-cancel (5 minutes).
    /// Prevents stuck sessions when the user walks away from the computer.
    /// Derived from the shared constant so the speech engine's audio buffer
    /// sizing stays in lockstep with the cap.
    private static let sessionTimeoutNanos: UInt64 =
        UInt64(TranscriptedConstants.dictationSessionMaxDuration * 1_000_000_000)
    private static let sessionTimeoutInterval: TimeInterval =
        TranscriptedConstants.dictationSessionMaxDuration
    /// Cap on each polling sleep so a wake from system sleep gets a chance to
    /// re-evaluate the uptime-based deadline before firing the cancel branch.
    private static let sessionTimeoutPollIntervalNanos: UInt64 = 30 * 1_000_000_000

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
                guard let self = self, self.isDictating else { return }
                self.handleDictationInterruption()
            }
    }

    // MARK: - Dictation Mode (Option+Space)

    /// Start dictation — show overlay and begin voice recording (no screenshot/vision)
    func startDictation(
        sourceApp: NSRunningApplication?,
        trigger: DictationTrigger = .unknown,
        anchorRect: NSRect? = nil
    ) {
        let requestStartedAt = CFAbsoluteTimeGetCurrent()
        guard let (appState, overlayController) = readyState() else { return }
        guard !isDictating else { return }
        guard !appState.sttRouter.isTranscribing else {
            overlayController.showError("Still finishing the last dictation. Try again in a moment.")
            return
        }
        if let unavailableReason = dictationStartUnavailableReason(appState: appState) {
            overlayController.showError(unavailableReason)
            return
        }
        isDictating = true
        currentDictationSessionID = UUID()
        sessionSourceApp = sourceApp
        sessionPasteTarget = DictationPasteTarget.capture(sourceApp: sourceApp)
        sessionAnchorRect = anchorRect
        sessionStartTime = requestStartedAt
        currentDictationTrigger = trigger
        lastCompletedText = nil
        appState.runtimeDiagnostics.recordSession(kind: "dictation", stage: "start_requested")

        switch TranscriptedPermissionAccess.microphoneAuthorizationStatus() {
        case .authorized:
            recordDictationStarted(appState: appState, trigger: trigger)
            continueDictationStart(
                appState: appState,
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

    private func trackDictationStartFailed(
        _ failureKind: String,
        extra: [String: String] = [:]
    ) {
        var properties = extra
        properties["failure_kind"] = failureKind
        properties["trigger"] = currentDictationTrigger.rawValue

        let analyticsProperties = dictationAnalyticsProperties(extra: properties)
        AnalyticsReporter.track(
            "dictation_start_failed",
            properties: analyticsProperties
        )
        ProductFrictionTelemetry.track(
            surface: .dictation,
            stage: "dictation_start",
            result: .blocked,
            failureKind: failureKind,
            routeShape: analyticsProperties["route_shape"],
            modelState: ProductFrictionTelemetry.modelState(isReady: appState?.sttRouter.isModelLoaded)
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
        sourceApp: NSRunningApplication?
    ) {
        guard isDictating else { return }
        if appState.sttRouter.isModelLoaded {
            beginDictationRecording(sourceApp: sourceApp)
            return
        }

        if appState.sttRouter.selectedModelFilesAvailableLocally {
            // The model files are already on disk — open the microphone now
            // and load the model concurrently so the first dictation after
            // launch doesn't stare at "Loading voice model" before it can
            // listen. The stop path already waits for the model before
            // transcribing (and surfaces a load failure gracefully), so a
            // stop that beats the load is covered.
            //
            // Deliberately untracked: cancelling this dictation must not
            // abandon a model load the next session will need, and the
            // engine dedupes concurrent initialization internally.
            Task { @MainActor in
                await appState.sttRouter.initializeSelectedModel()
            }
            beginDictationRecording(sourceApp: sourceApp)
            return
        }

        startDictationAfterWarmup(sourceApp: sourceApp)
    }

    private func dictationStartUnavailableReason(appState: TranscriptedAppState) -> String? {
        guard #available(macOS 14.0, *) else { return nil }
        return DictationStartAvailabilityPolicy.unavailableReason(
            hasActiveMeetingCapture: appState.meetingSession.shouldBlockDictationForActiveMeetingCapture,
            isSpeakerReviewPending: appState.meetingSession.isSpeakerReviewPending
        )
    }

    /// Actually start dictation recording — called directly from startDictation
    private func beginDictationRecording(sourceApp: NSRunningApplication?) {
        guard let overlayController = overlayController else { return }
        guard isDictating else { return }

        guard let appState = appState else { return }

        switch DictationRecordingStartOverlayPolicy.plan(
            isRecovering: appState.sttRouter.isRecovering,
            inputFormatReady: appState.sttRouter.inputFormatReady
        ) {
        case .skipLoadingAndStartRecording:
            // Fast path — engine is ready right now. The actual CoreAudio start
            // still runs asynchronously so a slow device graph never blocks UI.
            overlayController.showStartingState(near: sourceApp, anchorRect: sessionAnchorRect)
            recordingStartRetryTask?.cancel()
            recordingStartRetryTask = Task { @MainActor [weak self] in
                guard let self,
                      self.isDictating,
                      let appState = self.appState,
                      let overlayController = self.overlayController else { return }
                let startAttemptedAt = CFAbsoluteTimeGetCurrent()
                let started = await appState.sttRouter.startRecording()
                let startMs = Int((CFAbsoluteTimeGetCurrent() - startAttemptedAt) * 1000)
                guard !Task.isCancelled, self.isDictating else {
                    if started {
                        await appState.sttRouter.stopRecording()
                    }
                    return
                }
                if started {
                    let requestToRecordingMs = Int((CFAbsoluteTimeGetCurrent() - self.sessionStartTime) * 1000)
                    self.recordingStartRetryTask = nil
                    overlayController.state = .listening
                    if !overlayController.isVisible {
                        overlayController.showPanel(near: sourceApp, anchorRect: self.sessionAnchorRect)
                    }
                    self.resizePanelToCompact()
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
                    AppSoundPlayer.shared.play(.dictationStart)
                    self.installSessionTimeout()
                } else {
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
                                "is_recovering": "\(appState.sttRouter.isRecovering)",
                                "format_ready": "\(appState.sttRouter.inputFormatReady)"
                            ]
                        )
                    )
                    await self.waitForEngineAndStart(sourceApp: sourceApp)
                }
            }
            return
        case .showLoadingWhileWaiting:
            // Slow path — engine is settling after a device change. Wait for it.
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

    private func waitForEngineAndStart(sourceApp: NSRunningApplication?) async {
        guard let appState = appState, let overlayController = overlayController else { return }
        guard isDictating else { return }

        // Permission check up front — no point waiting if the user denied mic access.
        let microphoneStatus = TranscriptedPermissionAccess.microphoneAuthorizationStatus()
        guard microphoneStatus == .authorized else {
            presentMicrophonePermissionError(microphoneStatus, sourceApp: sourceApp)
            return
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        let deadline = startedAt + TranscriptedConstants.dictationRecoveryBudget
        var startAttempts = 0
        var readyStartFailures = 0
        var recoveryStartAttempts = 0
        var readinessRefreshes = 0
        var forcedReadinessRecoveries = 0
        var readinessRefreshTimedOut = false
        var nextReadinessRefreshAt = startedAt
        let readinessRefresher = DictationReadinessRefreshRunner()
        defer {
            readinessRefresher.cancel()
        }

        if !appState.sttRouter.isRecovering, !appState.sttRouter.inputFormatReady {
            if readinessRefresher.start(appState: appState) {
                readinessRefreshes += 1
            }
            nextReadinessRefreshAt = ProcessInfo.processInfo.systemUptime + TranscriptedConstants.dictationReadinessRefreshInterval
        }

        while ProcessInfo.processInfo.systemUptime < deadline {
            guard isDictating, !Task.isCancelled else { return }

            let now = ProcessInfo.processInfo.systemUptime
            if let staleRefresh = readinessRefresher.cancelIfTimedOut(now: now) {
                readinessRefreshTimedOut = true
                DiagnosticsTrail.record(
                    logger: appState.logger,
                    level: .warning,
                    engine: "dictation",
                    event: "dictation_readiness_refresh_timeout",
                    message: "Dictation input-readiness refresh timed out while waiting to start",
                    context: dictationContext(
                        extra: [
                            "operation": staleRefresh.operation,
                            "elapsed_ms": "\(Int(staleRefresh.elapsed * 1000))",
                            "readiness_refreshes": "\(readinessRefreshes)",
                            "is_recovering": "\(appState.sttRouter.isRecovering)",
                            "format_ready": "\(appState.sttRouter.inputFormatReady)"
                        ]
                    )
                )
            }

            let elapsed = now - startedAt
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
                readyStartFailures: readyStartFailures,
                readinessRefreshes: readinessRefreshes,
                forcedRecoveryAttempts: forcedReadinessRecoveries,
                recoveryStartAttempts: recoveryStartAttempts,
                readinessRefreshTimedOut: readinessRefreshTimedOut
            ) {
            case .waitForRecovery:
                break

            case .refreshInputReadiness:
                if now >= nextReadinessRefreshAt {
                    if readinessRefresher.start(appState: appState) {
                        readinessRefreshes += 1
                    }
                    nextReadinessRefreshAt = ProcessInfo.processInfo.systemUptime + TranscriptedConstants.dictationReadinessRefreshInterval
                }

            case .forceInputRecovery:
                if readinessRefresher.startForcedRecovery(
                    appState: appState,
                    reason: "dictation_readiness_wait_stalled"
                ) {
                    forcedReadinessRecoveries += 1
                    readinessRefreshes = 0
                    nextReadinessRefreshAt = ProcessInfo.processInfo.systemUptime + TranscriptedConstants.dictationReadinessRefreshInterval
                }

            case .startRecoveryRecording:
                startAttempts += 1
                recoveryStartAttempts += 1
                readinessRefreshTimedOut = false
                DiagnosticsTrail.record(
                    logger: appState.logger,
                    level: .warning,
                    engine: "dictation",
                    event: "dictation_recording_recovery_start",
                    message: "Dictation forcing one recovery recording start after stale readiness refreshes",
                    context: dictationContext(
                        extra: [
                            "attempt": "\(startAttempts)",
                            "readiness_refreshes": "\(readinessRefreshes)",
                            "is_recovering": "\(appState.sttRouter.isRecovering)",
                            "format_ready": "\(appState.sttRouter.inputFormatReady)"
                        ]
                    )
                )
                let started = await appState.sttRouter.startRecordingRecoveryAttempt()
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
                    let waited = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
                    let requestToRecordingMs = Int((CFAbsoluteTimeGetCurrent() - sessionStartTime) * 1000)
                    appState.logger.log("DICTATION | started after forced recovery start and \(waited)ms wait (parakeet, \(appState.sttRouter.inputDeviceName))")
                    DiagnosticsTrail.record(
                        logger: appState.logger,
                        engine: "dictation",
                        event: "dictation_started_after_wait",
                        message: "Dictation started after forcing a recovery recording start",
                        context: dictationContext(
                            extra: [
                                "request_to_recording_ms": "\(requestToRecordingMs)",
                                "wait_ms": "\(waited)",
                                "start_attempts": "\(startAttempts)",
                                "readiness_refreshes": "\(readinessRefreshes)"
                            ]
                        )
                    )
                    AppSoundPlayer.shared.play(.dictationStart)
                    installSessionTimeout()
                    return
                }

                readinessRefreshes = 0
                if readinessRefresher.start(appState: appState) {
                    readinessRefreshes += 1
                }
                nextReadinessRefreshAt = ProcessInfo.processInfo.systemUptime + TranscriptedConstants.dictationReadinessRefreshInterval

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
                    let waited = Int((ProcessInfo.processInfo.systemUptime - startedAt) * 1000)
                    let requestToRecordingMs = Int((CFAbsoluteTimeGetCurrent() - sessionStartTime) * 1000)
                    appState.logger.log("DICTATION | started after \(waited)ms wait (parakeet, \(appState.sttRouter.inputDeviceName))")
                    DiagnosticsTrail.record(
                        logger: appState.logger,
                        engine: "dictation",
                        event: "dictation_started_after_wait",
                        message: "Dictation started after waiting for engine readiness",
                        context: dictationContext(
                            extra: [
                                "request_to_recording_ms": "\(requestToRecordingMs)",
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

                readyStartFailures += 1
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
                    if readinessRefresher.start(appState: appState) {
                        readinessRefreshes += 1
                    }
                    nextReadinessRefreshAt = ProcessInfo.processInfo.systemUptime + TranscriptedConstants.dictationReadinessRefreshInterval
                }
            }

            try? await Task.sleep(nanoseconds: TranscriptedConstants.dictationReadinessPollInterval)
        }

        guard isDictating, !Task.isCancelled else { return }
        readinessRefresher.cancel()

        let waited = Int(TranscriptedConstants.dictationRecoveryBudget * 1000)
        let cleanupPlan = DictationRecordingStartFailurePolicy.cleanupPlan(for: "microphone_start_timeout")
        if !cleanupPlan.reportBeforeCleanup {
            await finishFailedDictationStart(appState: appState, cleanupPlan: cleanupPlan)
        }
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
                    "failure_kind": "microphone_start_timeout",
                    "is_recovering": "\(appState.sttRouter.isRecovering)",
                    "format_ready": "\(appState.sttRouter.inputFormatReady)",
                    "start_attempts": "\(startAttempts)",
                    "readiness_refreshes": "\(readinessRefreshes)",
                    "recovery_start_attempts": "\(recoveryStartAttempts)",
                    "forced_readiness_recoveries": "\(forcedReadinessRecoveries)"
                ]
            )
        )
        trackDictationStartFailed(
            cleanupPlan.outcome,
            extra: [
                "start_attempt_bucket": AnalyticsReporter.countBucket(startAttempts)
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
                    "forced_readiness_recoveries": "\(forcedReadinessRecoveries)",
                    "readiness_refreshes": "\(readinessRefreshes)",
                    "recovering": "\(appState.sttRouter.isRecovering)",
                    "recovery_start_attempts": "\(recoveryStartAttempts)",
                    "start_attempts": "\(startAttempts)",
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
                startAttempts: startAttempts,
                inputFormatReady: appState.sttRouter.inputFormatReady,
                routeContext: appState.sttRouter.dictationAudioRouteAnalyticsContext
            ),
            actionTitle: "Try Again",
            action: { [weak self] in
                guard let self else { return }
                self.startDictation(sourceApp: sourceApp, trigger: self.currentDictationTrigger)
            }
        )
    }

    private func finishFailedDictationStart(
        appState: TranscriptedAppState,
        cleanupPlan: DictationRecordingStartFailureCleanupPlan
    ) async {
        recordingStartRetryTask = nil
        sessionTimeoutTask?.cancel()
        sessionTimeoutTask = nil
        if cleanupPlan.resetSpeechEngine {
            if cleanupPlan.hardResetSpeechEngine {
                appState.sttRouter.abandonBlockedRecordingStart(reason: cleanupPlan.outcome)
            } else {
                await appState.sttRouter.resetAfterFailedRecordingStart()
            }
        }
        appState.runtimeDiagnostics.clearSession(
            kind: "dictation",
            outcome: cleanupPlan.outcome,
            resetToIdle: cleanupPlan.resetRuntimeSessionToIdle
        )
        isDictating = false
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
                    overlayController.dismissError()
                    TranscriptedPermissionAccess.openSettings(for: .microphone)
                case .authorized:
                    self.startDictation(
                        sourceApp: sourceApp,
                        trigger: self.currentDictationTrigger,
                        anchorRect: self.sessionAnchorRect
                    )
                @unknown default:
                    overlayController.dismissError()
                    TranscriptedPermissionAccess.openSettings(for: .microphone)
                }
            } : nil
        )
        isDictating = false
    }

    /// Stop dictation and paste — selected local STT batch transcription.
    ///
    /// When `autoPaste` is `false` the transcript is still transcribed and saved
    /// to the daily Markdown file, but it is not pasted into the focused app and
    /// auto-send is suppressed. The 5-minute session cap uses this to recover a
    /// walked-away dictation instead of discarding it, without injecting text
    /// into whatever app now happens to hold focus.
    func stopDictationAndPaste(trigger: DictationTrigger = .unknown, autoPaste: Bool = true) {
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
        let stopDecision = DictationRecordingStartLifecyclePolicy.stopDecision(
            isLoadingOverlay: overlayController.state == .loading,
            isListeningOverlay: overlayController.state == .listening,
            hasStartupTask: startupTask != nil,
            hasRecordingStartTask: recordingStartRetryTask != nil,
            sttIsRecording: appState.sttRouter.isRecording
        )

        if stopDecision == .cancelPendingStart {
            if trigger == .physicalKey {
                cancelPendingDictationStartAfterEarlyRelease(appState: appState, overlayController: overlayController)
                return
            }
            cancelDictation()
            return
        }

        guard stopDecision == .stopRecording else {
            if overlayController.state == .drafting || appState.sttRouter.isTranscribing {
                overlayController.showError("Still finishing the last dictation. Try again in a moment.")
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
        }
        let hasRecoverableRecording = appState.sttRouter.hasRecoverableRecording
        guard appState.sttRouter.isRecording || hasRecoverableRecording else {
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
                    self.startDictation(sourceApp: self.sessionSourceApp, trigger: self.currentDictationTrigger)
                }
            )
            return
        }
        sessionTimeoutTask?.cancel()
        sessionTimeoutTask = nil
        recordingStartRetryTask?.cancel()
        recordingStartRetryTask = nil

        streamingTask?.cancel()
        let taskSessionID = currentDictationSessionID
        streamingTask = Task {
            var stopTiming = DictationStopTiming(requestedAt: stopRequestedAt)
            appState.runtimeDiagnostics.recordSession(kind: "dictation", stage: "stop_requested")
            if appState.sttRouter.isRecording || appState.sttRouter.hasRecoverableRecording {
                await appState.sttRouter.stopRecording()
            }
            stopTiming.micStoppedAt = CFAbsoluteTimeGetCurrent()
            guard !Task.isCancelled,
                  self.isDictating,
                  self.currentDictationSessionID == taskSessionID else { return }

            // Surface model warmup honestly instead of calling it "Transcribing"
            // before the local dictation model is actually ready.
            if !appState.sttRouter.isModelLoaded {
                stopTiming.modelWaitStartedAt = CFAbsoluteTimeGetCurrent()
                appState.logger.log("DICTATION | waiting for voice model before transcribe…")
                self.updateLoadingOverlay(sourceApp: self.sessionSourceApp, phase: .afterRecording)
                let modelWaitDeadline = ProcessInfo.processInfo.systemUptime
                    + TranscriptedConstants.modelLoadWaitBudget
                modelWait: while !appState.sttRouter.isModelLoaded,
                    ProcessInfo.processInfo.systemUptime < modelWaitDeadline {
                    guard !Task.isCancelled,
                          self.isDictating,
                          self.currentDictationSessionID == taskSessionID else { return }
                    self.updateLoadingOverlay(sourceApp: self.sessionSourceApp, phase: .afterRecording)
                    switch appState.sttRouter.modelDownloadState {
                    case .failed:
                        // The concurrent load already failed — surface the
                        // error now instead of waiting out the full budget.
                        break modelWait
                    case .notLoaded, .cached:
                        // Nothing is loading the model; kick (or join) the
                        // deduped initialization instead of waiting for
                        // another caller to do it.
                        let stateBefore = appState.sttRouter.modelDownloadState.diagnosticName
                        await appState.sttRouter.initializeSelectedModel()
                        // If initialization bailed without progressing (e.g.
                        // mid-shutdown), sleep so this loop can't spin hot.
                        if appState.sttRouter.modelDownloadState.diagnosticName == stateBefore {
                            try? await Task.sleep(nanoseconds: TranscriptedConstants.modelLoadPollInterval)
                        }
                    case .downloading, .loading, .ready:
                        await appState.sttRouter.waitForModelLoadProgress()
                    }
                }
                guard self.isDictating,
                      self.currentDictationSessionID == taskSessionID else { return }
                guard appState.sttRouter.isModelLoaded else {
                    appState.logger.log("DICTATION | voice model failed to load for transcription")
                    overlayController.showError("The voice model didn't load. Please try dictating again in a moment.")
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
                stopTiming.modelReadyAt = CFAbsoluteTimeGetCurrent()
            } else {
                stopTiming.modelWaitStartedAt = stopTiming.micStoppedAt
                stopTiming.modelReadyAt = stopTiming.micStoppedAt
            }
            overlayController.state = .drafting
            overlayController.resizePanelToCompact()
            appState.runtimeDiagnostics.recordSession(kind: "dictation", stage: "transcribing")
            stopTiming.transcriptionStartedAt = CFAbsoluteTimeGetCurrent()
            let voiceText = await appState.sttRouter.transcribe()
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
                ProductFrictionTelemetry.track(
                    surface: .dictation,
                    stage: "dictation_transcribe",
                    result: .giveUp,
                    failureKind: "no_speech",
                    elapsedBucket: AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime),
                    routeShape: self.dictationAnalyticsProperties()["route_shape"],
                    modelState: ProductFrictionTelemetry.modelState(isReady: appState.sttRouter.isModelLoaded)
                )
                NotificationCenter.default.post(name: .dictationNoSpeechDetected, object: nil)
                AppSoundPlayer.shared.play(.noSpeech)
                overlayController.showNoSpeechAndDismiss(trigger: currentDictationTrigger.rawValue)
                isDictating = false
                appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "no_speech")
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
                self.finalizeWithoutPaste(
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
            let pasteOutcome = self.pasteWithClipboardRestore(text)
            stopTiming.pastedAt = CFAbsoluteTimeGetCurrent()
            let finalization = await DictationStopFinalizer.finalize(
                order: DictationStopFinalizationPolicy.order,
                startSaving: {
                    stopTiming.saveStartedAt = CFAbsoluteTimeGetCurrent()
                    return self.startPersistingDictationTranscript(
                        text: text,
                        delivery: pasteOutcome.delivery
                    )
                },
                finishSaving: { saveTask in
                    let failure = await self.finishPersistingDictationTranscript(
                        saveTask,
                        delivery: pasteOutcome.delivery
                    )
                    stopTiming.savedAt = CFAbsoluteTimeGetCurrent()
                    return failure
                },
                saveSynchronously: {
                    stopTiming.saveStartedAt = CFAbsoluteTimeGetCurrent()
                    let failure = self.persistDictationTranscript(text: text, delivery: pasteOutcome.delivery)
                    stopTiming.savedAt = CFAbsoluteTimeGetCurrent()
                    return failure
                },
                performAutoEnter: {
                    stopTiming.autoEnterStartedAt = CFAbsoluteTimeGetCurrent()
                    let outcome = await self.performAutoEnterIfNeeded(
                        text: text,
                        delivery: pasteOutcome.delivery
                    )
                    stopTiming.autoEnterFinishedAt = CFAbsoluteTimeGetCurrent()
                    return outcome
                }
            )
            let autoSendOutcome = finalization.autoEnterOutcome
            let saveFailureMessage = finalization.saveFailure
            let wordCount = text.split(whereSeparator: \.isWhitespace).count
            stopTiming.completedAt = CFAbsoluteTimeGetCurrent()
            let deliveryLevel: EventLevel = pasteOutcome.delivery == .pasted ? .info : .warning
            DiagnosticsTrail.record(
                logger: appState.logger,
                level: deliveryLevel,
                engine: "dictation",
                event: "dictation_delivery_completed",
                message: pasteOutcome.diagnosticMessage,
                context: self.dictationContext(
                    extra: [
                        "dictation_session_id": taskSessionID.uuidString,
                        "trigger": self.currentDictationTrigger.rawValue,
                        "delivery": pasteOutcome.diagnosticName,
                        "auto_send": autoSendOutcome.diagnosticName,
                        "chars": "\(text.count)",
                        "words": "\(wordCount)",
                        "duration_ms": "\(Int((CFAbsoluteTimeGetCurrent() - self.sessionStartTime) * 1000))"
                    ]
                )
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
            switch pasteOutcome {
            case .pasted:
                AppSoundPlayer.shared.play(.dictationDelivered)
                if let saveFailureMessage {
                    overlayController.showError(saveFailureMessage)
                } else if case .failed(let message) = autoSendOutcome {
                    overlayController.showError("Text pasted, but Auto Enter didn't run. \(message)")
                } else {
                    overlayController.showSuccessAndDismiss(title: autoSendOutcome.confirmationTitle ?? "Pasted")
                }
            case .copied(let message, reason: _):
                if let saveFailureMessage {
                    overlayController.showError("\(message) \(saveFailureMessage)")
                } else {
                    // The text is safe on the clipboard — present it as a calm
                    // "press ⌘V" notice, not a warning-triangle error.
                    overlayController.showClipboardNotice(message)
                }
            case .failed(let message):
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
            if saveFailureMessage == nil {
                ActivationTelemetry.trackDictationArtifactSaved(
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

    /// Finalize a dictation by saving it to the daily Markdown file without
    /// pasting into the focused app or auto-sending. Used by the 5-minute
    /// session cap so a walked-away session is recovered instead of discarded.
    private func finalizeWithoutPaste(
        text: String,
        appState: TranscriptedAppState,
        overlayController: FloatingOverlayController,
        sessionID: UUID
    ) {
        lastCompletedText = text
        let saveFailureMessage = persistDictationTranscript(text: text, delivery: .savedWithoutPaste)
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        let durationSeconds = CFAbsoluteTimeGetCurrent() - sessionStartTime
        appState.logger.log("DICTATION | session cap reached, saved \(text.count) chars without pasting")
        DiagnosticsTrail.record(
            logger: appState.logger,
            level: saveFailureMessage == nil ? .info : .warning,
            engine: "dictation",
            event: "dictation_session_cap_saved",
            message: saveFailureMessage == nil
                ? "Dictation auto-saved at session cap without pasting"
                : "Dictation session cap save failed",
            context: dictationContext(
                extra: [
                    "dictation_session_id": sessionID.uuidString,
                    "trigger": currentDictationTrigger.rawValue,
                    "chars": "\(text.count)",
                    "words": "\(wordCount)",
                    "duration_ms": "\(Int(durationSeconds * 1000))",
                    "save_failed": "\(saveFailureMessage != nil)"
                ]
            )
        )
        AnalyticsReporter.track(
            "dictation_completed",
            properties: dictationAnalyticsProperties(
                extra: [
                    "delivery": DictationDelivery.savedWithoutPaste.rawValue,
                    "auto_send": "disabled",
                    "duration_bucket": AnalyticsReporter.durationBucket(seconds: durationSeconds),
                    "trigger": currentDictationTrigger.rawValue,
                    "word_count_bucket": AnalyticsReporter.wordCountBucket(wordCount),
                ]
            )
        )
        if let saveFailureMessage {
            overlayController.showError(saveFailureMessage)
        } else {
            overlayController.showError(
                "Saved to Markdown. Paste it now, or use Paste Last Dictation later.",
                actionTitle: "Paste It",
                action: { [weak self] in
                    guard let self else { return }
                    let outcome = self.pasteWithClipboardRestore(text)
                    switch outcome {
                    case .pasted:
                        overlayController.showSuccessAndDismiss(title: "Pasted")
                    case .copied(let message, reason: _), .failed(let message):
                        overlayController.showError(message)
                    }
                }
            )
            ActivationTelemetry.trackDictationArtifactSaved(
                delivery: DictationDelivery.savedWithoutPaste.rawValue,
                durationBucket: AnalyticsReporter.durationBucket(seconds: durationSeconds),
                trigger: currentDictationTrigger.rawValue,
                wordCountBucket: AnalyticsReporter.wordCountBucket(wordCount)
            )
            ActivationTelemetry.trackFirstArtifactSavedIfNeeded(
                artifactKind: .dictation,
                surface: .dictationSave,
                trigger: currentDictationTrigger.rawValue,
                wordCountBucket: AnalyticsReporter.wordCountBucket(wordCount),
                durationBucket: AnalyticsReporter.durationBucket(seconds: durationSeconds)
            )
        }
        isDictating = false
        appState.runtimeDiagnostics.clearSession(
            kind: "dictation",
            outcome: saveFailureMessage == nil ? "session_cap_saved" : "session_cap_save_failed"
        )
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
        ProductFrictionTelemetry.track(
            surface: .dictation,
            stage: "dictation_recording",
            result: .cancelled,
            failureKind: "user_cancelled",
            elapsedBucket: AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime),
            routeShape: dictationAnalyticsProperties()["route_shape"],
            modelState: ProductFrictionTelemetry.modelState(isReady: appState.sttRouter.isModelLoaded)
        )
    }

    func finishDictationForTermination() async {
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
        overlayController.showMiniCursorStartingStateIfNeeded(
            near: sourceApp,
            anchorRect: sessionAnchorRect
        )
        updateLoadingOverlay(sourceApp: sourceApp)

        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }

            if case .failed = appState.sttRouter.modelDownloadState {
                // A previous attempt failed; retry once before the wait loop
                // treats .failed as terminal.
                await appState.sttRouter.initializeSelectedModel()
            }

            let deadline = ProcessInfo.processInfo.systemUptime
                + TranscriptedConstants.modelLoadWaitBudget
            while ProcessInfo.processInfo.systemUptime < deadline {
                guard !Task.isCancelled, self.isDictating else { return }

                let modelState = appState.sttRouter.modelDownloadState
                self.updateLoadingOverlay(sourceApp: sourceApp, modelState: modelState)

                switch modelState {
                case .ready:
                    self.startupTask = nil
                    guard self.isDictating else { return }
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
                case .notLoaded, .cached:
                    let stateBefore = appState.sttRouter.modelDownloadState.diagnosticName
                    await appState.sttRouter.initializeSelectedModel()
                    // If initialization bailed without progressing (e.g.
                    // mid-shutdown), sleep so this loop can't spin hot.
                    if appState.sttRouter.modelDownloadState.diagnosticName == stateBefore {
                        try? await Task.sleep(nanoseconds: TranscriptedConstants.modelLoadPollInterval)
                    }
                case .downloading, .loading:
                    // Downloads publish progress the overlay refreshes on a
                    // short poll; an in-flight load is joined directly so
                    // recording starts the moment it settles.
                    await appState.sttRouter.waitForModelLoadProgress()
                }
            }

            guard !Task.isCancelled else { return }
            self.startupTask = nil
            self.isDictating = false
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
                        anchorRect: self?.sessionAnchorRect
                    )
                }
            )
        }
    }

    private func updateLoadingOverlay(
        sourceApp: NSRunningApplication?,
        modelState: ParakeetModelState? = nil,
        phase: DictationWarmupPresentationPolicy.Phase = .beforeRecording
    ) {
        guard let appState = appState else { return }
        let presentation = loadingPresentation(
            for: modelState ?? appState.sttRouter.modelDownloadState,
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
            modelState: warmupModelState(for: modelState),
            phase: phase
        )
        return .init(
            title: copy.title,
            detail: copy.detail,
            progress: copy.progress,
            status: copy.status
        )
    }

    private func warmupModelState(for modelState: ParakeetModelState) -> DictationWarmupPresentationPolicy.ModelState {
        switch modelState {
        case .notLoaded:
            return .notLoaded
        case .downloading(let progress):
            return .downloading(progress: progress)
        case .cached:
            return .cached
        case .loading:
            return .loading
        case .ready:
            return .ready
        case .failed(let message):
            return .failed(message)
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
    private func resizePanelToCompact() {
        overlayController?.resizePanelToCompact()
    }

    /// Install a timeout that auto-cancels the session after 5 minutes of
    /// *active* uptime. Tracks the deadline against `ProcessInfo.systemUptime`
    /// so Mac sleep does not consume the session's remaining record window —
    /// otherwise a session that sees the Mac sleep for hours would auto-cancel
    /// immediately on wake when Task.sleep's wall-clock deadline expires.
    private func installSessionTimeout() {
        sessionTimeoutTask?.cancel()
        var timeout = DictationSessionTimeout(timeoutInterval: Self.sessionTimeoutInterval)
        timeout.start(at: ProcessInfo.processInfo.systemUptime)
        sessionTimeoutTask = Task { [weak self] in
            var didWarnSessionCap = false
            while !Task.isCancelled {
                let now = ProcessInfo.processInfo.systemUptime
                if timeout.isExpired(at: now) { break }
                let remainingSeconds = timeout.remaining(at: now) ?? 0
                if !didWarnSessionCap, remainingSeconds <= 30 {
                    didWarnSessionCap = true
                    self?.overlayController?.showLoadingState(
                        near: self?.sessionSourceApp,
                        presentation: .init(
                            title: "Long dictation",
                            detail: "Wrapping up soon. Release the key to finish now.",
                            progress: 0.94,
                            status: "30 seconds left"
                        ),
                        anchorRect: self?.sessionAnchorRect
                    )
                }
                let remainingNanos = UInt64((remainingSeconds * 1_000_000_000).rounded(.up))
                let sleepNanos = min(remainingNanos, Self.sessionTimeoutPollIntervalNanos)
                if sleepNanos == 0 { break }
                try? await Task.sleep(nanoseconds: sleepNanos)
            }
            guard !Task.isCancelled, let self = self else { return }
            if self.isDictating {
                let shouldAutoPaste = self.sessionPasteTarget?.matchesCurrentFrontmostApp() ?? false
                self.appState?.logger.log(
                    shouldAutoPaste
                        ? "DICTATION | session cap reached, finalizing with original paste target still active"
                        : "DICTATION | session cap reached, finalizing without paste"
                )
                EventReporter.shared.capture(level: .info, engine: "overlay", event: "dictation_timeout",
                    message: shouldAutoPaste
                        ? "Dictation reached the 5-minute cap; pasting because the original target is still active"
                        : "Dictation reached the 5-minute cap; saving without paste")
                self.stopDictationAndPaste(trigger: .sessionCap, autoPaste: shouldAutoPaste)
            }
        }
    }

    private func cancelPendingDictationStartAfterEarlyRelease(
        appState: TranscriptedAppState,
        overlayController: FloatingOverlayController
    ) {
        cancelActiveTasks(cancelRecording: true)
        AppSoundPlayer.shared.play(.dictationCancelled)
        isDictating = false
        appState.runtimeDiagnostics.clearSession(kind: "dictation", outcome: "microphone_not_ready")
        DiagnosticsTrail.record(
            logger: appState.logger,
            level: .info,
            engine: "dictation",
            event: "dictation_cancelled_before_microphone_ready",
            message: "Push-to-talk release cancelled before microphone capture started",
            context: dictationContext(
                extra: [
                    "trigger": currentDictationTrigger.rawValue,
                    "duration_ms": "\(Int((CFAbsoluteTimeGetCurrent() - sessionStartTime) * 1000))"
                ]
            )
        )
        overlayController.showError("Mic wasn't ready yet. Nothing was recorded. Try again.")
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

    private func cancelActiveTasks(cancelRecording: Bool) {
        let recordingStartWasInFlight = recordingStartRetryTask != nil
        let sttIsRecording = appState?.sttRouter.isRecording ?? false
        let sttIsTranscribing = appState?.sttRouter.isTranscribing ?? false
        let cancellationPlan = DictationActiveTaskCancellationPolicy.plan(
            cancelRecording: cancelRecording,
            recordingStartWasInFlight: recordingStartWasInFlight,
            sttIsRecording: sttIsRecording,
            sttIsTranscribing: sttIsTranscribing
        )

        startupTask?.cancel()
        startupTask = nil
        if cancellationPlan.cancelStreamingTask {
            streamingTask?.cancel()
            streamingTask = nil
        }
        textPaster.restorePendingClipboardNow()
        recordingStartRetryTask?.cancel()
        recordingStartRetryTask = nil
        sessionTimeoutTask?.cancel()
        sessionTimeoutTask = nil

        guard cancellationPlan.cancelSpeechEngine,
              let appState else { return }
        appState.sttRouter.cancel()
    }

    private func handleDictationInterruption() {
        let hasRecoverableRecording = appState?.sttRouter.hasRecoverableRecording ?? false
        cancelActiveTasks(cancelRecording: !hasRecoverableRecording)
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
            hasRecoverableRecording
                ? "Recording was interrupted. Transcripted kept the audio captured so far."
                : "Recording was interrupted. Check your microphone or audio device, then try again.",
            actionTitle: hasRecoverableRecording ? "Transcribe Captured Audio" : "Retry Dictation",
            action: { [weak self] in
                guard let self else { return }
                if hasRecoverableRecording {
                    self.isDictating = true
                    self.overlayController?.state = .listening
                    self.stopDictationAndPaste(trigger: .unknown, autoPaste: false)
                } else {
                    self.startDictation(
                        sourceApp: self.sessionSourceApp,
                        trigger: self.currentDictationTrigger,
                        anchorRect: self.sessionAnchorRect
                    )
                }
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
        let outcome = textPaster.paste(text, target: sessionPasteTarget)

        switch outcome.copyReason {
        case .accessibilityMissing:
            appState?.logger.log("DICTATION | Accessibility missing, copying text instead")
        case .pasteEventCreationFailed:
            EventReporter.shared.capture(level: .error, engine: "overlay", event: "cgevent_create_failed",
                message: "CGEvent creation returned nil — paste will not work")
            appState?.logger.log("DICTATION | CGEvent paste failed, keeping text on clipboard")
        case .focusChanged:
            EventReporter.shared.capture(level: .warning, engine: "overlay", event: "dictation_paste_target_changed",
                message: "Focus changed before dictation paste")
            appState?.logger.log("DICTATION | focus changed, copying text instead")
        case .pasteNotConfirmed:
            EventReporter.shared.capture(level: .warning, engine: "overlay", event: "dictation_paste_not_confirmed",
                message: "Paste-back was dispatched but the target did not confirm reading the borrowed clipboard")
            appState?.logger.log("DICTATION | paste not confirmed, keeping text on clipboard")
        case .pasteConfirmationUnavailable:
            EventReporter.shared.capture(level: .warning, engine: "overlay", event: "dictation_paste_confirmation_unavailable",
                message: "Paste-back was dispatched but the target did not expose confirmation")
            appState?.logger.log("DICTATION | paste confirmation unavailable, keeping text on clipboard")
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
        if delivery == .pasted {
            await textPaster.waitForClipboardReadyForAutoEnter()
        }
        guard !Task.isCancelled else { return .disabled }
        return autoSender.send(DictationAutoSendPreferences.sendKey(), target: sessionPasteTarget)
    }

    @discardableResult
    private func persistDictationTranscript(text: String, delivery: DictationDelivery) -> String? {
        do {
            let saved = try DictationTranscriptStore.save(
                text: text,
                sourceApp: sessionSourceApp,
                delivery: delivery
            )
            recordDictationTranscriptSaved(saved, delivery: delivery)
            return nil
        } catch {
            return recordDictationTranscriptSaveFailed(error)
        }
    }

    private func startPersistingDictationTranscript(
        text: String,
        delivery: DictationDelivery
    ) -> Task<Result<SavedDictationTranscript, Error>, Never> {
        let sourceAppName = sessionSourceApp?.localizedName ?? "Unknown"
        let sourceBundleID = sessionSourceApp?.bundleIdentifier

        return Task.detached(priority: .utility) {
            Result {
                try DictationTranscriptWriter.save(
                    text: text,
                    sourceAppName: sourceAppName,
                    sourceBundleID: sourceBundleID,
                    delivery: delivery
                )
            }
        }
    }

    private func finishPersistingDictationTranscript(
        _ task: Task<Result<SavedDictationTranscript, Error>, Never>,
        delivery: DictationDelivery
    ) async -> String? {
        switch await task.value {
        case .success(let saved):
            NotificationCenter.default.post(name: .dictationTranscriptDidSave, object: saved.url)
            recordDictationTranscriptSaved(saved, delivery: delivery)
            return nil
        case .failure(let error):
            return recordDictationTranscriptSaveFailed(error)
        }
    }

    private func recordDictationTranscriptSaved(
        _ saved: SavedDictationTranscript,
        delivery: DictationDelivery
    ) {
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
    }

    private func trackOnboardingFirstDictationSavedIfNeeded(
        delivery: DictationDelivery,
        wordCount: Int
    ) {
        guard PermissionsOnboardingPreferences.markFirstDictationSavedTrackedIfNeeded() else { return }

        AnalyticsReporter.track(
            "onboarding_first_dictation_saved",
            properties: [
                "delivery": delivery.rawValue,
                "step_id": "dictation_test",
                "word_count_bucket": AnalyticsReporter.wordCountBucket(wordCount),
            ]
        )
    }

    private func recordDictationTranscriptSaveFailed(_ error: Error) -> String {
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

    private func trackDictationDeliveryFriction(
        pasteOutcome: DictationPasteOutcome,
        saveSucceeded: Bool,
        elapsedSeconds: Double
    ) {
        if pasteOutcome.delivery == .failed {
            ProductFrictionTelemetry.track(
                surface: .dictation,
                stage: "pasteback",
                result: .failed,
                failureKind: "pasteback_failed",
                elapsedBucket: AnalyticsReporter.durationBucket(seconds: elapsedSeconds),
                routeShape: dictationAnalyticsProperties()["route_shape"],
                modelState: ProductFrictionTelemetry.modelState(isReady: appState?.sttRouter.isModelLoaded)
            )
        } else if let copyReason = pasteOutcome.copyReason {
            ProductFrictionTelemetry.track(
                surface: .dictation,
                stage: "pasteback",
                result: .fallback,
                failureKind: "pasteback_\(copyReason.diagnosticName)",
                elapsedBucket: AnalyticsReporter.durationBucket(seconds: elapsedSeconds),
                routeShape: dictationAnalyticsProperties()["route_shape"],
                modelState: ProductFrictionTelemetry.modelState(isReady: appState?.sttRouter.isModelLoaded)
            )
        }

        guard !saveSucceeded else { return }
        ProductFrictionTelemetry.track(
            surface: .dictation,
            stage: "artifact_save",
            result: .failed,
            failureKind: "dictation_save_failed",
            elapsedBucket: AnalyticsReporter.durationBucket(seconds: elapsedSeconds),
            routeShape: dictationAnalyticsProperties()["route_shape"],
            modelState: ProductFrictionTelemetry.modelState(isReady: appState?.sttRouter.isModelLoaded)
        )
    }

    private func recordDictationStopLatency(
        appState: TranscriptedAppState,
        timing: DictationStopTiming,
        sessionID: UUID,
        stopTrigger: DictationTrigger,
        startTrigger: DictationTrigger,
        pasteOutcome: DictationPasteOutcome,
        autoSendOutcome: DictationAutoSendOutcome,
        wordCount: Int,
        charCount: Int,
        cleanupEnabled: Bool,
        cleanupChanged: Bool,
        saveSucceeded: Bool
    ) {
        let measurements = timing.measurements()
        let saveOutcome = saveSucceeded ? "saved" : "failed"
        let outcome: String
        if !saveSucceeded {
            outcome = "save_failed"
        } else if pasteOutcome.delivery == .failed {
            outcome = "delivery_failed"
        } else {
            outcome = "completed"
        }

        var localContext: [String: String] = [
            "dictation_session_id": sessionID.uuidString,
            "start_trigger": startTrigger.rawValue,
            "stop_trigger": stopTrigger.rawValue,
            "delivery": pasteOutcome.diagnosticName,
            "auto_send": autoSendOutcome.diagnosticName,
            "save_outcome": saveOutcome,
            "outcome": outcome,
            "cleanup_enabled": "\(cleanupEnabled)",
            "cleanup_changed": "\(cleanupChanged)",
            "chars": "\(charCount)",
            "words": "\(wordCount)",
        ]
        if let copyReason = pasteOutcome.copyReason?.diagnosticName {
            localContext["copy_reason"] = copyReason
        }
        for (key, value) in measurements {
            localContext[key] = "\(value)"
        }

        DiagnosticsTrail.record(
            logger: appState.logger,
            level: pasteOutcome.delivery == .pasted && saveSucceeded ? .info : .warning,
            engine: "dictation",
            event: "dictation_stop_latency_measured",
            message: "Measured dictation stop latency",
            context: dictationContext(extra: localContext)
        )

        var analyticsProperties = dictationAnalyticsProperties(
            extra: [
                "trigger": stopTrigger.rawValue,
                "delivery": pasteOutcome.delivery.rawValue,
                "auto_send": autoSendOutcome.diagnosticName,
                "save_outcome": saveOutcome,
                "outcome": outcome,
                "cleanup_enabled": "\(cleanupEnabled)",
                "cleanup_changed": "\(cleanupChanged)",
                "word_count_bucket": AnalyticsReporter.wordCountBucket(wordCount),
            ]
        )
        if let copyReason = pasteOutcome.copyReason?.diagnosticName {
            analyticsProperties["copy_reason"] = copyReason
        }
        let timingBuckets: [(metric: String, bucket: String)] = [
            ("stop_to_mic_stop_ms", "mic_stop_bucket"),
            ("model_wait_ms", "model_wait_bucket"),
            ("decode_ms", "decode_bucket"),
            ("cleanup_ms", "cleanup_bucket"),
            ("paste_ms", "paste_bucket"),
            ("auto_enter_ms", "auto_enter_bucket"),
            ("save_ms", "save_bucket"),
            ("stop_to_paste_ms", "stop_to_paste_bucket"),
            ("stop_to_done_ms", "stop_to_done_bucket"),
        ]
        for timingBucket in timingBuckets {
            guard let milliseconds = measurements[timingBucket.metric] else { continue }
            analyticsProperties[timingBucket.bucket] = AnalyticsReporter.latencyBucket(milliseconds: milliseconds)
        }

        AnalyticsReporter.track(
            "dictation_stop_latency_measured",
            properties: analyticsProperties
        )
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

@MainActor
private final class DictationReadinessRefreshRunner {
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var operation: String?
    private var startedAt: TimeInterval?

    func start(appState: TranscriptedAppState) -> Bool {
        start(operation: "refresh_input_readiness") {
            await appState.sttRouter.refreshInputReadiness()
        }
    }

    func startForcedRecovery(appState: TranscriptedAppState, reason: String) -> Bool {
        if task != nil, operation != "force_input_recovery" {
            cancel()
        }
        return start(operation: "force_input_recovery") {
            await appState.sttRouter.forceInputReadinessRecovery(reason: reason)
        }
    }

    func cancelIfTimedOut(now: TimeInterval) -> DictationReadinessRefreshTimeout? {
        guard task != nil,
              DictationReadinessRefreshTimeoutPolicy.timedOut(startedAt: startedAt, now: now) else {
            return nil
        }

        let stale = DictationReadinessRefreshTimeout(
            operation: operation ?? "unknown",
            elapsed: now - (startedAt ?? now)
        )
        generation &+= 1
        task?.cancel()
        task = nil
        operation = nil
        startedAt = nil
        return stale
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        operation = nil
        startedAt = nil
    }

    private func start(
        operation operationName: String,
        _ body: @escaping @MainActor () async -> Void
    ) -> Bool {
        guard task == nil else { return false }
        generation &+= 1
        let taskGeneration = generation
        operation = operationName
        startedAt = ProcessInfo.processInfo.systemUptime
        task = Task { @MainActor [weak self] in
            await body()
            guard !Task.isCancelled else { return }
            guard self?.generation == taskGeneration else { return }
            self?.task = nil
            self?.operation = nil
            self?.startedAt = nil
        }
        return true
    }
}

private struct DictationReadinessRefreshTimeout {
    let operation: String
    let elapsed: TimeInterval
}

private struct DictationStopTiming {
    let requestedAt: CFAbsoluteTime
    var micStoppedAt: CFAbsoluteTime?
    var modelWaitStartedAt: CFAbsoluteTime?
    var modelReadyAt: CFAbsoluteTime?
    var transcriptionStartedAt: CFAbsoluteTime?
    var transcribedAt: CFAbsoluteTime?
    var cleanedAt: CFAbsoluteTime?
    var pasteStartedAt: CFAbsoluteTime?
    var pastedAt: CFAbsoluteTime?
    var autoEnterStartedAt: CFAbsoluteTime?
    var autoEnterFinishedAt: CFAbsoluteTime?
    var saveStartedAt: CFAbsoluteTime?
    var savedAt: CFAbsoluteTime?
    var completedAt: CFAbsoluteTime?

    func measurements() -> [String: Int] {
        var values: [String: Int] = [:]
        values["stop_to_mic_stop_ms"] = milliseconds(from: requestedAt, to: micStoppedAt)
        values["mic_stop_to_decode_start_ms"] = milliseconds(from: micStoppedAt, to: transcriptionStartedAt)
        values["model_wait_ms"] = milliseconds(from: modelWaitStartedAt, to: modelReadyAt)
        values["decode_ms"] = milliseconds(from: transcriptionStartedAt, to: transcribedAt)
        values["cleanup_ms"] = milliseconds(from: transcribedAt, to: cleanedAt)
        values["paste_ms"] = milliseconds(from: pasteStartedAt, to: pastedAt)
        values["auto_enter_ms"] = milliseconds(from: autoEnterStartedAt, to: autoEnterFinishedAt)
        values["save_ms"] = milliseconds(from: saveStartedAt, to: savedAt)
        values["stop_to_paste_ms"] = milliseconds(from: requestedAt, to: pastedAt)
        values["stop_to_save_ms"] = milliseconds(from: requestedAt, to: savedAt)
        values["stop_to_done_ms"] = milliseconds(from: requestedAt, to: completedAt)
        return values
    }

    private func milliseconds(from start: CFAbsoluteTime?, to end: CFAbsoluteTime?) -> Int? {
        guard let start, let end else { return nil }
        return max(0, Int(((end - start) * 1_000).rounded()))
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

private extension TextPasteCopyReason {
    var diagnosticName: String {
        switch self {
        case .accessibilityMissing:
            return "accessibility_missing"
        case .pasteEventCreationFailed:
            return "paste_event_creation_failed"
        case .focusChanged:
            return "focus_changed"
        case .pasteNotConfirmed:
            return "paste_not_confirmed"
        case .pasteConfirmationUnavailable:
            return "paste_confirmation_unavailable"
        }
    }
}

// AVAuthorizationStatus.diagnosticName is defined once in
// Sources/Support/TranscriptedPermissionAccess.swift and reused here.
