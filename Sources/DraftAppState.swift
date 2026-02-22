// DraftAppState.swift
// Centralized engine ownership — lives in AppDelegate, survives window cycles

import SwiftUI

// MARK: - Transcription Engine Selection

enum TranscriptionEngine: String, CaseIterable {
    case appleSpeech = "apple"
    case whisper = "whisper"

    var displayName: String {
        switch self {
        case .appleSpeech: return "Apple Speech"
        case .whisper: return "Whisper"
        }
    }

    static var stored: TranscriptionEngine {
        guard let raw = UserDefaults.standard.string(forKey: "transcription-engine"),
              let engine = TranscriptionEngine(rawValue: raw) else { return .appleSpeech }
        return engine
    }

    func save() {
        UserDefaults.standard.set(rawValue, forKey: "transcription-engine")
    }
}

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
    @Published var transcriptionEngine: TranscriptionEngine = .stored

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

        // Pre-load Whisper model if selected and available
        if transcriptionEngine == .whisper, let path = modelManager.modelPath {
            _ = whisperEngine.loadModel(path: path)
        }

        logger.log("🚀 APP LAUNCHED | auth: \(drafter.authModeName), style: \(styleEngine.exampleCount) examples, model: \(promptStore.config.model), engine: \(transcriptionEngine.displayName), hotkey registered, analysis engine started")
    }

    func switchTranscriptionEngine(to engine: TranscriptionEngine) {
        transcriptionEngine = engine
        engine.save()
        if engine == .whisper {
            if let path = modelManager.modelPath, !whisperEngine.isModelLoaded {
                _ = whisperEngine.loadModel(path: path)
            }
        } else {
            whisperEngine.unloadModel()
        }
        logger.log("🔄 ENGINE | switched to \(engine.displayName)")
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
