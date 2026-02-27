// DraftSessionController.swift
// Session orchestration for draft mode (Option+D) and dictation mode (Option+Space)

import SwiftUI
import AppKit
import Combine

@MainActor
class DraftSessionController: ObservableObject {
    @Published var isInSession = false
    @Published var isDictating = false

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

    private var lastCapturedContext: CapturedContext?
    private var sessionSourceApp: NSRunningApplication?
    private var streamingTask: Task<Void, Never>?
    private var visionTask: Task<Void, Never>?

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
        guard let appState = appState, let overlayController = overlayController else { return }
        guard !isInSession, !isDictating else { return }
        isInSession = true
        sessionSourceApp = sourceApp

        // Store source app for paste-back
        if let app = sourceApp {
            appState.contextCapture.sourceApp = app
        }

        lastCapturedContext = nil
        appState.drafter.clear()

        // Show overlay and start recording
        overlayController.activeMode = .draft
        overlayController.state = .listening
        overlayController.showPanel(near: sourceApp)

        if !appState.sttRouter.isModelLoaded {
            appState.logger.log("SESSION | model not loaded yet")
            overlayController.showError("Voice model loading…")
            isInSession = false
            return
        }
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
        guard let appState = appState, let overlayController = overlayController else { return }
        guard isInSession else { return }
        overlayController.state = .drafting

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

            guard let auth = AuthCredential.load() else {
                appState.logger.log("SESSION | no auth credential, cancelling")
                EventReporter.shared.capture(level: .error, engine: "overlay", event: "auth_missing",
                    message: "No API credential configured")
                visionTask?.cancel()
                visionTask = nil
                overlayController.showError("No API key configured")
                isInSession = false
                return
            }

            // Wait for vision to complete (or its 8-second timeout) before checking context
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
                userMessage = "The user dictated the following message. Clean it up, fix grammar, and make it sound natural while preserving their intent and tone. Do NOT add greetings, sign-offs, or change the meaning. Output ONLY the cleaned-up message.\n\nDICTATED:\n\(voiceText.trimmingCharacters(in: .whitespacesAndNewlines))"
            }

            let model = appState.promptStore.config.draftModel
            let stream = AnthropicAPI.streamDraft(
                rawText: userMessage,
                auth: auth,
                model: model,
                systemPrompt: systemPrompt.isEmpty ? nil : systemPrompt
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
        guard let appState = appState, let overlayController = overlayController else { return }
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
    }

    // MARK: - Dictation Mode (Option+Space)

    /// Start dictation — show overlay and begin voice recording (no screenshot/vision)
    func startDictation(sourceApp: NSRunningApplication?) {
        guard let appState = appState, let overlayController = overlayController else { return }
        guard !isDictating, !isInSession else { return }
        isDictating = true
        sessionSourceApp = sourceApp

        if let app = sourceApp {
            appState.contextCapture.sourceApp = app
        }

        overlayController.activeMode = .dictation
        overlayController.state = .listening
        overlayController.showPanel(near: sourceApp)

        if !appState.sttRouter.isModelLoaded {
            appState.logger.log("DICTATION | model not loaded yet")
            overlayController.showError("Voice model loading…")
            isDictating = false
            return
        }
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
        guard let appState = appState, let overlayController = overlayController else { return }
        guard isDictating, overlayController.state == .listening else { return }
        overlayController.state = .drafting

        appState.sttRouter.stopRecording()
        Task {
            let voiceText = await appState.sttRouter.transcribe()

            guard let text = voiceText, !text.isEmpty else {
                appState.logger.log("DICTATION | no transcription, cancelling")
                EventReporter.shared.capture(level: .warning, engine: "overlay", event: "no_voice_input",
                    message: "Dictation transcription empty")
                overlayController.showError("No speech detected")
                isDictating = false
                return
            }

            appState.logger.log("DICTATION | pasting \(text.count) chars")
            overlayController.hideWithConfirmAnimation { [weak self] in
                self?.pasteWithClipboardRestore(text)
            }
            isDictating = false
            appState.logger.log("DICTATION | pasted \(text.count) chars")
        }
    }

    /// Cancel dictation without pasting
    func cancelDictation() {
        guard let appState = appState, let overlayController = overlayController else { return }
        if appState.sttRouter.isRecording {
            appState.sttRouter.cancel()
        }
        overlayController.hideWithCancelAnimation()
        isDictating = false
        appState.logger.log("DICTATION | cancelled")
    }

    /// Apply light polish (punctuation, capitalization, grammar) to raw dictation.
    /// Falls back to raw text if API call fails — dictation must NEVER lose text.
    private func polishDictation(_ rawText: String) async -> String {
        guard let appState = appState else { return rawText }
        guard let auth = AuthCredential.load() else {
            appState.logger.log("DICTATION | no auth, pasting raw text")
            return rawText
        }

        let polishPrompt = """
            Fix punctuation, capitalization, and obvious grammar errors in this dictation. \
            Do NOT rephrase, reorganize, or change wording. Preserve the user's exact words. \
            Do NOT add greetings, sign-offs, or extra text. Output ONLY the corrected text.
            """

        let model = appState.promptStore.config.draftModel

        do {
            let polished = try await AnthropicAPI.withTimeout(seconds: 5) {
                try await AnthropicAPI.draft(
                    rawText: "DICTATED:\n\(rawText)",
                    auth: auth,
                    model: model,
                    systemPrompt: polishPrompt,
                    maxTokens: 1024
                )
            }

            // Sanity check: reject if length ratio is suspicious (hallucination or truncation)
            let ratio = Double(polished.count) / Double(max(1, rawText.count))
            if ratio < 0.5 || ratio > 2.0 {
                appState.logger.log("DICTATION | polish length suspicious (ratio \(String(format: "%.2f", ratio))), using raw")
                return rawText
            }

            return polished.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            appState.logger.log("DICTATION | polish failed: \(error.localizedDescription), pasting raw text")
            EventReporter.shared.capture(level: .warning, engine: "overlay", event: "polish_failed",
                message: error.localizedDescription)
            return rawText
        }
    }

    // MARK: - Private

    private func processVision(imageData: Data?, sourceApp: NSRunningApplication?) async {
        guard let appState = appState else { return }
        guard let auth = AuthCredential.load(), let imageData = imageData else {
            appState.logger.log("SESSION | no auth or screenshot, proceeding voice-only")
            return
        }

        let userName = UserDefaults.standard.string(forKey: "user-display-name")
        let appName = sourceApp?.localizedName
        let model = appState.promptStore.config.model
        let extractionPrompt = appState.promptStore.contextExtractionPrompt(userName: userName, appName: appName)

        do {
            // 8-second timeout — vision calls typically take 2-6s; 4s was too tight and caused frequent timeouts
            let context = try await AnthropicAPI.withTimeout(seconds: 8) {
                try await AnthropicAPI.extractStructuredContext(
                    imageData: imageData,
                    auth: auth,
                    model: model,
                    systemPrompt: extractionPrompt
                )
            }
            lastCapturedContext = context
            appState.logger.log("SESSION | vision complete — platform=\(context.platform ?? "nil")")
        } catch {
            appState.logger.log("SESSION | vision timeout/error: \(error.localizedDescription), proceeding voice-only")
            EventReporter.shared.capture(level: .warning, engine: "overlay", event: "vision_timeout",
                message: error.localizedDescription)
            // Proceed without context — voiceText alone is enough to draft
        }
    }

    /// Detect if a draft is Claude refusing/asking for clarification rather than an actual message
    private func looksLikeRefusal(_ text: String) -> Bool {
        let lower = text.lowercased()
        let refusalPhrases = [
            "i need the actual",
            "i need more context",
            "could you provide",
            "i'd need to see",
            "please provide",
            "i can't write",
            "i don't have enough"
        ]
        return refusalPhrases.contains { lower.contains($0) }
    }

    /// Called by Enter key in review — injects the (possibly edited) text
    private func confirmAndInject(platform: PlatformFormatter) {
        guard let appState = appState, let overlayController = overlayController else { return }
        guard isInSession else { return }
        let editedText = overlayController.reviewText
        let originalDraft = appState.drafter.originalDraft

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
        } else {
            appState.logger.log("STYLE | skipping refusal example — not recording as training data")
            EventReporter.shared.capture(level: .info, engine: "overlay", event: "refusal_detected",
                message: "Draft contained refusal pattern — skipping training pair",
                context: ["draft_length": "\(originalDraft.count)"])
        }

        // Check if style refinement is needed
        if appState.styleEngine.shouldRefineNow(), let auth = appState.drafter.getAuth() {
            Task {
                await appState.styleEngine.regenerateStyleSummary(auth: auth)
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
        let vDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: true)
        vDown?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)

        let vUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x09, keyDown: false)
        vUp?.flags = .maskCommand
        vUp?.post(tap: .cghidEventTap)

        // Restore clipboard after paste completes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            pasteboard.clearContents()
            for typeData in savedItems {
                let item = NSPasteboardItem()
                for (type, data) in typeData {
                    item.setData(data, forType: type)
                }
                pasteboard.writeObjects([item])
            }
        }
    }
}
