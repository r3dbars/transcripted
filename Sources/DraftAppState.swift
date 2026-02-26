// DraftAppState.swift
// Centralized engine ownership — lives in AppDelegate, survives window cycles

import SwiftUI

@MainActor
class DraftAppState: ObservableObject {
    let drafter = DraftEngine()
    let styleEngine = StyleEngine()
    let promptStore = PromptStore()
    let feedbackStore = FeedbackStore()
    let logger = AppLogger()
    let previousAppTracker = PreviousAppTracker()
    let contextCapture = ContextCaptureEngine()
    let analysisEngine = AnalysisEngine()
    let chatEngine = StreamingChatEngine()
    let sttRouter = STTRouter()

    private var promptsObserver: NSObjectProtocol?
    private var isInitialized = false

    func initialize() async {
        guard !isInitialized else { return }
        isInitialized = true
        drafter.checkCredential()
        drafter.styleEngine = styleEngine
        drafter.promptStore = promptStore
        styleEngine.promptStore = promptStore
        contextCapture.promptStore = promptStore
        chatEngine.promptStore = promptStore

        // Start native analysis engine (replaces Python agent subprocess)
        analysisEngine.start()

        // Wire chat engine → analysis engine for insight card passthrough
        chatEngine.onInsightProposed = { [weak analysisEngine] card in
            analysisEngine?.addInsight(card)
        }

        // Listen for prompt changes applied by the analysis engine
        if promptsObserver == nil {
            promptsObserver = NotificationCenter.default.addObserver(
                forName: .promptsDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.promptStore.reload()
                    self?.logger.log("🤖 AGENT | prompts.json reloaded after analysis change")
                }
            }
        }

        // Initialize Parakeet STT engine in background (don't block app startup)
        Task {
            await sttRouter.parakeetEngine.initialize()
            sttRouter.parakeetEngine.prewarm()
        }

        logger.log("🚀 APP LAUNCHED | auth: \(drafter.authModeName), style: \(styleEngine.exampleCount) examples, model: \(promptStore.config.model), hotkey registered, analysis engine started")

        // Wire EventReporter with live engine state for context enrichment
        EventReporter.shared.setEngineStateSummary { [weak self] in
            guard let self else { return [:] }
            return [
                "parakeet_loaded": "\(sttRouter.parakeetEngine.isModelLoaded)",
                "stt_recording": "\(sttRouter.isRecording)",
                "style_examples": "\(styleEngine.exampleCount)",
                "auth_mode": drafter.authModeName,
            ]
        }
        EventReporter.shared.capture(level: .info, engine: "app", event: "app_launched",
            message: "Draft initialized", context: [
                "auth": drafter.authModeName,
                "style_examples": "\(styleEngine.exampleCount)",
                "model": promptStore.config.model,
            ])
    }

    func shutdown() {
        analysisEngine.stop()
        sttRouter.parakeetEngine.cleanup()
        contextCapture.unregisterHotkey()
        if let observer = promptsObserver {
            NotificationCenter.default.removeObserver(observer)
            promptsObserver = nil
        }
    }
}
