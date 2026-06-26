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

    struct FailedMeetingItem: Identifiable, Equatable {
        let id: UUID
        let timestamp: Date
        let title: String
        let detail: String
        let meta: String
        let failureKind: MeetingFailureKind
        let isRetryable: Bool
        let isRetrying: Bool
        let hasAudioFiles: Bool
        let audioURLs: [URL]
    }

    private struct QueuedTranscriptionJob {
        enum Kind {
            case recorded(
                micURL: URL,
                systemURL: URL?,
                healthInfo: RecordingHealthInfo,
                captureDiagnostics: [String: String],
                meetingTitle: String?,
                recordingDate: Date
            )
            case imported(
                audioURL: URL,
                suggestedTitle: String,
                recordingDate: Date
            )
        }

        let id = UUID()
        let kind: Kind
        let startTrigger: StartTrigger
        let sttModel: TranscriptionModelChoice

        var captureDiagnostics: [String: String]? {
            switch kind {
            case .recorded(_, _, _, let captureDiagnostics, _, _):
                return captureDiagnostics
            case .imported:
                return nil
            }
        }

        var artifactRetained: Bool {
            switch kind {
            case .recorded:
                return true
            case .imported:
                return false
            }
        }
    }

    private enum TerminalTranscriptionOutcome: Equatable {
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

    private struct BackgroundTranscriptionWorkSnapshot {
        let activeCount: Int
        let speakerNamingRequest: SpeakerNamingRequest?
    }

    // MARK: - Published state (for meeting UI bindings)

    /// High-level session state for the meeting UI.
    enum State: Equatable {
        case idle                // Models not loaded, no recording
        case loadingModels       // ensureModelsReady() in flight
        case ready               // Models loaded, ready to record
        case recording           // Capture in progress
        case transcribing        // Background transcription or speaker naming running
        case error(String)       // Fatal error — see message
    }

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

    // Pass-throughs for UI convenience (updated via Combine subscriptions below).
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var audioLevel: Float = 0          // mic-only level
    @Published private(set) var systemLevel: Float = 0         // system audio level
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var displayStatus: DisplayStatus = .idle
    @Published private(set) var lastSavedTranscriptURL: URL? = nil
    @Published private(set) var lastSavedTitle: String? = nil
    @Published private(set) var savedMeetingReplacementCommitCount: Int = 0
    @Published private(set) var audioInactivityWarning: MeetingAudioInactivityWarning?
    @Published private(set) var isMicBoostPromptVisible = false

    @Published private(set) var failedMeetings: [FailedMeetingItem] = []
    @Published private(set) var warmupStatus: ModelWarmupStatus = .ready {
        didSet {
            guard warmupStatus != oldValue else { return }
            logWarmupStatusChange(from: oldValue, to: warmupStatus)
        }
    }

    // MARK: - Core services (owned)

    private let storagePaths: CoreStoragePaths
    private let sttRouter: STTRouter
    let capture: MeetingCaptureBridge
    private let liveCodexSession = LiveMeetingCodexSession()
    private let liveMeetingTranscriber = LiveMeetingTranscriber()
    /// In-memory live transcript behind the meeting overlay's embedded
    /// drawer. Fed by `liveMeetingTranscriber` alongside the sidecar files.
    let liveTranscriptFeed = LiveMeetingTranscriptFeed()
    let services: AppServices
    let taskManager: TranscriptionTaskManager
    private let failedManager: FailedTranscriptionManager
    private let diarization: DiarizationService
    private let sttAdapter: MeetingSTTAdapter
    private let speakerDatabase: SpeakerDatabase
    private let statsDatabase: StatsDatabase
    private let downloader: MeetingModelDownloader
    var calendarSuggestedTitleProvider: (() -> String?)?

    private var cancellables: Set<AnyCancellable> = []
    private var modelPreparationTask: Task<Result<Void, Error>, Never>?
    private var savedTranscriptRestyleTask: Task<StyledMeetingTranscript, Never>?
    private var retryingFailedMeetingIDs: Set<UUID> = []
    private var queuedTranscriptionJobs: [QueuedTranscriptionJob] = []
    private var preparingQueuedTranscriptionJob: QueuedTranscriptionJob?
    private var queuedTranscriptionStartTask: Task<Void, Never>?
    private var importPreparationTask: Task<PreparedImportedMeetingAudio, Error>?
    private var importPreparationToken: UUID?
    private var queuedRuntimeDiagnosticsJobIDs: Set<UUID> = []
    private var lastTerminalTranscriptionOutcome: TerminalTranscriptionOutcome?
    private var activeTranscriptionCaptureDiagnostics: [String: String]?
    private var activeRecordingTrigger: StartTrigger = .unknown
    private var activeRecordingIdentity: UUID?
    private var micBoostPromptRecordingIdentity: UUID?
    private var micBoostPromptOutcome: MeetingMicBoostPromptOutcome = .notShown
    private var activeRecordingSuggestedTitle: String?
    private var activeRecordingStartedAt: Date?
    private var activeTranscriptionTrigger: StartTrigger = .unknown
    private var isFinishingRecording = false
    private var shouldSurfaceMeetingWarmupFailure = false
    private var audioInactivityDetector = MeetingAudioInactivityDetector()
    private var latestMicLevel: Float = 0
    private var latestSystemLevel: Float = 0
    private var liveCodexSessionIsActive = false
    private var liveCodexSessionAwaitingFinalTranscript = false
    private var liveCodexSessionCanAttachFinalTranscript = false
    private var liveCodexSessionOwnedByActiveRecording = false
    private var liveCodexPreviewHandlersNeedClearingAfterActiveRecording = false
    private var liveCodexFinalTranscriptNeedsQueuedJobID = false
    private var liveCodexAwaitedTranscriptionJobID: UUID?
    private var activeQueuedTranscriptionJobID: UUID?
    private var failedAudioCompressionTask: Task<Void, Never>?
    private var failedAudioCompressionNeedsReschedule = false

    var shouldConfirmQuitForActiveCapture: Bool {
        isCaptureSessionActive || isFinishingRecording
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

        // Build app-owned CoreStoragePaths so captures and internal state stay split.
        self.storagePaths = CoreStoragePaths(
            transcripts: MeetingStoragePaths.transcriptsFolder,
            speakerDB: MeetingStoragePaths.speakersDatabase,
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
        self.diarization = DiarizationService()

        // Speaker store: app-owned SQLite file under state/.
        self.speakerDatabase = SpeakerDatabase(path: storagePaths.speakerDB.path)
        self.statsDatabase = StatsDatabase(path: storagePaths.statsDB.path)

        // Failed-queue manager: takes CoreStoragePaths so its JSON file lives
        // under app-owned state, not the capture library. The queue is drained
        // by `refreshFailedMeetings()` (subscribed to
        // `failedManager.$failedTranscriptions`) and surfaced in Settings →
        // Meetings → "Needs Attention", with retry / dismiss / delete actions
        // wired through `retryFailedMeeting`, `dismissFailedMeeting`, and
        // `deleteFailedMeeting`.
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

        wireSubscriptions()

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
            state = .loadingModels
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
                try await downloader.ensureModelsReady()
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
    func startRecording(trigger: StartTrigger = .unknown, suggestedTitle: String? = nil) async -> Bool {
        Self.runtimeDiagnosticsRecorder?.recordSession(kind: "meeting", stage: "start_requested")
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_start_requested",
            message: "Meeting start requested",
            context: baseDiagnosticsContext(extra: ["trigger": trigger.rawValue])
        )

        switch state {
        case .recording:
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
            state = .error(
                startDecision.errorMessage
                    ?? "Turn on the required permissions in System Settings before recording a meeting."
            )
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "start_blocked_permission")
            return false
        }

        guard await ensureModelsReadyForRecording(trigger: trigger) else {
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "models_unavailable")
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
        activeRecordingSuggestedTitle = resolvedMeetingTitle
        startLiveCodexSessionIfNeeded(title: resolvedMeetingTitle)

        let started = await capture.startRecording()
        guard started else {
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
            state = .error(failureMessage)
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "start_failed")
            return false
        }

        activeRecordingStartedAt = Date()
        state = .recording
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
        case .recording:
            return true
        }
    }

    /// Stop capture and queue the finished meeting for background transcription.
    /// Returns once the finished audio has either started transcribing or been
    /// placed behind the current background task.
    func stopRecording(reason: StopReason = .unknown) async {
        guard case .recording = state else { return }
        guard !isFinishingRecording else { return }
        isFinishingRecording = true
        defer { isFinishingRecording = false }
        Self.runtimeDiagnosticsRecorder?.recordSession(kind: "meeting", stage: "stop_requested")
        _ = audioInactivityDetector.stopRecording()
        audioInactivityWarning = nil
        isMicBoostPromptVisible = false
        clearActiveRecordingIdentity()

        let recordingSnapshot = makeRecordingStopSnapshot()

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
        let stopResult = await capture.stopAndAwaitFiles { [weak self] lateResult in
            self?.refreshTimedOutFailedMeetingAudio(
                id: stopTimeoutFailedTaskId,
                result: lateResult
            )
        }
        let files = (micURL: stopResult.micURL, systemURL: stopResult.systemURL)
        let shouldAwaitFinalLiveCodexTranscript = files.micURL != nil && !stopResult.didTimeOut
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
        activeRecordingTrigger = .unknown
        activeRecordingSuggestedTitle = nil
        activeRecordingStartedAt = nil
        state = .transcribing
        Self.runtimeDiagnosticsRecorder?.recordSession(kind: "meeting", stage: "transcribing")
        let stopDiagnosticsContext = stopCaptureDiagnostics.merging(
            [
                "trigger": recordingSnapshot.trigger.rawValue,
                "reason": reason.rawValue,
                "duration_ms": "\(recordingSnapshot.durationMilliseconds)",
                "mic_file_present": boolString(files.micURL != nil),
                "system_file_present": boolString(files.systemURL != nil),
                "stop_timed_out": boolString(stopResult.didTimeOut),
                "capture_quality": recordingSnapshot.healthInfo.captureQuality.rawValue,
                "audio_gaps": "\(recordingSnapshot.healthInfo.audioGaps)",
                "device_switches": "\(recordingSnapshot.healthInfo.deviceSwitches)"
            ],
            uniquingKeysWith: { _, new in new }
        )

        DiagnosticsTrail.record(
            level: recordingSnapshot.systemAudioStatus.isWarning ? .warning : .info,
            engine: "meeting",
            event: "meeting_recording_stopped",
            message: "Meeting recording stopped",
            context: baseDiagnosticsContext(extra: stopDiagnosticsContext)
        )
        AnalyticsReporter.track(
            "meeting_recording_stopped",
            properties: stopCaptureDiagnostics.merging(
                [
                    "capture_quality": recordingSnapshot.healthInfo.captureQuality.rawValue,
                    "duration_bucket": AnalyticsReporter.durationBucket(seconds: recordingSnapshot.durationSeconds),
                    "gap_count_bucket": AnalyticsReporter.countBucket(recordingSnapshot.healthInfo.audioGaps),
                    "reason": reason.rawValue,
                    "route_change_count_bucket": AnalyticsReporter.countBucket(recordingSnapshot.healthInfo.deviceSwitches),
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
                    health: captureHealthFacts(from: recordingSnapshot.healthInfo),
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
            healthInfo: recordingSnapshot.healthInfo,
            trigger: recordingSnapshot.trigger,
            reason: reason,
            durationSeconds: recordingSnapshot.durationSeconds,
            files: files,
            stopTimedOut: stopResult.didTimeOut
        )

        guard let micURL = files.micURL else {
            let preserved = preserveFailedMeetingForRetry(
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
            state = files.systemURL == nil
                ? .error("No meeting audio was captured.")
                : .error("Microphone audio was missing. Open Transcripted Home to retry the system audio.")
            return
        }

        // Stop timeout means Audio.onRecordingComplete never fired. The WAV
        // header may not be fully patched, so route the audio to the failed
        // queue rather than enqueuing for transcription. The user can retry
        // from Transcripted Home, where the pipeline will either succeed
        // on a now-finalized file or fail cleanly.
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
            let preserved = preserveFailedMeetingForRetry(
                taskId: stopTimeoutFailedTaskId,
                micAudioURL: micURL,
                systemAudioURL: files.systemURL,
                errorMessage: "Recording stop timed out before audio files were finalized.",
                meetingTitle: recordingSnapshot.suggestedTitle,
                recordingDate: recordingSnapshot.recordingStartedAt,
                archiveAudio: false
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
            state = .error("Recording didn't close cleanly. Open Transcripted Home to retry.")
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "stop_timeout")
            return
        }

        // Issue #500: when stop diagnostics classified an unrecovered
        // voice-processed quiet mic, ride the facts into the saved transcript
        // frontmatter so Home can surface the enable-for-next-time hint.
        let healthInfoForSave: RecordingHealthInfo
        if micAttenuatedByCallApp {
            let base = recordingSnapshot.healthInfo
            healthInfoForSave = RecordingHealthInfo(
                captureQuality: base.captureQuality,
                audioGaps: base.audioGaps,
                deviceSwitches: base.deviceSwitches,
                gapDescriptions: base.gapDescriptions,
                micAttenuatedByCallApp: true,
                micBoostPrompt: micBoostPromptOutcome.rawValue
            )
        } else {
            healthInfoForSave = recordingSnapshot.healthInfo
        }

        let outcome = enqueueTranscriptionJob(
            micURL: micURL,
            systemURL: files.systemURL,
            healthInfo: healthInfoForSave,
            captureDiagnostics: stopCaptureDiagnostics,
            meetingTitle: recordingSnapshot.suggestedTitle,
            recordingDate: recordingSnapshot.recordingStartedAt ?? Date(),
            startTrigger: recordingSnapshot.trigger
        )

        let queueDepth = queuedTranscriptionJobs.count
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

    private func handleMicAttenuationCue() {
        guard case .recording = state,
              let activeRecordingIdentity else { return }
        guard MeetingMicBoostPromptPolicy.shouldPresent(
            isRecording: isRecording,
            isFinishingRecording: isFinishingRecording,
            sessionStateIsRecording: state == .recording,
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
            isRecording: isRecording,
            isFinishingRecording: isFinishingRecording,
            sessionStateIsRecording: state == .recording
        )
    }

    private func clearStaleMicBoostPrompt() {
        isMicBoostPromptVisible = false
        micBoostPromptRecordingIdentity = nil
    }

    private func clearActiveRecordingIdentity() {
        activeRecordingIdentity = nil
        micBoostPromptRecordingIdentity = nil
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
        guard !isFinishingRecording else { return }
        isFinishingRecording = true
        defer { isFinishingRecording = false }
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
            state = .error("Stop the current meeting before importing an audio file.")
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
            displayStatus = .gettingReady
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
                displayStatus = .idle
            }
            if case .transcribing = state {} else {
                state = .ready
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
                displayStatus = .idle
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
            state = .error(displayMessage)
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "file_import_failed")
            return false
        }

        let outcome = enqueueImportedAudioJob(
            audioURL: preparedAudio.copiedAudioURL,
            suggestedTitle: preparedAudio.suggestedTitle,
            recordingDate: preparedAudio.recordingDate,
            startTrigger: .fileImport
        )

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
                    "queue_depth": "\(queuedTranscriptionJobs.count)",
                    "trigger": StartTrigger.fileImport.rawValue
                ]
            )
        )
        AnalyticsReporter.track(
            "meeting_file_imported",
            properties: [
                "queue_depth_bucket": AnalyticsReporter.queueDepthBucket(queuedTranscriptionJobs.count),
            ]
        )
        Self.runtimeDiagnosticsRecorder?.recordSession(kind: "meeting", stage: "transcribing")
        return true
    }

    private func importPreparationFailureKind(for error: Error) -> String {
        if let preparationError = error as? MeetingImportedAudioPreparationError {
            return preparationError.diagnosticKind
        }

        return MeetingFailureKind.classify(message: error.localizedDescription).rawValue
    }

    private func importPreparationFailureMessage(for error: Error) -> String {
        if let preparationError = error as? MeetingImportedAudioPreparationError,
           let description = preparationError.errorDescription {
            return description
        }

        return "Transcripted couldn't prepare that audio file. Try choosing it again, or convert it to WAV or M4A first."
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

        let queuedJobs = queuedTranscriptionJobs
        queuedTranscriptionJobs.removeAll()
        let preparingJob = preparingQueuedTranscriptionJob
        queuedTranscriptionStartTask?.cancel()
        queuedTranscriptionStartTask = nil
        preparingQueuedTranscriptionJob = nil
        lastTerminalTranscriptionOutcome = nil
        activeTranscriptionTrigger = .unknown
        activeTranscriptionCaptureDiagnostics = nil

        for job in queuedJobs + [preparingJob].compactMap({ $0 }) {
            switch job.kind {
            case .recorded(let micURL, let systemURL, _, _, let meetingTitle, let recordingDate):
                preserveFailedMeetingForRetry(
                    micAudioURL: micURL,
                    systemAudioURL: systemURL,
                    errorMessage: "Transcription cancelled",
                    meetingTitle: meetingTitle,
                    recordingDate: recordingDate
                )
            case .imported(let audioURL, _, _):
                try? FileManager.default.removeItem(at: audioURL)
            }
        }

        taskManager.cancelAll()
        if liveCodexSessionAwaitingFinalTranscript {
            finishLiveCodexSession(status: .failed, shouldAwaitFinalTranscript: false)
            activeQueuedTranscriptionJobID = nil
        }
        state = .ready
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

        if isFinishingRecording {
            await waitForRecordingFinishBeforeTermination()
        }

        if case .recording = state, !isFinishingRecording {
            isFinishingRecording = true
            defer { isFinishingRecording = false }

            _ = audioInactivityDetector.stopRecording()
            audioInactivityWarning = nil
            isMicBoostPromptVisible = false
            clearActiveRecordingIdentity()

            let shutdownFailedTaskId = UUID()
            let files = await capture.stopAndAwaitFiles { [weak self] lateResult in
                self?.refreshTimedOutFailedMeetingAudio(
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

            if files.micURL != nil || files.systemURL != nil {
                didPreserveRecording = preserveFailedMeetingForRetry(
                    taskId: shutdownFailedTaskId,
                    micAudioURL: files.micURL,
                    systemAudioURL: files.systemURL,
                    errorMessage: "Meeting saved before quit. Audio is safe; finish the transcript from Home after reopening.",
                    meetingTitle: meetingTitle,
                    recordingDate: recordingDate,
                    archiveAudio: !files.didTimeOut
                )
            }
        } else {
            recordingTrigger = .unknown
        }

        let queuedPreserved = preserveQueuedTranscriptionJobsForShutdown(
            errorMessage: "Meeting saved before quit. Audio is safe; finish the queued transcript from Home after reopening."
        )
        let activePreserved = taskManager.preserveActiveTranscriptionsForShutdown(
            errorMessage: "Meeting saved before quit. Audio is safe; finish the transcript from Home after reopening."
        )
        let shouldFailPendingLiveHandoff = queuedPreserved > 0
            || activePreserved > 0
            || liveCodexSessionAwaitingFinalTranscript
        if shouldFailPendingLiveHandoff {
            finishLiveCodexSession(status: .failed, shouldAwaitFinalTranscript: false)
            activeQueuedTranscriptionJobID = nil
        }

        guard didPreserveRecording || queuedPreserved > 0 || activePreserved > 0 else { return }

        refreshFailedMeetings()
        state = .ready
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
        while isFinishingRecording && Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    private func preserveQueuedTranscriptionJobsForShutdown(errorMessage: String) -> Int {
        let preparingJob = preparingQueuedTranscriptionJob
        let jobs = queuedTranscriptionJobs + [preparingJob].compactMap { $0 }
        guard !jobs.isEmpty else { return 0 }

        queuedTranscriptionStartTask?.cancel()
        queuedTranscriptionStartTask = nil
        preparingQueuedTranscriptionJob = nil
        queuedTranscriptionJobs.removeAll()

        var preservedCount = 0
        for job in jobs {
            switch job.kind {
            case .recorded(let micURL, let systemURL, _, _, let meetingTitle, let recordingDate):
                if preserveFailedMeetingForRetry(
                    micAudioURL: micURL,
                    systemAudioURL: systemURL,
                    errorMessage: errorMessage,
                    meetingTitle: meetingTitle,
                    recordingDate: recordingDate
                ) {
                    preservedCount += 1
                }
            case .imported(let audioURL, _, _):
                try? FileManager.default.removeItem(at: audioURL)
            }
        }
        return preservedCount
    }

    @discardableResult
    func retryFailedMeeting(id: UUID) -> Bool {
        guard !isRecording, !hasBackgroundTranscriptionWork, !isSpeakerReviewPending else { return false }
        guard !retryingFailedMeetingIDs.contains(id) else { return false }
        guard failedManager.failedTranscriptions.contains(where: { $0.id == id }) else {
            refreshFailedMeetings()
            return false
        }

        failedAudioCompressionTask?.cancel()
        retryingFailedMeetingIDs.insert(id)
        activeTranscriptionTrigger = .unknown
        refreshFailedMeetings()
        let retryStartedAt = CFAbsoluteTimeGetCurrent()
        WorkflowRecoveryTelemetry.attempted(
            workflowKind: "meeting_transcription",
            failureKind: "failed_meeting",
            retrySource: "failed_meeting_retry",
            surface: "home",
            artifactRetained: true
        )

        Task { [weak self] in
            guard let self else { return }
            await self.prepareModels()
            guard case .ready = self.state else {
                DiagnosticsTrail.record(
                    level: .warning,
                    engine: "meeting",
                    event: "meeting_failed_retry_blocked_models",
                    message: "Failed meeting retry blocked because models were not ready",
                    context: self.baseDiagnosticsContext(extra: ["failed_id": id.uuidString])
                )
                self.retryingFailedMeetingIDs.remove(id)
                self.refreshFailedMeetings()
                WorkflowRecoveryTelemetry.finished(
                    workflowKind: "meeting_transcription",
                    failureKind: "failed_meeting",
                    retrySource: "failed_meeting_retry",
                    result: "failed",
                    elapsedSeconds: CFAbsoluteTimeGetCurrent() - retryStartedAt,
                    surface: "home",
                    artifactRetained: true
                )
                return
            }

            let retryPublished = await self.taskManager.retryFailedTranscription(
                failedId: id,
                outputFolder: MeetingStoragePaths.transcriptsFolder
            )
            self.retryingFailedMeetingIDs.remove(id)
            self.refreshFailedMeetings()
            WorkflowRecoveryTelemetry.finished(
                workflowKind: "meeting_transcription",
                failureKind: "failed_meeting",
                retrySource: "failed_meeting_retry",
                result: retryPublished ? "success" : "failed",
                elapsedSeconds: CFAbsoluteTimeGetCurrent() - retryStartedAt,
                surface: "home",
                artifactRetained: true
            )
        }
        return true
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
            state = .error("Wait for the current dictation to finish before re-transcribing saved audio.")
            return false
        }
        guard !isCaptureSessionActive else {
            state = .error("Stop the current meeting before re-transcribing saved audio.")
            return false
        }
        guard !hasBackgroundTranscriptionWork else {
            state = .error("Wait for the current meeting to finish saving or transcribing before re-transcribing saved audio.")
            return false
        }
        guard !isSpeakerReviewPending else {
            state = .error("Finish the speaker review window before re-transcribing saved audio.")
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
        state = .transcribing
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

    @discardableResult
    func dismissFailedMeeting(id: UUID) -> Bool {
        retryingFailedMeetingIDs.remove(id)
        let didDismiss = failedManager.removeFailedTranscription(id: id)
        refreshFailedMeetings()
        return didDismiss || !failedManager.failedTranscriptions.contains(where: { $0.id == id })
    }

    @discardableResult
    func deleteFailedMeeting(id: UUID) -> Bool {
        retryingFailedMeetingIDs.remove(id)
        let didDelete = failedManager.deleteFailedTranscription(id: id)
        refreshFailedMeetings()
        return didDelete || !failedManager.failedTranscriptions.contains(where: { $0.id == id })
    }

    // MARK: - Subscriptions

    private func wireSubscriptions() {
        capture.$isRecording
            .sink { [weak self] isRecording in
                guard let self else { return }
                self.isRecording = isRecording
                let event: MeetingAudioInactivityDetector.Event
                if isRecording {
                    event = self.audioInactivityDetector.startRecording(at: self.recordingDuration)
                } else {
                    event = self.audioInactivityDetector.stopRecording()
                    // Capture can stop underneath the controller (device
                    // watchdog give-up, disk-full guard) without any app-side
                    // stop path running. The boost prompt must never outlive
                    // the recording it offered to fix.
                    self.isMicBoostPromptVisible = false
                }
                self.applyAudioInactivityEvent(event)
            }
            .store(in: &cancellables)

        capture.$audioLevel
            .sink { [weak self] level in
                guard let self else { return }
                self.audioLevel = level
                self.latestMicLevel = level
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
                self.recordingDuration = duration
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

        capture.$systemAudioStatus
            .removeDuplicates()
            .sink { [weak self] status in
                guard let self else { return }
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
                self.handleBackgroundTranscriptionWorkChanged(
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
                guard let self else { return }
                let previousStatus = self.displayStatus
                self.displayStatus = status
                self.handleDisplayStatusChange(from: previousStatus, to: status)
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
            || isFinishingRecording
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

    private func finishLiveCodexSession(
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
        let dictationState: MeetingWarmupDictationState = sttRouter.isModelLoaded
            ? .ready
            : MeetingWarmupDictationState(sttRouter.modelDownloadState)

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
            case .recording, .transcribing:
                break
            default:
                state = .ready
            }
        case .failure(let error):
            shouldSurfaceMeetingWarmupFailure = showLoadingUI
            if showLoadingUI {
                state = .error(error.localizedDescription)
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
        case .recording, .transcribing:
            refreshWarmupStatus()
            return
        case .idle, .loadingModels, .ready, .error:
            break
        }

        modelPreparationTask = nil
        sttAdapter.cleanup()
        if case .ready = state {
            state = .idle
        }
        refreshWarmupStatus()
    }

    private enum QueueInsertionOutcome: Equatable {
        case startedImmediately
        case queued(position: Int)
    }

    private var hasBackgroundTranscriptionWork: Bool {
        taskManager.activeCount > 0
            || isPreparingQueuedTranscriptionStart
            || !queuedTranscriptionJobs.isEmpty
    }

    var hasRuntimeDiagnosticsWork: Bool {
        isCaptureSessionActive || isFinishingRecording || hasBackgroundTranscriptionWork
    }

    var queuedTranscriptionCount: Int {
        queuedTranscriptionJobs.count
    }

    var isSpeakerReviewPending: Bool {
        taskManager.speakerNamingRequest != nil
    }

    private var hasVisibleBackgroundTranscriptionWork: Bool {
        hasVisibleBackgroundTranscriptionWork(snapshot: currentBackgroundTranscriptionWorkSnapshot)
    }

    private var isSpeechModelPreparedForSelection: Bool {
        sttAdapter.transcriptionEngineDescriptor.identifier == sttRouter.selectedModel.transcriptionEngineIdentifier
            && sttAdapter.isReady
    }

    private var canStartQueuedTranscriptionImmediately: Bool {
        canStartQueuedTranscriptionImmediately(snapshot: currentBackgroundTranscriptionWorkSnapshot)
    }

    private var isPreparingQueuedTranscriptionStart: Bool {
        preparingQueuedTranscriptionJob != nil || queuedTranscriptionStartTask != nil
    }

    private var currentBackgroundTranscriptionWorkSnapshot: BackgroundTranscriptionWorkSnapshot {
        BackgroundTranscriptionWorkSnapshot(
            activeCount: taskManager.activeCount,
            speakerNamingRequest: taskManager.speakerNamingRequest
        )
    }

    private var isCaptureSessionActive: Bool {
        if case .recording = state {
            return true
        }
        return isRecording
    }

    private func enqueueTranscriptionJob(
        micURL: URL,
        systemURL: URL?,
        healthInfo: RecordingHealthInfo,
        captureDiagnostics: [String: String],
        meetingTitle: String?,
        recordingDate: Date,
        startTrigger: StartTrigger
    ) -> QueueInsertionOutcome {
        let job = QueuedTranscriptionJob(
            kind: .recorded(
                micURL: micURL,
                systemURL: systemURL,
                healthInfo: healthInfo,
                captureDiagnostics: captureDiagnostics,
                meetingTitle: meetingTitle,
                recordingDate: recordingDate
            ),
            startTrigger: startTrigger,
            sttModel: sttRouter.selectedModel
        )

        if liveCodexFinalTranscriptNeedsQueuedJobID && liveCodexSessionAwaitingFinalTranscript {
            liveCodexAwaitedTranscriptionJobID = job.id
            liveCodexFinalTranscriptNeedsQueuedJobID = false
        }
        return enqueue(job)
    }

    private func enqueueImportedAudioJob(
        audioURL: URL,
        suggestedTitle: String,
        recordingDate: Date,
        startTrigger: StartTrigger
    ) -> QueueInsertionOutcome {
        let job = QueuedTranscriptionJob(
            kind: .imported(
                audioURL: audioURL,
                suggestedTitle: suggestedTitle,
                recordingDate: recordingDate
            ),
            startTrigger: startTrigger,
            sttModel: sttRouter.selectedModel
        )

        return enqueue(job)
    }

    private func enqueue(_ job: QueuedTranscriptionJob) -> QueueInsertionOutcome {
        if canStartQueuedTranscriptionImmediately {
            startQueuedTranscription(job)
            return .startedImmediately
        }

        queuedTranscriptionJobs.append(job)
        return .queued(position: queuedTranscriptionJobs.count)
    }

    private func startQueuedTranscription(_ job: QueuedTranscriptionJob) {
        lastTerminalTranscriptionOutcome = nil
        activeTranscriptionTrigger = job.startTrigger
        activeTranscriptionCaptureDiagnostics = job.captureDiagnostics
        sttAdapter.selectPreparedModel(job.sttModel)
        preparingQueuedTranscriptionJob = job

        if !isCaptureSessionActive {
            state = .transcribing
        }
        recordQueuedTranscriptionRuntimeDiagnosticsIfSafe(for: job)

        displayStatus = .gettingReady
        queuedTranscriptionStartTask?.cancel()
        queuedTranscriptionStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareAndStartQueuedTranscription(job)
        }
    }

    private func prepareAndStartQueuedTranscription(_ job: QueuedTranscriptionJob) async {
        let modelsReady = await ensureModelsReadyForQueuedTranscription(job)

        // A cancelled task must not touch shared state: a newer
        // startQueuedTranscription has already taken ownership of
        // queuedTranscriptionStartTask / preparingQueuedTranscriptionJob.
        guard !Task.isCancelled else { return }
        guard preparingQueuedTranscriptionJob?.id == job.id else { return }

        queuedTranscriptionStartTask = nil
        preparingQueuedTranscriptionJob = nil

        guard modelsReady else {
            failQueuedTranscriptionJobAfterModelRecovery(job)
            handleBackgroundTranscriptionWorkChanged()
            return
        }

        runPreparedQueuedTranscription(job)
    }

    private func ensureModelsReadyForQueuedTranscription(_ job: QueuedTranscriptionJob) async -> Bool {
        sttAdapter.selectPreparedModel(job.sttModel)

        if sttAdapter.isReady && diarization.isReady {
            return true
        }

        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_transcription_model_recovery_started",
            message: "Meeting transcription is loading models before starting queued audio",
            context: baseDiagnosticsContext(
                extra: [
                    "trigger": job.startTrigger.rawValue,
                    "queued_stt_model": job.sttModel.rawValue
                ]
            )
        )
        let modelRecoveryStartedAt = CFAbsoluteTimeGetCurrent()
        WorkflowRecoveryTelemetry.attempted(
            workflowKind: "model_preparation",
            failureKind: "models_not_ready",
            retrySource: "queued_transcription",
            surface: "meeting",
            artifactRetained: job.artifactRetained
        )

        do {
            try await downloader.ensureModelsReady(sttModel: job.sttModel)
            sttAdapter.selectPreparedModel(job.sttModel)
        } catch {
            DiagnosticsTrail.record(
                level: .error,
                engine: "meeting",
                event: "meeting_transcription_model_recovery_failed",
                message: "Meeting transcription models could not be loaded before queued audio started",
                context: baseDiagnosticsContext(
                    extra: [
                        "error": error.localizedDescription,
                        "trigger": job.startTrigger.rawValue,
                        "queued_stt_model": job.sttModel.rawValue
                    ]
                )
            )
            WorkflowRecoveryTelemetry.finished(
                workflowKind: "model_preparation",
                failureKind: "models_not_ready",
                retrySource: "queued_transcription",
                result: "failed",
                elapsedSeconds: CFAbsoluteTimeGetCurrent() - modelRecoveryStartedAt,
                surface: "meeting",
                artifactRetained: job.artifactRetained
            )
            return false
        }

        let ready = sttAdapter.isReady && diarization.isReady
        if !ready {
            DiagnosticsTrail.record(
                level: .error,
                engine: "meeting",
                event: "meeting_transcription_model_recovery_failed",
                message: "Meeting transcription models were still unavailable after reload",
                context: baseDiagnosticsContext(
                    extra: [
                        "trigger": job.startTrigger.rawValue,
                        "queued_stt_model": job.sttModel.rawValue
                    ]
                )
            )
        }

        WorkflowRecoveryTelemetry.finished(
            workflowKind: "model_preparation",
            failureKind: "models_not_ready",
            retrySource: "queued_transcription",
            result: ready ? "success" : "failed",
            elapsedSeconds: CFAbsoluteTimeGetCurrent() - modelRecoveryStartedAt,
            surface: "meeting",
            artifactRetained: job.artifactRetained
        )

        return ready
    }

    private func runPreparedQueuedTranscription(_ job: QueuedTranscriptionJob) {
        sttAdapter.selectPreparedModel(job.sttModel)
        queuedRuntimeDiagnosticsJobIDs.remove(job.id)
        activeQueuedTranscriptionJobID = job.id

        switch job.kind {
        case .recorded(let micURL, let systemURL, let healthInfo, _, let meetingTitle, let recordingDate):
            taskManager.startTranscription(
                taskId: job.id,
                micURL: micURL,
                systemURL: systemURL,
                outputFolder: MeetingStoragePaths.transcriptsFolder,
                healthInfo: healthInfo,
                meetingTitle: meetingTitle,
                splitLocalSpeakers: LocalSpeakerPreferences.isEnabled(),
                recordingDate: recordingDate
            )
        case .imported(let audioURL, let suggestedTitle, let recordingDate):
            taskManager.startImportedTranscription(
                audioURL: audioURL,
                outputFolder: MeetingStoragePaths.transcriptsFolder,
                meetingTitle: suggestedTitle,
                recordingDate: recordingDate
            )
        }
    }

    private func failQueuedTranscriptionJobAfterModelRecovery(_ job: QueuedTranscriptionJob) {
        let message = "Meeting transcription models were not ready. Try again after models finish loading."
        lastTerminalTranscriptionOutcome = .failed(message)
        state = .error(message)
        displayStatus = .failed(message: message)
        if liveCodexAwaitedTranscriptionJobID == job.id {
            finishLiveCodexSession(status: .failed, shouldAwaitFinalTranscript: false)
        }
        if activeQueuedTranscriptionJobID == job.id {
            activeQueuedTranscriptionJobID = nil
        }

        switch job.kind {
        case .recorded(let micURL, let systemURL, _, _, let meetingTitle, let recordingDate):
            preserveFailedMeetingForRetry(
                micAudioURL: micURL,
                systemAudioURL: systemURL,
                errorMessage: message,
                meetingTitle: meetingTitle,
                recordingDate: recordingDate
            )
        case .imported(let audioURL, _, _):
            try? FileManager.default.removeItem(at: audioURL)
        }
        clearQueuedTranscriptionRuntimeDiagnosticsIfOwned(for: job, outcome: "model_recovery_failed")
    }

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

    private func recordQueuedTranscriptionRuntimeDiagnosticsIfSafe(for job: QueuedTranscriptionJob) {
        guard !isCaptureSessionActive else { return }
        guard !(sttRouter.isRecording || sttRouter.isTranscribing) else { return }
        queuedRuntimeDiagnosticsJobIDs.insert(job.id)
        Self.runtimeDiagnosticsRecorder?.recordSession(kind: "meeting", stage: "transcribing")
    }

    private func clearQueuedTranscriptionRuntimeDiagnosticsIfOwned(
        for job: QueuedTranscriptionJob,
        outcome: String
    ) {
        guard queuedRuntimeDiagnosticsJobIDs.remove(job.id) != nil else { return }
        guard !isCaptureSessionActive else { return }
        guard !(sttRouter.isRecording || sttRouter.isTranscribing) else { return }
        Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: outcome)
    }

    private func canStartQueuedTranscriptionImmediately(
        snapshot: BackgroundTranscriptionWorkSnapshot
    ) -> Bool {
        MeetingSessionUIPolicy.canStartQueuedTranscription(
            activeTranscriptions: snapshot.activeCount,
            isPreparingQueuedTranscriptionStart: isPreparingQueuedTranscriptionStart
        )
    }

    private func hasVisibleBackgroundTranscriptionWork(
        snapshot: BackgroundTranscriptionWorkSnapshot
    ) -> Bool {
        MeetingSessionUIPolicy.shouldShowTranscribing(
            activeTranscriptions: snapshot.activeCount + (isPreparingQueuedTranscriptionStart ? 1 : 0),
            queuedTranscriptions: queuedTranscriptionJobs.count
        )
    }

    private func handleBackgroundTranscriptionWorkChanged() {
        handleBackgroundTranscriptionWorkChanged(snapshot: currentBackgroundTranscriptionWorkSnapshot)
    }

    private func handleBackgroundTranscriptionWorkChanged(
        snapshot: BackgroundTranscriptionWorkSnapshot
    ) {
        if canStartQueuedTranscriptionImmediately(snapshot: snapshot) {
            if let nextJob = popNextQueuedTranscriptionJob() {
                startQueuedTranscription(nextJob)
                return
            }

            finalizeBackgroundTranscriptionStateIfNeeded(snapshot: snapshot)
            return
        }

        if !hasVisibleBackgroundTranscriptionWork(snapshot: snapshot) {
            finalizeBackgroundTranscriptionStateIfNeeded(snapshot: snapshot)
            return
        }

        if !isCaptureSessionActive {
            state = .transcribing
        }
    }

    private func popNextQueuedTranscriptionJob() -> QueuedTranscriptionJob? {
        guard !queuedTranscriptionJobs.isEmpty else { return nil }
        return queuedTranscriptionJobs.removeFirst()
    }

    private func finalizeBackgroundTranscriptionStateIfNeeded() {
        finalizeBackgroundTranscriptionStateIfNeeded(snapshot: currentBackgroundTranscriptionWorkSnapshot)
    }

    private func finalizeBackgroundTranscriptionStateIfNeeded(
        snapshot: BackgroundTranscriptionWorkSnapshot
    ) {
        guard !hasVisibleBackgroundTranscriptionWork(snapshot: snapshot) else { return }
        guard !isCaptureSessionActive else { return }
        if MeetingSessionUIPolicy.shouldClearTranscriptionTriggerAfterBackgroundWork(
            hasTerminalOutcome: lastTerminalTranscriptionOutcome != nil,
            hasSpeakerReviewWork: snapshot.speakerNamingRequest != nil
        ) {
            activeTranscriptionTrigger = .unknown
        }

        switch lastTerminalTranscriptionOutcome {
        case .failed(let message):
            state = .error(message)
        case .transcriptSaved:
            state = .ready
        case .none:
            if case .transcribing = state {
                state = .ready
            }
        }
    }

    private func restoreStateAfterRecordingEndedWithoutNewWork() {
        guard !hasVisibleBackgroundTranscriptionWork else {
            state = .transcribing
            return
        }

        switch lastTerminalTranscriptionOutcome {
        case .failed(let message):
            state = .error(message)
        case .transcriptSaved, .none:
            state = .ready
        }
    }

    private func handleDisplayStatusChange(from previousStatus: DisplayStatus, to status: DisplayStatus) {
        switch status {
        case .transcriptSaved:
            lastTerminalTranscriptionOutcome = .transcriptSaved
            let transcriptionTrigger = activeTranscriptionTrigger
            DiagnosticsTrail.record(
                engine: "meeting",
                event: "meeting_transcript_saved",
                message: "Meeting transcript saved",
                context: baseDiagnosticsContext(
                    extra: [
                        "queue_depth": "\(queuedTranscriptionJobs.count)",
                        "trigger": transcriptionTrigger.rawValue
                    ]
                )
            )
            trackSavedTranscriptAnalyticsInBackground(
                baseProperties: [
                    "queue_depth_bucket": AnalyticsReporter.queueDepthBucket(queuedTranscriptionJobs.count),
                    "trigger": transcriptionTrigger.rawValue,
                ]
            )
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "transcript_saved")
            AppSoundPlayer.shared.play(.meetingTranscriptComplete)
            activeQueuedTranscriptionJobID = nil
            activeTranscriptionCaptureDiagnostics = nil
        case .failed(let message):
            lastTerminalTranscriptionOutcome = .failed(message)
            let transcriptionTrigger = activeTranscriptionTrigger
            let diagnosticMessage = taskManager.lastFailureDiagnosticMessage ?? message
            let failureKind = MeetingFailureKind.classify(message: diagnosticMessage)
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
                            "queue_depth": "\(queuedTranscriptionJobs.count)",
                            "trigger": transcriptionTrigger.rawValue
                        ]
                    )
                )
                AnalyticsReporter.track(
                    "meeting_transcript_skipped",
                    properties: failureTelemetryContext
                )
                ProductFrictionTelemetry.track(
                    surface: .meeting,
                    stage: "meeting_transcription",
                    result: .giveUp,
                    failureKind: failureKind.rawValue,
                    modelState: state.diagnosticName
                )
                activeTranscriptionCaptureDiagnostics = nil
                Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: failureKind.rawValue)
                finalizeBackgroundTranscriptionStateIfNeeded()
                return
            }

            if failureKind == .speakerFinalizationFailed || failureKind == .speakerNameFinalizationFailed {
                finishLiveCodexSessionForCurrentTranscriptionFailureIfNeeded(
                    failedJobID: activeQueuedTranscriptionJobID,
                    allowLastSavedTranscriptOwner: true
                )
                activeQueuedTranscriptionJobID = nil
                let queueDepthBucket = AnalyticsReporter.queueDepthBucket(queuedTranscriptionJobs.count)
                DiagnosticsTrail.record(
                    level: .error,
                    engine: "meeting",
                    event: "speaker_finalization_failed",
                    message: "Meeting speaker naming finalization failed",
                    context: baseDiagnosticsContext(
                        extra: [
                            "failure_kind": failureKind.rawValue,
                            "session_stage": CaptureFailureStage.save.rawValue,
                            "queue_depth": "\(queuedTranscriptionJobs.count)",
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
                ProductFrictionTelemetry.track(
                    surface: .meeting,
                    stage: "speaker_finalization",
                    result: .failed,
                    failureKind: failureKind.rawValue,
                    modelState: state.diagnosticName
                )
                activeTranscriptionCaptureDiagnostics = nil
                Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "speaker_finalization_failed")
                finalizeBackgroundTranscriptionStateIfNeeded()
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
                    "queue_depth": "\(queuedTranscriptionJobs.count)",
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
            ProductFrictionTelemetry.track(
                surface: .meeting,
                stage: "meeting_transcription",
                result: .failed,
                failureKind: failureKind.rawValue,
                modelState: state.diagnosticName
            )
            activeTranscriptionCaptureDiagnostics = nil
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "transcript_failed")
            finalizeBackgroundTranscriptionStateIfNeeded()
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
                "queue_depth_bucket": AnalyticsReporter.queueDepthBucket(queuedTranscriptionJobs.count),
                "trigger": transcriptionTrigger.rawValue,
            ],
            uniquingKeysWith: { _, new in new }
        )
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
    private func trackSavedTranscriptAnalyticsInBackground(baseProperties: [String: String]) {
        let restyle = savedTranscriptRestyleTask
        let fallbackTranscriptURL = taskManager.lastSavedTranscriptURL ?? lastSavedTranscriptURL
        Task.detached(priority: .utility) {
            let transcriptURL: URL?
            if let restyle {
                transcriptURL = await restyle.value.url
            } else {
                transcriptURL = fallbackTranscriptURL
            }
            let transcriptProperties = Self.savedTranscriptAnalyticsProperties(transcriptURL: transcriptURL)
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
            }
        }
    }

    nonisolated private static func savedTranscriptAnalyticsProperties(transcriptURL: URL?) -> [String: String] {
        guard let transcriptURL,
              let values = try? TranscriptFrontmatter.readValues(from: transcriptURL) else {
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
        return RecordingStopSnapshot(
            trigger: activeRecordingTrigger,
            systemAudioStatus: systemAudioStatus,
            durationSeconds: durationSeconds,
            healthInfo: capture.healthInfo(overrideSystemAudioStatus: systemAudioStatus),
            pipelineSnapshot: capture.pipelineDiagnosticsSnapshot(
                overrideSystemAudioStatus: systemAudioStatus
            ),
            suggestedTitle: activeRecordingSuggestedTitle,
            recordingStartedAt: activeRecordingStartedAt
        )
    }

    private func baseDiagnosticsContext(extra: [String: String] = [:]) -> [String: String] {
        var context: [String: String] = [
            "session_state": state.diagnosticName,
            "display_status": displayStatus.diagnosticName,
            "dictation_model": sttRouter.selectedModel.rawValue,
            "dictation_model_state": sttRouter.modelDownloadState.diagnosticName,
            "meeting_model_state": diarization.modelState.diagnosticName,
            "system_audio_status": capture.systemAudioStatus.diagnosticName,
            "queue_depth": "\(queuedTranscriptionJobs.count)"
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

    @discardableResult
    private func preserveFailedMeetingForRetry(
        taskId: UUID = UUID(),
        micAudioURL: URL?,
        systemAudioURL: URL?,
        errorMessage: String,
        meetingTitle: String?,
        recordingDate: Date? = nil,
        archiveAudio: Bool = true
    ) -> Bool {
        let preserved = taskManager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: micAudioURL,
            systemAudioURL: systemAudioURL,
            errorMessage: errorMessage,
            taskId: taskId,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate,
            archiveAudio: archiveAudio
        )
        if preserved {
            refreshFailedMeetings()
        }
        return preserved
    }

    private func refreshTimedOutFailedMeetingAudio(id: UUID, result: CaptureStopResult) {
        let existingFailure = failedManager.failedTranscriptions
            .first(where: { $0.id == id })
        let existingMicURL = existingFailure?.micAudioURL
        let existingSystemURL = existingFailure?.systemAudioURL
        guard let micURL = result.micURL ?? existingMicURL else { return }
        let systemURL = result.systemURL ?? existingSystemURL

        let updated = taskManager.promoteFinalizedFailedTranscriptionAudio(
            id: id,
            micAudioURL: micURL,
            systemAudioURL: systemURL
        )
        DiagnosticsTrail.record(
            level: updated ? .info : .warning,
            engine: "meeting",
            event: "meeting_recording_stop_timeout_audio_finalized",
            message: updated
                ? "Timed-out meeting audio finalized and failed queue was refreshed"
                : "Timed-out meeting audio finalized but failed queue entry was not found",
            context: baseDiagnosticsContext(
                extra: [
                    "failed_id": id.uuidString,
                    "mic_file_present": boolString(FileManager.default.fileExists(atPath: micURL.path)),
                    "system_file_present": boolString(systemURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
                ]
            )
        )
        if updated {
            refreshFailedMeetings()
        }
    }

    private func refreshFailedMeetings(_ updatedFailedTranscriptions: [FailedTranscription]? = nil) {
        let failedTranscriptions = updatedFailedTranscriptions ?? failedManager.failedTranscriptions
        retryingFailedMeetingIDs.formIntersection(Set(failedTranscriptions.map(\.id)))

        failedMeetings = failedTranscriptions
            .sorted(by: { $0.timestamp > $1.timestamp })
            .map { failed in
                FailedMeetingPresentation.item(
                    from: failed,
                    isRetrying: retryingFailedMeetingIDs.contains(failed.id)
                )
            }
        scheduleFailedAudioCompression(for: failedTranscriptions)
    }

    private func scheduleFailedAudioCompression(for failedTranscriptions: [FailedTranscription]) {
        guard failedAudioCompressionTask == nil else {
            failedAudioCompressionNeedsReschedule = true
            return
        }

        let candidates = failedTranscriptions.compactMap { failed -> FailedMeetingAudioCompressionCandidate? in
            guard !retryingFailedMeetingIDs.contains(failed.id) else { return nil }
            var urls = [failed.micAudioURL]
            if let systemAudioURL = failed.systemAudioURL {
                urls.append(systemAudioURL)
            }
            guard urls.contains(where: { $0.pathExtension.localizedCaseInsensitiveCompare("wav") == .orderedSame }) else {
                return nil
            }
            return FailedMeetingAudioCompressionCandidate(
                id: failed.id,
                micAudioURL: failed.micAudioURL,
                systemAudioURL: failed.systemAudioURL
            )
        }
        guard !candidates.isEmpty else { return }

        failedAudioCompressionNeedsReschedule = false
        let audioArchiveRoot = MeetingStoragePaths.audioArchiveFolder
        failedAudioCompressionTask = Task { [weak self] in
            _ = await MeetingAudioStorageManager.compressFailedTranscriptionAudio(
                candidates: candidates,
                audioArchiveRoot: audioArchiveRoot,
                persistUpdate: { [weak self] update in
                    await MainActor.run {
                        guard let self,
                              !self.retryingFailedMeetingIDs.contains(update.id) else {
                            return false
                        }
                        return self.failedManager.updateFailedTranscriptionAudio(
                            id: update.id,
                            micAudioURL: update.micAudioURL,
                            systemAudioURL: update.systemAudioURL
                        )
                    }
                }
            )
            await MainActor.run { [weak self] in
                let shouldReschedule = self?.failedAudioCompressionNeedsReschedule == true
                self?.failedAudioCompressionTask = nil
                self?.failedAudioCompressionNeedsReschedule = false
                if shouldReschedule, let self {
                    self.scheduleFailedAudioCompression(for: self.failedManager.failedTranscriptions)
                }
            }
        }
    }
}

private extension MeetingSessionController.State {
    var diagnosticName: String {
        switch self {
        case .idle: return "idle"
        case .loadingModels: return "loading_models"
        case .ready: return "ready"
        case .recording: return "recording"
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

private extension MeetingWarmupDictationState {
    init(_ state: ParakeetModelState) {
        switch state {
        case .notLoaded:
            self = .notLoaded
        case .downloading(let progress):
            self = .downloading(progress: progress)
        case .cached:
            self = .cached
        case .loading:
            self = .loading
        case .ready:
            self = .ready
        case .failed(let message):
            self = .failed(message)
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
        case .recording:
            self = .recording
        case .transcribing:
            self = .transcribing
        case .error:
            self = .error
        }
    }
}
