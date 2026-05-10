// TranscriptedAppState.swift
// Centralized engine ownership — lives in AppDelegate, survives window cycles

import SwiftUI
import TranscriptedCore

@MainActor
class TranscriptedAppState: ObservableObject {
    private static let wakeHotkeyRetryAttempts = 3
    private static let wakeHotkeyRetryDelay: UInt64 = 500_000_000
    let logger = AppLogger()
    let sparkleUpdater = SparkleUpdaterController()
    let contextCapture = ContextCaptureEngine()
    let sttRouter = STTRouter()
    let runtimeDiagnostics = RuntimeDiagnostics()

    /// Meeting-mode pipeline (Lane B). Lazily instantiated so unit tests that
    /// don't exercise the meeting feature don't pay the construction cost.
    @available(macOS 14.0, *)
    private lazy var storedMeetingSession: MeetingSessionController = MeetingSessionController(
        sttRouter: sttRouter
    )
    private var hasLoadedMeetingSession = false

    @available(macOS 14.0, *)
    var meetingSession: MeetingSessionController {
        hasLoadedMeetingSession = true
        return storedMeetingSession
    }

    @available(macOS 14.0, *)
    var loadedMeetingSession: MeetingSessionController? {
        guard hasLoadedMeetingSession else { return nil }
        return storedMeetingSession
    }

    private var runtimeReadinessTask: Task<Void, Never>?
    private var audioStorageMaintenanceTask: Task<Void, Never>?
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

        do {
            try LaunchAtLoginController.applySavedOptOutAtStartup()
        } catch {
            EventReporter.shared.capture(level: .warning, engine: "app", event: "login_item_opt_out_sync_failed",
                message: error.localizedDescription)
        }

        sparkleUpdater.performStartupUpdateCheckIfNeeded()
        AppSoundPlayer.shared.setWarningReporter { cue in
            Task { @MainActor in
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "ui_sound",
                    event: "cue_preload_failed",
                    message: "UI sound cue could not be preloaded",
                    context: ["cue": String(describing: cue)]
                )
            }
        }
        AppSoundPlayer.shared.preload()

        // Kick off shared runtime prep once; wake recovery can await or reuse it.
        startRuntimeReadinessIfNeeded()
        startAudioStorageMaintenanceIfNeeded()

        logger.log("APP LAUNCHED | modes: dictation + meetings")
        AnalyticsReporter.track("app_launched")
        runtimeDiagnostics.start()
        if #available(macOS 14.0, *) {
            MeetingSessionController.runtimeDiagnosticsRecorder = runtimeDiagnostics
        }

        // Wire EventReporter with live engine state for context enrichment
        EventReporter.shared.setEngineStateSummary { [weak self] in
            guard let self else { return [:] }
            return [
                "stt_model": sttRouter.selectedModel.rawValue,
                "stt_model_loaded": "\(sttRouter.isModelLoaded)",
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

        // ParakeetEngine handles its own wake recovery once its audio lifecycle
        // observers are armed during first recording/prewarm. No app-level
        // action needed here.
        EventReporter.shared.capture(
            level: result.hotkeysRecovered ? .info : .warning,
            engine: "app",
            event: "wake_recovery",
            message: result.hotkeysRecovered ? "System wake recovery completed" : "System wake recovery completed with hotkey warnings"
        )
    }

    func recoverHotkeysAfterPermissionChange() {
        logger.log("HOTKEY | refreshing hotkeys after onboarding permissions")
        contextCapture.unregisterHotkey()
        contextCapture.registerHotkey()
        contextCapture.refreshShortcutStatus()
    }

    func shutdown() {
        wakeRecoveryCoordinator.cancel()
        runtimeReadinessTask?.cancel()
        runtimeReadinessTask = nil
        audioStorageMaintenanceTask?.cancel()
        audioStorageMaintenanceTask = nil
        sttRouter.cleanup()
        contextCapture.unregisterHotkey()
        if #available(macOS 14.0, *) {
            MeetingSessionController.runtimeDiagnosticsRecorder = nil
        }
        runtimeDiagnostics.markCleanShutdown()
    }

    private func startRuntimeReadinessIfNeeded() {
        guard runtimeReadinessTask == nil else { return }

        runtimeReadinessTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.runtimeReadinessTask = nil }

            // Loading models at launch keeps first-use latency down without
            // touching AVAudioEngine input nodes on the main thread. Sentry app
            // hang reports showed launch-time prewarm blocking inside CoreAudio.
            guard !Task.isCancelled else { return }
            await self.sttRouter.initializeSelectedModel()
            guard !Task.isCancelled else { return }

            if #available(macOS 14.0, *), let meetingSession = self.loadedMeetingSession {
                await meetingSession.prepareModels(showLoadingUI: false)
            }
        }
    }

    private func startAudioStorageMaintenanceIfNeeded() {
        guard audioStorageMaintenanceTask == nil else { return }

        audioStorageMaintenanceTask = Task.detached(priority: .utility) {
            await MeetingAudioStorageManager.processExistingRetainedAudio(
                in: MeetingStoragePaths.transcriptsFolder
            )
        }
    }

    private func waitForRuntimeReadiness() async {
        startRuntimeReadinessIfNeeded()
        guard let runtimeReadinessTask else { return }

        do {
            try await TranscriptedConstants.withTimeout(
                seconds: TranscriptedConstants.wakeRuntimeReadinessTimeout
            ) {
                await runtimeReadinessTask.value
            }
        } catch {
            logger.log("WAKE | runtime readiness wait timed out")
            EventReporter.shared.capture(
                level: .warning,
                engine: "app",
                event: "wake_runtime_readiness_timeout",
                message: "Wake recovery timed out waiting for runtime readiness",
                context: [
                    "timeout_s": String(format: "%.1f", TranscriptedConstants.wakeRuntimeReadinessTimeout),
                    "stt_model_loaded": "\(sttRouter.isModelLoaded)",
                    "meeting_state": meetingStateSummary,
                ]
            )
        }
    }

    private var meetingStateSummary: String {
        if #available(macOS 14.0, *) {
            guard let meetingSession = loadedMeetingSession else { return "not_loaded" }
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
