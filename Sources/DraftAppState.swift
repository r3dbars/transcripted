// DraftAppState.swift
// Centralized engine ownership — lives in AppDelegate, survives window cycles

import SwiftUI
import ServiceManagement
import TranscriptedCore

@MainActor
class DraftAppState: ObservableObject {
    let logger = AppLogger()
    let contextCapture = ContextCaptureEngine()
    let sttRouter = STTRouter()
    #if BETA_BUILD
    let updateManager = UpdateManager()
    #endif

    /// Meeting-mode pipeline (Lane B). Lazily instantiated so unit tests that
    /// don't exercise the meeting feature don't pay the construction cost.
    @available(macOS 14.0, *)
    lazy var meetingSession: MeetingSessionController = MeetingSessionController(
        parakeet: sttRouter.parakeetEngine
    )

    private var promptsObserver: NSObjectProtocol?
    private var runtimeReadinessTask: Task<Void, Never>?
    private var wakeRecoveryTask: Task<Void, Never>?
    private var isInitialized = false

    func initialize() async {
        guard !isInitialized else { return }
        isInitialized = true

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
            payload: [:]
        )
        #endif

        // Kick off shared runtime prep once; wake recovery can await or reuse it.
        startRuntimeReadinessIfNeeded()

        logger.log("APP LAUNCHED | modes: dictation + meetings")
        EventTracker.track("app.launched")

        // Wire EventReporter with live engine state for context enrichment
        EventReporter.shared.setEngineStateSummary { [weak self] in
            guard let self else { return [:] }
            return [
                "parakeet_loaded": "\(sttRouter.parakeetEngine.isModelLoaded)",
                "stt_recording": "\(sttRouter.isRecording)",
                "meeting_state": meetingStateSummary,
            ]
        }
        EventReporter.shared.capture(level: .info, engine: "app", event: "app_launched",
            message: "Transcripted initialized for dictation and meetings")
    }

    #if BETA_BUILD
    // Beta config check removed — no cloud dependency
    #endif

    // MARK: - Wake Recovery

    /// Centralized recovery after system wake. Each subsystem that holds OS-level resources
    /// (file descriptors, audio hardware, Metal contexts, Carbon hotkeys) must be checked
    /// and restored here. ParakeetEngine handles its own wake via NSWorkspace observer.
    func handleSystemWake() async {
        if let task = wakeRecoveryTask {
            await task.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.wakeRecoveryTask = nil }

            logger.log("WAKE | system wake detected — running recovery checks")

            // 1. Carbon hotkeys — can become unresponsive after sleep. Re-register.
            contextCapture.unregisterHotkey()
            contextCapture.registerHotkey()
            logger.log("WAKE | hotkeys re-registered")

            // Shared runtime prep is deduplicated through a single in-flight task.
            await self.waitForRuntimeReadiness()

            // ParakeetEngine handles its own wake recovery via NSWorkspace.didWakeNotification
            // observer installed during prewarm(). No action needed here.

            EventReporter.shared.capture(level: .info, engine: "app", event: "wake_recovery",
                message: "System wake recovery completed")
        }
        wakeRecoveryTask = task
        await task.value
    }

    func shutdown() {
        #if BETA_BUILD
        BetaTelemetry.shared.stopPeriodicShipping()
        #endif
        wakeRecoveryTask?.cancel()
        wakeRecoveryTask = nil
        runtimeReadinessTask?.cancel()
        runtimeReadinessTask = nil
        sttRouter.parakeetEngine.cleanup()
        contextCapture.unregisterHotkey()
        if let observer = promptsObserver {
            NotificationCenter.default.removeObserver(observer)
            promptsObserver = nil
        }
    }

    private func startRuntimeReadinessIfNeeded() {
        guard runtimeReadinessTask == nil else { return }

        runtimeReadinessTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.runtimeReadinessTask = nil }

            await self.sttRouter.parakeetEngine.initialize()
            guard !Task.isCancelled else { return }
            self.sttRouter.parakeetEngine.prewarm()
            guard !Task.isCancelled else { return }

            if #available(macOS 14.0, *) {
                await self.meetingSession.prepareModels(showLoadingUI: false)
            }
        }
    }

    private func waitForRuntimeReadiness() async {
        startRuntimeReadinessIfNeeded()
        await runtimeReadinessTask?.value
    }

    private var meetingStateSummary: String {
        if #available(macOS 14.0, *) {
            switch meetingSession.state {
            case .idle: return "idle"
            case .loadingModels: return "loadingModels"
            case .ready: return "ready"
            case .recording: return "recording"
            case .transcribing: return "transcribing"
            case .error: return "error"
            }
        }
        return "unavailable"
    }
}
