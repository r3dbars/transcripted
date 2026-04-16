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
        case keyboardShortcut = "keyboard_shortcut"
        case overlayButton = "overlay_button"
        case menu = "menu"
        case onboarding = "onboarding"
        case unknown = "unknown"
    }

    private enum DictationPasteOutcome {
        case pasted
        case copied(String)
        case failed(String)

        var delivery: DictationDelivery {
            switch self {
            case .pasted: return .pasted
            case .copied: return .copied
            case .failed: return .failed
            }
        }

        var diagnosticName: String {
            switch self {
            case .pasted: return "pasted"
            case .copied: return "copied"
            case .failed: return "failed"
            }
        }

        var diagnosticMessage: String {
            switch self {
            case .pasted:
                return "Dictation pasted successfully"
            case .copied(let message), .failed(let message):
                return message
            }
        }
    }

    @Published var isInSession = false
    @Published var isDictating = false
    @Published var lastCompletedText: String?

    private var interruptionSubscription: AnyCancellable?

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
    private var startupTask: Task<Void, Never>?
    private var streamingTask: Task<Void, Never>?
    private var clipboardRestoreTask: Task<Void, Never>?
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
        clipboardRestoreTask?.cancel()
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
    func startDictation(sourceApp: NSRunningApplication?, trigger: DictationTrigger = .unknown) {
        guard let (appState, overlayController) = readyState() else { return }
        guard !isDictating, !isInSession else { return }
        isDictating = true
        sessionSourceApp = sourceApp
        sessionStartTime = CFAbsoluteTimeGetCurrent()
        currentDictationTrigger = trigger
        lastCompletedText = nil

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
            properties: [
                "trigger": trigger.rawValue,
            ]
        )

        if appState.sttRouter.isModelLoaded {
            overlayController.state = .listening
            overlayController.showPanel(near: sourceApp)
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

        // Fast path — engine is ready right now.
        if let appState = appState,
           !appState.sttRouter.isRecovering,
           appState.sttRouter.inputFormatReady,
           appState.sttRouter.startRecording() {
            recordingStartRetryTask?.cancel()
            recordingStartRetryTask = nil
            resizePanelToCompact()
            appState.logger.log("DICTATION | started (parakeet, \(appState.sttRouter.inputDeviceName))")
            AppSoundPlayer.shared.play(.dictationStart)
            installSessionTimeout()
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
        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard microphoneStatus == .authorized else {
            presentMicrophonePermissionError(microphoneStatus)
            return
        }

        let startedAt = CFAbsoluteTimeGetCurrent()
        let deadline = startedAt + TranscriptedConstants.dictationRecoveryBudget

        while CFAbsoluteTimeGetCurrent() < deadline {
            guard isDictating, !Task.isCancelled else { return }

            let elapsed = CFAbsoluteTimeGetCurrent() - startedAt
            overlayController.showLoadingState(
                near: sourceApp,
                presentation: microphoneRecoveryPresentation(
                    elapsed: elapsed,
                    deviceName: appState.sttRouter.inputDeviceName
                )
            )

            if !appState.sttRouter.isRecovering, appState.sttRouter.inputFormatReady {
                if appState.sttRouter.startRecording() {
                    overlayController.state = .listening
                    resizePanelToCompact()
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
                                "audio_device": appState.sttRouter.inputDeviceName
                            ]
                        )
                    )
                    AppSoundPlayer.shared.play(.dictationStart)
                    installSessionTimeout()
                    return
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
            event: "dictation_recording_failed",
            message: "Dictation recording failed to start within recovery budget",
            context: dictationContext(
                extra: [
                    "wait_ms": "\(waited)",
                    "audio_device": appState.sttRouter.inputDeviceName,
                    "is_recovering": "\(appState.sttRouter.isRecovering)",
                    "format_ready": "\(appState.sttRouter.inputFormatReady)"
                ]
            )
        )
        overlayController.showError(
            microphoneTimeoutMessage(deviceName: appState.sttRouter.inputDeviceName)
        )
        isDictating = false
    }

    private func presentMicrophonePermissionError(_ status: AVAuthorizationStatus) {
        guard let appState = appState, let overlayController = overlayController else { return }
        let shouldOfferSettingsAction = shouldOfferMicrophoneSettingsAction(for: status)
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
        overlayController.showError(
            microphoneUnavailableMessage(for: status, openedSettings: false),
            actionTitle: shouldOfferSettingsAction ? "Open Microphone Settings" : nil,
            action: shouldOfferSettingsAction ? {
                TranscriptedPermissionAccess.openSettings(for: .microphone)
            } : nil
        )
        isDictating = false
    }

    /// Stop dictation and paste — Parakeet batch transcription
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

        appState.sttRouter.stopRecording()
        streamingTask?.cancel()
        streamingTask = Task {
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
                    return
                }
            }
            overlayController.state = .drafting
            let voiceText = await appState.sttRouter.transcribe()
            guard !Task.isCancelled else { return }

            guard let text = voiceText, !text.isEmpty else {
                appState.logger.log("DICTATION | no transcription, cancelling")
                EventReporter.shared.capture(level: .warning, engine: "overlay", event: "no_voice_input",
                    message: "Dictation transcription empty")
                AnalyticsReporter.track(
                    "dictation_no_speech",
                    properties: [
                        "duration_bucket": AnalyticsReporter.durationBucket(
                            seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime
                        ),
                        "trigger": currentDictationTrigger.rawValue,
                    ]
                )
                AppSoundPlayer.shared.play(.noSpeech)
                overlayController.showNoSpeechAndDismiss()
                isDictating = false
                return
            }

            guard !Task.isCancelled else { return }
            appState.logger.log("DICTATION | pasting \(text.count) chars")
            lastCompletedText = text
            let pasteOutcome = self.pasteWithClipboardRestore(text)
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
            case .copied(let message), .failed(let message):
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
            AnalyticsReporter.track(
                "dictation_completed",
                properties: [
                    "delivery": pasteOutcome.delivery.rawValue,
                    "duration_bucket": AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime),
                    "trigger": currentDictationTrigger.rawValue,
                    "word_count_bucket": AnalyticsReporter.wordCountBucket(wordCount),
                ]
            )
        }
    }

    /// Cancel dictation without pasting
    func cancelDictation() {
        guard let (appState, overlayController) = readyState() else { return }
        cancelActiveTasks(cancelRecording: true)
        AppSoundPlayer.shared.play(.dictationCancelled)
        overlayController.hideWithCancelAnimation()
        isDictating = false
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
        AnalyticsReporter.track(
            "dictation_cancelled",
            properties: [
                "duration_bucket": AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime),
                "trigger": currentDictationTrigger.rawValue,
            ]
        )
    }

    // MARK: - Private

    private func startDictationAfterWarmup(sourceApp: NSRunningApplication?) {
        guard let appState = appState, let overlayController = overlayController else { return }

        startupTask?.cancel()
        updateLoadingOverlay(sourceApp: sourceApp)
        retryModelWarmupIfNeeded()

        startupTask = Task { @MainActor [weak self] in
            guard let self else { return }

            for _ in 0..<TranscriptedConstants.modelLoadMaxIterations {
                guard !Task.isCancelled, self.isDictating else { return }

                let modelState = appState.sttRouter.parakeetEngine.modelDownloadState
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
                    overlayController.showError("Dictation couldn't start: \(message)")
                    return
                default:
                    break
                }

                try? await Task.sleep(nanoseconds: TranscriptedConstants.modelLoadPollInterval)
            }

            guard !Task.isCancelled else { return }
            self.startupTask = nil
            self.isDictating = false
            overlayController.showError("Dictation is still loading. Please try again in a moment.")
        }
    }

    private func retryModelWarmupIfNeeded() {
        guard let appState else { return }

        switch appState.sttRouter.parakeetEngine.modelDownloadState {
        case .notLoaded, .failed:
            Task { @MainActor [weak appState] in
                await appState?.sttRouter.parakeetEngine.initialize()
            }
        case .downloading, .loading, .ready:
            break
        }
    }

    private func updateLoadingOverlay(
        sourceApp: NSRunningApplication?,
        modelState: ParakeetModelState? = nil
    ) {
        guard let appState = appState else { return }
        let presentation = loadingPresentation(for: modelState ?? appState.sttRouter.parakeetEngine.modelDownloadState)
        overlayController?.showLoadingState(near: sourceApp, presentation: presentation)
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

    private func microphoneRecoveryPresentation(elapsed: TimeInterval, deviceName: String) -> FloatingOverlayController.LoadingPresentation {
        let budget = TranscriptedConstants.dictationRecoveryBudget
        let progress = min(0.85, 0.1 + (elapsed / budget) * 0.75)
        let status: String? = elapsed > 1.5 ? "Still connecting to \(deviceName)…" : nil
        return .init(
            title: "Switching microphone",
            detail: "Connecting to the new audio device.",
            progress: progress,
            status: status
        )
    }

    private func microphoneTimeoutMessage(deviceName: String) -> String {
        "Couldn't reach \(deviceName). Try selecting a different input in System Settings."
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
        case .streaming: return "streaming"
        case .review: return "review"
        case .diffFlash: return "diff_flash"
        }
    }

    private func cancelActiveTasks(cancelRecording: Bool) {
        startupTask?.cancel()
        startupTask = nil
        streamingTask?.cancel()
        streamingTask = nil
        clipboardRestoreTask?.cancel()
        clipboardRestoreTask = nil
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
        overlayController?.showError("Recording was interrupted. Try again.")
    }

    private func shouldOfferMicrophoneSettingsAction(for status: AVAuthorizationStatus) -> Bool {
        switch status {
        case .denied, .restricted:
            return true
        case .notDetermined, .authorized:
            return false
        @unknown default:
            return false
        }
    }

    private func microphoneUnavailableMessage(
        for status: AVAuthorizationStatus,
        openedSettings: Bool = false
    ) -> String {
        switch status {
        case .notDetermined:
            return "Transcripted is still waiting for microphone permission."
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

    /// Bundle identifiers of dedicated terminal emulators. Auto-paste is refused into
    /// these targets because dictated text containing a trailing newline (or any
    /// shell metacharacter) would be interpreted as a command and executed. The user
    /// can still press Cmd+V manually if they really meant to paste into a shell.
    private static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "dev.warp.Warp-Stable",
        "co.zeit.hyper",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.mitchellh.ghostty",
    ]

    private func isFrontmostAppATerminal() -> Bool {
        guard let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else {
            return false
        }
        return Self.terminalBundleIDs.contains(bundleID)
    }

    private func pasteWithClipboardRestore(_ text: String) -> DictationPasteOutcome {
        guard let appState = appState else { return .failed("Couldn't paste dictation") }

        // Refuse to auto-paste into a terminal: a trailing newline or shell
        // metacharacter in the dictated text would execute as a command.
        if isFrontmostAppATerminal() {
            appState.logger.log("DICTATION | terminal frontmost, copying instead of auto-paste")
            copyTextToClipboard(text)
            return .copied("Dictation won't auto-paste into a terminal for safety. Press Cmd+V to paste.")
        }

        // Check Accessibility permission BEFORE modifying clipboard
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            appState.logger.log("DICTATION | Accessibility missing, copying text instead")
            copyTextToClipboard(text)
            return .copied("Couldn't paste automatically. Accessibility is off, so the text was copied.")
        }

        let pasteboard = NSPasteboard.general

        // Save current clipboard contents
        let savedItems: [[NSPasteboard.PasteboardType: Data]] = pasteboard.pasteboardItems?.map { item in
            var typeData: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    typeData[type] = data
                }
            }
            return typeData
        } ?? []

        // Set our drafted text
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Simulate Cmd+V — target app is already frontmost (overlay is non-activating)
        guard let vDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false) else {
            EventReporter.shared.capture(level: .error, engine: "overlay", event: "cgevent_create_failed",
                message: "CGEvent creation returned nil — paste will not work")
            appState.logger.log("DICTATION | CGEvent paste failed, keeping text on clipboard")
            return .copied("Couldn't paste automatically. The text was copied instead.")
        }
        vDown.flags = .maskCommand
        vDown.post(tap: .cghidEventTap)

        vUp.flags = .maskCommand
        vUp.post(tap: .cghidEventTap)

        // Restore clipboard after paste completes.
        // Poll changeCount every 50ms — some apps (rich text editors) write back to the
        // clipboard on paste, which increments changeCount. If no change detected, fall
        // back to a 2-second timeout (more conservative than the old 500ms for slow
        // Electron apps like Slack/Teams).
        let changeCountAfterSet = pasteboard.changeCount
        clipboardRestoreTask?.cancel()
        clipboardRestoreTask = Task { @MainActor in
            // Defer guarantees the dictated text is wiped from the global pasteboard
            // even if this task is cancelled or the actor is torn down mid-loop —
            // otherwise a clipboard manager could scrape it indefinitely.
            defer {
                pasteboard.clearContents()
                let items = savedItems.map { typeData -> NSPasteboardItem in
                    let item = NSPasteboardItem()
                    for (type, data) in typeData {
                        item.setData(data, forType: type)
                    }
                    return item
                }
                if !items.isEmpty {
                    pasteboard.writeObjects(items)
                }
            }
            let startTime = CFAbsoluteTimeGetCurrent()
            while CFAbsoluteTimeGetCurrent() - startTime < TranscriptedConstants.clipboardRestoreTimeout {
                try? await Task.sleep(nanoseconds: TranscriptedConstants.clipboardPollInterval)
                if pasteboard.changeCount != changeCountAfterSet { break }
            }
        }
        return .pasted
    }

    private func copyTextToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    @discardableResult
    private func persistDictationTranscript(text: String, delivery: DictationDelivery) -> String? {
        do {
            let saved = try DictationTranscriptWriter.save(
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

        for (key, value) in extra {
            context[key] = value
        }

        return context
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
