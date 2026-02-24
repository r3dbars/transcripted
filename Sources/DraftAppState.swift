// DraftAppState.swift
// Centralized engine ownership — lives in AppDelegate, survives window cycles

import SwiftUI

@MainActor
class DraftAppState: ObservableObject {
    let speech = SpeechEngine()
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
    let modelManager = ModelManager()

    private var promptsObserver: NSObjectProtocol?
    private var isInitialized = false

    func initialize() async {
        guard !isInitialized else { return }
        isInitialized = true
        _ = await speech.requestPermissions()
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

        // Load Whisper model (always available as fallback)
        if let path = modelManager.modelPath {
            _ = sttRouter.whisperEngine.loadModel(path: path)
            sttRouter.whisperEngine.prewarm()
            logger.log("🎙️ WHISPER | model loaded + engine pre-warmed (\(sttRouter.whisperEngine.inputDeviceName), \(path))")
        } else {
            logger.log("⚠️ WHISPER | model not found — run build-whisper.sh to download")
        }

        // If Parakeet is the active engine, start model download in background
        // (don't block app startup — Whisper is always available as fallback)
        #if PARAKEET_AVAILABLE
        if sttRouter.activeChoice == .parakeet {
            Task {
                await sttRouter.parakeetEngine.initialize()
                sttRouter.parakeetEngine.prewarm()
            }
        }
        #endif

        logger.log("🚀 APP LAUNCHED | auth: \(drafter.authModeName), style: \(styleEngine.exampleCount) examples, model: \(promptStore.config.model), engine: \(sttRouter.activeChoice.rawValue), hotkey registered, analysis engine started")

        // Wire EventReporter with live engine state for context enrichment
        EventReporter.shared.setEngineStateSummary { [weak self] in
            guard let self else { return [:] }
            return [
                "stt_engine": sttRouter.activeChoice.rawValue,
                "whisper_loaded": "\(sttRouter.whisperEngine.isModelLoaded)",
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
                "stt_engine": sttRouter.activeChoice.rawValue,
            ])
    }

    func shutdown() {
        analysisEngine.stop()
        sttRouter.whisperEngine.unloadModel()
        #if PARAKEET_AVAILABLE
        sttRouter.parakeetEngine.cleanup()
        #endif
        contextCapture.unregisterHotkey()
        if let observer = promptsObserver {
            NotificationCenter.default.removeObserver(observer)
            promptsObserver = nil
        }
    }
}
