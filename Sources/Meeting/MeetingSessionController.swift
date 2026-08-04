// MeetingSessionController.swift
// Top-level @MainActor ObservableObject that wires TranscriptedCore into the app.
// Owns Core's DI container (AppServices), the capture bridge, the task manager,
// and the model downloader. Exposes @Published state for the meeting UI to
// bind against.
//
// Boot sequence:
//   1. init() constructs all Core services with app-owned CoreStoragePaths
//      so meeting captures follow the selected capture library while speakers DB,
//      stats DB, failed-queue, logs, and scratch audio stay under the app-owned
//      Transcripted Application Support folders.
//   2. prepareModels() loads the selected STT model + offline PyAnnote/WeSpeaker diarization.
//      Optional streaming diarization warms only when bundled and never blocks
//      the current meeting transcript path.
//   3. startRecording() begins capture via MeetingCaptureBridge.
//   4. stopRecording() awaits capture files, then either starts a background
//      transcription immediately or enqueues it behind the current one.
//      TranscriptionTaskManager still runs one diarize→transcribe→save
//      pipeline at a time and writes a .md to MeetingStoragePaths.transcriptsFolder.
//
// The session controller does NOT own a hotkey or UI — Lane C (meeting-ui)
// wires those up.

import Combine
import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class MeetingSessionController: ObservableObject {
    static var runtimeDiagnosticsRecorder: RuntimeDiagnostics?

    enum StartTrigger: String {
        case hotkey = "hotkey"
        case menu = "menu"
        case onboarding = "onboarding"
        case detectedPrompt = "detected_prompt"
        case fileImport = "file_import"
        case savedMeetingRetranscription = "saved_meeting_retranscription"
        case unknown = "unknown"
    }

    enum StopReason: String {
        case hotkeyToggle = "hotkey_toggle"
        case overlayStopButton = "overlay_stop_button"
        case menuBarStopButton = "menu_bar_stop_button"
        case quitConfirmation = "quit_confirmation"
        case audioInactivityPrompt = "audio_inactivity_prompt"
        case audioInactivityTimeout = "audio_inactivity_timeout"
        case audioRouteWarning = "audio_route_warning"
        case systemAudioWarning = "system_audio_warning"
        case unknown = "unknown"
    }

    enum RecordingCancelReason: String {
        case discardButton = "discard_button"
        case unknown = "unknown"
    }

    enum TranscriptionCancelReason: String {
        case userRequested = "user_requested"
        case unknown = "unknown"
    }

    typealias ModelWarmupStatus = MeetingWarmupStatus

    // Moved to FailedMeetingStore.swift / TranscriptionQueueCoordinator.swift
    // (audit 2026-07-08 wave 2, W2-B). Typealiases keep every existing
    // reference — including `MeetingSessionController.FailedMeetingItem` in
    // UI files — resolving unchanged.
    typealias FailedMeetingItem = FailedMeetingStore.FailedMeetingItem
    typealias QueuedTranscriptionJob = TranscriptionQueueCoordinator.QueuedTranscriptionJob
    typealias BackgroundTranscriptionWorkSnapshot = TranscriptionQueueCoordinator.BackgroundTranscriptionWorkSnapshot

    enum TerminalTranscriptionOutcome: Equatable {
        case transcriptSaved
        case failed(String)
    }

    private struct RecordingStopSnapshot {
        let trigger: StartTrigger
        let systemAudioStatus: SystemAudioStatus
        let durationSeconds: TimeInterval
        var durationMilliseconds: Int { Int(durationSeconds * 1000) }
        let healthInfo: RecordingHealthInfo
        let pipelineSnapshot: AudioPipelineDiagnosticsSnapshot
        let suggestedTitle: String?
        let recordingStartedAt: Date?
    }

    // MARK: - Published state (for meeting UI bindings)

    /// High-level session state for the meeting UI. The real declaration is
    /// `MeetingSessionState` (MeetingSessionState.swift) — pulled out to its
    /// own Foundation-only file so it and `MeetingSessionStateMachine` get
    /// direct fast-test coverage. This typealias keeps every existing
    /// `MeetingSessionController.State` reference resolving unchanged.
    typealias State = MeetingSessionState

    @Published private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            DiagnosticsTrail.record(
                engine: "meeting",
                event: "meeting_state_changed",
                message: "Meeting state changed",
                context: baseDiagnosticsContext(
                    extra: [
                        "from": oldValue.diagnosticName,
                        "to": state.diagnosticName
                    ]
                )
            )
        }
    }

    /// True only during steady-state recording (excludes the
    /// starting/stopping windows) — computed from `state` so it can never
    /// desync from the session state machine. See
    /// `MeetingSessionStateMachine.isSteadyStateRecording`.
    var isRecording: Bool {
        MeetingSessionStateMachine.isSteadyStateRecording(state)
    }

    /// A `startRecording()` call is currently engaging capture. Used only as
    /// the internal reentrancy guard at the top of `startRecording()` — see
    /// that function for why the whole call isn't guarded by `state` alone.
    private var isStartingRecording: Bool {
        if case .startingRecording = state { return true }
        return false
    }

    /// A stop/cancel/termination teardown is in flight.
    private var isStoppingRecording: Bool {
        if case .stoppingRecording = state { return true }
        return false
    }

    // Pass-throughs for UI convenience (updated via Combine subscriptions below).
    @Published private(set) var audioLevel: Float = 0          // mic-only level
    @Published private(set) var systemLevel: Float = 0         // system audio level
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var displayStatus: DisplayStatus = .idle
    @Published private(set) var lastSavedTranscriptURL: URL? = nil
    @Published private(set) var lastSavedTitle: String? = nil
    @Published private(set) var savedMeetingReplacementCommitCount: Int = 0
    @Published private(set) var audioInactivityWarning: MeetingAudioInactivityWarning?
    @Published private(set) var isMicBoostPromptVisible = false
    @Published private(set) var audioRouteWarning: CaptureRouteStabilizationOutcome?
    @Published private(set) var systemAudioDegradationWarning: MeetingSystemAudioDegradationWarning?

    @Published private(set) var failedMeetings: [FailedMeetingItem] = []
    @Published private(set) var warmupStatus: ModelWarmupStatus = .ready {
        didSet {
            guard warmupStatus != oldValue else { return }
            logWarmupStatusChange(from: oldValue, to: warmupStatus)
        }
    }

    // MARK: - Core services (owned)

    private let storagePaths: CoreStoragePaths
    // Was `private`; FailedMeetingStore / TranscriptionQueueCoordinator live in
    // sibling files and need module-internal access (audit 2026-07-08 W2-B).
    let sttRouter: STTRouter
    let capture: MeetingCaptureBridge
    private let liveCodexSession = LiveMeetingCodexSession()
    private let liveMeetingTranscriber = LiveMeetingTranscriber()
    /// In-memory live transcript behind the meeting overlay's embedded
    /// drawer. Fed by `liveMeetingTranscriber` alongside the sidecar files.
    let liveTranscriptFeed = LiveMeetingTranscriptFeed()
    let services: AppServices
    let taskManager: TranscriptionTaskManager
    private let failedManager: FailedTranscriptionManager
    let diarization: DiarizationService
    let sttAdapter: MeetingSTTAdapter
    private let speakerDatabase: SpeakerDatabase
    private let statsDatabase: StatsDatabase
    let downloader: MeetingModelDownloader
    var calendarSuggestedTitleProvider: (() -> String?)?

    /// Failed-meeting queue/persistence/retry bookkeeping (audit 2026-07-08
    /// wave 2, W2-B). Plain owned object — this controller stays the single
    /// ObservableObject; `failedMeetings` below is still published here.
    /// Laziness lets the store receive narrow weak callbacks after this
    /// controller has finished initializing, without an unowned back-reference
    /// or an implicitly-unwrapped stored property.
    private(set) lazy var failedMeetingStore = makeFailedMeetingStore()
    /// Background-transcription queue/dispatch bookkeeping (audit 2026-07-08
    /// wave 2, W2-B). Plain owned object, same rationale as above.
    private(set) var transcriptionQueue: TranscriptionQueueCoordinator!

    private var cancellables: Set<AnyCancellable> = []
    private var modelPreparationTask: Task<Result<Void, Error>, Never>?
    private var savedTranscriptRestyleTask: Task<StyledMeetingTranscript, Never>?
    private var importPreparationTask: Task<PreparedImportedMeetingAudio, Error>?
    private var importPreparationToken: UUID?
    var lastTerminalTranscriptionOutcome: TerminalTranscriptionOutcome?
    var activeTranscriptionCaptureDiagnostics: [String: String]?
    private var activeDetectedPromptRecordingTelemetryProperties: [String: String]?
    private var activeDetectedPromptRecordingStartedAt: Date?
    var activeDetectedPromptTranscriptionTelemetryProperties: [String: String]?
    var activeDetectedPromptTranscriptionRecordingStartedAt: Date?
    private var activeRecordingTrigger: StartTrigger = .unknown
    private var activeRecordingIdentity: UUID?
    private var micBoostPromptRecordingIdentity: UUID?
    private var micBoostPromptOutcome: MeetingMicBoostPromptOutcome = .notShown
    private var activeRecordingSuggestedTitle: String?
    private var activeRecordingStartedAt: Date?
    var activeTranscriptionTrigger: StartTrigger = .unknown
    // Whole-function reentrancy guard for startRecording() — deliberately
    // NOT derived from `state` (see the comment at its use site). Everything
    // else that used to read `isStartingRecording`/`isFinishingRecording`
    // reads `state` directly now.
    private var startRecordingCallInFlight = false
    private var shouldSurfaceMeetingWarmupFailure = false
    private var audioInactivityDetector = MeetingAudioInactivityDetector()
    private var latestMicLevel: Float = 0
    private var latestSystemLevel: Float = 0
    private var liveCodexSessionIsActive = false
    var liveCodexSessionAwaitingFinalTranscript = false
    private var liveCodexSessionCanAttachFinalTranscript = false
    private var liveCodexSessionOwnedByActiveRecording = false
    private var liveCodexPreviewHandlersNeedClearingAfterActiveRecording = false
    var liveCodexFinalTranscriptNeedsQueuedJobID = false
    var liveCodexAwaitedTranscriptionJobID: UUID?
    var activeQueuedTranscriptionJobID: UUID?
    var activeStoppedAudioRecovery: DictationStoppedAudioRecovery?
    private var stoppedAudioRecoveryRetryRegistry = DictationStoppedAudioRecoveryRetryRegistry()

    var shouldConfirmQuitForActiveCapture: Bool {
        isCaptureSessionActive
    }

    var shouldConfirmQuitForBackgroundTranscription: Bool {
        taskManager.hasActiveTranscriptionWorkRequiringQuitConfirmation
            || transcriptionQueue.isPreparingQueuedTranscriptionStart
            || !transcriptionQueue.queuedTranscriptionJobs.isEmpty
    }

    var shouldBlockDictationForActiveMeetingCapture: Bool {
        isCaptureSessionActive
    }

    var canShareMicWithDictation: Bool {
        isRecording
    }

    /// Check capture ownership and arm borrowed dictation without an `await`
    /// between those actions, so meeting stop cannot slip into the handoff.
    func startDictationFromActiveMeetingMic() -> Bool {
        guard canShareMicWithDictation else { return false }
        return sttRouter.startRecordingFromSharedMeetingMic()
    }

    // MARK: - State transitions

    /// Single writer for `state`. Every transition in this file — and every
    /// outcome `TranscriptionQueueCoordinator` reports back through the
    /// methods below — routes through here, so there is exactly one place
    /// that mutates the meeting session's state machine (audit 2026-08
    /// state-collapse: this replaces the old `setState`/`setDisplayStatus`
    /// seam that let the coordinator drive `state` directly from a sibling
    /// file). In DEBUG builds, a transition `MeetingSessionStateMachine`
    /// doesn't recognize is logged rather than asserted — see that type's
    /// header comment for why a hand-written table this permissive isn't
    /// worth crashing a recording over.
    private func transition(to newState: State, reason: StaticString) {
        #if DEBUG
        if !MeetingSessionStateMachine.isLegalTransition(from: state, to: newState) {
            DiagnosticsTrail.record(
                level: .error,
                engine: "meeting",
                event: "meeting_state_illegal_transition",
                message: "Meeting state transition not recognized by MeetingSessionStateMachine",
                context: baseDiagnosticsContext(
                    extra: [
                        "from": state.diagnosticName,
                        "to": newState.diagnosticName,
                        "reason": "\(reason)"
                    ]
                )
            )
        }
        #endif
        state = newState
    }

    /// `displayStatus`'s single writer. `source` only distinguishes the two
    /// callers for behavior that was already conditional on the caller: the
    /// `taskManager.$displayStatus` mirror also runs `handleDisplayStatusChange`
    /// (it is the only place that ever did, before this change), while
    /// controller/coordinator-driven phase updates (getting ready, prep
    /// failed) do not. This preserves existing effective behavior — last
    /// write wins, in call order — just through one function instead of
    /// three separate write sites.
    private enum DisplayStatusSource {
        case taskManagerMirror
        case controllerPhase
    }

    private func updateDisplayStatus(_ newStatus: DisplayStatus, source: DisplayStatusSource) {
        let previousStatus = displayStatus
        displayStatus = newStatus
        if source == .taskManagerMirror {
            handleDisplayStatusChange(from: previousStatus, to: newStatus)
        }
    }

    // MARK: - Outcome reporting (for TranscriptionQueueCoordinator)
    //
    // TranscriptionQueueCoordinator no longer drives `state`/`displayStatus`
    // directly (the old `setState`/`setDisplayStatus` seam). It reports what
    // happened; the handlers below own translating that into a transition.

    /// A queued transcription job began preparing/running.
    func transcriptionJobDidStart() {
        if !isCaptureSessionActive {
            transition(to: .transcribing, reason: "transcription_job_started")
        }
        updateDisplayStatus(.gettingReady, source: .controllerPhase)
    }

    /// A queued job failed before it could start (bounded model-recovery
    /// retry gave up).
    func transcriptionJobFailedToPrepare(message: String) {
        transition(to: .error(message), reason: "transcription_job_prepare_failed")
        updateDisplayStatus(.failed(message: message), source: .controllerPhase)
    }

    /// Background transcription work is still visible and capture isn't
    /// active — keep showing the transcribing state.
    func transcriptionWorkContinues() {
        guard !isCaptureSessionActive else { return }
        transition(to: .transcribing, reason: "transcription_work_continues")
    }

    /// The transcription queue has nothing left running or queued — settle
    /// `state` onto the terminal outcome of the last job that finished.
    func transcriptionQueueSettled() {
        guard !isCaptureSessionActive else { return }
        switch lastTerminalTranscriptionOutcome {
        case .failed(let message):
            transition(to: .error(message), reason: "transcription_queue_settled_failed")
        case .transcriptSaved:
            transition(to: .ready, reason: "transcription_queue_settled_saved")
        case .none:
            if case .transcribing = state {
                transition(to: .ready, reason: "transcription_queue_settled_idle")
            }
        }
    }

    // MARK: - Init

    /// Construct the full Core stack with app-owned storage isolation.
    ///
    /// - Parameter sttRouter: The app's shared speech router. Dictation,
    ///   meetings, and imports all use this same selected local STT engine.
    init(sttRouter: STTRouter) {
        self.sttRouter = sttRouter
        // Ensure the capture library and app-owned directories exist on disk before use.
        _ = MeetingStoragePaths.root
        _ = MeetingStoragePaths.stateFolder
        _ = MeetingStoragePaths.logsFolder
        _ = MeetingStoragePaths.recordingsScratch
        _ = MeetingStoragePaths.audioArchiveFolder

        // Speaker embedding model selection. ERes2Net (codec-robust, 192-dim) runs
        // after diarization to drive same-voice consolidation + cross-call matching;
        // WeSpeaker (256-dim, diarizer-native) is the default. The two produce
        // different-dimension vectors, so each gets its own speaker database file —
        // a SpeakerProfile row must never mix dimensions. The DB path is derived from
        // the *actually-loaded* embedder (not mere model-file presence): if ERes2Net
        // is selected but its model can't be loaded, makeEmbedder returns nil and we
        // transparently fall back to the WeSpeaker path — native embedding AND the
        // default speakers.sqlite — so 256-d vectors can never land in the 192-d DB.
        let embedderChoice = SpeakerEmbedderPreferences.effectiveChoice()
        let segmentEmbedder = SpeakerEmbedderFactory.makeEmbedder(for: embedderChoice)

        // Build app-owned CoreStoragePaths so captures and internal state stay split.
        self.storagePaths = CoreStoragePaths(
            transcripts: MeetingStoragePaths.transcriptsFolder,
            speakerDB: SpeakerEmbedderFactory.speakerDBURL(for: segmentEmbedder),
            statsDB: MeetingStoragePaths.statsDatabase,
            failedQueue: MeetingStoragePaths.failedTranscriptionsFile,
            speakerClips: MeetingStoragePaths.speakerClipsFolder,
            audioCaptures: MeetingStoragePaths.recordingsScratch,
            logs: MeetingStoragePaths.logsFolder
        )

        // Capture bridge owns an `Audio` instance with our storage paths so
        // raw mic/system WAV captures land in the app scratch folder.
        self.capture = MeetingCaptureBridge(audio: Audio(paths: storagePaths))

        // STT: wrap the app's selected speech router in the Core-facing adapter.
        self.sttAdapter = MeetingSTTAdapter(router: sttRouter)

        // Diarization: Core's concrete DiarizationService already conforms to
        // DiarizationEngine via an empty extension (see DiarizationService.swift).
        // When a segment embedder is present, the diarizer re-embeds each segment
        // with it (e.g. ERes2Net) before the speaker identity stack runs.
        self.diarization = DiarizationService(segmentEmbedder: segmentEmbedder)

        // Speaker store: app-owned SQLite file under state/.
        self.speakerDatabase = SpeakerDatabase(path: storagePaths.speakerDB.path)
        self.statsDatabase = StatsDatabase(path: storagePaths.statsDB.path)

        // Failed-queue manager: takes CoreStoragePaths so its JSON file lives
        // under app-owned state, not the capture library. The queue is drained
        // by `refreshFailedMeetings()` (subscribed to
        // `failedManager.$failedTranscriptions`) and surfaced in Settings →
        // Meetings → "Needs Attention", with retry / delete actions wired
        // through `retryFailedMeeting` and `deleteFailedMeeting`.
        self.failedManager = FailedTranscriptionManager(paths: storagePaths)
        self.failedManager.cleanupOldFailedTranscriptions(
            olderThanDays: TranscriptedConstants.failedMeetingAudioRetentionDays
        )

        // DI container — the protocol-typed "what Core sees" surface.
        self.services = AppServices(
            speechToText: sttAdapter,
            diarization: diarization,
            speakerStore: speakerDatabase
        )

        // Task manager drives the pipeline and publishes progress.
        self.taskManager = TranscriptionTaskManager(
            failedTranscriptionManager: failedManager,
            speechToText: services.speechToText,
            diarization: services.diarization,
            speakerStore: services.speakerStore,
            speakerClipsDirectory: storagePaths.speakerClips,
            cleanupDirectories: [storagePaths.audioCaptures, storagePaths.speakerClips],
            retainedAudioDirectoryProvider: { MeetingStoragePaths.audioArchiveFolder },
            transcriptFormatOptionsProvider: {
                TranscriptFormatOptions(
                    includeObsidianMetadata: UserDefaults.standard.bool(forKey: "enableObsidianFormat")
                )
            },
            statsStore: statsDatabase
        )

        // Model downloader — coordinates selected STT + PyAnnote readiness.
        self.downloader = MeetingModelDownloader(stt: sttAdapter, diarization: diarization)

        // Transcription-queue bookkeeping (audit 2026-07-08 wave 2, W2-B).
        // Constructed last because it still holds an unowned controller
        // reference. `failedMeetingStore` initializes lazily when
        // `wireSubscriptions()` first needs it.
        self.transcriptionQueue = TranscriptionQueueCoordinator(controller: self)

        capture.onUnexpectedRecordingComplete = { [weak self] result in
            self?.handleUnexpectedCaptureStop(result)
        }
        capture.onExpiredTimedOutRecordingComplete = { [weak self] failedMeetingID, result in
            if let failedMeetingID {
                self?.failedMeetingStore.refreshTimedOutFailedMeetingAudio(
                    id: failedMeetingID,
                    result: result
                )
            } else {
                self?.failedMeetingStore.recoverExpiredTimedOutMeetingAudio(result)
            }
        }
        capture.onRecordingJournalFinalizationAbandoned = { [weak self] in
            guard let self else { return }
            let taskManager = self.taskManager
            let scratchDirectory = self.storagePaths.audioCaptures
            Task {
                await taskManager.recoverOrphanedRecordings(in: scratchDirectory)
            }
        }

        wireSubscriptions()
        transcriptionQueue.recoverImportedAudioJobs()

        // Recover recordings orphaned by a crash before any failed-queue entry
        // existed — they become visible, retryable items on Home.
        let scratchDirectory = storagePaths.audioCaptures
        Task { [taskManager] in
            await taskManager.recoverOrphanedRecordings(in: scratchDirectory)
        }
    }

    // MARK: - Public API

    /// Load STT + diarization models. Call once before the first recording.
    /// Transitions state: idle → loadingModels → ready, or → error(String).
    ///
    func prepareModels(showLoadingUI: Bool = true) async {
        resetPreparedSpeechModelIfNeeded()

        if case .ready = state, sttAdapter.isReady { return }

        if showLoadingUI, case .loadingModels = state {
            if let task = modelPreparationTask {
                _ = await task.value
                return
            }
        }

        if showLoadingUI {
            shouldSurfaceMeetingWarmupFailure = false
            transition(to: .loadingModels, reason: "model_preparation_started")
            refreshWarmupStatus()
        }

        if let task = modelPreparationTask {
            let result = await task.value
            applyModelPreparationResult(result, showLoadingUI: showLoadingUI)
            return
        }

        let modelPreparationStartedAt = CFAbsoluteTimeGetCurrent()
        let retrySource = showLoadingUI ? "warmup" : "background_warmup"
        let surface = showLoadingUI ? "meeting" : "runtime"
        WorkflowRecoveryTelemetry.attempted(
            workflowKind: "model_preparation",
            failureKind: "models_not_ready",
            retrySource: retrySource,
            surface: surface,
            artifactRetained: false
        )
        let task = Task<Result<Void, Error>, Never> { [downloader] in
            do {
                try await TranscriptedConstants.withDetachedTimeout(
                    seconds: TranscriptedConstants.modelLoadWaitBudget
                ) {
                    try await downloader.ensureModelsReady()
                }
                return .success(())
            } catch {
                return .failure(error)
            }
        }

        modelPreparationTask = task
        let result = await task.value
        modelPreparationTask?.cancel()
        modelPreparationTask = nil
        applyModelPreparationResult(result, showLoadingUI: showLoadingUI)
        trackModelPreparationRecoveryFinished(
            result,
            retrySource: retrySource,
            elapsedSeconds: CFAbsoluteTimeGetCurrent() - modelPreparationStartedAt,
            surface: surface
        )
    }

    /// Begin a new meeting recording. Safe to call from UI buttons. If a prior
    /// meeting is still transcribing, the new capture starts immediately and
    /// the older transcript continues in the background.
    @discardableResult
    func startRecording(
        trigger: StartTrigger = .unknown,
        suggestedTitle: String? = nil,
        promptTelemetryProperties: [String: String]? = nil
    ) async -> Bool {
        guard !startRecordingCallInFlight else {
            DiagnosticsTrail.record(
                engine: "meeting",
                event: "meeting_start_ignored",
                message: "Meeting start ignored because another start is already in progress",
                context: baseDiagnosticsContext(extra: ["trigger": trigger.rawValue])
            )
            // The caller did not start a recording. Returning false keeps a
            // prompt action from treating a competing start as accepted.
            return false
        }

        switch state {
        case .recording, .startingRecording, .stoppingRecording:
            DiagnosticsTrail.record(
                engine: "meeting",
                event: "meeting_start_ignored",
                message: "Meeting start ignored because another meeting flow is active",
                context: baseDiagnosticsContext(extra: ["trigger": trigger.rawValue])
            )
            return true
        case .idle, .loadingModels, .ready, .transcribing, .error:
            break
        }

        // `state` cannot carry this reentrancy guard on its own: the
        // permission-check + model-prep preamble below legitimately cycles
        // `state` through .loadingModels/.ready/.error via the shared
        // prepareModels() path (see ensureModelsReadyForRecording), so a
        // second concurrent call would see one of those "free" values and
        // slip past a `state`-only guard. `.startingRecording` is used
        // further down for the narrower, unambiguous "capture.startRecording()
        // is actually engaging the mic" window instead.
        startRecordingCallInFlight = true
        defer { startRecordingCallInFlight = false }
        Self.runtimeDiagnosticsRecorder?.recordSession(kind: "meeting", stage: "start_requested")
        activeDetectedPromptRecordingTelemetryProperties = trigger == .detectedPrompt ? promptTelemetryProperties : nil
        activeDetectedPromptRecordingStartedAt = nil
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_start_requested",
            message: "Meeting start requested",
            context: baseDiagnosticsContext(extra: ["trigger": trigger.rawValue])
        )

        let startDecision = await resolveStartRecordingPermissionDecision(trigger: trigger)
        guard startDecision.canStart else {
            ProductFrictionTelemetry.track(
                surface: .meeting,
                stage: "permission_start",
                result: .blocked,
                failureKind: startDecision.failureReason ?? "permissions",
                modelState: state.diagnosticName
            )
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "meeting_start_blocked_permission",
                message: "Meeting recording blocked because a required permission is missing",
                context: baseDiagnosticsContext(
                    extra: [
                        "trigger": trigger.rawValue,
                        "failure_reason": startDecision.failureReason ?? "permissions",
                        "missing_permissions": startDecision.missingPermissions.joined(separator: ",")
                    ]
                )
            )
            transition(
                to: .error(
                    startDecision.errorMessage
                        ?? "Turn on the required permissions in System Settings before recording a meeting."
                ),
                reason: "start_blocked_permission"
            )
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "start_blocked_permission")
            trackDetectedPromptOutcome(
                .recordingStartFailed,
                promptProperties: activeDetectedPromptRecordingTelemetryProperties
            )
            clearDetectedPromptRecordingTelemetry()
            return false
        }

        guard await ensureModelsReadyForRecording(trigger: trigger) else {
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "models_unavailable")
            trackDetectedPromptOutcome(
                .recordingStartFailed,
                promptProperties: activeDetectedPromptRecordingTelemetryProperties
            )
            clearDetectedPromptRecordingTelemetry()
            return false
        }

        let resolvedMeetingTitle = MeetingRecordingTitlePolicy.resolve(
            explicitTitle: suggestedTitle,
            calendarTitle: calendarSuggestedTitleProvider?()
        )
        activeRecordingTrigger = trigger
        activeRecordingIdentity = UUID()
        micBoostPromptRecordingIdentity = nil
        micBoostPromptOutcome = .notShown
        isMicBoostPromptVisible = false
        audioRouteWarning = nil
        systemAudioDegradationWarning = nil
        activeRecordingSuggestedTitle = resolvedMeetingTitle
        installSharedDictationMicRelay()
        startLiveCodexSessionIfNeeded(title: resolvedMeetingTitle)

        transition(to: .startingRecording, reason: "capture_start_requested")
        let started = await capture.startRecording()
        guard started else {
            clearSharedDictationMicRelay()
            finishLiveCodexSessionForActiveRecording(status: .failed, shouldAwaitFinalTranscript: false)
            activeRecordingTrigger = .unknown
            clearActiveRecordingIdentity()
            activeRecordingSuggestedTitle = nil
            activeRecordingStartedAt = nil
            let failureMessage = capture.errorMessage ?? "Meeting recording couldn't start. Check Transcripted's permissions and audio setup, then try again."
            let pipelineSnapshot = capture.pipelineDiagnosticsSnapshot()
            let failureProperties = meetingCaptureAnalyticsProperties(snapshot: pipelineSnapshot).merging(
                [
                    "failure_kind": meetingStartFailureKind(from: failureMessage),
                    "trigger": trigger.rawValue,
                ],
                uniquingKeysWith: { _, new in new }
            )
            DiagnosticsTrail.record(
                level: .error,
                engine: "meeting",
                event: "meeting_start_failed",
                message: failureMessage,
                context: baseDiagnosticsContext(extra: failureProperties)
            )
            AnalyticsReporter.track(
                "meeting_recording_start_failed",
                properties: failureProperties
            )
            ProductFrictionTelemetry.track(
                surface: .meeting,
                stage: "meeting_start",
                result: .failed,
                failureKind: failureProperties["failure_kind"],
                modelState: state.diagnosticName
            )
            transition(to: .error(failureMessage), reason: "capture_start_failed")
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "start_failed")
            trackDetectedPromptOutcome(
                .recordingStartFailed,
                promptProperties: activeDetectedPromptRecordingTelemetryProperties
            )
            clearDetectedPromptRecordingTelemetry()
            return false
        }

        activeRecordingStartedAt = Date()
        if trigger == .detectedPrompt {
            activeDetectedPromptRecordingStartedAt = activeRecordingStartedAt
            trackDetectedPromptOutcome(
                .recordingStarted,
                elapsedSeconds: 0,
                promptProperties: activeDetectedPromptRecordingTelemetryProperties
            )
        }
        transition(to: .recording, reason: "capture_start_confirmed")
        Self.runtimeDiagnosticsRecorder?.recordSession(kind: "meeting", stage: "recording")
        let pipelineSnapshot = capture.pipelineDiagnosticsSnapshot()
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_recording_started",
            message: "Meeting recording started",
            context: baseDiagnosticsContext(
                extra: meetingCaptureAnalyticsProperties(snapshot: pipelineSnapshot).merging(
                    ["trigger": trigger.rawValue],
                    uniquingKeysWith: { _, new in new }
                )
            )
        )
        AnalyticsReporter.track(
            "meeting_recording_started",
            properties: meetingCaptureAnalyticsProperties(snapshot: pipelineSnapshot).merging(
                ["trigger": trigger.rawValue],
                uniquingKeysWith: { _, new in new }
            )
        )
        return true
    }

    private func installSharedDictationMicRelay() {
        let dictationEngine = sttRouter.parakeetEngine
        capture.setSharedDictationMicHandler { [weak dictationEngine] buffer in
            dictationEngine?.appendSharedMeetingMicBuffer(buffer)
        }
    }

    private func clearSharedDictationMicRelay() {
        capture.setSharedDictationMicHandler(nil)
    }

    private func resolveStartRecordingPermissionDecision(
        trigger: StartTrigger
    ) async -> MeetingRecordingStartDecision {
        let microphoneGranted = await TranscriptedPermissionAccess.requestMicrophoneAccessIfNeeded()
        var systemAudioRecordingGranted = TranscriptedPermissionAccess.isGranted(.systemAudioRecording)
        var startDecision = MeetingRecordingStartGate.evaluate(
            microphoneGranted: microphoneGranted,
            systemAudioRecordingGranted: systemAudioRecordingGranted
        )
        let shouldRevalidateCachedSystemAudioPermission = microphoneGranted && systemAudioRecordingGranted
        let shouldRequestMissingSystemAudioPermission =
            microphoneGranted &&
            !startDecision.canStart &&
            startDecision.failureReason == "system_audio_recording"

        guard shouldRevalidateCachedSystemAudioPermission || shouldRequestMissingSystemAudioPermission else {
            return startDecision
        }

        let permissionCheckMode = shouldRevalidateCachedSystemAudioPermission ? "revalidation" : "request"
        DiagnosticsTrail.record(
            engine: "meeting",
            event: shouldRevalidateCachedSystemAudioPermission
                ? "meeting_start_revalidating_system_audio_permission"
                : "meeting_start_requesting_system_audio_permission",
            message: shouldRevalidateCachedSystemAudioPermission
                ? "Meeting start is revalidating cached system audio permission"
                : "Meeting start is requesting system audio permission",
            context: baseDiagnosticsContext(
                extra: [
                    "trigger": trigger.rawValue,
                    "permission_check": permissionCheckMode
                ]
            )
        )

        systemAudioRecordingGranted = await TranscriptedPermissionAccess.requestSystemAudioRecordingAccessIfNeeded(
            forceRefresh: shouldRevalidateCachedSystemAudioPermission
        )
        startDecision = MeetingRecordingStartGate.evaluate(
            microphoneGranted: microphoneGranted,
            systemAudioRecordingGranted: systemAudioRecordingGranted
        )

        DiagnosticsTrail.record(
            level: systemAudioRecordingGranted ? .info : .warning,
            engine: "meeting",
            event: systemAudioRecordingGranted
                ? "meeting_start_system_audio_permission_granted"
                : "meeting_start_system_audio_permission_missing",
            message: systemAudioRecordingGranted
                ? "System audio permission is ready for meeting capture"
                : "System audio permission is still missing for meeting capture",
            context: baseDiagnosticsContext(
                extra: [
                    "trigger": trigger.rawValue,
                    "permission_check": permissionCheckMode
                ]
            )
        )

        return startDecision
    }

    private func ensureModelsReadyForRecording(trigger: StartTrigger) async -> Bool {
        switch state {
        case .idle, .loadingModels, .error:
            await prepareModels()
            guard case .ready = state else {
                ProductFrictionTelemetry.track(
                    surface: .meeting,
                    stage: "model_warmup",
                    result: .blocked,
                    failureKind: "model_not_ready",
                    modelState: state.diagnosticName
                )
                DiagnosticsTrail.record(
                    level: .warning,
                    engine: "meeting",
                    event: "meeting_start_blocked",
                    message: "Meeting could not start because models were not ready",
                    context: baseDiagnosticsContext(extra: ["trigger": trigger.rawValue])
                )
                return false
            }
            return true
        case .ready:
            if !isSpeechModelPreparedForSelection {
                await prepareModels()
                guard case .ready = state else {
                    ProductFrictionTelemetry.track(
                        surface: .meeting,
                        stage: "model_warmup",
                        result: .blocked,
                        failureKind: "speech_model_not_ready",
                        modelState: state.diagnosticName
                    )
                    DiagnosticsTrail.record(
                        level: .warning,
                        engine: "meeting",
                        event: "meeting_start_blocked",
                        message: "Meeting could not start because the selected speech model was not ready",
                        context: baseDiagnosticsContext(extra: ["trigger": trigger.rawValue])
                    )
                    return false
                }
            }
            return true
        case .transcribing:
            return true
        case .recording, .startingRecording, .stoppingRecording:
            // Unreachable in practice — startRecording()'s entry switch
            // already returns before calling this for any of these three —
            // kept for exhaustiveness and as a safe default if that ever
            // changes.
            return true
        }
    }

    /// Stop capture and queue the finished meeting for background transcription.
    /// Returns once the finished audio has either started transcribing or been
    /// placed behind the current background task.
    func stopRecording(reason: StopReason = .unknown) async {
        guard case .recording = state else { return }
        transition(to: .stoppingRecording, reason: "stop_requested")
        Self.runtimeDiagnosticsRecorder?.recordSession(kind: "meeting", stage: "stop_requested")
        let recordingSnapshot = makeRecordingStopSnapshot()
        _ = audioInactivityDetector.stopRecording()
        audioInactivityWarning = nil
        isMicBoostPromptVisible = false
        audioRouteWarning = nil
        clearActiveRecordingIdentity()

        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_stop_requested",
            message: "Meeting stop requested",
            context: baseDiagnosticsContext(
                extra: [
                    "trigger": recordingSnapshot.trigger.rawValue,
                    "reason": reason.rawValue,
                    "duration_ms": "\(recordingSnapshot.durationMilliseconds)"
                ]
            )
        )

        let stopTimeoutFailedTaskId = UUID()
        let stopResult = await capture.stopAndAwaitFiles(
            timedOutOwner: .failedMeeting(stopTimeoutFailedTaskId)
        ) { [weak self] lateResult in
            self?.failedMeetingStore.refreshTimedOutFailedMeetingAudio(
                id: stopTimeoutFailedTaskId,
                result: lateResult
            )
        }
        clearSharedDictationMicRelay()
        await sttRouter.resumeRegularRecordingAfterSharedMeetingMicEndedIfNeeded()
        let files = (micURL: stopResult.micURL, systemURL: stopResult.systemURL)
        let shouldAwaitFinalLiveCodexTranscript = MeetingRecordingFinalizationPolicy
            .shouldAwaitLiveCodexFinalTranscript(
                micFilePresent: files.micURL != nil,
                systemFilePresent: files.systemURL != nil,
                stopTimedOut: stopResult.didTimeOut
            )
        finishLiveCodexSessionForActiveRecording(
            status: shouldAwaitFinalLiveCodexTranscript ? .stopped : .failed,
            shouldAwaitFinalTranscript: shouldAwaitFinalLiveCodexTranscript
        )
        let afterStopVolumeContext = capture.routeVolumeDiagnosticsContext(currentPhase: "after")
        var stopCaptureDiagnostics = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: meetingCaptureAnalyticsProperties(snapshot: recordingSnapshot.pipelineSnapshot),
            afterStopContext: afterStopVolumeContext
        )
        // Read the prompt outcome before any state mutations below; it is only
        // reset at the NEXT recording start, so the value is stable through stop.
        let micAttenuatedByCallApp = MeetingCaptureVolumeDiagnostics.isVoiceProcessedUnrecovered(in: stopCaptureDiagnostics)
        stopCaptureDiagnostics["mic_boost_prompt"] = micBoostPromptOutcome.rawValue
        var finalizedHealthInfo = recordingSnapshot.healthInfo
        if micAttenuatedByCallApp {
            finalizedHealthInfo = finalizedHealthInfo.markingMicAttenuatedByCallApp(
                micBoostPrompt: micBoostPromptOutcome.rawValue
            )
        }
        if files.systemURL == nil {
            finalizedHealthInfo = finalizedHealthInfo.markingSystemAudioMissing()
        }
        activeRecordingTrigger = .unknown
        activeRecordingSuggestedTitle = nil
        activeRecordingStartedAt = nil
        transition(to: .transcribing, reason: "stop_completed")
        Self.runtimeDiagnosticsRecorder?.recordSession(kind: "meeting", stage: "transcribing")
        let stopDiagnosticsContext = stopCaptureDiagnostics.merging(
            [
                "trigger": recordingSnapshot.trigger.rawValue,
                "reason": reason.rawValue,
                "duration_ms": "\(recordingSnapshot.durationMilliseconds)",
                "mic_file_present": boolString(files.micURL != nil),
                "system_file_present": boolString(files.systemURL != nil),
                "stop_timed_out": boolString(stopResult.didTimeOut),
                "capture_quality": finalizedHealthInfo.captureQuality.rawValue,
                "audio_gaps": "\(finalizedHealthInfo.audioGaps)",
                "device_switches": "\(finalizedHealthInfo.deviceSwitches)"
            ],
            uniquingKeysWith: { _, new in new }
        )

        DiagnosticsTrail.record(
            level: recordingSnapshot.systemAudioStatus.isWarning || files.systemURL == nil ? .warning : .info,
            engine: "meeting",
            event: "meeting_recording_stopped",
            message: "Meeting recording stopped",
            context: baseDiagnosticsContext(extra: stopDiagnosticsContext)
        )
        AnalyticsReporter.track(
            "meeting_recording_stopped",
            properties: stopCaptureDiagnostics.merging(
                [
                    "capture_quality": finalizedHealthInfo.captureQuality.rawValue,
                    "duration_bucket": AnalyticsReporter.durationBucket(seconds: recordingSnapshot.durationSeconds),
                    "gap_count_bucket": AnalyticsReporter.countBucket(finalizedHealthInfo.audioGaps),
                    "reason": reason.rawValue,
                    "route_change_count_bucket": AnalyticsReporter.countBucket(finalizedHealthInfo.deviceSwitches),
                    "system_stream_present": boolString(files.systemURL != nil),
                    "stop_timed_out": boolString(stopResult.didTimeOut),
                    "trigger": recordingSnapshot.trigger.rawValue,
                ],
                uniquingKeysWith: { _, new in new }
            )
        )
        AnalyticsReporter.track(
            "meeting_capture_health_snapshot",
            properties: MeetingCaptureHealthTelemetry.snapshotProperties(
                .init(
                    captureDiagnostics: stopCaptureDiagnostics,
                    health: captureHealthFacts(from: finalizedHealthInfo),
                    trigger: recordingSnapshot.trigger.rawValue,
                    reason: reason.rawValue,
                    durationSeconds: recordingSnapshot.durationSeconds,
                    systemStreamPresent: files.systemURL != nil,
                    stopTimedOut: stopResult.didTimeOut
                )
            )
        )
        reportCaptureHealthIfNeeded(
            snapshot: recordingSnapshot.pipelineSnapshot,
            captureDiagnostics: stopCaptureDiagnostics,
            healthInfo: finalizedHealthInfo,
            trigger: recordingSnapshot.trigger,
            reason: reason,
            durationSeconds: recordingSnapshot.durationSeconds,
            files: files,
            stopTimedOut: stopResult.didTimeOut
        )

        // Every timed-out stop keeps the preallocated task ID used by its late
        // completion callback. Handle this before the generic missing-mic path
        // so an initially absent mic URL cannot create an unrelated failed row.
        if stopResult.didTimeOut {
            Self.runtimeDiagnosticsRecorder?.recordStall(
                kind: "meeting",
                stage: "recording_stop_timeout",
                durationSeconds: recordingSnapshot.durationSeconds,
                extra: [
                    "trigger": recordingSnapshot.trigger.rawValue,
                    "reason": reason.rawValue
                ]
            )
            let preserved = failedMeetingStore.preserveTimedOutFailedMeetingForRetry(
                taskId: stopTimeoutFailedTaskId,
                micAudioURL: files.micURL,
                systemAudioURL: files.systemURL,
                errorMessage: "Recording stop timed out before audio files were finalized.",
                meetingTitle: recordingSnapshot.suggestedTitle,
                recordingDate: recordingSnapshot.recordingStartedAt
            )
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "meeting_recording_stop_timeout_failed",
                message: "Meeting routed to failed queue due to stop timeout",
                context: baseDiagnosticsContext(
                    extra: [
                        "reason": reason.rawValue,
                        "preserved_for_retry": boolString(preserved)
                    ]
                )
            )
            transition(to: .error("Recording didn't close cleanly. Open Transcripted Home to retry."), reason: "stop_timeout")
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "stop_timeout")
            trackDetectedPromptOutcome(
                .transcriptFailed,
                elapsedSeconds: activeDetectedPromptRecordingStartedAt.map { Date().timeIntervalSince($0) },
                promptProperties: activeDetectedPromptRecordingTelemetryProperties
            )
            clearDetectedPromptRecordingTelemetry()
            return
        }

        guard let micURL = files.micURL else {
            let preserved = failedMeetingStore.preserveFailedMeetingForRetry(
                micAudioURL: nil,
                systemAudioURL: files.systemURL,
                errorMessage: "Recording stopped without microphone audio.",
                meetingTitle: recordingSnapshot.suggestedTitle,
                recordingDate: recordingSnapshot.recordingStartedAt
            )
            DiagnosticsTrail.record(
                level: .error,
                engine: "meeting",
                event: "meeting_recording_missing_mic_audio",
                message: "Meeting recording stopped without a microphone file",
                context: baseDiagnosticsContext(
                    extra: [
                        "reason": reason.rawValue,
                        "system_file_present": boolString(files.systemURL != nil),
                        "preserved_for_retry": boolString(preserved)
                    ]
                )
            )
            Self.runtimeDiagnosticsRecorder?.clearSession(
                kind: "meeting",
                outcome: files.systemURL == nil ? "no_audio_captured" : "missing_mic_audio"
            )
            transition(
                to: files.systemURL == nil
                    ? .error("No meeting audio was captured.")
                    : .error("Microphone audio was missing. Open Transcripted Home to retry the system audio."),
                reason: "stop_missing_mic_audio"
            )
            return
        }

        if files.systemURL == nil {
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "meeting_recording_missing_system_audio_mic_only",
                message: "Meeting recording will continue through the mic-only recovery pipeline",
                context: baseDiagnosticsContext(
                    extra: [
                        "reason": reason.rawValue,
                        "mic_file_present": boolString(true),
                        "partial_output": boolString(true)
                    ]
                )
            )
        }

        let outcome = transcriptionQueue.enqueueTranscriptionJob(
            micURL: micURL,
            systemURL: files.systemURL,
            healthInfo: finalizedHealthInfo,
            captureDiagnostics: stopCaptureDiagnostics,
            meetingTitle: recordingSnapshot.suggestedTitle,
            recordingDate: recordingSnapshot.recordingStartedAt ?? Date(),
            startTrigger: recordingSnapshot.trigger,
            promptTelemetryProperties: recordingSnapshot.trigger == .detectedPrompt
                ? activeDetectedPromptRecordingTelemetryProperties
                : nil,
            promptRecordingStartedAt: recordingSnapshot.trigger == .detectedPrompt
                ? activeDetectedPromptRecordingStartedAt
                : nil
        )
        clearDetectedPromptRecordingTelemetry()

        let queueDepth = transcriptionQueue.queuedTranscriptionJobs.count
        DiagnosticsTrail.record(
            engine: "meeting",
            event: outcome == .startedImmediately ? "meeting_transcription_started" : "meeting_transcription_queued",
            message: outcome == .startedImmediately
                ? "Meeting transcription started"
                : "Meeting queued behind an earlier transcription",
            context: baseDiagnosticsContext(
                extra: [
                    "trigger": recordingSnapshot.trigger.rawValue,
                    "reason": reason.rawValue,
                    "duration_ms": "\(recordingSnapshot.durationMilliseconds)",
                    "queue_depth": "\(queueDepth)"
                ]
            )
        )
    }

    func dismissAudioInactivityWarning() {
        guard audioInactivityWarning != nil else { return }
        applyAudioInactivityEvent(audioInactivityDetector.dismissWarning())
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_audio_inactivity_warning_dismissed",
            message: "Meeting audio inactivity warning dismissed",
            context: baseDiagnosticsContext(
                extra: [
                    "duration_ms": "\(Int(recordingDuration * 1000))"
                ]
            )
        )
    }

    func acknowledgeSystemAudioDegradationWarning() {
        guard let warning = systemAudioDegradationWarning,
              warning.shouldPresentPrompt else { return }
        systemAudioDegradationWarning = warning.dismissingPrompt()
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_system_audio_warning_acknowledged",
            message: "System audio degradation warning acknowledged",
            context: baseDiagnosticsContext(
                extra: [
                    "duration_ms": "\(Int(recordingDuration * 1000))",
                    "warning_phase": warning.phase.diagnosticName
                ]
            )
        )
    }

    func dismissAudioRouteWarning() {
        guard audioRouteWarning != nil else { return }
        audioRouteWarning = nil
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_capture_route_warning_dismissed",
            message: "Meeting Bluetooth route warning dismissed",
            context: baseDiagnosticsContext(
                extra: [
                    "duration_ms": "\(Int(recordingDuration * 1000))"
                ]
            )
        )
    }

    private func handleMicAttenuationCue() {
        guard case .recording = state,
              let activeRecordingIdentity else { return }
        guard MeetingMicBoostPromptPolicy.shouldPresent(
            isRecording: isRecording,
            voiceProcessingPreferenceEnabled: MicrophoneProcessingPreferences.isVoiceProcessingEnabled(),
            currentOutcome: micBoostPromptOutcome
        ) else { return }
        micBoostPromptOutcome = .shown
        micBoostPromptRecordingIdentity = activeRecordingIdentity
        isMicBoostPromptVisible = true
        DiagnosticsTrail.record(
            level: .warning,
            engine: "meeting",
            event: "meeting_mic_boost_prompt_shown",
            message: "Mic attenuated by another app's voice processing; offering boost",
            context: baseDiagnosticsContext(
                extra: [
                    "duration_ms": "\(Int(recordingDuration * 1000))"
                ]
            )
        )
        AnalyticsReporter.track(
            "meeting_mic_boost_prompt_shown",
            properties: [
                "trigger": activeRecordingTrigger.rawValue,
                "duration_bucket": AnalyticsReporter.durationBucket(seconds: recordingDuration),
            ]
        )
    }

    private func handleRouteStabilityWarning(
        _ outcome: CaptureRouteStabilizationOutcome
    ) {
        // Audio inactivity and mic-boost prompts belong to the overlay; they
        // leave the session state as .recording. The route outcome is latched
        // here and the overlay restores its priority after those prompts.
        guard case .recording = state else { return }
        guard audioRouteWarning == nil else { return }
        audioRouteWarning = outcome

        let snapshot = capture.pipelineDiagnosticsSnapshot()
        let properties = meetingCaptureAnalyticsProperties(snapshot: snapshot).merging(
            [
                "duration_bucket": AnalyticsReporter.durationBucket(seconds: recordingDuration),
                "stabilization_outcome": outcome.rawValue,
                "trigger": activeRecordingTrigger.rawValue,
                "warning_kind": "bluetooth_route_unstable",
            ],
            uniquingKeysWith: { _, new in new }
        )
        DiagnosticsTrail.record(
            level: .warning,
            engine: "meeting",
            event: "meeting_capture_route_warning_shown",
            message: "Meeting Bluetooth route instability detected",
            context: baseDiagnosticsContext(extra: properties)
        )
        AnalyticsReporter.track(
            "meeting_capture_route_warning_shown",
            properties: properties
        )
    }

    func acceptMicBoostPrompt() {
        guard shouldApplyMicBoostPromptAction() else {
            clearStaleMicBoostPrompt()
            return
        }
        micBoostPromptOutcome = .accepted
        isMicBoostPromptVisible = false
        micBoostPromptRecordingIdentity = nil
        capture.armVoiceProcessingForActiveRecording()
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_mic_boost_prompt_actioned",
            message: "Mic boost prompt accepted; arming VPIO mid-recording",
            context: baseDiagnosticsContext(
                extra: [
                    "action": "accepted",
                    "duration_ms": "\(Int(recordingDuration * 1000))"
                ]
            )
        )
        AnalyticsReporter.track(
            "meeting_mic_boost_prompt_actioned",
            properties: [
                "action": "accepted",
                "trigger": activeRecordingTrigger.rawValue,
                "duration_bucket": AnalyticsReporter.durationBucket(seconds: recordingDuration),
            ]
        )
    }

    func declineMicBoostPrompt() {
        guard shouldApplyMicBoostPromptAction() else {
            clearStaleMicBoostPrompt()
            return
        }
        micBoostPromptOutcome = .declined
        isMicBoostPromptVisible = false
        micBoostPromptRecordingIdentity = nil
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_mic_boost_prompt_actioned",
            message: "Mic boost prompt declined",
            context: baseDiagnosticsContext(
                extra: [
                    "action": "declined",
                    "duration_ms": "\(Int(recordingDuration * 1000))"
                ]
            )
        )
        AnalyticsReporter.track(
            "meeting_mic_boost_prompt_actioned",
            properties: [
                "action": "declined",
                "trigger": activeRecordingTrigger.rawValue,
                "duration_bucket": AnalyticsReporter.durationBucket(seconds: recordingDuration),
            ]
        )
    }

    private func shouldApplyMicBoostPromptAction() -> Bool {
        guard case .recording = state,
              let activeRecordingIdentity,
              let micBoostPromptRecordingIdentity,
              micBoostPromptRecordingIdentity == activeRecordingIdentity else {
            return false
        }
        return MeetingMicBoostPromptPolicy.shouldApplyPromptAction(
            isPromptVisible: isMicBoostPromptVisible,
            isRecording: isRecording
        )
    }

    private func clearStaleMicBoostPrompt() {
        isMicBoostPromptVisible = false
        micBoostPromptRecordingIdentity = nil
    }

    private func clearActiveRecordingIdentity() {
        activeRecordingIdentity = nil
        micBoostPromptRecordingIdentity = nil
        audioRouteWarning = nil
        systemAudioDegradationWarning = nil
    }

    func endRecordingFromAudioInactivityPrompt(automatic: Bool) async {
        guard let warning = audioInactivityWarning else { return }
        if automatic, !warning.automaticStopAllowed {
            let diagnostics = currentAudioInactivityDiagnostics()
            applyAudioInactivityEvent(audioInactivityDetector.dismissWarning())
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "meeting_audio_inactivity_timeout_deferred",
                message: "Meeting audio inactivity auto-stop deferred because capture route looked degraded",
                context: baseDiagnosticsContext(
                    extra: diagnostics.merging(
                        [
                            "duration_ms": "\(Int(recordingDuration * 1000))",
                            "warning_kind": warning.kind.rawValue,
                            "automatic_stop_allowed": boolString(warning.automaticStopAllowed)
                        ],
                        uniquingKeysWith: { _, new in new }
                    )
                )
            )
            return
        }
        let reason: StopReason = automatic ? .audioInactivityTimeout : .audioInactivityPrompt

        DiagnosticsTrail.record(
            level: automatic ? .warning : .info,
            engine: "meeting",
            event: automatic ? "meeting_audio_inactivity_timeout" : "meeting_audio_inactivity_end_requested",
            message: automatic
                ? "Meeting recording ended after audio inactivity countdown"
                : "Meeting recording ended from audio inactivity prompt",
            context: baseDiagnosticsContext(
                extra: [
                    "duration_ms": "\(Int(recordingDuration * 1000))"
                ]
            )
        )

        await stopRecording(reason: reason)
    }

    /// Cancel capture after an explicit confirmation, without queueing
    /// transcription or saving a transcript.
    func cancelRecording(reason: RecordingCancelReason = .unknown) async {
        guard case .recording = state else { return }
        transition(to: .stoppingRecording, reason: "cancel_requested")
        _ = audioInactivityDetector.stopRecording()
        audioInactivityWarning = nil
        isMicBoostPromptVisible = false
        clearActiveRecordingIdentity()

        let recordingSnapshot = makeRecordingStopSnapshot()

        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_cancel_requested",
            message: "Meeting cancellation requested",
            context: baseDiagnosticsContext(
                extra: [
                    "trigger": recordingSnapshot.trigger.rawValue,
                    "reason": reason.rawValue,
                    "duration_ms": "\(recordingSnapshot.durationMilliseconds)"
                ]
            )
        )

        let stopResult = await capture.stopAndDiscardFiles()
        clearSharedDictationMicRelay()
        await sttRouter.resumeRegularRecordingAfterSharedMeetingMicEndedIfNeeded()
        let files = (micURL: stopResult.micURL, systemURL: stopResult.systemURL)
        finishLiveCodexSessionForActiveRecording(status: .cancelled, shouldAwaitFinalTranscript: false)
        let afterStopVolumeContext = capture.routeVolumeDiagnosticsContext(currentPhase: "after")
        var cancelCaptureDiagnostics = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: meetingCaptureAnalyticsProperties(snapshot: recordingSnapshot.pipelineSnapshot),
            afterStopContext: afterStopVolumeContext
        )
        // Mirror stopRecording(): cancelled meetings carry the prompt outcome
        // too, so diagnostics can correlate cancellations with the prompt.
        cancelCaptureDiagnostics["mic_boost_prompt"] = micBoostPromptOutcome.rawValue
        activeRecordingTrigger = .unknown
        activeRecordingSuggestedTitle = nil
        activeRecordingStartedAt = nil
        restoreStateAfterRecordingEndedWithoutNewWork()
        AppSoundPlayer.shared.play(.dictationCancelled)
        Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "cancelled")
        let cancelDiagnosticsContext = cancelCaptureDiagnostics.merging(
            [
                "trigger": recordingSnapshot.trigger.rawValue,
                "reason": reason.rawValue,
                "duration_ms": "\(recordingSnapshot.durationMilliseconds)",
                "mic_file_present": boolString(files.micURL != nil),
                "system_file_present": boolString(files.systemURL != nil),
                "stop_timed_out": boolString(stopResult.didTimeOut)
            ],
            uniquingKeysWith: { _, new in new }
        )

        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_recording_cancelled",
            message: "Meeting recording cancelled",
            context: baseDiagnosticsContext(extra: cancelDiagnosticsContext)
        )
        AnalyticsReporter.track(
            "meeting_recording_cancelled",
            properties: cancelCaptureDiagnostics.merging(
                [
                    "duration_bucket": AnalyticsReporter.durationBucket(seconds: recordingSnapshot.durationSeconds),
                    "reason": reason.rawValue,
                    "stop_timed_out": boolString(stopResult.didTimeOut),
                    "system_stream_present": boolString(files.systemURL != nil),
                    "trigger": recordingSnapshot.trigger.rawValue,
                ],
                uniquingKeysWith: { _, new in new }
            )
        )
        ProductFrictionTelemetry.track(
            surface: .meeting,
            stage: "meeting_recording",
            result: .cancelled,
            failureKind: reason.rawValue,
            elapsedBucket: AnalyticsReporter.durationBucket(seconds: recordingSnapshot.durationSeconds),
            modelState: state.diagnosticName
        )
        AnalyticsReporter.track(
            "meeting_capture_health_snapshot",
            properties: MeetingCaptureHealthTelemetry.snapshotProperties(
                .init(
                    captureDiagnostics: cancelCaptureDiagnostics,
                    health: captureHealthFacts(from: recordingSnapshot.healthInfo),
                    trigger: recordingSnapshot.trigger.rawValue,
                    reason: reason.rawValue,
                    durationSeconds: recordingSnapshot.durationSeconds,
                    systemStreamPresent: files.systemURL != nil,
                    stopTimedOut: stopResult.didTimeOut
                )
            )
        )
    }

    @discardableResult
    func importAudioFile(from sourceURL: URL) async -> Bool {
        guard !isCaptureSessionActive else {
            transition(to: .error("Stop the current meeting before importing an audio file."), reason: "import_blocked_capture_active")
            return false
        }

        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_file_import_requested",
            message: "Imported meeting transcription requested",
            context: baseDiagnosticsContext(extra: ["trigger": StartTrigger.fileImport.rawValue])
        )
        Self.runtimeDiagnosticsRecorder?.recordSession(kind: "meeting", stage: "file_import_requested")

        if case .idle = state {
            await prepareModels()
        } else if case .loadingModels = state {
            await prepareModels()
        } else if case .error = state {
            await prepareModels()
        }
        if case .ready = state, !isSpeechModelPreparedForSelection {
            await prepareModels()
        }

        switch state {
        case .ready, .transcribing:
            break
        default:
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "models_unavailable")
            return false
        }

        // Surface a cancellable "preparing" card while the source file is copied
        // into scratch. Large imports can take a while; the user can cancel here
        // and the partial copy is cleaned up before any job is enqueued. Only
        // drive the card when no other transcription is already owning it, so we
        // don't stomp an active job's real progress with this prep state.
        let drivesActivityDisplay = !hasBackgroundTranscriptionWork
        if drivesActivityDisplay {
            updateDisplayStatus(.gettingReady, source: .controllerPhase)
        }
        let preparationTask = Task.detached(priority: .utility) {
            try await MeetingImportedAudioPreparer.prepareImportedAudio(from: sourceURL)
        }
        let preparationToken = UUID()
        importPreparationTask = preparationTask
        importPreparationToken = preparationToken
        defer {
            // Only clear if a later import hasn't already replaced this one.
            if importPreparationToken == preparationToken {
                importPreparationTask = nil
                importPreparationToken = nil
            }
        }

        let preparedAudio: PreparedImportedMeetingAudio
        do {
            preparedAudio = try await preparationTask.value
        } catch is CancellationError {
            // The user cancelled mid-import. The preparer already removed the
            // partial scratch copy, so just reset the visible state.
            if drivesActivityDisplay, case .gettingReady = displayStatus {
                updateDisplayStatus(.idle, source: .controllerPhase)
            }
            if case .transcribing = state {} else {
                transition(to: .ready, reason: "import_cancelled")
            }
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "meeting_file_import_cancelled",
                message: "Imported meeting audio preparation cancelled before transcription",
                context: baseDiagnosticsContext(
                    extra: ["trigger": StartTrigger.fileImport.rawValue]
                )
            )
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "file_import_cancelled")
            return false
        } catch {
            if drivesActivityDisplay, case .gettingReady = displayStatus {
                updateDisplayStatus(.idle, source: .controllerPhase)
            }
            let failureKind = importPreparationFailureKind(for: error)
            let displayMessage = importPreparationFailureMessage(for: error)
            DiagnosticsTrail.record(
                level: .error,
                engine: "meeting",
                event: "meeting_file_import_failed",
                message: "Imported meeting audio could not be prepared",
                context: baseDiagnosticsContext(
                    extra: [
                        "failure_kind": failureKind,
                        "import_stage": "preparation",
                        "trigger": StartTrigger.fileImport.rawValue
                    ]
                )
            )
            AnalyticsReporter.track(
                "meeting_file_import_failed",
                properties: [
                    "failure_kind": failureKind,
                    "import_stage": "preparation",
                ]
            )
            ProductFrictionTelemetry.track(
                surface: .meeting,
                stage: "imported_audio_prepare",
                result: .failed,
                failureKind: failureKind,
                modelState: state.diagnosticName
            )
            transition(to: .error(displayMessage), reason: "import_preparation_failed")
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "file_import_failed")
            return false
        }

        let stoppedAudioRecovery = DictationStoppedAudioRecoveryStore
            .pendingRecoveries(limit: Int.max)
            .first { $0.url.standardizedFileURL == sourceURL.standardizedFileURL }
        let outcome: TranscriptionQueueCoordinator.QueueInsertionOutcome
        do {
            outcome = try transcriptionQueue.enqueueImportedAudioJob(
                audioURL: preparedAudio.copiedAudioURL,
                suggestedTitle: preparedAudio.suggestedTitle,
                recordingDate: preparedAudio.recordingDate,
                startTrigger: .fileImport,
                stoppedAudioRecovery: stoppedAudioRecovery
            )
        } catch {
            let preservedForRelaunch = failedMeetingStore.preserveFailedMeetingForRetry(
                micAudioURL: nil,
                systemAudioURL: preparedAudio.copiedAudioURL,
                errorMessage: ImportedAudioQueuePersistenceFailureCopy.retryEntryMessage,
                meetingTitle: preparedAudio.suggestedTitle,
                recordingDate: preparedAudio.recordingDate
            )
            if !preservedForRelaunch {
                try? FileManager.default.removeItem(at: preparedAudio.copiedAudioURL)
            }
            let message = ImportedAudioQueuePersistenceFailureCopy.displayMessage(
                preservedForRelaunch: preservedForRelaunch
            )
            transition(to: .error(message), reason: "import_queue_persist_failed")
            updateDisplayStatus(.failed(message: message), source: .controllerPhase)
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "import_queue_persist_failed")
            return false
        }

        DiagnosticsTrail.record(
            engine: "meeting",
            event: outcome == .startedImmediately
                ? "meeting_file_import_started"
                : "meeting_file_import_queued",
            message: outcome == .startedImmediately
                ? "Imported meeting transcription started"
                : "Imported meeting transcription queued",
            context: baseDiagnosticsContext(
                extra: [
                    "queue_depth": "\(transcriptionQueue.queuedTranscriptionJobs.count)",
                    "trigger": StartTrigger.fileImport.rawValue
                ]
            )
        )
        AnalyticsReporter.track(
            "meeting_file_imported",
            properties: [
                "queue_depth_bucket": AnalyticsReporter.queueDepthBucket(transcriptionQueue.queuedTranscriptionJobs.count),
            ]
        )
        Self.runtimeDiagnosticsRecorder?.recordSession(kind: "meeting", stage: "transcribing")
        return true
    }

    private func importPreparationFailureKind(for error: Error) -> String {
        MeetingImportPreparationFailureCopy.kind(for: error)
    }

    private func importPreparationFailureMessage(for error: Error) -> String {
        MeetingImportPreparationFailureCopy.message(for: error)
    }

    /// Cancel any in-progress pipeline. Does not cancel an active recording —
    /// use stopRecording() for that.
    func cancelActiveTranscription(reason: TranscriptionCancelReason = .unknown) {
        // An in-flight imported-audio copy is cancellable too. Cancelling the
        // task makes the preparer interrupt the copy and remove the partial
        // scratch file; importAudioFile() then resets the visible state.
        importPreparationTask?.cancel()
        importPreparationTask = nil
        importPreparationToken = nil

        let queuedJobs = transcriptionQueue.queuedTranscriptionJobs
        transcriptionQueue.queuedTranscriptionJobs.removeAll()
        let preparingJob = transcriptionQueue.preparingQueuedTranscriptionJob
        transcriptionQueue.queuedTranscriptionStartTask?.cancel()
        transcriptionQueue.queuedTranscriptionStartTask = nil
        transcriptionQueue.preparingQueuedTranscriptionJob = nil
        sttAdapter.discardPreparedModel()
        lastTerminalTranscriptionOutcome = nil
        activeTranscriptionTrigger = .unknown
        activeTranscriptionCaptureDiagnostics = nil

        for job in queuedJobs + [preparingJob].compactMap({ $0 }) {
            switch job.kind {
            case .recorded(let micURL, let systemURL, _, _, let meetingTitle, let recordingDate):
                failedMeetingStore.preserveFailedMeetingForRetry(
                    micAudioURL: micURL,
                    systemAudioURL: systemURL,
                    errorMessage: "Transcription cancelled",
                    meetingTitle: meetingTitle,
                    recordingDate: recordingDate
                )
            case .imported(let audioURL, let suggestedTitle, let recordingDate):
                if reason == .userRequested {
                    guard transcriptionQueue.prepareImportedScratchCleanup(for: job) else {
                        continue
                    }
                    do {
                        try FileManager.default.removeItem(at: audioURL)
                        transcriptionQueue.confirmImportedScratchCleanup(for: job)
                    } catch where (error as NSError).code == NSFileNoSuchFileError {
                        transcriptionQueue.confirmImportedScratchCleanup(for: job)
                    } catch {
                        AppLogger.pipeline.warning("Failed to discard queued imported scratch audio", [
                            "file": audioURL.lastPathComponent,
                            "errorType": String(describing: type(of: error))
                        ])
                    }
                } else {
                    if failedMeetingStore.preserveFailedMeetingForRetry(
                        micAudioURL: nil,
                        systemAudioURL: audioURL,
                        errorMessage: "Imported audio saved before cancellation. Audio is safe; finish the transcript from Home.",
                        meetingTitle: suggestedTitle,
                        recordingDate: recordingDate
                    ) {
                        transcriptionQueue.confirmImportedFailedQueueHandoff(for: job)
                    }
                }
            }
        }

        taskManager.cancelAll()
        if liveCodexSessionAwaitingFinalTranscript {
            finishLiveCodexSession(status: .failed, shouldAwaitFinalTranscript: false)
        }
        activeQueuedTranscriptionJobID = nil
        activeStoppedAudioRecovery = nil
        transition(to: .ready, reason: "transcription_cancelled")
        DiagnosticsTrail.record(
            level: .warning,
            engine: "meeting",
            event: "meeting_transcription_cancelled",
            message: "Meeting transcription cancelled",
            context: baseDiagnosticsContext(extra: ["reason": reason.rawValue])
        )
        Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "transcription_cancelled")
    }

    func prepareForTermination() async {
        var didPreserveRecording = false
        var recordingTrigger = activeRecordingTrigger
        var stoppedFiles: (micURL: URL?, systemURL: URL?) = (nil, nil)
        var stopTimedOut = false

        if isStoppingRecording {
            await waitForRecordingFinishBeforeTermination()
        }

        if case .recording = state {
            // prepareForTermination() is only reached on the guaranteed-quit
            // path (see applicationShouldTerminate's .saveAudioAndQuit
            // branch) — there is no "back out of stop" case to restore
            // .recording for afterward.
            transition(to: .stoppingRecording, reason: "prepare_for_termination")

            _ = audioInactivityDetector.stopRecording()
            audioInactivityWarning = nil
            isMicBoostPromptVisible = false
            clearActiveRecordingIdentity()

            let shutdownFailedTaskId = UUID()
            let files = await capture.stopAndAwaitFiles(
                timedOutOwner: .failedMeeting(shutdownFailedTaskId)
            ) { [weak self] lateResult in
                self?.failedMeetingStore.refreshTimedOutFailedMeetingAudio(
                    id: shutdownFailedTaskId,
                    result: lateResult
                )
            }
            stoppedFiles = (micURL: files.micURL, systemURL: files.systemURL)
            stopTimedOut = files.didTimeOut
            finishLiveCodexSessionForActiveRecording(status: .failed, shouldAwaitFinalTranscript: false)
            let meetingTitle = activeRecordingSuggestedTitle
            let recordingDate = activeRecordingStartedAt
            activeRecordingTrigger = .unknown
            activeRecordingSuggestedTitle = nil
            activeRecordingStartedAt = nil

            if files.didTimeOut {
                // The late completion may already be buffered even when the
                // timeout snapshot has no URLs, so always give the stable task
                // ID a chance to create its durable failed row.
                didPreserveRecording = failedMeetingStore.preserveTimedOutFailedMeetingForRetry(
                    taskId: shutdownFailedTaskId,
                    micAudioURL: files.micURL,
                    systemAudioURL: files.systemURL,
                    errorMessage: "Meeting saved before quit. Audio is safe; finish the transcript from Home after reopening.",
                    meetingTitle: meetingTitle,
                    recordingDate: recordingDate
                )
            } else if files.micURL != nil || files.systemURL != nil {
                didPreserveRecording = failedMeetingStore.preserveFailedMeetingForRetry(
                    taskId: shutdownFailedTaskId,
                    micAudioURL: files.micURL,
                    systemAudioURL: files.systemURL,
                    errorMessage: "Meeting saved before quit. Audio is safe; finish the transcript from Home after reopening.",
                    meetingTitle: meetingTitle,
                    recordingDate: recordingDate
                )
            }
        } else {
            recordingTrigger = .unknown
        }

        let queuedPreserved = transcriptionQueue.preserveQueuedTranscriptionJobsForShutdown(
            errorMessage: "Meeting saved before quit. Audio is safe; finish the queued transcript from Home after reopening."
        )
        let activePreserved = taskManager.preserveActiveTranscriptionsForShutdown(
            errorMessage: "Meeting saved before quit. Audio is safe; finish the transcript from Home after reopening."
        )
        // An active imported pipeline can enqueue speaker review just before
        // committing its transcript. Preserve that task first so review cleanup
        // cannot retire the journal and delete its only scratch copy. Completed
        // pipelines still finalize their typed recovery owner here.
        taskManager.cleanupPendingNaming()
        let shouldFailPendingLiveHandoff = queuedPreserved > 0
            || activePreserved > 0
            || liveCodexSessionAwaitingFinalTranscript
        if shouldFailPendingLiveHandoff {
            finishLiveCodexSession(status: .failed, shouldAwaitFinalTranscript: false)
            activeQueuedTranscriptionJobID = nil
        }

        guard didPreserveRecording || queuedPreserved > 0 || activePreserved > 0 else { return }

        refreshFailedMeetings()
        transition(to: .ready, reason: "prepare_for_termination_preserved_work")
        DiagnosticsTrail.record(
            level: .warning,
            engine: "meeting",
            event: "meeting_recording_saved_for_shutdown",
            message: "Meeting audio was preserved during app termination",
            context: baseDiagnosticsContext(
                extra: [
                    "trigger": recordingTrigger.rawValue,
                    "mic_file_present": boolString(stoppedFiles.micURL != nil),
                    "system_file_present": boolString(stoppedFiles.systemURL != nil),
                    "stop_timed_out": boolString(stopTimedOut),
                    "active_preserved": "\(activePreserved)",
                    "queued_preserved": "\(queuedPreserved)"
                ]
            )
        )
    }

    private func waitForRecordingFinishBeforeTermination() async {
        let deadline = Date().addingTimeInterval(TranscriptedConstants.meetingTerminationFinishWaitTimeout)
        while isStoppingRecording && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func handleUnexpectedCaptureStop(_ stopResult: CaptureStopResult) {
        // `state` alone now distinguishes this from an app-initiated stop:
        // stopRecording()/cancelRecording()/prepareForTermination() move
        // state to .stoppingRecording before capture ever tears down, so by
        // the time capture reports an unexpected completion, state is only
        // ever still .recording when nothing else asked for the stop.
        guard case .recording = state else { return }

        _ = audioInactivityDetector.stopRecording()
        audioInactivityWarning = nil
        isMicBoostPromptVisible = false
        clearSharedDictationMicRelay()
        Task { @MainActor [weak self] in
            await self?.sttRouter.resumeRegularRecordingAfterSharedMeetingMicEndedIfNeeded()
        }

        let recordingSnapshot = makeRecordingStopSnapshot()
        let files = (micURL: stopResult.micURL, systemURL: stopResult.systemURL)
        let failureMessage = capture.errorMessage
            ?? "Recording stopped unexpectedly. Open Transcripted Home to retry the saved audio."

        finishLiveCodexSessionForActiveRecording(status: .failed, shouldAwaitFinalTranscript: false)
        clearActiveRecordingIdentity()
        activeRecordingTrigger = .unknown
        activeRecordingSuggestedTitle = nil
        activeRecordingStartedAt = nil

        let preserved = failedMeetingStore.preserveFailedMeetingForRetry(
            micAudioURL: files.micURL,
            systemAudioURL: files.systemURL,
            errorMessage: failureMessage,
            meetingTitle: recordingSnapshot.suggestedTitle,
            recordingDate: recordingSnapshot.recordingStartedAt
        )

        DiagnosticsTrail.record(
            level: .error,
            engine: "meeting",
            event: "meeting_capture_stopped_under_controller",
            message: "Meeting capture stopped before the app stop path ran",
            context: baseDiagnosticsContext(
                extra: [
                    "mic_file_present": boolString(files.micURL != nil),
                    "system_file_present": boolString(files.systemURL != nil),
                    "preserved_for_retry": boolString(preserved),
                    "capture_quality": recordingSnapshot.healthInfo.captureQuality.rawValue,
                    "audio_gaps": "\(recordingSnapshot.healthInfo.audioGaps)",
                    "device_switches": "\(recordingSnapshot.healthInfo.deviceSwitches)"
                ]
            )
        )

        AnalyticsReporter.track(
            "meeting_capture_stopped_under_controller",
            properties: MeetingCaptureHealthTelemetry.snapshotProperties(
                .init(
                    captureDiagnostics: meetingCaptureAnalyticsProperties(snapshot: recordingSnapshot.pipelineSnapshot),
                    health: captureHealthFacts(from: recordingSnapshot.healthInfo),
                    trigger: recordingSnapshot.trigger.rawValue,
                    reason: "internal_stop",
                    durationSeconds: recordingSnapshot.durationSeconds,
                    systemStreamPresent: files.systemURL != nil,
                    stopTimedOut: stopResult.didTimeOut
                )
            )
        )

        transition(
            to: preserved
                ? .error("Recording stopped early. Open Transcripted Home to retry the saved audio.")
                : .error("Recording stopped early and no meeting audio was saved."),
            reason: "unexpected_capture_stop"
        )
        Self.runtimeDiagnosticsRecorder?.clearSession(
            kind: "meeting",
            outcome: preserved ? "capture_stopped_under_controller" : "capture_stopped_no_audio"
        )
    }

    // preserveQueuedTranscriptionJobsForShutdown moved to
    // TranscriptionQueueCoordinator.swift (audit 2026-07-08 wave 2, W2-B).

    // Full implementation moved to FailedMeetingStore.swift (audit
    // 2026-07-08 wave 2, W2-B). This forwarder keeps the public signature
    // controller callers (Settings/Home UI) already depend on.
    @discardableResult
    func retryFailedMeeting(id: UUID) -> Bool {
        failedMeetingStore.retryFailedMeeting(id: id)
    }

    @discardableResult
    func retranscribeSavedMeeting(
        micAudioURL: URL?,
        systemAudioURL: URL,
        title: String?,
        transcriptURL: URL? = nil,
        recordingDate: Date? = nil
    ) async -> Bool {
        guard !(sttRouter.isRecording || sttRouter.isTranscribing) else {
            transition(to: .error("Wait for the current dictation to finish before re-transcribing saved audio."), reason: "retranscribe_blocked_dictation")
            return false
        }
        guard !isCaptureSessionActive else {
            transition(to: .error("Stop the current meeting before re-transcribing saved audio."), reason: "retranscribe_blocked_capture_active")
            return false
        }
        guard !hasBackgroundTranscriptionWork else {
            transition(to: .error("Wait for the current meeting to finish saving or transcribing before re-transcribing saved audio."), reason: "retranscribe_blocked_background_work")
            return false
        }
        guard !isSpeakerReviewPending else {
            transition(to: .error("Finish the speaker review window before re-transcribing saved audio."), reason: "retranscribe_blocked_speaker_review")
            return false
        }

        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_saved_audio_retranscription_requested",
            message: "Saved meeting audio retranscription requested",
            context: baseDiagnosticsContext(
                extra: [
                    "mic_stream_present": boolString(micAudioURL != nil),
                    "trigger": StartTrigger.savedMeetingRetranscription.rawValue
                ]
            )
        )
        AnalyticsReporter.track(
            "meeting_saved_audio_retranscription_requested",
            properties: [
                "mic_stream_present": boolString(micAudioURL != nil),
                "trigger": StartTrigger.savedMeetingRetranscription.rawValue
            ]
        )
        ProductFrictionTelemetry.track(
            surface: .meeting,
            stage: "meeting_retry",
            result: .started,
            modelState: state.diagnosticName
        )

        if case .idle = state {
            await prepareModels()
        } else if case .loadingModels = state {
            await prepareModels()
        } else if case .error = state {
            await prepareModels()
        }
        if case .ready = state, !isSpeechModelPreparedForSelection {
            await prepareModels()
        }

        guard case .ready = state else {
            return false
        }

        activeTranscriptionTrigger = .savedMeetingRetranscription
        transition(to: .transcribing, reason: "retranscribe_started")
        Self.runtimeDiagnosticsRecorder?.recordSession(kind: "meeting", stage: "saved_audio_retranscribing")
        taskManager.startSavedAudioRetranscription(
            micURL: micAudioURL,
            systemURL: systemAudioURL,
            outputFolder: MeetingStoragePaths.transcriptsFolder,
            meetingTitle: title,
            splitLocalSpeakers: true,
            replacementTranscriptURL: transcriptURL,
            recordingDate: recordingDate,
            onReplacementTranscriptCommitted: { [weak self] committedTranscriptURL in
                self?.handleReplacementTranscriptCommitted(for: committedTranscriptURL)
            }
        )
        return true
    }

    private func handleReplacementTranscriptCommitted(for transcriptURL: URL) {
        clearGeneratedSummaryAfterReplacementRetranscription(for: transcriptURL)
        savedMeetingReplacementCommitCount &+= 1
    }

    private func clearGeneratedSummaryAfterReplacementRetranscription(for transcriptURL: URL) {
        do {
            guard try LocalMeetingSummaryStore.removeGeneratedSummary(for: transcriptURL) else {
                return
            }
            DiagnosticsTrail.record(
                engine: "meeting",
                event: "meeting_retranscription_summary_invalidated",
                message: "Removed stale local summary after saved meeting retranscription",
                context: baseDiagnosticsContext()
            )
        } catch {
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "meeting_retranscription_summary_invalidation_failed",
                message: "Failed to remove stale local summary after saved meeting retranscription",
                context: baseDiagnosticsContext(extra: [
                    "error_type": "\(type(of: error))"
                ])
            )
        }
    }

    // Full implementations moved to FailedMeetingStore.swift (audit
    // 2026-07-08 wave 2, W2-B). These forwarders keep the public signatures
    // controller callers (Settings/Home UI) already depend on.
    @discardableResult
    func deleteFailedMeeting(id: UUID) -> Bool {
        failedMeetingStore.deleteFailedMeeting(id: id)
    }

    private func prepareStoppedAudioRecoveryForRetry(failedMeetingID: UUID) {
        activeStoppedAudioRecovery = stoppedAudioRecoveryRetryRegistry.recovery(
            for: failedMeetingID
        )
    }

    private func discardStoppedAudioRecoveryForRetry(failedMeetingID: UUID) {
        let recovery = stoppedAudioRecoveryRetryRegistry.remove(for: failedMeetingID)
        if activeQueuedTranscriptionJobID == failedMeetingID {
            activeStoppedAudioRecovery = nil
        }
        guard recovery != nil else { return }
        Task.detached(priority: .utility) {
            DictationStoppedAudioRecoveryStore.cleanup(recovery, explicitDiscard: true)
        }
    }

    // MARK: - Subscriptions

    private func wireSubscriptions() {
        capture.$isRecording
            .sink { [weak self] captureIsRecording in
                guard let self else { return }
                // This is an event handler, not a mirror: `isRecording` is
                // computed from `state` now (audit 2026-08 state-collapse),
                // so this sink no longer writes it. It still does two real
                // jobs: (1) closes the .startingRecording -> .recording gap
                // as soon as capture confirms the mic actually engaged
                // (idempotent — startRecording() already sets .recording
                // synchronously once capture.startRecording() returns, so
                // whichever of the two runs first wins and the other is a
                // no-op), and (2) runs cleanup that must never outlive a
                // recording, because capture can stop underneath the
                // controller (device watchdog give-up, disk-full guard)
                // without any app-side stop path running. The actual state
                // transition for THAT case — moving to .error — stays in
                // handleUnexpectedCaptureStop(_:), driven by
                // capture.onUnexpectedRecordingComplete with the real
                // CaptureStopResult (audio URLs) needed to preserve a failed
                // meeting; this sink has no URLs to do that safely itself.
                let event: MeetingAudioInactivityDetector.Event
                if captureIsRecording {
                    if case .startingRecording = self.state {
                        self.transition(to: .recording, reason: "capture_confirmed_recording")
                    }
                    event = self.audioInactivityDetector.startRecording(at: self.recordingDuration)
                } else {
                    event = self.audioInactivityDetector.stopRecording()
                    self.isMicBoostPromptVisible = false
                    self.audioRouteWarning = nil
                    self.systemAudioDegradationWarning = nil
                }
                self.applyAudioInactivityEvent(event)
            }
            .store(in: &cancellables)

        capture.$audioLevel
            .sink { [weak self] level in
                guard let self else { return }
                self.audioLevel = level
                self.latestMicLevel = level
                self.sttRouter.updateSharedMeetingMicAudioLevel(level)
                self.observeAudioActivity()
            }
            .store(in: &cancellables)

        capture.$systemLevel
            .sink { [weak self] level in
                guard let self else { return }
                self.systemLevel = level
                self.latestSystemLevel = level
                self.observeAudioActivity()
            }
            .store(in: &cancellables)

        capture.$recordingDuration
            .sink { [weak self] duration in
                guard let self else { return }
                // The capture timer ticks every 0.2s, but every @Published
                // mutation here re-renders any SwiftUI view observing this
                // controller (Home observes it directly). UI consumers only
                // display whole seconds, so republish the mirror on second
                // boundaries plus resets; diagnostics reads tolerate the
                // sub-second staleness. The inactivity tick below stays on
                // the raw 0.2s cadence.
                if Int(duration) != Int(self.recordingDuration) || duration < self.recordingDuration {
                    self.recordingDuration = duration
                }
                guard self.isRecording else { return }
                self.applyAudioInactivityEvent(
                    self.audioInactivityDetector.tick(at: duration)
                )
            }
            .store(in: &cancellables)

        capture.$micAttenuationCueObserved
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.handleMicAttenuationCue()
            }
            .store(in: &cancellables)

        capture.$routeStabilityWarningOutcome
            // Keep the nil reset in the deduplication stream. It separates
            // identical outcomes from consecutive recordings.
            .removeDuplicates()
            .compactMap { $0 }
            .sink { [weak self] outcome in
                self?.handleRouteStabilityWarning(outcome)
            }
            .store(in: &cancellables)

        capture.$systemAudioStatus
            .removeDuplicates()
            .sink { [weak self] status in
                guard let self else { return }
                self.systemAudioDegradationWarning = MeetingSystemAudioDegradationPolicy.next(
                    current: self.systemAudioDegradationWarning,
                    status: MeetingSystemAudioStatusCopy.caseValue(for: status),
                    isRecording: self.isRecording
                )
                let level: EventLevel = status.isWarning ? .warning : .info
                DiagnosticsTrail.record(
                    level: level,
                    engine: "meeting",
                    event: "system_audio_status_changed",
                    message: self.systemAudioStatusMessage(for: status),
                    context: self.baseDiagnosticsContext(
                        extra: [
                            "system_audio_status": status.diagnosticName,
                            "recording": self.boolString(self.isRecording),
                            "duration_ms": "\(Int(self.recordingDuration * 1000))"
                        ]
                    )
                )
            }
            .store(in: &cancellables)

        taskManager.$activeCount
            .combineLatest(taskManager.$speakerNamingRequest)
            .sink { [weak self] activeCount, speakerNamingRequest in
                guard let self else { return }
                if activeCount > 0 {
                    self.sttAdapter.beginTranscriptionJob()
                } else {
                    self.sttAdapter.finishTranscriptionJob()
                }
                self.transcriptionQueue.handleBackgroundTranscriptionWorkChanged(
                    snapshot: BackgroundTranscriptionWorkSnapshot(
                        activeCount: activeCount,
                        speakerNamingRequest: speakerNamingRequest
                    )
                )
                self.attachLiveCodexFinalTranscriptIfReady()
            }
            .store(in: &cancellables)

        taskManager.$displayStatus
            .sink { [weak self] status in
                self?.updateDisplayStatus(status, source: .taskManagerMirror)
            }
            .store(in: &cancellables)

        taskManager.$lastSavedTranscriptURL
            .sink { [weak self] url in
                guard let self else { return }
                guard let url else {
                    self.savedTranscriptRestyleTask = nil
                    self.lastSavedTranscriptURL = nil
                    self.lastSavedTitle = nil
                    return
                }

                self.restyleSavedTranscriptInBackground(at: url)
            }
            .store(in: &cancellables)

        failedManager.$failedTranscriptions
            .sink { [weak self] failedTranscriptions in
                self?.refreshFailedMeetings(failedTranscriptions)
            }
            .store(in: &cancellables)

        sttRouter.$modelDownloadState
            .sink { [weak self] _ in
                self?.refreshWarmupStatus()
            }
            .store(in: &cancellables)

        diarization.$modelState
            .sink { [weak self] _ in
                self?.refreshWarmupStatus()
            }
            .store(in: &cancellables)

        refreshFailedMeetings()
        refreshWarmupStatus()
    }

    /// Restyling reads and rewrites the whole saved transcript and can rename
    /// the markdown + retained-audio artifacts, so it must stay off the main
    /// actor; multi-hour meetings produce multi-MB files. Restyles are chained
    /// so two passes never touch the same artifacts concurrently.
    private func restyleSavedTranscriptInBackground(at url: URL) {
        let previousRestyle = savedTranscriptRestyleTask
        let restyle = Task.detached(priority: .userInitiated) { () -> StyledMeetingTranscript in
            _ = await previousRestyle?.value
            let styled = MeetingTranscriptStyler.restyleTranscript(at: url)
            // Always-on cheap field extraction so the search index covers every
            // meeting, not just the heavy local-summary beta opt-in. Runs after
            // restyle (the body is now in canonical styled form) on this chained
            // background task, and is idempotent + frontmatter-only.
            MeetingQuickSummaryWriter.ensureQuickSummary(at: styled.url)
            return styled
        }
        savedTranscriptRestyleTask = restyle

        Task { @MainActor [weak self] in
            let styled = await restyle.value
            let transcriptURL = styled.url
            // The restyle may have renamed the transcript + its audio/<stem>_audio
            // directory. Tell Home so any cached URLs for the old stem re-resolve.
            if styled.url != url {
                CaptureLibraryChangeBroadcaster.shared.noteArtifactsChanged(
                    transcriptURLs: [styled.url]
                )
            }
            Task.detached(priority: .utility) {
                let didChangeArtifacts = await MeetingAudioStorageManager
                    .processSavedTranscript(at: transcriptURL)
                // Recompression (WAV->M4A) and retention pruning rewrite the audio
                // paths Home cached at scan time; signal so the cache re-resolves.
                if didChangeArtifacts {
                    await MainActor.run {
                        CaptureLibraryChangeBroadcaster.shared.noteArtifactsChanged(
                            transcriptURLs: [transcriptURL]
                        )
                    }
                }
            }
            guard let self, self.savedTranscriptRestyleTask == restyle else { return }
            self.lastSavedTranscriptURL = styled.url
            self.lastSavedTitle = styled.title
            self.attachLiveCodexFinalTranscriptIfReady(url: styled.url, title: styled.title)
            DiagnosticsTrail.record(
                engine: "meeting",
                event: "meeting_transcript_artifact_ready",
                message: "Meeting transcript artifact is ready",
                context: self.baseDiagnosticsContext()
            )
        }
    }

    private func observeAudioActivity() {
        guard isRecording else { return }
        applyAudioInactivityEvent(
            audioInactivityDetector.observe(
                micLevel: latestMicLevel,
                systemLevel: latestSystemLevel,
                at: recordingDuration
            )
        )
    }

    private func currentAudioInactivityDiagnostics() -> [String: String] {
        let snapshot = capture.pipelineDiagnosticsSnapshot()
        return MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: meetingCaptureAnalyticsProperties(snapshot: snapshot),
            afterStopContext: [:]
        )
    }

    private func applyAudioInactivityEvent(_ event: MeetingAudioInactivityDetector.Event) {
        switch event {
        case .none:
            return
        case .warningStarted(let warning):
            let diagnostics = currentAudioInactivityDiagnostics()
            let presentedWarning = MeetingAudioInactivityRecoveryPolicy.warning(
                from: warning,
                durationSeconds: recordingDuration,
                diagnostics: diagnostics
            )
            audioInactivityWarning = presentedWarning
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "meeting_audio_inactivity_warning_started",
                message: "No meeting audio detected",
                context: baseDiagnosticsContext(
                    extra: diagnostics.merging(
                        [
                            "inactive_ms": "\(Int(warning.inactiveDuration * 1000))",
                            "countdown_seconds": "\(warning.countdownSeconds)",
                            "duration_ms": "\(Int(recordingDuration * 1000))",
                            "warning_kind": presentedWarning.kind.rawValue,
                            "automatic_stop_allowed": boolString(presentedWarning.automaticStopAllowed)
                        ],
                        uniquingKeysWith: { _, new in new }
                    )
                )
            )
        case .warningCleared:
            guard audioInactivityWarning != nil else { return }
            audioInactivityWarning = nil
            DiagnosticsTrail.record(
                engine: "meeting",
                event: "meeting_audio_inactivity_warning_cleared",
                message: "Meeting audio inactivity warning cleared",
                context: baseDiagnosticsContext(
                    extra: [
                        "duration_ms": "\(Int(recordingDuration * 1000))"
                    ]
                )
            )
        }
    }

    private func startLiveCodexSessionIfNeeded(title: String?) {
        guard LiveMeetingCodexPreferences.isEnabled() else {
            liveCodexSessionOwnedByActiveRecording = false
            liveCodexFinalTranscriptNeedsQueuedJobID = false
            liveCodexSessionIsActive = false
            liveCodexSessionAwaitingFinalTranscript = false
            liveCodexSessionCanAttachFinalTranscript = false
            liveCodexAwaitedTranscriptionJobID = nil
            liveTranscriptFeed.reset()
            return
        }

        guard !liveCodexSessionAwaitingFinalTranscript else {
            liveCodexSessionOwnedByActiveRecording = false
            liveCodexFinalTranscriptNeedsQueuedJobID = false
            liveTranscriptFeed.beginDeferred(
                note: "Live transcript is paused while the previous meeting finishes its handoff. This meeting still saves normally."
            )
            DiagnosticsTrail.record(
                level: .info,
                engine: "meeting",
                event: "live_codex_session_deferred_pending_handoff",
                message: "Live meeting sidecar kept the previous pending final handoff",
                context: baseDiagnosticsContext()
            )
            return
        }

        let canStartLiveBackend = !hasBackgroundTranscriptionWork
        let backendStatus = canStartLiveBackend
            ? "local_streaming_asr_initializing"
            : "deferred_background_transcription_active"

        do {
            try liveCodexSession.start(
                title: title,
                streamingBackendStatus: backendStatus
            )
            liveCodexSessionIsActive = true
            liveCodexSessionAwaitingFinalTranscript = false
            liveCodexSessionCanAttachFinalTranscript = true
            liveCodexSessionOwnedByActiveRecording = true
            liveCodexPreviewHandlersNeedClearingAfterActiveRecording = false
            liveCodexFinalTranscriptNeedsQueuedJobID = false
            liveCodexAwaitedTranscriptionJobID = nil
            if canStartLiveBackend {
                liveTranscriptFeed.beginStarting()
                liveMeetingTranscriber.start(
                    capture: capture,
                    codexSession: liveCodexSession,
                    feed: liveTranscriptFeed
                )
            } else {
                liveTranscriptFeed.beginDeferred(
                    note: "Live transcript is paused while another meeting finishes processing. This meeting still saves normally."
                )
                try? liveCodexSession.updateStreamingBackendStatus(
                    backendStatus,
                    note: "Live ASR was deferred because another meeting transcript was already processing. The normal final transcript will still save through Transcripted."
                )
            }
            DiagnosticsTrail.record(
                engine: "meeting",
                event: "live_codex_session_started",
                message: "Live meeting sidecar started",
                context: baseDiagnosticsContext(
                    extra: [
                        "live_backend_status": backendStatus,
                        "live_backend_enabled": boolString(canStartLiveBackend)
                    ]
                )
            )
        } catch {
            liveMeetingTranscriber.stop(capture: capture)
            liveCodexSessionIsActive = false
            liveCodexSessionAwaitingFinalTranscript = false
            liveCodexSessionCanAttachFinalTranscript = false
            liveCodexSessionOwnedByActiveRecording = false
            liveCodexFinalTranscriptNeedsQueuedJobID = false
            liveCodexAwaitedTranscriptionJobID = nil
            liveTranscriptFeed.markFailed(
                note: "Live transcript couldn't start for this meeting. The final transcript still saves normally."
            )
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "live_codex_session_start_failed",
                message: "Live meeting sidecar could not start",
                context: baseDiagnosticsContext(extra: ["error": error.localizedDescription])
            )
        }
    }

    /// Late-join entry point for the meeting overlay's Live View affordance:
    /// the user enabled live meetings while this recording was already in
    /// flight. Live streaming ASR cannot attach mid-recording — the bridge's
    /// live PCM preview handlers must be installed before capture starts and
    /// never reassigned mid-session — so this starts the sidecar session
    /// without provisional live text. The final transcript still attaches
    /// automatically after the recording is saved, and the next recording
    /// gets the full live pipeline from `startLiveCodexSessionIfNeeded`.
    func connectLiveSidecarToActiveRecording() {
        guard LiveMeetingCodexPreferences.isEnabled() else { return }
        guard state == .recording else { return }
        guard !liveCodexSessionIsActive, !liveCodexSessionAwaitingFinalTranscript else { return }

        let backendStatus = "deferred_live_view_joined_mid_recording"
        do {
            try liveCodexSession.start(
                title: activeRecordingSuggestedTitle,
                startedAt: activeRecordingStartedAt ?? Date(),
                streamingBackendStatus: backendStatus
            )
            liveCodexSessionIsActive = true
            liveCodexSessionAwaitingFinalTranscript = false
            liveCodexSessionCanAttachFinalTranscript = true
            liveCodexSessionOwnedByActiveRecording = true
            liveCodexFinalTranscriptNeedsQueuedJobID = false
            liveCodexAwaitedTranscriptionJobID = nil
            // Leave liveCodexPreviewHandlersNeedClearingAfterActiveRecording
            // untouched: a disable-then-re-enable during the same recording
            // still owes a post-recording handler clear, and clearing the
            // flag here would leak the installed handlers.
            liveTranscriptFeed.beginDeferred(
                note: "Live transcript is on now and begins with your next meeting. This meeting's transcript still saves normally when you stop."
            )
            try? liveCodexSession.updateStreamingBackendStatus(
                backendStatus,
                note: "Live View joined after this recording started, so live transcript lines begin with your next meeting. The final transcript will still attach here when this recording is saved."
            )
            DiagnosticsTrail.record(
                engine: "meeting",
                event: "live_codex_session_joined_mid_recording",
                message: "Live meeting sidecar joined an active recording without live ASR",
                context: baseDiagnosticsContext(
                    extra: ["live_backend_status": backendStatus]
                )
            )
        } catch {
            liveCodexSessionIsActive = false
            liveCodexSessionAwaitingFinalTranscript = false
            liveCodexSessionCanAttachFinalTranscript = false
            liveCodexSessionOwnedByActiveRecording = false
            liveCodexFinalTranscriptNeedsQueuedJobID = false
            liveCodexAwaitedTranscriptionJobID = nil
            liveTranscriptFeed.markFailed(
                note: "Live transcript couldn't start. This meeting's transcript still saves normally."
            )
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "live_codex_session_join_failed",
                message: "Live meeting sidecar could not join the active recording",
                context: baseDiagnosticsContext(extra: ["error": error.localizedDescription])
            )
        }
    }

    func stopLiveCodexSessionFromSettings() {
        guard liveCodexSessionIsActive || liveCodexSessionAwaitingFinalTranscript else { return }
        let shouldDeferPreviewHandlerClear = liveCodexSessionOwnedByActiveRecording
            || isCaptureSessionActive
        if shouldDeferPreviewHandlerClear {
            liveCodexPreviewHandlersNeedClearingAfterActiveRecording = true
        }

        liveCodexSessionOwnedByActiveRecording = false
        liveCodexFinalTranscriptNeedsQueuedJobID = false
        finishLiveCodexSession(
            status: .disabled,
            shouldAwaitFinalTranscript: false,
            clearPreviewHandlers: !shouldDeferPreviewHandlerClear
        )
    }

    private func finishLiveCodexSessionForActiveRecording(
        status: LiveMeetingCodexSessionStatus,
        shouldAwaitFinalTranscript: Bool
    ) {
        clearDeferredLiveCodexPreviewHandlersIfNeeded()
        guard liveCodexSessionOwnedByActiveRecording else { return }
        let shouldAssignNextQueuedJobID = shouldAwaitFinalTranscript && liveCodexSessionCanAttachFinalTranscript
        finishLiveCodexSession(status: status, shouldAwaitFinalTranscript: shouldAwaitFinalTranscript)
        liveCodexSessionOwnedByActiveRecording = false
        liveCodexFinalTranscriptNeedsQueuedJobID = shouldAssignNextQueuedJobID && liveCodexSessionAwaitingFinalTranscript
    }

    private func clearDeferredLiveCodexPreviewHandlersIfNeeded() {
        guard liveCodexPreviewHandlersNeedClearingAfterActiveRecording else { return }
        liveMeetingTranscriber.clearCapturePreviewHandlers(capture: capture)
        liveCodexPreviewHandlersNeedClearingAfterActiveRecording = false
    }

    // Was `private`; TranscriptionQueueCoordinator lives in a sibling file
    // and needs module-internal access (audit 2026-07-08 wave 2, W2-B).
    func finishLiveCodexSession(
        status: LiveMeetingCodexSessionStatus,
        shouldAwaitFinalTranscript: Bool,
        clearPreviewHandlers: Bool = true
    ) {
        guard liveCodexSessionIsActive || liveCodexSessionAwaitingFinalTranscript else { return }

        liveMeetingTranscriber.stop(capture: capture, clearPreviewHandlers: clearPreviewHandlers)
        liveTranscriptFeed.finish()
        if clearPreviewHandlers {
            liveCodexPreviewHandlersNeedClearingAfterActiveRecording = false
        }

        let willAwaitFinalTranscript = shouldAwaitFinalTranscript && liveCodexSessionCanAttachFinalTranscript

        do {
            try liveCodexSession.finish(status: status)
            liveCodexSessionIsActive = false
            liveCodexSessionAwaitingFinalTranscript = willAwaitFinalTranscript
            liveCodexSessionCanAttachFinalTranscript = willAwaitFinalTranscript
            if !willAwaitFinalTranscript {
                liveCodexFinalTranscriptNeedsQueuedJobID = false
                liveCodexAwaitedTranscriptionJobID = nil
            }
            if shouldAwaitFinalTranscript && !willAwaitFinalTranscript {
                try? liveCodexSession.updateStreamingBackendStatus(
                    "final_transcript_attach_deferred",
                    note: "Final transcript auto-linking was skipped because another transcript was already processing when this live session started."
                )
            }
            DiagnosticsTrail.record(
                engine: "meeting",
                event: "live_codex_session_finished",
                message: "Live meeting sidecar finished recording",
                context: baseDiagnosticsContext(
                    extra: [
                        "live_codex_status": status.rawValue,
                        "awaiting_final_transcript": boolString(willAwaitFinalTranscript)
                    ]
                )
            )
        } catch {
            liveCodexSessionIsActive = false
            liveCodexSessionAwaitingFinalTranscript = false
            liveCodexSessionCanAttachFinalTranscript = false
            liveCodexSessionOwnedByActiveRecording = false
            liveCodexFinalTranscriptNeedsQueuedJobID = false
            liveCodexAwaitedTranscriptionJobID = nil
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "live_codex_session_finish_failed",
                message: "Live meeting sidecar could not finish",
                context: baseDiagnosticsContext(extra: ["error": error.localizedDescription])
            )
        }
    }

    private func attachLiveCodexFinalTranscriptIfReady() {
        guard let url = lastSavedTranscriptURL else { return }
        attachLiveCodexFinalTranscriptIfReady(url: url, title: lastSavedTitle)
    }

    private func attachLiveCodexFinalTranscriptIfReady(url: URL, title: String?) {
        guard liveCodexSessionAwaitingFinalTranscript else { return }
        guard let awaitedJobID = liveCodexAwaitedTranscriptionJobID,
              taskManager.lastSavedTranscriptTaskId == awaitedJobID else {
            return
        }
        guard !taskManager.hasPendingSpeakerNamingReviewForLastSavedTranscript() else { return }

        do {
            try liveCodexSession.attachFinalTranscript(url: url, title: title)
            liveCodexSessionAwaitingFinalTranscript = false
            liveCodexSessionCanAttachFinalTranscript = false
            liveCodexFinalTranscriptNeedsQueuedJobID = false
            liveCodexAwaitedTranscriptionJobID = nil
            DiagnosticsTrail.record(
                engine: "meeting",
                event: "live_codex_session_final_transcript_attached",
                message: "Live meeting sidecar attached the final transcript path",
                context: baseDiagnosticsContext()
            )
        } catch {
            liveCodexSessionAwaitingFinalTranscript = false
            liveCodexSessionCanAttachFinalTranscript = false
            liveCodexFinalTranscriptNeedsQueuedJobID = false
            liveCodexAwaitedTranscriptionJobID = nil
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "live_codex_session_final_transcript_attach_failed",
                message: "Live meeting sidecar could not attach the final transcript path",
                context: baseDiagnosticsContext(extra: ["error": error.localizedDescription])
            )
        }
    }

    private func refreshWarmupStatus() {
        let isMeetingWarmupInFlight = modelPreparationTask != nil || state == .loadingModels
        let dictationState: ParakeetModelState = sttRouter.isModelLoaded
            ? .ready
            : sttRouter.modelDownloadState

        warmupStatus = MeetingWarmupStatusPolicy.status(
            dictationState: dictationState,
            meetingState: MeetingWarmupMeetingState(diarization.modelState),
            isMeetingWarmupInFlight: isMeetingWarmupInFlight,
            shouldSurfaceMeetingWarmupFailure: shouldSurfaceMeetingWarmupFailure
        )
    }

    private func applyModelPreparationResult(_ result: Result<Void, Error>, showLoadingUI: Bool) {
        switch result {
        case .success:
            shouldSurfaceMeetingWarmupFailure = false
            switch state {
            case .recording, .transcribing, .startingRecording, .stoppingRecording:
                break
            default:
                transition(to: .ready, reason: "model_preparation_succeeded")
            }
        case .failure(let error):
            shouldSurfaceMeetingWarmupFailure = showLoadingUI
            if showLoadingUI {
                transition(to: .error(error.localizedDescription), reason: "model_preparation_failed")
            }
        }

        refreshWarmupStatus()
    }

    private func trackModelPreparationRecoveryFinished(
        _ result: Result<Void, Error>,
        retrySource: String,
        elapsedSeconds: TimeInterval,
        surface: String
    ) {
        let recoveryResult: String
        switch result {
        case .success:
            recoveryResult = "success"
        case .failure:
            recoveryResult = "failed"
        }
        WorkflowRecoveryTelemetry.finished(
            workflowKind: "model_preparation",
            failureKind: "models_not_ready",
            retrySource: retrySource,
            result: recoveryResult,
            elapsedSeconds: elapsedSeconds,
            surface: surface,
            artifactRetained: false
        )
    }

    private func resetPreparedSpeechModelIfNeeded() {
        let preparedEngine = sttAdapter.transcriptionEngineDescriptor.identifier
        let selectedEngine = sttRouter.selectedModel.transcriptionEngineIdentifier
        guard preparedEngine != selectedEngine else { return }

        switch state {
        case .recording, .transcribing, .startingRecording, .stoppingRecording:
            refreshWarmupStatus()
            return
        case .idle, .loadingModels, .ready, .error:
            break
        }

        modelPreparationTask = nil
        sttAdapter.cleanup()
        if case .ready = state {
            transition(to: .idle, reason: "speech_model_selection_changed")
        }
        refreshWarmupStatus()
    }

    private var hasBackgroundTranscriptionWork: Bool {
        taskManager.activeCount > 0
            || transcriptionQueue.isPreparingQueuedTranscriptionStart
            || !transcriptionQueue.queuedTranscriptionJobs.isEmpty
    }

    var hasRuntimeDiagnosticsWork: Bool {
        isCaptureSessionActive || hasBackgroundTranscriptionWork
    }

    var queuedTranscriptionCount: Int {
        transcriptionQueue.queuedTranscriptionJobs.count
    }

    var isSpeakerReviewPending: Bool {
        taskManager.speakerNamingRequest != nil
    }

    private var hasVisibleBackgroundTranscriptionWork: Bool {
        transcriptionQueue.hasVisibleBackgroundTranscriptionWork(snapshot: transcriptionQueue.currentBackgroundTranscriptionWorkSnapshot)
    }

    private var isSpeechModelPreparedForSelection: Bool {
        sttAdapter.transcriptionEngineDescriptor.identifier == sttRouter.selectedModel.transcriptionEngineIdentifier
            && sttAdapter.isReady
    }

    // Was `private`; TranscriptionQueueCoordinator lives in a sibling file
    // and needs module-internal access (audit 2026-07-08 wave 2, W2-B).
    var isCaptureSessionActive: Bool {
        MeetingSessionStateMachine.isCaptureSessionActive(state)
    }

    // enqueueTranscriptionJob, enqueueImportedAudioJob, enqueue,
    // startQueuedTranscription, prepareAndStartQueuedTranscription,
    // ensureModelsReadyForQueuedTranscription, runPreparedQueuedTranscription,
    // and failQueuedTranscriptionJobAfterModelRecovery moved to
    // TranscriptionQueueCoordinator.swift (audit 2026-07-08 wave 2, W2-B).
    // Call sites below now go through `transcriptionQueue.`.

    private func finishLiveCodexSessionForCurrentTranscriptionFailureIfNeeded(
        failedJobID: UUID? = nil,
        allowLastSavedTranscriptOwner: Bool = false
    ) {
        guard liveCodexSessionAwaitingFinalTranscript,
              let awaitedJobID = liveCodexAwaitedTranscriptionJobID else {
            return
        }
        let failureBelongsToAwaitedJob = failedJobID == awaitedJobID
            || (allowLastSavedTranscriptOwner && taskManager.lastSavedTranscriptTaskId == awaitedJobID)
        guard failureBelongsToAwaitedJob else { return }
        finishLiveCodexSession(status: .failed, shouldAwaitFinalTranscript: false)
    }

    // recordQueuedTranscriptionRuntimeDiagnosticsIfSafe,
    // clearQueuedTranscriptionRuntimeDiagnosticsIfOwned,
    // canStartQueuedTranscriptionImmediately(snapshot:),
    // hasVisibleBackgroundTranscriptionWork(snapshot:),
    // handleBackgroundTranscriptionWorkChanged, popNextQueuedTranscriptionJob,
    // and finalizeBackgroundTranscriptionStateIfNeeded moved to
    // TranscriptionQueueCoordinator.swift (audit 2026-07-08 wave 2, W2-B).

    private func restoreStateAfterRecordingEndedWithoutNewWork() {
        guard !hasVisibleBackgroundTranscriptionWork else {
            transition(to: .transcribing, reason: "cancel_completed_background_work_visible")
            return
        }

        switch lastTerminalTranscriptionOutcome {
        case .failed(let message):
            transition(to: .error(message), reason: "cancel_completed_prior_failure")
        case .transcriptSaved, .none:
            transition(to: .ready, reason: "cancel_completed")
        }
    }

    private func handleDisplayStatusChange(from previousStatus: DisplayStatus, to status: DisplayStatus) {
        switch status {
        case .transcriptSaved:
            lastTerminalTranscriptionOutcome = .transcriptSaved
            let completedJobID = activeQueuedTranscriptionJobID
            if let stoppedAudioRecovery = activeStoppedAudioRecovery {
                activeStoppedAudioRecovery = nil
                Task.detached(priority: .utility) {
                    DictationStoppedAudioRecoveryStore.cleanup(
                        stoppedAudioRecovery,
                        transcriptPersisted: true
                    )
                }
            }
            if let completedJobID {
                stoppedAudioRecoveryRetryRegistry.remove(for: completedJobID)
            }
            let transcriptionTrigger = activeTranscriptionTrigger
            let promptTelemetryProperties = activeDetectedPromptTranscriptionTelemetryProperties
            let promptRecordingStartedAt = activeDetectedPromptTranscriptionRecordingStartedAt
            DiagnosticsTrail.record(
                engine: "meeting",
                event: "meeting_transcript_saved",
                message: "Meeting transcript saved",
                context: baseDiagnosticsContext(
                    extra: [
                        "queue_depth": "\(transcriptionQueue.queuedTranscriptionJobs.count)",
                        "trigger": transcriptionTrigger.rawValue
                    ]
                )
            )
            trackSavedTranscriptAnalyticsInBackground(
                baseProperties: [
                    "queue_depth_bucket": AnalyticsReporter.queueDepthBucket(transcriptionQueue.queuedTranscriptionJobs.count),
                    "trigger": transcriptionTrigger.rawValue,
                ],
                promptTelemetryProperties: promptTelemetryProperties,
                promptRecordingStartedAt: promptRecordingStartedAt
            )
            clearDetectedPromptTelemetry()
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "transcript_saved")
            AppSoundPlayer.shared.play(.meetingTranscriptComplete)
            activeQueuedTranscriptionJobID = nil
            activeTranscriptionCaptureDiagnostics = nil
        case .failed(let message):
            lastTerminalTranscriptionOutcome = .failed(message)
            // A failed import must retain its original stopped-audio checkpoint.
            if let failedJobID = activeQueuedTranscriptionJobID,
               let stoppedAudioRecovery = activeStoppedAudioRecovery {
                stoppedAudioRecoveryRetryRegistry.retain(
                    stoppedAudioRecovery,
                    for: failedJobID
                )
            }
            activeStoppedAudioRecovery = nil
            let transcriptionTrigger = activeTranscriptionTrigger
            let diagnosticMessage = taskManager.lastFailureDiagnosticMessage ?? message
            // Only trust the typed kind when it was captured alongside the diagnostic
            // message actually being classified below — not when this fell back to
            // the raw overlay `message`, which never had a typed kind computed for it.
            let errorKind = taskManager.lastFailureDiagnosticMessage != nil ? taskManager.lastFailureErrorKind : nil
            let failureKind = MeetingFailureKind.classify(errorKind: errorKind, message: diagnosticMessage)
            if failureKind.shouldReportAsSkippedTranscript {
                finishLiveCodexSessionForCurrentTranscriptionFailureIfNeeded(
                    failedJobID: activeQueuedTranscriptionJobID
                )
                activeQueuedTranscriptionJobID = nil
                let failureTelemetryContext = meetingFailureTelemetryContext(
                    failureKind: failureKind,
                    transcriptionTrigger: transcriptionTrigger
                )
                DiagnosticsTrail.record(
                    engine: "meeting",
                    event: "meeting_transcript_skipped",
                    message: "Meeting transcription skipped because the recording had no transcriptable speech",
                    context: baseDiagnosticsContext(
                        extra: [
                            "failure_kind": failureKind.rawValue,
                            "queue_depth": "\(transcriptionQueue.queuedTranscriptionJobs.count)",
                            "trigger": transcriptionTrigger.rawValue
                        ]
                    )
                )
                AnalyticsReporter.track(
                    "meeting_transcript_skipped",
                    properties: failureTelemetryContext
                )
                trackDetectedPromptOutcome(
                    .transcriptSkipped,
                    elapsedSeconds: detectedPromptRecordingElapsedSeconds(),
                    promptProperties: activeDetectedPromptTranscriptionTelemetryProperties
                )
                clearDetectedPromptTelemetry()
                ProductFrictionTelemetry.track(
                    surface: .meeting,
                    stage: "meeting_transcription",
                    result: .giveUp,
                    failureKind: failureKind.rawValue,
                    modelState: state.diagnosticName
                )
                lastTerminalTranscriptionOutcome = .failed(diagnosticMessage)
                transition(to: .error(diagnosticMessage), reason: "transcript_skipped")
                activeTranscriptionCaptureDiagnostics = nil
                Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: failureKind.rawValue)
                transcriptionQueue.handleBackgroundTranscriptionWorkChanged()
                return
            }

            if failureKind == .speakerFinalizationFailed || failureKind == .speakerNameFinalizationFailed {
                finishLiveCodexSessionForCurrentTranscriptionFailureIfNeeded(
                    failedJobID: activeQueuedTranscriptionJobID,
                    allowLastSavedTranscriptOwner: true
                )
                activeQueuedTranscriptionJobID = nil
                let queueDepthBucket = AnalyticsReporter.queueDepthBucket(transcriptionQueue.queuedTranscriptionJobs.count)
                DiagnosticsTrail.record(
                    level: .error,
                    engine: "meeting",
                    event: "speaker_finalization_failed",
                    message: "Meeting speaker naming finalization failed",
                    context: baseDiagnosticsContext(
                        extra: [
                            "failure_kind": failureKind.rawValue,
                            "session_stage": CaptureFailureStage.save.rawValue,
                            "queue_depth": "\(transcriptionQueue.queuedTranscriptionJobs.count)",
                            "queue_depth_bucket": queueDepthBucket,
                            "trigger": transcriptionTrigger.rawValue
                        ]
                    )
                )
                AnalyticsReporter.track(
                    "meeting_speaker_finalization_failed",
                    properties: [
                        "session_stage": CaptureFailureStage.save.rawValue,
                        "failure_kind": failureKind.rawValue,
                        "queue_depth_bucket": queueDepthBucket,
                        "trigger": transcriptionTrigger.rawValue,
                    ]
                )
                trackDetectedPromptOutcome(
                    .speakerFinalizationFailed,
                    elapsedSeconds: detectedPromptRecordingElapsedSeconds(),
                    promptProperties: activeDetectedPromptTranscriptionTelemetryProperties
                )
                clearDetectedPromptTelemetry()
                ProductFrictionTelemetry.track(
                    surface: .meeting,
                    stage: "speaker_finalization",
                    result: .failed,
                    failureKind: failureKind.rawValue,
                    modelState: state.diagnosticName
                )
                activeTranscriptionCaptureDiagnostics = nil
                Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "speaker_finalization_failed")
                transcriptionQueue.handleBackgroundTranscriptionWorkChanged()
                return
            }

            finishLiveCodexSessionForCurrentTranscriptionFailureIfNeeded(
                failedJobID: activeQueuedTranscriptionJobID
            )
            activeQueuedTranscriptionJobID = nil
            let failureTelemetryContext = meetingFailureTelemetryContext(
                failureKind: failureKind,
                transcriptionTrigger: transcriptionTrigger
            )
            let failureDiagnosticsContext = failureTelemetryContext.merging(
                [
                    "error": message,
                    "diagnostic_error": diagnosticMessage,
                    "queue_depth": "\(transcriptionQueue.queuedTranscriptionJobs.count)",
                ],
                uniquingKeysWith: { _, new in new }
            )
            DiagnosticsTrail.record(
                level: .error,
                engine: "meeting",
                event: "meeting_transcript_failed",
                message: "Meeting transcription failed",
                context: baseDiagnosticsContext(extra: failureDiagnosticsContext)
            )
            AnalyticsReporter.track(
                "meeting_transcript_failed",
                properties: failureTelemetryContext
            )
            trackDetectedPromptOutcome(
                .transcriptFailed,
                elapsedSeconds: detectedPromptRecordingElapsedSeconds(),
                promptProperties: activeDetectedPromptTranscriptionTelemetryProperties
            )
            clearDetectedPromptTelemetry()
            ProductFrictionTelemetry.track(
                surface: .meeting,
                stage: "meeting_transcription",
                result: .failed,
                failureKind: failureKind.rawValue,
                modelState: state.diagnosticName
            )
            activeTranscriptionCaptureDiagnostics = nil
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "transcript_failed")
            transcriptionQueue.handleBackgroundTranscriptionWorkChanged()
        case .gettingReady:
            if previousStatus.diagnosticName != status.diagnosticName {
                DiagnosticsTrail.record(
                    engine: "meeting",
                    event: "meeting_pipeline_phase",
                    message: "Meeting pipeline getting ready",
                    context: baseDiagnosticsContext(extra: ["phase": "getting_ready"])
                )
            }
        case .transcribing(let progress):
            let previousBucket = Int(previousStatus.progress * 4)
            let currentBucket = Int(progress * 4)
            if previousStatus.diagnosticName != status.diagnosticName || previousBucket != currentBucket {
                DiagnosticsTrail.record(
                    engine: "meeting",
                    event: "meeting_pipeline_phase",
                    message: "Meeting transcription in progress",
                    context: baseDiagnosticsContext(
                        extra: [
                            "phase": "transcribing",
                            "progress_pct": "\(Int(progress * 100))"
                        ]
                    )
                )
            }
        case .finishing:
            if previousStatus.diagnosticName != status.diagnosticName {
                DiagnosticsTrail.record(
                    engine: "meeting",
                    event: "meeting_pipeline_phase",
                    message: "Meeting transcription finishing",
                    context: baseDiagnosticsContext(extra: ["phase": "finishing"])
                )
            }
        default:
            break
        }
    }

    private func logWarmupStatusChange(from oldValue: ModelWarmupStatus, to newValue: ModelWarmupStatus) {
        guard warmupDiagnosticsSignature(for: oldValue) != warmupDiagnosticsSignature(for: newValue) else { return }

        DiagnosticsTrail.record(
            level: newValue.title.contains("Couldn’t") ? .warning : .info,
            engine: "meeting",
            event: "warmup_status_changed",
            message: newValue.subtitle,
            context: [
                "title": newValue.title,
                "subtitle": newValue.subtitle,
                "progress_pct": "\(Int(newValue.progress * 100))",
                "dictation_status": newValue.dictationStatus,
                "meetings_status": newValue.meetingsStatus
            ]
        )
    }

    private func warmupDiagnosticsSignature(for status: ModelWarmupStatus) -> String {
        [
            status.title,
            status.subtitle,
            status.dictationStatus,
            status.meetingsStatus,
            "\(Int(status.progress * 10))"
        ].joined(separator: "|")
    }

    private func meetingStartFailureKind(from message: String) -> String {
        MeetingStartFailureClassifier.kind(from: message)
    }

    private func meetingCaptureAnalyticsProperties(snapshot: AudioPipelineDiagnosticsSnapshot) -> [String: String] {
        var properties = snapshot.privacySafeContext
        properties["gap_count_bucket"] = AnalyticsReporter.countBucket(snapshot.gapCount)
        properties["route_change_count_bucket"] = AnalyticsReporter.countBucket(snapshot.routeChangeCount)
        properties["recovery_attempt_bucket"] = AnalyticsReporter.countBucket(snapshot.recoveryAttemptCount)
        return properties
    }

    private func meetingFailureTelemetryContext(
        failureKind: MeetingFailureKind,
        transcriptionTrigger: StartTrigger
    ) -> [String: String] {
        (activeTranscriptionCaptureDiagnostics ?? [:]).merging(
            [
                "failure_kind": failureKind.rawValue,
                "queue_depth_bucket": AnalyticsReporter.queueDepthBucket(transcriptionQueue.queuedTranscriptionJobs.count),
                "trigger": transcriptionTrigger.rawValue,
            ],
            uniquingKeysWith: { _, new in new }
        )
    }

    private func trackDetectedPromptOutcome(
        _ outcomeKind: MeetingPromptTelemetry.OutcomeKind,
        elapsedSeconds: TimeInterval? = nil,
        promptProperties: [String: String]?
    ) {
        // No implicit fallback here: a nil `promptProperties` means this call
        // site has no detected-prompt properties to attribute (e.g. a
        // manual/hotkey-triggered recording), so tracking is skipped rather
        // than mislabeling the outcome with an unrelated detected-prompt
        // meeting that happens to be transcribing in the background. Callers
        // that legitimately want the currently-transcribing job's properties
        // must pass `activeDetectedPromptTranscriptionTelemetryProperties`
        // explicitly.
        guard let properties = promptProperties else { return }
        AnalyticsReporter.track(
            "meeting_prompt_outcome_recorded",
            properties: MeetingPromptTelemetry.outcomeProperties(
                promptProperties: properties,
                outcomeKind: outcomeKind,
                elapsedSeconds: elapsedSeconds
            )
        )
    }

    private func detectedPromptRecordingElapsedSeconds() -> TimeInterval? {
        guard let activeDetectedPromptTranscriptionRecordingStartedAt else {
            return nil
        }
        return Date().timeIntervalSince(activeDetectedPromptTranscriptionRecordingStartedAt)
    }

    private func clearDetectedPromptTelemetry() {
        activeDetectedPromptTranscriptionTelemetryProperties = nil
        activeDetectedPromptTranscriptionRecordingStartedAt = nil
    }

    private func clearDetectedPromptRecordingTelemetry() {
        activeDetectedPromptRecordingTelemetryProperties = nil
        activeDetectedPromptRecordingStartedAt = nil
    }

    private func reportCaptureHealthIfNeeded(
        snapshot: AudioPipelineDiagnosticsSnapshot,
        captureDiagnostics: [String: String],
        healthInfo: RecordingHealthInfo,
        trigger: StartTrigger,
        reason: StopReason,
        durationSeconds: Double,
        files: (micURL: URL?, systemURL: URL?),
        stopTimedOut: Bool
    ) {
        guard let context = MeetingCaptureHealthTelemetry.degradedDiagnosticsContext(
            .init(
                captureDiagnostics: captureDiagnostics,
                health: captureHealthFacts(from: healthInfo),
                trigger: trigger.rawValue,
                reason: reason.rawValue,
                durationSeconds: durationSeconds,
                micFileAvailable: files.micURL != nil,
                systemStreamPresent: files.systemURL != nil,
                stopTimedOut: stopTimedOut,
                systemFailed: snapshot.systemFailed,
                systemStatus: snapshot.systemStatus
            )
        ) else { return }

        DiagnosticsTrail.record(
            level: .error,
            engine: "meeting",
            event: "recording_capture_degraded",
            message: "Meeting capture health degraded",
            context: baseDiagnosticsContext(extra: context)
        )
    }

    private func captureHealthFacts(from healthInfo: RecordingHealthInfo) -> MeetingCaptureHealthTelemetry.HealthFacts {
        .init(
            captureQuality: healthInfo.captureQuality.rawValue,
            audioGaps: healthInfo.audioGaps,
            deviceSwitches: healthInfo.deviceSwitches
        )
    }

    /// The bucketed properties come from transcript frontmatter on disk, so the
    /// read happens off the main actor and waits for any in-flight restyle to
    /// finish renaming the saved artifact before reading it.
    private func trackSavedTranscriptAnalyticsInBackground(
        baseProperties: [String: String],
        promptTelemetryProperties: [String: String]?,
        promptRecordingStartedAt: Date?
    ) {
        let restyle = savedTranscriptRestyleTask
        let fallbackTranscriptURL = taskManager.lastSavedTranscriptURL ?? lastSavedTranscriptURL
        let speakerDatabase = self.speakerDatabase
        Task.detached(priority: .utility) {
            let transcriptURL: URL?
            if let restyle {
                transcriptURL = await restyle.value.url
            } else {
                transcriptURL = fallbackTranscriptURL
            }
            let frontmatterValues = transcriptURL.flatMap {
                (try? TranscriptFrontmatter.readValues(from: $0)) ?? nil
            }
            let transcriptProperties = Self.savedTranscriptAnalyticsProperties(values: frontmatterValues)
            let autoRecognitionEvents = Self.autoRecognitionAnalyticsProperties(
                frontmatterValues: frontmatterValues,
                speakerDatabase: speakerDatabase
            )
            await MainActor.run {
                let properties = transcriptProperties.merging(
                    baseProperties,
                    uniquingKeysWith: { _, new in new }
                )
                ActivationTelemetry.trackFirstArtifactSavedIfNeeded(
                    artifactKind: .meeting,
                    surface: .meetingSave,
                    trigger: properties["trigger"] ?? StartTrigger.unknown.rawValue,
                    wordCountBucket: properties["word_count_bucket"],
                    durationBucket: properties["duration_bucket"]
                )
                AnalyticsReporter.track(
                    "meeting_transcript_saved",
                    properties: properties
                )
                if let promptTelemetryProperties {
                    AnalyticsReporter.track(
                        "meeting_prompt_outcome_recorded",
                        properties: MeetingPromptTelemetry.outcomeProperties(
                            promptProperties: promptTelemetryProperties,
                            outcomeKind: .transcriptSaved,
                            elapsedSeconds: promptRecordingStartedAt.map { Date().timeIntervalSince($0) }
                        )
                    )
                }
                for eventProperties in autoRecognitionEvents {
                    AnalyticsReporter.track(
                        "meeting_speaker_auto_recognized",
                        properties: eventProperties
                    )
                }
            }
        }
    }

    /// One bucketed event per auto-recognized *person* in the saved meeting,
    /// read back from the local lifeline store keyed by the transcript id in
    /// frontmatter. Outcomes are deduplicated by profile (the pipeline can
    /// record one row per channel, and a retranscription of the same meeting
    /// appends rows for its transcript id again), so one save emits at most
    /// one event per speaker. `graduated` marks a profile whose only
    /// auto-recognitions belong to this meeting — the "how many meetings
    /// until the app just knows them" milestone. Only enum buckets leave the
    /// device; no names, ids, or raw scores.
    nonisolated private static func autoRecognitionAnalyticsProperties(
        frontmatterValues: [String: String]?,
        speakerDatabase: SpeakerDatabase
    ) -> [[String: String]] {
        guard let frontmatterValues,
              let transcriptId = TranscriptFrontmatter.captureID(in: frontmatterValues) else {
            return []
        }

        let autoOutcomes = speakerDatabase.matchOutcomes(transcriptId: transcriptId)
            .filter { $0.kind == .autoAccepted }
        // Rows arrive most-recent-first; keep the newest row per profile so a
        // retranscription reports the latest run, not every historical run.
        var newestByProfile: [UUID: SpeakerMatchOutcome] = [:]
        var rowsPerProfile: [UUID: Int] = [:]
        for outcome in autoOutcomes {
            rowsPerProfile[outcome.profileId, default: 0] += 1
            if newestByProfile[outcome.profileId] == nil {
                newestByProfile[outcome.profileId] = outcome
            }
        }

        return newestByProfile.values.map { outcome in
            // Graduated when every auto-recognition this profile has ever had
            // belongs to this meeting — robust to multi-channel rows within
            // one save, unlike a bare count == 1 check.
            let totalCount = speakerDatabase.autoAcceptedOutcomeCount(profileId: outcome.profileId)
            let graduated = totalCount <= (rowsPerProfile[outcome.profileId] ?? 0)
            return [
                "similarity_bucket": SpeakerRecognitionTelemetry.similarityBucket(outcome.similarity),
                "margin_bucket": SpeakerRecognitionTelemetry.marginBucket(
                    similarity: outcome.similarity,
                    secondSimilarity: outcome.secondSimilarity
                ),
                "call_count_bucket": AnalyticsReporter.countBucket(outcome.callCountAtMatch ?? 0),
                "channel": outcome.channel ?? "unknown",
                "graduated": graduated ? "true" : "false",
                "surface": "meeting_save",
            ]
        }
    }

    nonisolated private static func savedTranscriptAnalyticsProperties(values: [String: String]?) -> [String: String] {
        guard let values else {
            return [:]
        }

        var properties: [String: String] = [:]

        if let duration = values["duration"],
           let durationSeconds = TranscriptFrontmatter.durationSeconds(from: duration) {
            properties["duration_bucket"] = AnalyticsReporter.durationBucket(seconds: Double(durationSeconds))
        }

        if let wordCount = Int(values["total_word_count"] ?? "") {
            properties["word_count_bucket"] = AnalyticsReporter.wordCountBucket(wordCount)
        }

        let participantCount = (Int(values["mic_speakers"] ?? "") ?? 0)
            + (Int(values["system_speakers"] ?? "") ?? 0)
        if participantCount > 0 {
            properties["participant_count_bucket"] = AnalyticsReporter.countBucket(participantCount)
        }

        return properties
    }

    /// Snapshot capture health before the stop call, since the system-audio
    /// backend can clean up buffer counters before file-close completion resumes.
    private func makeRecordingStopSnapshot() -> RecordingStopSnapshot {
        let systemAudioStatus = capture.systemAudioStatus
        let durationSeconds = recordingDuration
        let baseHealthInfo = capture.healthInfo(overrideSystemAudioStatus: systemAudioStatus)
        let healthInfo = systemAudioDegradationWarning == nil
            ? baseHealthInfo
            : baseHealthInfo.markingSystemAudioDegraded()
        return RecordingStopSnapshot(
            trigger: activeRecordingTrigger,
            systemAudioStatus: systemAudioStatus,
            durationSeconds: durationSeconds,
            healthInfo: healthInfo,
            pipelineSnapshot: capture.pipelineDiagnosticsSnapshot(
                overrideSystemAudioStatus: systemAudioStatus
            ),
            suggestedTitle: activeRecordingSuggestedTitle,
            recordingStartedAt: activeRecordingStartedAt
        )
    }

    // TranscriptionQueueCoordinator lives in a sibling file and needs
    // module-internal access.
    func baseDiagnosticsContext(extra: [String: String] = [:]) -> [String: String] {
        var context: [String: String] = [
            "session_state": state.diagnosticName,
            "display_status": displayStatus.diagnosticName,
            "dictation_model": sttRouter.selectedModel.rawValue,
            "dictation_model_state": sttRouter.modelDownloadState.diagnosticName,
            "meeting_model_state": diarization.modelState.diagnosticName,
            "system_audio_status": capture.systemAudioStatus.diagnosticName,
            "queue_depth": "\(transcriptionQueue.queuedTranscriptionJobs.count)"
        ]

        for (key, value) in extra {
            context[key] = value
        }

        return context
    }

    private func systemAudioStatusMessage(for status: SystemAudioStatus) -> String {
        MeetingSystemAudioStatusCopy.message(for: status)
    }

    private func boolString(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private func makeFailedMeetingStore() -> FailedMeetingStore {
        FailedMeetingStore(
            taskManager: taskManager,
            failedManager: failedManager,
            canRetry: { [weak self] in
                guard let self else { return false }
                return !self.isRecording
                    && !self.hasBackgroundTranscriptionWork
                    && !self.isSpeakerReviewPending
            },
            prepareModelsForRetry: { [weak self] in
                guard let self else { return false }
                await self.prepareModels()
                guard case .ready = self.state else { return false }
                return true
            },
            markRetryStarted: { [weak self] in
                self?.activeTranscriptionTrigger = .unknown
            },
            prepareStoppedAudioRecoveryForRetry: { [weak self] failedMeetingID in
                self?.prepareStoppedAudioRecoveryForRetry(failedMeetingID: failedMeetingID)
            },
            discardStoppedAudioRecoveryForRetry: { [weak self] failedMeetingID in
                self?.discardStoppedAudioRecoveryForRetry(failedMeetingID: failedMeetingID)
            },
            publishRefresh: { [weak self] in
                self?.refreshFailedMeetings()
            },
            diagnosticsContext: { [weak self] extra in
                self?.baseDiagnosticsContext(extra: extra) ?? extra
            }
        )
    }

    // preserveFailedMeetingForRetry, refreshTimedOutFailedMeetingAudio, and
    // scheduleFailedAudioCompression moved to FailedMeetingStore.swift
    // (audit 2026-07-08 wave 2, W2-B). Call sites now go through
    // `failedMeetingStore.`.

    /// Recomputes and assigns the published failed-meeting list. Kept on the
    /// controller (rather than moved wholesale) because `failedMeetings` is
    /// `@Published` here — the store computes the list, the controller owns
    /// the publish.
    private func refreshFailedMeetings(_ updatedFailedTranscriptions: [FailedTranscription]? = nil) {
        failedMeetings = failedMeetingStore.refreshFailedMeetings(updatedFailedTranscriptions)
    }
}

private extension MeetingSessionController.State {
    var diagnosticName: String {
        switch self {
        case .idle: return "idle"
        case .loadingModels: return "loading_models"
        case .ready: return "ready"
        case .startingRecording: return "starting_recording"
        case .recording: return "recording"
        case .stoppingRecording: return "stopping_recording"
        case .transcribing: return "transcribing"
        case .error: return "error"
        }
    }
}

private extension DisplayStatus {
    var diagnosticName: String {
        switch self {
        case .idle: return "idle"
        case .gettingReady: return "getting_ready"
        case .transcribing: return "transcribing"
        case .finishing: return "finishing"
        case .transcriptSaved: return "transcript_saved"
        case .failed: return "failed"
        }
    }
}

private extension MeetingWarmupMeetingState {
    init(_ state: DiarizationModelState) {
        switch state {
        case .notLoaded:
            self = .notLoaded
        case .loading:
            self = .loading
        case .ready:
            self = .ready
        case .failed(let message):
            self = .failed(message)
        }
    }
}

private extension DiarizationModelState {
    var diagnosticName: String {
        switch self {
        case .notLoaded: return "not_loaded"
        case .loading: return "loading"
        case .ready: return "ready"
        case .failed: return "failed"
        }
    }
}

private extension SystemAudioStatus {
    var diagnosticName: String {
        switch self {
        case .unknown: return "unknown"
        case .healthy: return "healthy"
        case .reconnecting: return "reconnecting"
        case .silent: return "silent"
        case .failed: return "failed"
        }
    }
}

@available(macOS 14.0, *)
extension MeetingPromptSessionPromptState {
    init(_ state: MeetingSessionController.State) {
        switch state {
        case .idle:
            self = .idle
        case .loadingModels:
            self = .loadingModels
        case .ready:
            self = .ready
        // Starting/stopping are treated as "recording" here on purpose: a
        // detected-meeting prompt must not fire while capture is engaging or
        // tearing down any more than while it's steady-state recording.
        case .startingRecording, .recording, .stoppingRecording:
            self = .recording
        case .transcribing:
            self = .transcribing
        case .error:
            self = .error
        }
    }
}
