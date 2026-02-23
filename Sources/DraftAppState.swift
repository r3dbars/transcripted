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
    let whisperEngine = WhisperEngine()
    let modelManager = ModelManager()

    private var promptsObserver: NSObjectProtocol?

    func initialize() async {
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

        // Load Whisper model (sole transcription engine)
        if let path = modelManager.modelPath {
            _ = whisperEngine.loadModel(path: path)
            whisperEngine.prewarm()
            logger.log("🎙️ WHISPER | model loaded + engine pre-warmed (\(whisperEngine.inputDeviceName), \(path))")
        } else {
            logger.log("⚠️ WHISPER | model not found — run build-whisper.sh to download")
        }

        logger.log("🚀 APP LAUNCHED | auth: \(drafter.authModeName), style: \(styleEngine.exampleCount) examples, model: \(promptStore.config.model), engine: Whisper, hotkey registered, analysis engine started")
    }

    func shutdown() {
        analysisEngine.stop()
        whisperEngine.unloadModel()
        contextCapture.unregisterHotkey()
        if let observer = promptsObserver {
            NotificationCenter.default.removeObserver(observer)
            promptsObserver = nil
        }
    }
}
