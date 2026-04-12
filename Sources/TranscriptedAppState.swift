// TranscriptedAppState.swift
// Centralized engine ownership — lives in AppDelegate, survives window cycles

import SwiftUI
import ServiceManagement
import TranscriptedCore

@MainActor
class TranscriptedAppState: ObservableObject {
    private static let wakeHotkeyRetryAttempts = 3
    private static let wakeHotkeyRetryDelay: UInt64 = 500_000_000
    let logger = AppLogger()
    let sparkleUpdater = SparkleUpdaterController()
    let contextCapture = ContextCaptureEngine()
    let sttRouter = STTRouter()

    /// Meeting-mode pipeline (Lane B). Lazily instantiated so unit tests that
    /// don't exercise the meeting feature don't pay the construction cost.
    @available(macOS 14.0, *)
    lazy var meetingSession: MeetingSessionController = MeetingSessionController(
        parakeet: sttRouter.parakeetEngine
    )

    private var promptsObserver: NSObjectProtocol?
    private var runtimeReadinessTask: Task<Void, Never>?
    private var isInitialized = false
    private lazy var wakeRecoveryCoordinator = WakeRecoveryCoordinator(
        hotkeyRetryAttempts: Self.wakeHotkeyRetryAttempts,
        hotkeyRetryDelay: Self.wakeHotkeyRetryDelay,
        unregisterHotkeys: { [weak self] in
            self?.contextCapture.unregisterHotkey()
        },
        registerHotkeys: { [weak self] in
            self?.contextCapture.registerHotkey()
        },
        currentHotkeyError: { [weak self] in
            self?.contextCapture.hotkeyError
        },
        onHotkeyAttempt: { [weak self] attempt, error in
            guard let self else { return }
            if let error {
                self.logger.log("WAKE | hotkey re-register failed on attempt \(attempt): \(error)")
            } else {
                self.logger.log("WAKE | hotkeys re-registered (attempt \(attempt))")
            }
        },
        waitForRuntimeReadiness: { [weak self] in
            guard let self else { return }
            await self.waitForRuntimeReadiness()
        }
    )

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
        #endif

        sparkleUpdater.performStartupUpdateCheckIfNeeded()

        // Kick off shared runtime prep once; wake recovery can await or reuse it.
        startRuntimeReadinessIfNeeded()

        logger.log("APP LAUNCHED | modes: dictation + meetings")
        AnalyticsReporter.track("app_launched")

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

    // MARK: - Wake Recovery

    /// Centralized recovery after system wake. Each subsystem that holds OS-level resources
    /// (file descriptors, audio hardware, Metal contexts, Carbon hotkeys) must be checked
    /// and restored here. ParakeetEngine handles its own wake via NSWorkspace observer.
    func handleSystemWake() async {
        let result = await wakeRecoveryCoordinator.handleSystemWake {
            self.logger.log("WAKE | system wake detected — running recovery checks")
        }

        guard result.performedRecovery else { return }

        if !result.hotkeysRecovered {
            EventReporter.shared.capture(
                level: .warning,
                engine: "app",
                event: "wake_hotkey_recovery_failed",
                message: result.hotkeyError ?? "Hotkey re-registration failed after wake"
            )
        }

        // ParakeetEngine handles its own wake recovery via NSWorkspace.didWakeNotification
        // observer installed during prewarm(). No action needed here.
        EventReporter.shared.capture(
            level: result.hotkeysRecovered ? .info : .warning,
            engine: "app",
            event: "wake_recovery",
            message: result.hotkeysRecovered ? "System wake recovery completed" : "System wake recovery completed with hotkey warnings"
        )
    }

    func shutdown() {
        wakeRecoveryCoordinator.cancel()
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

            self.sttRouter.parakeetEngine.prewarm()
            guard !Task.isCancelled else { return }
            await self.sttRouter.parakeetEngine.initialize()
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
