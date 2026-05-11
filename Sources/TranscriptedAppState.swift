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
    lazy var meetingSession: MeetingSessionController = MeetingSessionController(
        sttRouter: sttRouter
    )

    private var promptsObserver: NSObjectProtocol?
    private var runtimeReadinessTask: Task<Void, Never>?
    private var existingInstallModelPrefetchTask: Task<Void, Never>?
    private var audioStorageMaintenanceTask: Task<Void, Never>?
    private var isInitialized = false
    private let eagerModelWarmupEnabled =
        ProcessInfo.processInfo.environment["TRANSCRIPTED_EAGER_MODEL_WARMUP"] == "1"
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

        if eagerModelWarmupEnabled {
            startRuntimeReadinessIfNeeded()
        } else {
            startExistingInstallModelPrefetchIfNeeded()
        }
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
        existingInstallModelPrefetchTask?.cancel()
        existingInstallModelPrefetchTask = nil
        audioStorageMaintenanceTask?.cancel()
        audioStorageMaintenanceTask = nil
        sttRouter.cleanup()
        contextCapture.unregisterHotkey()
        if let observer = promptsObserver {
            NotificationCenter.default.removeObserver(observer)
            promptsObserver = nil
        }
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

            // Keep default launch lightweight. Dictation, imports, model
            // preference changes, and the optional eager-warmup env flag load
            // the selected model only when that work is actually needed.
            guard !Task.isCancelled else { return }
            await self.sttRouter.initializeSelectedModel()
            // Keep heavier meeting diarization lazy. Meeting start/import paths
            // call prepareModels() with visible loading state when needed.
        }
    }

    private func startExistingInstallModelPrefetchIfNeeded() {
        guard existingInstallModelPrefetchTask == nil else { return }
        guard ExistingInstallModelPrefetchPolicy.shouldPrefetch(existingInstallPrefetchContext()) else { return }

        existingInstallModelPrefetchTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer { self.existingInstallModelPrefetchTask = nil }

            do {
                try await Task.sleep(nanoseconds: ExistingInstallModelPrefetchPolicy.startupDelayNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else { return }
            let context = self.existingInstallPrefetchContext()
            guard ExistingInstallModelPrefetchPolicy.shouldPrefetch(context) else { return }

            EventReporter.shared.capture(
                level: .info,
                engine: "app",
                event: "existing_install_model_prefetch_started",
                message: "Caching local dictation model files in the background for an existing install",
                context: [
                    "model": context.selectedModel.rawValue,
                    "delay_s": "12",
                ]
            )

            await self.sttRouter.prefetchSelectedModelFilesForExistingInstall()

            let failed = self.prefetchModelStateFailed(self.sttRouter.modelDownloadState)
            EventReporter.shared.capture(
                level: failed ? .warning : .info,
                engine: "app",
                event: failed
                    ? "existing_install_model_prefetch_unavailable"
                    : "existing_install_model_prefetch_completed",
                message: failed
                    ? "Existing-install model prefetch did not finish"
                    : "Existing-install model files are cached for first use",
                context: [
                    "model": self.sttRouter.selectedModel.rawValue,
                    "model_state": self.prefetchModelStateName(self.sttRouter.modelDownloadState),
                ]
            )
        }
    }

    private func existingInstallPrefetchContext() -> ExistingInstallModelPrefetchContext {
        ExistingInstallModelPrefetchContext(
            isExistingInstall: hasExistingInstallSignals(),
            selectedModel: sttRouter.selectedModel,
            isModelLoaded: sttRouter.isModelLoaded,
            isModelWorkInFlight: sttRouter.modelDownloadState.isExistingInstallPrefetchWorkInFlight,
            eagerModelWarmupEnabled: eagerModelWarmupEnabled
        )
    }

    private func hasExistingInstallSignals() -> Bool {
        ExistingInstallModelPrefetchPolicy.hasExistingInstallSignals(
            onboardingCompleted: PermissionsOnboardingPreferences.hasCompleted(),
            hasCaptureLibraryContent: hasExistingCaptureLibraryContent(),
            hasExplicitLaunchAtLoginChoice: LaunchAtLoginPreferences.hasExplicitChoice()
        )
    }

    private func hasExistingCaptureLibraryContent() -> Bool {
        let fileManager = FileManager.default
        return ExistingInstallModelPrefetchPolicy.captureLibraryCandidateURLs(
            customPath: UserDefaults.standard.string(forKey: TranscriptedStoragePreferences.captureLibraryLocationKey),
            appSupportRoot: fileManager.transcriptedAppSupportRootURL
        ).contains { captureLibraryURL in
            ExistingInstallModelPrefetchPolicy.captureLibraryHasContent(
                at: captureLibraryURL,
                fileManager: fileManager
            )
        }
    }

    private func prefetchModelStateFailed(_ state: ParakeetModelState) -> Bool {
        if case .failed = state {
            return true
        }
        return false
    }

    private func prefetchModelStateName(_ state: ParakeetModelState) -> String {
        switch state {
        case .notLoaded: return "not_loaded"
        case .downloading: return "downloading"
        case .loading: return "loading"
        case .ready: return "ready"
        case .failed: return "failed"
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
        guard eagerModelWarmupEnabled || sttRouter.isModelLoaded else {
            logger.log("WAKE | skipping voice-model readiness wait until first use")
            return
        }

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

private extension ParakeetModelState {
    var isExistingInstallPrefetchWorkInFlight: Bool {
        switch self {
        case .downloading, .loading:
            return true
        case .notLoaded, .ready, .failed:
            return false
        }
    }
}
