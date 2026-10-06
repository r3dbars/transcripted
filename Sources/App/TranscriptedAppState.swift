// TranscriptedAppState.swift
// Centralized engine ownership — lives in AppDelegate, survives window cycles

import Combine
import SwiftUI
import TranscriptedCore

@MainActor
class TranscriptedAppState: ObservableObject {
    private static let wakeHotkeyRetryAttempts = 3
    private static let wakeHotkeyRetryDelay: UInt64 = 500_000_000
    private static var isLaunchSmokeMode: Bool {
        AutomatedLaunchEnvironment.isActive()
    }
    let logger = AppLogSink()
    let sparkleUpdater = SparkleUpdaterController()
    let contextCapture = ContextCaptureEngine()
    let sttRouter = STTRouter()
    let runtimeDiagnostics = RuntimeDiagnostics()
    /// Writing's autocomplete runtime. Idle until `initialize()` starts it.
    let writingController = WritingController()

    /// Meeting-mode pipeline (Lane B). Lazily instantiated so unit tests that
    /// don't exercise the meeting feature don't pay the construction cost.
    @available(macOS 14.0, *)
    lazy var meetingSession: MeetingSessionController = MeetingSessionController(
        sttRouter: sttRouter
    )

    private var promptsObserver: NSObjectProtocol?
    private var runtimeReadinessTask: Task<Void, Never>?
    private var runtimeReadinessRerunRequested = false
    private var hasReportedLaunchWarmup = false
    private var modelSelectionWarmupCancellable: AnyCancellable?
    private var existingInstallModelPrefetchTask: Task<Void, Never>?
    private var audioStorageMaintenanceTask: Task<Void, Never>?
    private var isInitialized = false
    private var isShutDown = false
    // Dictation and meetings should be ready the moment the app opens, so the
    // selected speech model and the meeting speaker models load quietly in the
    // background at launch instead of on first use. Developers can opt back
    // into first-use loading for idle-memory measurements.
    private let eagerModelWarmupEnabled = ExistingInstallModelPrefetchPolicy.launchWarmupEnabled(
        environment: ProcessInfo.processInfo.environment
    )
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
            self?.contextCapture.hotkeyRegistrationError
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

        if !Self.isLaunchSmokeMode {
            // The saved opt-out, then the default enable, which covers existing
            // installs that finished onboarding before the default existed (fresh
            // installs get it from the onboarding-completion hook). The XPC calls
            // run off the main thread; nothing below waits on them.
            let onboardingCompleted = PermissionsOnboardingPreferences.hasCompleted()
            Task { @MainActor in
                let result = await LaunchAtLoginController.applyStartupState(onboardingCompleted: onboardingCompleted)
                if let message = result.optOutFailure {
                    EventReporter.shared.capture(level: .warning, engine: "app", event: "login_item_opt_out_sync_failed",
                        message: message)
                }
                if let message = result.defaultEnableFailure {
                    EventReporter.shared.capture(level: .warning, engine: "app", event: "login_item_default_enable_failed",
                        message: message)
                }
            }
        }

        if !Self.isLaunchSmokeMode {
            // Updates now download in the background by default; a ~500 MB
            // download (and Sparkle's unpacking after it) must not start while
            // a call records or while dictation, transcription or an import
            // is using the Mac.
            sparkleUpdater.setBackgroundUpdateCheckDeferral { [weak self] in
                guard let self else { return false }
                var busy = self.sttRouter.isRecording || self.sttRouter.isTranscribing
                if #available(macOS 14.0, *) {
                    // Meeting capture plus queued/in-flight transcription and imports.
                    busy = busy || self.meetingSession.hasRuntimeDiagnosticsWork
                }
                return busy
            }
            sparkleUpdater.performStartupUpdateCheckIfNeeded()
        }
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

        if eagerModelWarmupEnabled && !Self.isLaunchSmokeMode {
            startRuntimeReadinessIfNeeded()
            rewarmWhenModelSelectionChanges()
        } else {
            startExistingInstallModelPrefetchIfNeeded()
        }
        startAudioStorageMaintenanceIfNeeded()
        if !Self.isLaunchSmokeMode {
            startAgentHelperRefreshIfNeeded()
        }
        // Writing runs once its setup is done and a feature is on (or behind
        // the debug default); the Writing tab starts and stops it after that.
        // One main-actor turn later, so the hotkeys (registered in the
        // launch turn) come first: Writing's start installs the keyboard
        // synchronously.
        // This ordering assumes nothing above in initialize() awaits; the
        // controller's own guards (terminated, wake) cover a quit in between.
        if !Self.isLaunchSmokeMode {
            Task { @MainActor [weak self] in
                guard let self else { return }
                writingController.startIfEnabled { [weak self] message in self?.logger.log(message) }
            }
        }
        logger.log("APP LAUNCHED | modes: dictation + meetings")
        AnalyticsReporter.track("app_launched")
        runtimeDiagnostics.setActiveWorkProvider { [weak self] in
            guard let self else { return false }
            var workActive = self.sttRouter.isRecording || self.sttRouter.isTranscribing
            if #available(macOS 14.0, *) {
                workActive = workActive || self.meetingSession.hasRuntimeDiagnosticsWork
            }
            return workActive
        }
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
        MeetingAudioStorageManager.setMaintenanceFailureHandler { failure in
            Task { @MainActor in
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "meeting",
                    event: "audio_maintenance_failure",
                    message: "Retained-audio maintenance skipped a file",
                    context: [
                        "operation": failure.operation,
                        "error_domain": failure.errorDomain,
                        "error_code": "\(failure.errorCode)",
                    ]
                )
            }
        }
        EventReporter.shared.capture(level: .info, engine: "app", event: "app_launched",
            message: "Transcripted initialized for dictation and meetings")
    }

    // MARK: - Wake Recovery

    /// Centralized recovery after system wake. Each subsystem that holds OS-level resources
    /// (file descriptors, audio hardware, Metal contexts, Carbon hotkeys) must be checked
    /// and restored here. ParakeetEngine handles its own wake via NSWorkspace observer.
    func handleSystemWake() async {
        writingController.handleSystemWake()
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
        guard !isShutDown else { return }
        isShutDown = true
        wakeRecoveryCoordinator.cancel()
        modelSelectionWarmupCancellable = nil
        runtimeReadinessTask?.cancel()
        runtimeReadinessTask = nil
        existingInstallModelPrefetchTask?.cancel()
        existingInstallModelPrefetchTask = nil
        audioStorageMaintenanceTask?.cancel()
        audioStorageMaintenanceTask = nil
        sttRouter.cleanup()
        writingController.stop()
        contextCapture.unregisterHotkey()
        if let observer = promptsObserver {
            NotificationCenter.default.removeObserver(observer)
            promptsObserver = nil
        }
        if #available(macOS 14.0, *) {
            MeetingSessionController.runtimeDiagnosticsRecorder = nil
        }
        runtimeDiagnostics.setActiveWorkProvider(nil)
        runtimeDiagnostics.markCleanShutdown()
    }

    private func startAgentHelperRefreshIfNeeded() {
        Task.detached(priority: .utility) {
            let refreshed: Bool
            do {
                refreshed = try ClaudeDesktopIntegrationInstaller.refreshInstalledHelperIfNeeded()
            } catch {
                let message = error.localizedDescription
                await MainActor.run {
                    EventReporter.shared.capture(
                        level: .warning,
                        engine: "app",
                        event: "agent_helper_refresh_failed",
                        message: message
                    )
                }
                return
            }

            guard refreshed else { return }
            await MainActor.run {
                EventReporter.shared.capture(
                    level: .info,
                    engine: "app",
                    event: "agent_helper_refreshed",
                    message: "Installed agent helper was updated to match this app build"
                )
            }
        }
    }

    private func startRuntimeReadinessIfNeeded() {
        guard runtimeReadinessTask == nil else {
            // A pass is already running. Make it go around once more so a
            // model switched mid-warmup still ends up loaded.
            runtimeReadinessRerunRequested = true
            return
        }

        // The pass runs at `.utility` so launch-at-login, wake and model
        // switches don't spend full CPU on the meeting models. Only the
        // dictation model step runs at `.userInitiated`, in its own task:
        // at utility macOS can run Core ML compilation on the efficiency
        // cores, most launches in PostHog took 5s+ to warm, and a dictation
        // pressed in that window waited on it. Awaiting a task escalates it
        // to the waiter's priority, so the split has to go this way round.
        runtimeReadinessTask = Task(priority: .utility) { @MainActor [weak self] in
            guard let self else { return }
            defer { self.runtimeReadinessTask = nil }

            // UI setup is complete before this task starts. Load the selected
            // speech model first so dictation is ready soonest, then the
            // meeting speaker models, so the first dictation and the first
            // meeting both start without a cold load. Both steps are quiet:
            // no loading UI, no permission prompts, and a failure here is
            // retried by the next start, wake, or model switch.
            let warmupStartedAt = CFAbsoluteTimeGetCurrent()
            LaunchTimingTelemetry.markWarmupStarted()
            // First pass only: a rerun after a model switch is not launch time.
            var dictationWarmupMs: Int?
            var meetingWarmupMs: Int?
            repeat {
                self.runtimeReadinessRerunRequested = false
                guard !Task.isCancelled, !self.isShutDown else { return }
                let dictationWarmup = Task(priority: .userInitiated) { @MainActor [weak self] in
                    await self?.sttRouter.initializeSelectedModelInBackground()
                }
                await withTaskCancellationHandler {
                    await dictationWarmup.value
                } onCancel: {
                    dictationWarmup.cancel()
                }
                let dictationWarmedAt = CFAbsoluteTimeGetCurrent()
                if dictationWarmupMs == nil {
                    dictationWarmupMs = Self.elapsedMilliseconds(from: warmupStartedAt, to: dictationWarmedAt)
                }
                guard !Task.isCancelled, !self.isShutDown else { return }
                if #available(macOS 14.0, *), !self.meetingSession.areMeetingModelsWarm {
                    await self.meetingSession.prepareModels(showLoadingUI: false)
                }
                if meetingWarmupMs == nil {
                    meetingWarmupMs = Self.elapsedMilliseconds(from: dictationWarmedAt, to: CFAbsoluteTimeGetCurrent())
                }
            } while self.runtimeReadinessRerunRequested
            self.reportLaunchWarmupOnce(
                startedAt: warmupStartedAt,
                dictationWarmupMs: dictationWarmupMs,
                meetingWarmupMs: meetingWarmupMs
            )
        }
    }

    /// One PostHog event per launch saying whether the launch warmup left
    /// dictation and meetings ready, and how long it took. Later passes
    /// (model switch, wake) are not reported.
    private func reportLaunchWarmupOnce(
        startedAt: CFAbsoluteTime,
        dictationWarmupMs: Int?,
        meetingWarmupMs: Int?
    ) {
        guard !hasReportedLaunchWarmup else { return }
        hasReportedLaunchWarmup = true
        let meetingReady: Bool
        if #available(macOS 14.0, *) {
            meetingReady = meetingSession.areMeetingModelsWarm
        } else {
            meetingReady = false
        }
        let elapsedMs = Self.elapsedMilliseconds(from: startedAt, to: CFAbsoluteTimeGetCurrent())
        var properties = LaunchTimingTelemetry.properties(
            marks: LaunchTimingTelemetry.marks,
            dictationWarmupMs: dictationWarmupMs,
            meetingWarmupMs: meetingWarmupMs,
            speechModel: sttRouter.selectedModel.rawValue
        )
        properties["dictation_ready"] = sttRouter.isModelLoaded ? "true" : "false"
        properties["meeting_recording_ready"] = meetingReady ? "true" : "false"
        properties["warmup_latency_bucket"] = AnalyticsReporter.latencyBucket(milliseconds: elapsedMs)
        AnalyticsReporter.track("launch_models_warmed", properties: properties)
    }

    private static func elapsedMilliseconds(from start: CFAbsoluteTime, to end: CFAbsoluteTime) -> Int {
        max(0, Int(((end - start) * 1_000).rounded()))
    }

    /// STTRouter already reloads the newly selected dictation model on a
    /// switch; this makes meetings follow it too, so the next meeting does
    /// not stop to prepare the new model.
    private func rewarmWhenModelSelectionChanges() {
        guard modelSelectionWarmupCancellable == nil else { return }
        modelSelectionWarmupCancellable = sttRouter.$selectedModel
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                // @Published emits before the new value is stored; hop so the
                // warmup reads the model that was just selected.
                Task { @MainActor [weak self] in
                    guard let self, !self.isShutDown else { return }
                    self.startRuntimeReadinessIfNeeded()
                }
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
                    "model_state": self.sttRouter.modelDownloadState.diagnosticName,
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

    private func startAudioStorageMaintenanceIfNeeded() {
        guard audioStorageMaintenanceTask == nil else { return }

        audioStorageMaintenanceTask = Task.detached(priority: .utility) {
            // Kept dictation audio past its window (Settings → Storage). Launch
            // harnesses run under a temp HOME, so this never reaches a real library.
            DictationAudioArchive.prune(window: AudioStoragePreferences.dictationAudioKeepWindow())
            let result = await MeetingAudioStorageManager.processExistingRetainedAudio(
                in: MeetingStoragePaths.transcriptsFolder
            )
            // Launch backfill can create/recompress/prune many meetings' audio; if it
            // changed anything, tell Home so cached audio URLs re-resolve.
            if result.changedArtifacts {
                await MainActor.run {
                    CaptureLibraryChangeBroadcaster.shared.noteLibraryWideChange()
                }
            }

            if let libraryBytes = CaptureLibrarySize.measureBytes(at: MeetingStoragePaths.transcriptsFolder) {
                let bucket = CaptureLibrarySize.bucketLabel(forBytes: libraryBytes)
                let retention = AudioStoragePreferences.deleteAudioAfter().rawValue
                await MainActor.run {
                    EventReporter.shared.capture(
                        level: .info,
                        engine: "meeting",
                        event: "capture_library_size",
                        message: "Capture library size measured after audio maintenance",
                        context: [
                            "size_bucket": bucket,
                            "audio_retention": retention,
                        ]
                    )
                }
            }
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
            case .startingRecording: return "startingRecording"
            case .recording: return "recording"
            case .stoppingRecording: return "stoppingRecording"
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
        case .notLoaded, .cached, .ready, .failed:
            return false
        }
    }
}
