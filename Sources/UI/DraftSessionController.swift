// DraftSessionController.swift
// Session orchestration for dictation mode plus compatibility stubs for the
// removed draft mode.

import AppKit
import Combine

@MainActor
class DraftSessionController: ObservableObject {
    private static let removedDraftModeMessage = "This build of Transcripted supports dictation and meetings only."
    private static let sessionTimeoutInterval: TimeInterval = 5 * 60
    private static let sessionTimeoutPollInterval: TimeInterval = 1.0
    private static let transcriptionTimeoutSeconds: Double = 120

    enum DictationTrigger: String {
        case rightOptionTap = "right_option_tap"
        case keyboardShortcut = "keyboard_shortcut"
        case overlayButton = "overlay_button"
        case menu = "menu"
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

    var appState: DraftAppState? {
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
    private func readyState() -> (DraftAppState, FloatingOverlayController)? {
        guard let appState = appState, let overlayController = overlayController else {
            EventReporter.shared.capture(level: .warning, engine: "overlay", event: "session_not_wired",
                message: "appState or overlayController not set")
            return nil
        }
        return (appState, overlayController)
    }

    private var sessionSourceApp: NSRunningApplication?
    private var streamingTask: Task<Void, Never>?
    private var clipboardRestoreTask: Task<Void, Never>?
    private var sessionTimeoutTask: Task<Void, Never>?
    private var sessionStartTime: CFAbsoluteTime = 0
    private var currentDictationTrigger: DictationTrigger = .unknown
    private var sessionTimeout = DictationSessionTimeout(timeoutInterval: 5 * 60)

    deinit {
        streamingTask?.cancel()
        clipboardRestoreTask?.cancel()
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
                    let message = self.interruptionMessage(for: appState.sttRouter.interruptionReason)
                    self.handleDictationInterruption(message: message)
                }
            }
    }

    // MARK: - Removed Draft Mode

    func startSession(imageData: Data?, sourceApp: NSRunningApplication?) {
        let _ = imageData
        let _ = sourceApp
        guard let (_, overlayController) = readyState() else { return }
        overlayController.showError(Self.removedDraftModeMessage)
    }

    func stopSessionAndDraft() {
        guard let (_, overlayController) = readyState() else { return }
        overlayController.showError(Self.removedDraftModeMessage)
    }

    func cancelSession() {
        cancelSession(message: Self.removedDraftModeMessage)
    }

    private func cancelSession(message: String) {
        guard let (_, overlayController) = readyState() else { return }
        streamingTask?.cancel()
        streamingTask = nil
        clipboardRestoreTask?.cancel()
        clipboardRestoreTask = nil
        clearSessionTimeout()
        isInSession = false
        overlayController.showError(message)
    }

    // MARK: - Dictation Mode (Option+Space)

    /// Start dictation — show overlay and begin voice recording (no screenshot/vision)
    func startDictation(sourceApp: NSRunningApplication?, trigger: DictationTrigger = .unknown) {
        guard let (_, overlayController) = readyState() else { return }
        guard !isDictating, !isInSession else { return }
        isDictating = true
        sessionSourceApp = sourceApp
        sessionStartTime = CFAbsoluteTimeGetCurrent()
        currentDictationTrigger = trigger
        lastCompletedText = nil

        DiagnosticsTrail.record(
            logger: appState?.logger,
            engine: "dictation",
            event: "dictation_started",
            message: "Dictation started",
            context: dictationContext(
                extra: [
                    "trigger": trigger.rawValue,
                    "source_app_name": sourceApp?.localizedName ?? "",
                    "source_app_bundle_id": sourceApp?.bundleIdentifier ?? ""
                ]
            )
        )

        overlayController.state = .listening
        overlayController.showPanel(near: sourceApp)

        beginDictationRecording(sourceApp: sourceApp)
    }

    /// Actually start dictation recording — called directly from startDictation
    private func beginDictationRecording(sourceApp: NSRunningApplication?) {
        guard let appState = appState, let overlayController = overlayController else { return }
        guard isDictating else { return }

        overlayController.state = .listening

        guard appState.sttRouter.startRecording() else {
            appState.logger.log("DICTATION | recording failed to start")
            DiagnosticsTrail.record(
                logger: appState.logger,
                level: .error,
                engine: "dictation",
                event: "dictation_recording_failed",
                message: "Dictation recording failed to start",
                context: dictationContext(extra: ["audio_device": appState.sttRouter.inputDeviceName])
            )
            overlayController.showError("Microphone unavailable")
            isDictating = false
            return
        }
        appState.logger.log("DICTATION | started (parakeet, \(appState.sttRouter.inputDeviceName))")

        // Start session timeout — auto-cancel after 5 minutes to prevent stuck sessions
        installSessionTimeout()
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
        clearSessionTimeout()
        overlayController.state = .drafting

        appState.sttRouter.stopRecording()
        streamingTask?.cancel()
        streamingTask = Task {
            let voiceText: String?
            do {
                voiceText = try await DraftConstants.withTimeout(seconds: Self.transcriptionTimeoutSeconds) {
                    // Wait for voice model if still loading
                    if !(await MainActor.run { appState.sttRouter.isModelLoaded }) {
                        await MainActor.run {
                            appState.logger.log("DICTATION | waiting for voice model before transcribe…")
                        }
                        for _ in 0..<DraftConstants.modelLoadMaxIterations {
                            guard !Task.isCancelled else { throw CancellationError() }
                            if await MainActor.run(body: { appState.sttRouter.isModelLoaded }) { break }
                            try await Task.sleep(nanoseconds: DraftConstants.modelLoadPollInterval)
                        }
                        guard await MainActor.run(body: { appState.sttRouter.isModelLoaded }) else {
                            return nil
                        }
                    }
                    return await appState.sttRouter.transcribe()
                }
            } catch is CancellationError {
                guard !Task.isCancelled else { return }
                appState.logger.log("DICTATION | transcription timed out")
                DiagnosticsTrail.record(
                    logger: appState.logger,
                    level: .warning,
                    engine: "dictation",
                    event: "dictation_transcription_timeout",
                    message: "Dictation timed out while waiting for transcription",
                    context: self.dictationContext(
                        extra: [
                            "trigger": self.currentDictationTrigger.rawValue,
                            "duration_ms": "\(Int((CFAbsoluteTimeGetCurrent() - self.sessionStartTime) * 1000))"
                        ]
                    )
                )
                overlayController.showError("Dictation timed out while transcribing")
                isDictating = false
                return
            } catch {
                guard !Task.isCancelled else { return }
                appState.logger.log("DICTATION | transcription failed: \(error.localizedDescription)")
                DiagnosticsTrail.record(
                    logger: appState.logger,
                    level: .warning,
                    engine: "dictation",
                    event: "dictation_transcription_failed",
                    message: "Dictation transcription failed",
                    context: self.dictationContext(
                        extra: [
                            "trigger": self.currentDictationTrigger.rawValue,
                            "error": error.localizedDescription
                        ]
                    )
                )
                overlayController.showError("Dictation transcription failed")
                isDictating = false
                return
            }
            guard !Task.isCancelled else { return }

            if voiceText == nil, !appState.sttRouter.isModelLoaded {
                appState.logger.log("DICTATION | voice model failed to load for transcription")
                overlayController.showError("Voice model failed to load")
                isDictating = false
                return
            }

            guard let text = voiceText, !text.isEmpty else {
                appState.logger.log("DICTATION | no transcription, cancelling")
                EventReporter.shared.capture(level: .warning, engine: "overlay", event: "no_voice_input",
                    message: "Dictation transcription empty")
                overlayController.showNoSpeechAndDismiss()
                isDictating = false
                return
            }

            guard !Task.isCancelled else { return }
            appState.logger.log("DICTATION | pasting \(text.count) chars")
            lastCompletedText = text
            let pasteOutcome = self.pasteWithClipboardRestore(text)
            self.persistDictationTranscript(text: text, delivery: pasteOutcome.delivery)
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
                overlayController.showSuccessAndDismiss()
            case .copied(let message), .failed(let message):
                overlayController.showError(message)
            }
            isDictating = false
            appState.logger.log("DICTATION | completed with outcome \(pasteOutcome)")
            EventTracker.track("dictation.completed", with: ["word_count": "\(text.split(whereSeparator: \.isWhitespace).count)"])
            #if BETA_BUILD
            let duration = CFAbsoluteTimeGetCurrent() - sessionStartTime
            BetaTelemetry.shared.sendEvent(
                type: "dictation_completed",
                sourceApp: sessionSourceApp?.bundleIdentifier,
                payload: [
                    "chars": text.count,
                    "duration_s": Int(duration),
                ]
            )
            #endif
        }
    }

    /// Cancel dictation without pasting
    func cancelDictation() {
        guard let (appState, overlayController) = readyState() else { return }
        streamingTask?.cancel()
        streamingTask = nil
        clipboardRestoreTask?.cancel()
        clipboardRestoreTask = nil
        clearSessionTimeout()
        if appState.sttRouter.isRecording {
            appState.sttRouter.cancel()
        }
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
        #if BETA_BUILD
        let duration = CFAbsoluteTimeGetCurrent() - sessionStartTime
        BetaTelemetry.shared.sendEvent(
            type: "dictation_cancelled",
            sourceApp: sessionSourceApp?.bundleIdentifier,
            payload: ["duration_s": Int(duration)]
        )
        #endif
    }

    // MARK: - Private

    /// Shrink the panel to compact (header-only) height without animation.
    /// Called after loading → listening transition to undo showLoadingState()'s expansion.
    private func resizePanelToCompact() {
        overlayController?.resizePanelToCompact()
    }

    /// Install a timeout that auto-cancels the session after 5 minutes.
    /// Prevents stuck sessions if the user walks away from the computer.
    private func installSessionTimeout() {
        clearSessionTimeout()
        sessionTimeout.start(at: ProcessInfo.processInfo.systemUptime)
        sessionTimeoutTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { return }
                let uptime = ProcessInfo.processInfo.systemUptime
                if self.sessionTimeout.isExpired(at: uptime) {
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
                    return
                }

                let remaining = self.sessionTimeout.remaining(at: uptime) ?? 0
                let sleepSeconds = min(remaining, Self.sessionTimeoutPollInterval)
                guard sleepSeconds > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(sleepSeconds * 1_000_000_000))
            }
        }
    }

    private func clearSessionTimeout() {
        sessionTimeoutTask?.cancel()
        sessionTimeoutTask = nil
        sessionTimeout.clear()
    }

    private func handleDictationInterruption(message: String) {
        guard isDictating else { return }
        streamingTask?.cancel()
        streamingTask = nil
        clipboardRestoreTask?.cancel()
        clipboardRestoreTask = nil
        clearSessionTimeout()
        isDictating = false

        DiagnosticsTrail.record(
            logger: appState?.logger,
            level: .warning,
            engine: "dictation",
            event: "dictation_interrupted",
            message: message,
            context: dictationContext(
                extra: [
                    "trigger": currentDictationTrigger.rawValue,
                    "duration_ms": "\(Int((CFAbsoluteTimeGetCurrent() - sessionStartTime) * 1000))",
                    "reason": appState?.sttRouter.interruptionReason?.rawValue ?? "unknown"
                ]
            )
        )
        overlayController?.showError(message)
    }

    private func interruptionMessage(for reason: RecordingInterruptionReason?) -> String {
        switch reason {
        case .systemWake:
            return "Dictation stopped while your Mac was asleep"
        case .recoveryFailed:
            return "Microphone recovery failed"
        case .audioDeviceChanged, .none:
            return "Audio device changed"
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

    private func pasteWithClipboardRestore(_ text: String) -> DictationPasteOutcome {
        guard let appState = appState else { return .failed("Couldn't paste dictation") }

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
            let startTime = CFAbsoluteTimeGetCurrent()
            while CFAbsoluteTimeGetCurrent() - startTime < DraftConstants.clipboardRestoreTimeout {
                try? await Task.sleep(nanoseconds: DraftConstants.clipboardPollInterval)
                if pasteboard.changeCount != changeCountAfterSet { break }
            }
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
        return .pasted
    }

    private func copyTextToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func persistDictationTranscript(text: String, delivery: DictationDelivery) {
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
                        "delivery": delivery.rawValue,
                        "title": saved.title,
                        "filename": saved.url.lastPathComponent
                    ]
                )
            )
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
        }
    }

    private func dictationContext(extra: [String: String] = [:]) -> [String: String] {
        var context: [String: String] = [
            "source_app_name": sessionSourceApp?.localizedName ?? "",
            "source_app_bundle_id": sessionSourceApp?.bundleIdentifier ?? "",
            "audio_device": appState?.sttRouter.inputDeviceName ?? ""
        ]

        for (key, value) in extra {
            context[key] = value
        }

        return context
    }
}
