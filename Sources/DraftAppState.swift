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
    let previousAppTracker = PreviousAppTracker()
    let contextCapture = ContextCaptureEngine()
    let analysisEngine = AnalysisEngine()
    let chatEngine = StreamingChatEngine()
    let sttRouter = STTRouter()
    #if BETA_BUILD
    let updateManager = UpdateManager()
    #endif

    private var promptsObserver: NSObjectProtocol?
    private var isInitialized = false

    func initialize() async {
        guard !isInitialized else { return }
        isInitialized = true
        drafter.checkCredential()
        drafter.styleEngine = styleEngine
        drafter.promptStore = promptStore
        styleEngine.promptStore = promptStore
        chatEngine.promptStore = promptStore

        #if !BETA_BUILD
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
                    self?.chatEngine.invalidatePromptCache()
                    self?.logger.log("🤖 AGENT | prompts.json reloaded after analysis change")
                }
            }
        }
        #endif

        #if BETA_BUILD
        // Always inject beta token — clears any existing API key or subscription token
        _ = AuthCredential.saveBetaToken(BetaConfig.userToken)
        drafter.checkCredential()

        // Beta proxy may not support Sonnet — use Haiku for all API calls
        promptStore.config.draftModel = DefaultPrompts.model

        // Check if beta is still active
        Task {
            await checkBetaConfig()
        }

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
                "app_version": BetaConfig.appVersion,
            ]
        )
        #endif

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

    #if BETA_BUILD
    private func checkBetaConfig() async {
        guard let auth = AuthCredential.load() else { return }
        var request = URLRequest(url: URL(string: "\(BetaConfig.proxyBaseURL)/config")!)
        request.httpMethod = "GET"
        auth.apply(to: &request)

        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

            // Check if beta access is revoked
            if let active = json["active"] as? Bool, !active {
                let message = json["message"] as? String ?? "Beta access has ended. Thanks for testing!"
                logger.log("BETA | access revoked: \(message)")
                showBetaEndedAlert(message: message)
                return
            }

            // Auto-update if a newer version is available
            if let latestVersion = json["latest_version"] as? String,
               compareVersions(BetaConfig.appVersion, latestVersion) == .orderedAscending,
               let downloadURL = json["download_url"] as? String {
                logger.log("BETA | auto-update: current=\(BetaConfig.appVersion) latest=\(latestVersion)")
                await updateManager.checkAndUpdate(latestVersion: latestVersion, downloadURL: downloadURL)
            }

            // Show optional banner message
            if let message = json["message"] as? String, !message.isEmpty {
                logger.log("BETA | server message: \(message)")
            }
        } catch {
            // Config check failure is non-fatal — continue normally
            logger.log("BETA | config check failed: \(error.localizedDescription)")
        }
    }

    /// Semantic version comparison (e.g. "1.0.0" vs "1.1.0")
    private func compareVersions(_ a: String, _ b: String) -> ComparisonResult {
        let aParts = a.split(separator: ".").compactMap { Int($0) }
        let bParts = b.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(aParts.count, bParts.count)
        for i in 0..<maxLen {
            let av = i < aParts.count ? aParts[i] : 0
            let bv = i < bParts.count ? bParts[i] : 0
            if av < bv { return .orderedAscending }
            if av > bv { return .orderedDescending }
        }
        return .orderedSame
    }

    private func showBetaEndedAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "Draft Beta"
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    #endif

    func shutdown() {
        #if BETA_BUILD
        BetaTelemetry.shared.stopPeriodicShipping()
        #endif
        analysisEngine.stop()
        sttRouter.parakeetEngine.cleanup()
        contextCapture.unregisterHotkey()
        if let observer = promptsObserver {
            NotificationCenter.default.removeObserver(observer)
            promptsObserver = nil
        }
    }
}
