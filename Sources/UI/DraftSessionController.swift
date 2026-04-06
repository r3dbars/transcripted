// DraftSessionController.swift
// Session orchestration for dictation mode plus compatibility stubs for the
// removed draft mode.

import AppKit
import Combine

@MainActor
class DraftSessionController: ObservableObject {
    private enum DictationPasteOutcome {
        case pasted
        case copied(String)
        case failed(String)
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

    /// Max duration for a listening session before auto-cancel (5 minutes).
    /// Prevents stuck sessions when the user walks away from the computer.
    private static let sessionTimeoutNanos: UInt64 = 5 * 60 * 1_000_000_000

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
                    self.cancelSession(message: "Draft mode has been removed")
                } else if self.isDictating {
                    self.isDictating = false
                    self.overlayController?.showError("Audio device changed")
                }
            }
    }

    // MARK: - Removed Draft Mode

    func startSession(imageData: Data?, sourceApp: NSRunningApplication?) {
        let _ = imageData
        let _ = sourceApp
        guard let (_, overlayController) = readyState() else { return }
        overlayController.showError("Draft mode has been removed")
    }

    func stopSessionAndDraft() {
        guard let (_, overlayController) = readyState() else { return }
        overlayController.showError("Draft mode has been removed")
    }

    func cancelSession() {
        cancelSession(message: "Draft mode has been removed")
    }

    private func cancelSession(message: String) {
        guard let (_, overlayController) = readyState() else { return }
        streamingTask?.cancel()
        streamingTask = nil
        clipboardRestoreTask?.cancel()
        clipboardRestoreTask = nil
        sessionTimeoutTask?.cancel()
        sessionTimeoutTask = nil
        isInSession = false
        overlayController.showError(message)
    }

    // MARK: - Dictation Mode (Option+Space)

    /// Start dictation — show overlay and begin voice recording (no screenshot/vision)
    func startDictation(sourceApp: NSRunningApplication?) {
        guard let (_, overlayController) = readyState() else { return }
        guard !isDictating, !isInSession else { return }
        isDictating = true
        sessionSourceApp = sourceApp
        sessionStartTime = CFAbsoluteTimeGetCurrent()
        lastCompletedText = nil

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
            overlayController.showError("Microphone unavailable")
            isDictating = false
            return
        }
        appState.logger.log("DICTATION | started (parakeet, \(appState.sttRouter.inputDeviceName))")

        // Start session timeout — auto-cancel after 5 minutes to prevent stuck sessions
        installSessionTimeout()
    }

    /// Stop dictation and paste — Parakeet batch transcription
    func stopDictationAndPaste() {
        guard let (appState, overlayController) = readyState() else { return }
        guard isDictating, overlayController.state == .listening else { return }
        sessionTimeoutTask?.cancel()
        sessionTimeoutTask = nil
        overlayController.state = .drafting

        appState.sttRouter.stopRecording()
        streamingTask?.cancel()
        streamingTask = Task {
            // Wait for voice model if still loading
            if !appState.sttRouter.isModelLoaded {
                appState.logger.log("DICTATION | waiting for voice model before transcribe…")
                for _ in 0..<DraftConstants.modelLoadMaxIterations {
                    guard !Task.isCancelled else { return }
                    if appState.sttRouter.isModelLoaded { break }
                    try? await Task.sleep(nanoseconds: DraftConstants.modelLoadPollInterval)
                }
                guard appState.sttRouter.isModelLoaded else {
                    appState.logger.log("DICTATION | voice model failed to load for transcription")
                    overlayController.showError("Voice model failed to load")
                    isDictating = false
                    return
                }
            }
            let voiceText = await appState.sttRouter.transcribe()
            guard !Task.isCancelled else { return }

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
        sessionTimeoutTask?.cancel()
        sessionTimeoutTask = nil
        if appState.sttRouter.isRecording {
            appState.sttRouter.cancel()
        }
        overlayController.hideWithCancelAnimation()
        isDictating = false
        appState.logger.log("DICTATION | cancelled")
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
}
