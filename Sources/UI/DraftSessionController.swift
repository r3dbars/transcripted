// DraftSessionController.swift
// Session orchestration for draft mode (Option+D) and dictation mode (Option+Space)

import SwiftUI
import AppKit
import Combine

@MainActor
class DraftSessionController: ObservableObject {
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

    private var lastCapturedContext: CapturedContext?
    private var sessionSourceApp: NSRunningApplication?
    private var streamingTask: Task<Void, Never>?
    private var visionTask: Task<Void, Never>?
    private var sessionStartTime: CFAbsoluteTime = 0

    /// When set, processVision() uses this context directly instead of calling the vision API.
    /// Used by onboarding to inject a fake conversation without requiring screen recording permission.
    var overrideContext: CapturedContext?

    private func setupInterruptionObserver() {
        guard let appState = appState else { return }
        interruptionSubscription = appState.sttRouter.$recordingInterrupted
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                guard let self = self else { return }
                if self.isInSession {
                    // Clean up session state without hiding — let showError handle the dismiss
                    self.visionTask?.cancel()
                    self.visionTask = nil
                    self.streamingTask?.cancel()
                    self.streamingTask = nil
                    self.isInSession = false
                    self.overlayController?.showError("Audio device changed")
                } else if self.isDictating {
                    self.isDictating = false
                    self.overlayController?.showError("Audio device changed")
                }
            }
    }

    // MARK: - Draft Mode (Option+D)

    /// Start a new recording session — called on first hotkey press
    func startSession(imageData: Data?, sourceApp: NSRunningApplication?) {
        guard let (appState, overlayController) = readyState() else { return }
        guard !isInSession, !isDictating else { return }
        isInSession = true
        sessionSourceApp = sourceApp
        sessionStartTime = CFAbsoluteTimeGetCurrent()
        lastCompletedText = nil

        lastCapturedContext = nil
        appState.drafter.clear()

        // Show overlay and start recording
        overlayController.hasContext = true
        overlayController.activeMode = .draft
        overlayController.state = .listening
        overlayController.showPanel(near: sourceApp)

        // If model isn't loaded yet, show loading overlay and wait (up to 120s)
        if !appState.sttRouter.isModelLoaded {
            appState.logger.log("SESSION | waiting for model to load…")
            overlayController.showLoadingState()

            // Wait in background, then start recording once ready
            let capturedImageData = imageData
            let capturedSourceApp = sourceApp
            streamingTask?.cancel()
            streamingTask = Task { [weak self] in
                guard let self = self else { return }
                // Poll for model readiness (200ms intervals, up to 120s)
                for _ in 0..<DraftConstants.modelLoadMaxIterations {
                    guard !Task.isCancelled else { return }
                    if await self.appState?.sttRouter.isModelLoaded == true { break }
                    try? await Task.sleep(nanoseconds: DraftConstants.modelLoadPollInterval)
                }
                guard !Task.isCancelled else { return }
                guard await self.appState?.sttRouter.isModelLoaded == true else {
                    await self.appState?.logger.log("SESSION | model load timed out")
                    await self.overlayController?.showError("Voice model failed to load")
                    self.isInSession = false
                    return
                }
                // Model is ready — start recording
                await self.beginRecording(imageData: capturedImageData, sourceApp: capturedSourceApp)
            }
            return
        }

        beginRecording(imageData: imageData, sourceApp: sourceApp)
    }

    /// Actually start recording and vision — called directly or after model wait
    private func beginRecording(imageData: Data?, sourceApp: NSRunningApplication?) {
        guard let appState = appState, let overlayController = overlayController else { return }
        guard isInSession else { return }

        overlayController.state = .listening
        // After loading state, panel may be at full height — shrink to compact for listening
        resizePanelToCompact()

        guard appState.sttRouter.startRecording() else {
            appState.logger.log("SESSION | recording failed to start")
            overlayController.showError("Microphone unavailable")
            isInSession = false
            return
        }

        appState.logger.log("SESSION | started (parakeet, \(appState.sttRouter.inputDeviceName)), voice recording + vision in parallel")

        // Start vision processing in parallel (stored so we can await it before drafting)
        visionTask?.cancel()
        visionTask = Task {
            await processVision(imageData: imageData, sourceApp: sourceApp)
        }
    }

    /// Stop recording and trigger drafting — called on second hotkey press
    func stopSessionAndDraft() {
        guard let (appState, overlayController) = readyState() else { return }
        guard isInSession else { return }
        overlayController.enterDraftingState()

        streamingTask?.cancel()
        streamingTask = Task {
            // Stop recording and batch-transcribe
            appState.sttRouter.stopRecording()
            let voiceText = (await appState.sttRouter.transcribe() ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !voiceText.isEmpty else {
                appState.logger.log("SESSION | no voice input, cancelling")
                EventReporter.shared.capture(level: .warning, engine: "overlay", event: "no_voice_input",
                    message: "Voice text empty after recording")
                visionTask?.cancel()
                visionTask = nil
                overlayController.showError("No speech detected")
                isInSession = false
                return
            }

            let platform = PlatformFormatter.detect(from: sessionSourceApp)

            guard appState.localInference.isReady else {
                appState.logger.log("SESSION | local model not loaded, cancelling")
                EventReporter.shared.capture(level: .error, engine: "overlay", event: "model_not_ready",
                    message: "Local LLM not loaded")
                visionTask?.cancel()
                visionTask = nil
                overlayController.showError(appState.localInference.statusLabel)
                isInSession = false
                return
            }

            // Wait for vision to complete (or timeout) before checking context
            await visionTask?.value
            visionTask = nil

            appState.logger.log("SESSION | streaming draft [\(platform.rawValue)] — \(voiceText.count) chars, context: \(lastCapturedContext?.hasConversation == true ? "yes" : "no")")

            var systemPrompt = appState.styleEngine.buildSystemPrompt()
            if !platform.formattingInstructions.isEmpty {
                systemPrompt += "\n\n" + platform.formattingInstructions
            }

            let userMessage: String
            if let context = lastCapturedContext, context.hasConversation {
                userMessage = context.draftingPrompt(userInstructions: voiceText)
            } else {
                userMessage = "Clean up this dictation. Fix grammar, keep their tone. Output only the message.\n\n\(voiceText.trimmingCharacters(in: .whitespacesAndNewlines))"
            }

            let stream = await appState.localInference.draftEngine.generate(
                prompt: userMessage,
                systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
                maxTokens: DraftConstants.draftMaxTokens,
                temperature: 0.7
            )

            var fullText = ""
            var gotFirstToken = false

            do {
                for try await token in stream {
                    guard !Task.isCancelled else { break }
                    if !gotFirstToken {
                        gotFirstToken = true
                        overlayController.startStreaming(near: sessionSourceApp)
                    }
                    fullText += token
                    overlayController.appendStreamToken(token)
                }
            } catch {
                guard !Task.isCancelled else { return }
                appState.logger.log("SESSION | stream error: \(error.localizedDescription)")
                EventReporter.shared.capture(level: .error, engine: "overlay", event: "stream_draft_failed",
                    message: error.localizedDescription)
                overlayController.hideWithCancelAnimation()
                isInSession = false
                return
            }

            guard !Task.isCancelled, !fullText.isEmpty else {
                if !Task.isCancelled {
                    appState.logger.log("SESSION | empty draft")
                    EventReporter.shared.capture(level: .warning, engine: "overlay", event: "draft_empty",
                        message: "Draft was empty after streaming completed")
                    overlayController.hideWithCancelAnimation()
                    isInSession = false
                }
                return
            }

            let processed = platform.postProcess(fullText)
            appState.drafter.originalDraft = processed
            appState.drafter.lastRawText = voiceText

            overlayController.onConfirm = { [weak self] in
                self?.confirmAndInject(platform: platform)
            }
            overlayController.onCancel = { [weak self] in
                self?.cancelSession()
            }
            overlayController.finishStreaming()
            appState.logger.log("REVIEW | streaming complete, \(processed.count) chars")
        }
    }

    func cancelSession() {
        guard let (appState, overlayController) = readyState() else { return }
        visionTask?.cancel()
        visionTask = nil
        streamingTask?.cancel()
        streamingTask = nil
        if appState.sttRouter.isRecording {
            appState.sttRouter.cancel()
        }
        overlayController.hideWithCancelAnimation()
        isInSession = false
        appState.logger.log("SESSION | cancelled")
        #if BETA_BUILD
        let duration = CFAbsoluteTimeGetCurrent() - sessionStartTime
        BetaTelemetry.shared.sendEvent(
            type: "draft_cancelled",
            sourceApp: sessionSourceApp?.bundleIdentifier,
            payload: ["duration_s": Int(duration)]
        )
        #endif
    }

    // MARK: - Dictation Mode (Option+Space)

    /// Start dictation — show overlay and begin voice recording (no screenshot/vision)
    func startDictation(sourceApp: NSRunningApplication?) {
        guard let (appState, overlayController) = readyState() else { return }
        guard !isDictating, !isInSession else { return }
        isDictating = true
        sessionSourceApp = sourceApp
        sessionStartTime = CFAbsoluteTimeGetCurrent()
        lastCompletedText = nil

        overlayController.activeMode = .dictation
        overlayController.state = .listening
        overlayController.showPanel(near: sourceApp)

        // If model isn't loaded yet, show loading overlay and wait (up to 120s)
        if !appState.sttRouter.isModelLoaded {
            appState.logger.log("DICTATION | waiting for model to load…")
            overlayController.showLoadingState()

            let capturedSourceApp = sourceApp
            streamingTask?.cancel()
            streamingTask = Task { [weak self] in
                guard let self = self else { return }
                for _ in 0..<DraftConstants.modelLoadMaxIterations {
                    guard !Task.isCancelled else { return }
                    if await self.appState?.sttRouter.isModelLoaded == true { break }
                    try? await Task.sleep(nanoseconds: DraftConstants.modelLoadPollInterval)
                }
                guard !Task.isCancelled else { return }
                guard await self.appState?.sttRouter.isModelLoaded == true else {
                    await self.appState?.logger.log("DICTATION | model load timed out")
                    await self.overlayController?.showError("Voice model failed to load")
                    self.isDictating = false
                    return
                }
                await self.beginDictationRecording(sourceApp: capturedSourceApp)
            }
            return
        }

        beginDictationRecording(sourceApp: sourceApp)
    }

    /// Actually start dictation recording — called directly or after model wait
    private func beginDictationRecording(sourceApp: NSRunningApplication?) {
        guard let appState = appState, let overlayController = overlayController else { return }
        guard isDictating else { return }

        overlayController.state = .listening
        // After loading state, panel may be at full height — shrink to compact for listening
        resizePanelToCompact()

        guard appState.sttRouter.startRecording() else {
            appState.logger.log("DICTATION | recording failed to start")
            overlayController.showError("Microphone unavailable")
            isDictating = false
            return
        }
        appState.logger.log("DICTATION | started (parakeet, \(appState.sttRouter.inputDeviceName))")
    }

    /// Stop dictation and paste — Parakeet batch transcription
    func stopDictationAndPaste() {
        guard let (appState, overlayController) = readyState() else { return }
        guard isDictating, overlayController.state == .listening else { return }
        // Stay compact during transcription — don't expand to full drafting height.
        // Just update the state for the spinner, keeping the compact panel size.
        overlayController.transcriptExpanded = false
        overlayController.state = .drafting

        appState.sttRouter.stopRecording()
        streamingTask?.cancel()
        streamingTask = Task {
            let voiceText = await appState.sttRouter.transcribe()
            guard !Task.isCancelled else { return }

            guard let text = voiceText, !text.isEmpty else {
                appState.logger.log("DICTATION | no transcription, cancelling")
                EventReporter.shared.capture(level: .warning, engine: "overlay", event: "no_voice_input",
                    message: "Dictation transcription empty")
                overlayController.showError("No speech detected")
                isDictating = false
                return
            }

            guard !Task.isCancelled else { return }
            appState.logger.log("DICTATION | pasting \(text.count) chars")
            lastCompletedText = text
            overlayController.hideWithConfirmAnimation { [weak self] in
                self?.pasteWithClipboardRestore(text)
            }
            isDictating = false
            appState.logger.log("DICTATION | pasted \(text.count) chars")
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

    private func processVision(imageData: Data?, sourceApp: NSRunningApplication?) async {
        guard let appState = appState else { return }

        // Use injected context if provided (e.g., onboarding demo)
        if let override = overrideContext {
            lastCapturedContext = override
            appState.logger.log("SESSION | using override context — platform=\(override.platform ?? "nil")")
            return
        }

        guard let imageData = imageData else {
            appState.logger.log("SESSION | no screenshot, proceeding voice-only")
            overlayController?.hasContext = false
            return
        }

        do {
            // OCR only — no LLM call. Raw text goes directly into the drafting prompt.
            let context = try await LocalVisionExtractor.extractContext(imageData: imageData)
            lastCapturedContext = context
            let charCount = context.conversation?.count ?? 0
            appState.logger.log("SESSION | OCR complete — \(charCount) chars extracted")
        } catch {
            appState.logger.log("SESSION | OCR error: \(error.localizedDescription), proceeding voice-only")
            EventReporter.shared.capture(level: .warning, engine: "overlay", event: "ocr_failed",
                message: error.localizedDescription)
            overlayController?.hasContext = false
        }
    }

    private func looksLikeRefusal(_ text: String) -> Bool {
        DraftUtils.looksLikeRefusal(text)
    }

    /// Called by Enter key in review — injects the (possibly edited) text
    private func confirmAndInject(platform: PlatformFormatter) {
        guard let appState = appState, let overlayController = overlayController else { return }
        guard isInSession else { return }
        let editedText = overlayController.reviewText
        let originalDraft = appState.drafter.originalDraft

        // Surface completed text for observers (e.g., onboarding view)
        lastCompletedText = editedText

        // Confirm animation, then paste to target app
        overlayController.hideWithConfirmAnimation { [weak self] in
            self?.pasteWithClipboardRestore(editedText)
        }

        // Record with REAL edit data — but skip refusals to avoid poisoning style training
        if !looksLikeRefusal(originalDraft) {
            // Capture voice instructions + vision metadata for richer training signal
            let voiceInstructions = appState.drafter.lastRawText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let formalityLevel = lastCapturedContext?.formality

            appState.styleEngine.recordExample(
                aiDraft: originalDraft,
                userFinal: editedText,
                platform: platform.rawValue,
                userInstructions: voiceInstructions.isEmpty ? nil : voiceInstructions,
                formality: formalityLevel
            )
            appState.feedbackStore.record(
                rawText: voiceInstructions,
                draftedText: originalDraft,
                acceptedText: editedText,
                action: .paste,
                exampleCount: appState.styleEngine.exampleCount,
                formality: formalityLevel
            )
            #if BETA_BUILD
            let duration = CFAbsoluteTimeGetCurrent() - sessionStartTime
            BetaTelemetry.shared.sendEvent(
                type: "draft_accepted",
                sourceApp: sessionSourceApp?.bundleIdentifier,
                payload: [
                    "raw_chars": voiceInstructions.count,
                    "draft_chars": originalDraft.count,
                    "accepted_chars": editedText.count,
                    "platform": platform.rawValue,
                    "was_edited": originalDraft != editedText,
                    "duration_s": Int(duration),
                ]
            )
            #endif
        } else {
            appState.logger.log("STYLE | skipping refusal example — not recording as training data")
            EventReporter.shared.capture(level: .info, engine: "overlay", event: "refusal_detected",
                message: "Draft contained refusal pattern — skipping training pair",
                context: ["draft_length": "\(originalDraft.count)"])
        }

        // Check if style refinement is needed
        if appState.styleEngine.shouldRefineNow(), appState.localInference.isReady {
            Task {
                await appState.styleEngine.regenerateStyleSummary(draftEngine: appState.localInference.draftEngine)
                appState.logger.log("STYLE | summary updated")
            }
        }

        isInSession = false
        appState.logger.log("SESSION | confirmed and injected (\(editedText.count) chars)")
    }

    private func pasteWithClipboardRestore(_ text: String) {
        guard let appState = appState else { return }
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

        // Check Accessibility permission
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            appState.logger.log("SESSION | requesting Accessibility permission")
            return
        }

        // Simulate Cmd+V — target app is already frontmost (overlay is non-activating)
        guard let vDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true),
              let vUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false) else {
            EventReporter.shared.capture(level: .error, engine: "overlay", event: "cgevent_create_failed",
                message: "CGEvent creation returned nil — paste will not work")
            return
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
        Task { @MainActor in
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
    }
}
