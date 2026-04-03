// DraftAppState.swift
// Centralized engine ownership — lives in AppDelegate, survives window cycles

import SwiftUI
import ServiceManagement

@MainActor
class DraftAppState: ObservableObject {
    let drafter = DraftEngine()
    let styleEngine = StyleEngine()
    let promptStore = PromptStore()
    let feedbackStore = FeedbackStore()
    let logger = AppLogger()
    let contextCapture = ContextCaptureEngine()
    let analysisEngine = AnalysisEngine()
    let localInference = LocalInferenceManager()
    let geminiEngine = GeminiEngine()
    let sttRouter = STTRouter()
    #if BETA_BUILD
    let updateManager = UpdateManager()
    #endif

    private var promptsObserver: NSObjectProtocol?
    private var wakeHealthCheckTask: Task<Void, Never>?
    private var isInitialized = false

    func initialize() async {
        guard !isInitialized else { return }
        isInitialized = true
        drafter.styleEngine = styleEngine
        drafter.promptStore = promptStore
        styleEngine.promptStore = promptStore

        #if !BETA_BUILD
        // Wire analysis engine with local inference
        analysisEngine.localInference = localInference

        // Start native analysis engine
        analysisEngine.start()

        // Listen for prompt changes applied by the analysis engine
        if promptsObserver == nil {
            promptsObserver = NotificationCenter.default.addObserver(
                forName: .promptsDidChange,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.promptStore.reload()
                    self?.logger.log("AGENT | prompts.json reloaded after analysis change")
                }
            }
        }
        #endif

        #if BETA_BUILD
        // Register as login item so model is pre-loaded when user needs it
        do {
            try SMAppService.mainApp.register()
        } catch {
            EventReporter.shared.capture(level: .warning, engine: "app", event: "login_item_failed",
                message: error.localizedDescription)
        }

        // Start periodic telemetry shipping (60s incremental uploads)
        BetaTelemetry.shared.startPeriodicShipping()

        // Report app launch to proxy
        BetaTelemetry.shared.sendEvent(
            type: "app_launched",
            payload: [
                "style_examples": styleEngine.exampleCount,
            ]
        )
        #endif

        // Initialize models in background (don't block app startup)
        Task {
            await sttRouter.parakeetEngine.initialize()
            sttRouter.parakeetEngine.prewarm()
        }
        Task {
            await localInference.initialize()
        }

        let geminiStatus = GeminiEngine.isAvailable ? "configured" : "not configured"
        logger.log("APP LAUNCHED | style: \(styleEngine.exampleCount) examples, gemini: \(geminiStatus)")
        EventTracker.track("app.launched", with: [
            "style_examples": "\(styleEngine.exampleCount)",
        ])

        // Wire EventReporter with live engine state for context enrichment
        EventReporter.shared.setEngineStateSummary { [weak self] in
            guard let self else { return [:] }
            return [
                "parakeet_loaded": "\(sttRouter.parakeetEngine.isModelLoaded)",
                "stt_recording": "\(sttRouter.isRecording)",
                "style_examples": "\(styleEngine.exampleCount)",
                "llm_state": localInference.statusLabel,
                "gemini_available": "\(GeminiEngine.isAvailable)",
            ]
        }
        EventReporter.shared.capture(level: .info, engine: "app", event: "app_launched",
            message: "Draft initialized (local inference)", context: [
                "style_examples": "\(styleEngine.exampleCount)",
            ])
    }

    #if BETA_BUILD
    // Beta config check removed — no cloud dependency
    #endif

    // MARK: - Wake Recovery

    /// Centralized recovery after system wake. Each subsystem that holds OS-level resources
    /// (file descriptors, audio hardware, Metal contexts, Carbon hotkeys) must be checked
    /// and restored here. ParakeetEngine handles its own wake via NSWorkspace observer.
    func handleSystemWake() {
        logger.log("WAKE | system wake detected — running recovery checks")

        // 1. Carbon hotkeys — can become unresponsive after sleep. Re-register.
        contextCapture.unregisterHotkey()
        contextCapture.registerHotkey()
        logger.log("WAKE | hotkeys re-registered")

        // 2. Analysis engine file watcher — DispatchSource file descriptors can stale.
        #if !BETA_BUILD
        analysisEngine.stop()
        analysisEngine.start()
        logger.log("WAKE | analysis file watcher restarted")
        #endif

        // 3. MLX model — Metal GPU contexts can become invalid after sleep.
        //    If the model was loaded, verify it's still responsive. If not, reload.
        //    Skip if a session is active or the model is mid-generation.
        if localInference.isReady {
            let sessionActive = contextCapture.sessionController?.isInSession == true
                || contextCapture.sessionController?.isDictating == true
            if sessionActive {
                logger.log("WAKE | skipping MLX health check — session active")
            } else {
                wakeHealthCheckTask?.cancel()
                wakeHealthCheckTask = Task {
                    guard !Task.isCancelled else { return }
                    // Skip if model is busy (actor-isolated check)
                    guard await !localInference.draftEngine.isBusy else {
                        logger.log("WAKE | skipping MLX health check — model generating")
                        return
                    }
                    do {
                        // Quick health check — generate a single token
                        let _ = try await localInference.draftEngine.complete(
                            prompt: "hi",
                            systemPrompt: "Reply with OK",
                            maxTokens: 4,
                            temperature: 0
                        )
                        logger.log("WAKE | MLX model health check passed")
                    } catch {
                        guard !Task.isCancelled else { return }
                        logger.log("WAKE | MLX model health check failed: \(error.localizedDescription), reloading")
                        EventReporter.shared.capture(level: .warning, engine: "local",
                            event: "wake_model_stale",
                            message: "MLX model unresponsive after wake, reloading: \(error.localizedDescription)")
                        localInference.cleanup()
                        await localInference.initialize()
                    }
                }
            }
        }

        // ParakeetEngine handles its own wake recovery via NSWorkspace.didWakeNotification
        // observer installed during prewarm(). No action needed here.

        EventReporter.shared.capture(level: .info, engine: "app", event: "wake_recovery",
            message: "System wake recovery completed")
    }

    func shutdown() {
        #if BETA_BUILD
        BetaTelemetry.shared.stopPeriodicShipping()
        #endif
        wakeHealthCheckTask?.cancel()
        wakeHealthCheckTask = nil
        analysisEngine.stop()
        sttRouter.parakeetEngine.cleanup()
        localInference.cleanup()
        contextCapture.unregisterHotkey()
        if let observer = promptsObserver {
            NotificationCenter.default.removeObserver(observer)
            promptsObserver = nil
        }
    }
}
