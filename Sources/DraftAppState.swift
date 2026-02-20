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
    let orchestrator = OrchestratorBridge()
    let chatEngine = StreamingChatEngine()

    private var promptsObserver: NSObjectProtocol?

    func initialize() async {
        _ = await speech.requestPermissions()
        drafter.checkCredential()
        drafter.styleEngine = styleEngine
        drafter.promptStore = promptStore
        styleEngine.promptStore = promptStore
        contextCapture.promptStore = promptStore
        chatEngine.promptStore = promptStore

        // Start orchestrator agent subprocess
        orchestrator.logger = logger
        orchestrator.start()

        // Listen for prompt changes from the agent
        if promptsObserver == nil {
            promptsObserver = NotificationCenter.default.addObserver(
                forName: .promptsDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.promptStore.reload()
                    self?.logger.log("🤖 AGENT | prompts.json reloaded after agent change")
                }
            }
        }

        logger.log("🚀 APP LAUNCHED | auth: \(drafter.authModeName), style: \(styleEngine.exampleCount) examples, model: \(promptStore.config.model), hotkey registered, agent started")
    }

    func shutdown() {
        orchestrator.stop()
        contextCapture.unregisterHotkey()
        if let observer = promptsObserver {
            NotificationCenter.default.removeObserver(observer)
            promptsObserver = nil
        }
    }
}
