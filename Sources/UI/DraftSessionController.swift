// DraftSessionController.swift
// Session orchestration for draft mode (Option+D) and dictation mode (Option+Space)

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
    private var sessionImageData: Data?
    private var streamingTask: Task<Void, Never>?
    private var visionTask: Task<Void, Never>?
    private var clipboardRestoreTask: Task<Void, Never>?
    private var styleRefinementTask: Task<Void, Never>?
    private var sessionTimeoutTask: Task<Void, Never>?
    private var sessionStartTime: CFAbsoluteTime = 0

    /// Max duration for a listening session before auto-cancel (5 minutes).
    /// Prevents stuck sessions when the user walks away from the computer.
    private static let sessionTimeoutNanos: UInt64 = 5 * 60 * 1_000_000_000

    deinit {
        streamingTask?.cancel()
        visionTask?.cancel()
        clipboardRestoreTask?.cancel()
        styleRefinementTask?.cancel()
        sessionTimeoutTask?.cancel()
    }

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
        sessionImageData = imageData
        appState.drafter.clear()

        // Show overlay and start recording
        overlayController.hasContext = true
        overlayController.activeMode = .draft
        overlayController.state = .listening
        overlayController.showPanel(near: sourceApp)

        beginRecording(imageData: imageData, sourceApp: sourceApp)
    }

    /// Actually start recording — called directly from startSession
    private func beginRecording(imageData: Data?, sourceApp: NSRunningApplication?) {
        guard let appState = appState, let overlayController = overlayController else { return }
        guard isInSession else { return }

        overlayController.state = .listening

        guard appState.sttRouter.startRecording() else {
            appState.logger.log("SESSION | recording failed to start")
            overlayController.showError("Microphone unavailable")
            isInSession = false
            return
        }

        appState.logger.log("SESSION | started (parakeet, \(appState.sttRouter.inputDeviceName)), voice recording started")

        // Start session timeout — auto-cancel after 5 minutes to prevent stuck sessions
        installSessionTimeout()

        // No vision task needed — Gemini sees the screenshot image directly.
        // The sessionImageData stored in startSession() is sent to Gemini at draft time.
    }

    /// Stop recording and trigger drafting — called on second hotkey press
    func stopSessionAndDraft() {
        guard let (appState, overlayController) = readyState() else { return }
        guard isInSession else { return }
        overlayController.enterDraftingState()

        // Cancel any in-progress background generation (e.g., style refinement)
        // to prevent "Model busy" errors when starting the user's draft.
        styleRefinementTask?.cancel()
        styleRefinementTask = nil
        sessionTimeoutTask?.cancel()
        sessionTimeoutTask = nil

        streamingTask?.cancel()
        streamingTask = Task {
            // Cancel any lingering Gemini generation
            await appState.geminiEngine.cancelGeneration()
            // Stop recording and wait for transcription model if still loading
            appState.sttRouter.stopRecording()
            if !appState.sttRouter.isModelLoaded {
                appState.logger.log("SESSION | waiting for voice model before transcribe…")
                for _ in 0..<DraftConstants.modelLoadMaxIterations {
                    guard !Task.isCancelled else { return }
                    if appState.sttRouter.isModelLoaded { break }
                    try? await Task.sleep(nanoseconds: DraftConstants.modelLoadPollInterval)
                }
                guard appState.sttRouter.isModelLoaded else {
                    appState.logger.log("SESSION | voice model failed to load for transcription")
                    overlayController.showError("Voice model failed to load")
                    isInSession = false
                    return
                }
            }
            let voiceText = (await appState.sttRouter.transcribe() ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !voiceText.isEmpty else {
                appState.logger.log("SESSION | no voice input, cancelling")
                EventReporter.shared.capture(level: .warning, engine: "overlay", event: "no_voice_input",
                    message: "Voice text empty after recording")
                visionTask?.cancel()
                visionTask = nil
                overlayController.showNoSpeechAndDismiss()
                isInSession = false
                return
            }

            let platform = PlatformFormatter.detect(from: sessionSourceApp)

            guard GeminiEngine.isAvailable else {
                appState.logger.log("SESSION | no Gemini API key configured")
                EventReporter.shared.capture(level: .error, engine: "overlay", event: "gemini_not_configured",
                    message: "No Gemini API key — configure in Settings")
                overlayController.showError("No Gemini API key — check Settings")
                isInSession = false
                return
            }

            appState.logger.log("SESSION | streaming draft via Gemini [\(platform.rawValue)] — \(voiceText.count) chars, image: \(sessionImageData != nil)")

            var systemPrompt = appState.styleEngine.buildSystemPrompt()
            if !platform.formattingInstructions.isEmpty {
                systemPrompt += "\n\n" + platform.formattingInstructions
            }

            // Build user message — Gemini sees the screenshot as an image part,
            // so the text prompt just provides platform context and voice instructions.
            let trimmedVoice = voiceText.trimmingCharacters(in: .whitespacesAndNewlines)
            let userMessage: String
            if sessionImageData != nil {
                userMessage = "Write a reply to the conversation shown in the screenshot.\n\nPLATFORM: \(platform.rawValue)\n\nUSER WANTS TO SAY:\n\(trimmedVoice)\n\nWrite a reply. Match the conversation's length and energy. Output only the message text."
            } else {
                userMessage = "Clean up this dictation. Fix grammar, keep their tone. Output only the message.\n\n\(trimmedVoice)"
            }

            let stream = await appState.geminiEngine.generate(
                prompt: userMessage,
                systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt,
                imageData: sessionImageData,
                maxTokens: DraftConstants.geminiDraftMaxTokens,
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
                visionTask?.cancel()
                visionTask = nil
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
        sessionImageData = nil
        visionTask?.cancel()
        visionTask = nil
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
        isInSession = false
        appState.logger.log("SESSION | cancelled")
        EventTracker.track("draft.rejected")
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
        // Stay compact during transcription — don't expand to full drafting height.
        // Just update the state for the spinner, keeping the compact panel size.
        overlayController.transcriptExpanded = false
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
            overlayController.hideWithConfirmAnimation { [weak self] in
                self?.pasteWithClipboardRestore(text)
            }
            isDictating = false
            appState.logger.log("DICTATION | pasted \(text.count) chars")
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

    private func processVision(imageData: Data?, sourceApp: NSRunningApplication?) async {
        guard let appState = appState else { return }

        // Use injected context if provided (e.g., onboarding demo)
        if let override = overrideContext {
            lastCapturedContext = override
            overrideContext = nil
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

    /// First Enter in review: if user edited, show diff flash. If no edits, go straight to paste.
    private func handleReviewConfirm(platform: PlatformFormatter) {
        guard let overlayController = overlayController else { return }
        guard isInSession else { return }

        let editedText = overlayController.reviewText
        let originalDraft = overlayController.originalDraftForComparison

        if DiffSummary.hasSubstantiveEdits(original: originalDraft, edited: editedText) {
            // User made edits — show diff flash for review
            let description = DiffSummary.describeEdit(
                original: originalDraft,
                edited: editedText,
                platform: platform.rawValue
            )
            overlayController.showDiffFlash(editDescription: "Draft learned: \(description)")

            // Wire second Enter (from diff flash) to actually confirm
            overlayController.onConfirm = { [weak self] in
                self?.confirmAndInject(platform: platform)
            }
            // Escape from diff flash goes back to review with re-wired closures
            overlayController.onCancel = { [weak self] in
                guard let self = self, let oc = self.overlayController else { return }
                oc.state = .review
                oc.onConfirm = { [weak self] in
                    self?.handleReviewConfirm(platform: platform)
                }
                oc.onCancel = { [weak self] in
                    self?.cancelSession()
                }
            }
        } else {
            // No edits — skip diff flash, go straight to paste
            confirmAndInject(platform: platform)
        }
    }

    /// Called by Enter key in review (no edits) or Enter in diff flash (after edits) — injects text
    private func confirmAndInject(platform: PlatformFormatter) {
        guard let appState = appState, let overlayController = overlayController else { return }
        guard isInSession else { return }
        sessionTimeoutTask?.cancel()
        sessionTimeoutTask = nil
        let editedText = overlayController.reviewText
        let originalDraft = appState.drafter.originalDraft

        // Surface completed text for observers (e.g., onboarding view)
        lastCompletedText = editedText

        // Confirm animation, then paste to target app
        overlayController.hideWithConfirmAnimation { [weak self] in
            self?.pasteWithClipboardRestore(editedText)
        }
        EventTracker.track("draft.accepted", with: [
            "word_count": "\(editedText.split(whereSeparator: \.isWhitespace).count)",
            "was_edited": "\(editedText != originalDraft)"
        ])

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
                formality: formalityLevel,
                platform: platform.rawValue,
                conversationContext: lastCapturedContext?.conversation
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

        // Check if style refinement is needed — deferred by 5 seconds so the model
        // is free if the user immediately starts another draft session. The task is
        // cancellable via styleRefinementTask (cancelled in stopSessionAndDraft).
        if appState.styleEngine.shouldRefineNow(), appState.localInference.isReady {
            styleRefinementTask?.cancel()
            styleRefinementTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)  // 5 second delay
                guard !Task.isCancelled else { return }
                guard let self = self, let appState = self.appState else { return }
                await appState.styleEngine.regenerateStyleSummary(draftEngine: appState.localInference.draftEngine)
                appState.logger.log("STYLE | summary updated")
            }
        }

        // Show training toast for edited drafts and milestones
        let wasEdited = DiffSummary.hasSubstantiveEdits(original: originalDraft, edited: editedText)
        let milestone = DiffSummary.milestoneMessage(exampleCount: appState.styleEngine.exampleCount)
        if wasEdited && !looksLikeRefusal(originalDraft) {
            let description = DiffSummary.describeEdit(original: originalDraft, edited: editedText, platform: platform.rawValue)
            let toastMessage = milestone ?? "Draft learned: \(description)"
            Task { @MainActor [weak overlayController] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                overlayController?.showTrainingToast(toastMessage)
            }
        } else if let milestone = milestone {
            Task { @MainActor [weak overlayController] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                overlayController?.showTrainingToast(milestone)
            }
        }

        isInSession = false
        sessionImageData = nil
        appState.logger.log("SESSION | confirmed and injected (\(editedText.count) chars)")
    }

    private func pasteWithClipboardRestore(_ text: String) {
        guard let appState = appState else { return }

        // Check Accessibility permission BEFORE modifying clipboard
        guard AXIsProcessTrusted() else {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            appState.logger.log("SESSION | requesting Accessibility permission")
            return
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
    }
}
