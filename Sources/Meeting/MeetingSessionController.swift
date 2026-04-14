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
//   2. prepareModels() loads Parakeet + PyAnnote/WeSpeaker/Sortformer. Safe to
//      call multiple times — each engine is idempotent.
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
    enum StartTrigger: String {
        case hotkey = "hotkey"
        case menu = "menu"
        case detectedPrompt = "detected_prompt"
        case unknown = "unknown"
    }

    enum StopReason: String {
        case hotkeyToggle = "hotkey_toggle"
        case overlayStopButton = "overlay_stop_button"
        case unknown = "unknown"
    }

    enum TranscriptionCancelReason: String {
        case unknown = "unknown"
    }

    struct ModelWarmupStatus: Equatable {
        let title: String
        let subtitle: String
        let detail: String
        let progress: Double
        let dictationStatus: String
        let meetingsStatus: String

        static let ready = ModelWarmupStatus(
            title: "Transcripted is ready",
            subtitle: "Dictation and meetings are available",
            detail: "",
            progress: 1.0,
            dictationStatus: "Ready",
            meetingsStatus: "Ready"
        )
    }

    struct FailedMeetingItem: Identifiable, Equatable {
        let id: UUID
        let timestamp: Date
        let title: String
        let detail: String
        let meta: String
        let isRetryable: Bool
        let isRetrying: Bool
        let hasAudioFiles: Bool
    }

    private struct QueuedTranscriptionJob {
        let micURL: URL
        let systemURL: URL?
        let healthInfo: RecordingHealthInfo
    }

    private enum TerminalTranscriptionOutcome: Equatable {
        case transcriptSaved
        case failed(String)
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

    @Published private(set) var failedMeetings: [FailedMeetingItem] = []
    @Published private(set) var warmupStatus: ModelWarmupStatus = .ready {
        didSet {
            guard warmupStatus != oldValue else { return }
            logWarmupStatusChange(from: oldValue, to: warmupStatus)
        }
    }

    // MARK: - Core services (owned)

    private let storagePaths: CoreStoragePaths
    private let parakeetEngine: ParakeetEngine
    let capture: MeetingCaptureBridge
    let services: AppServices
    let taskManager: TranscriptionTaskManager
    private let failedManager: FailedTranscriptionManager
    private let diarization: DiarizationService
    private let sttAdapter: MeetingSTTAdapter
    private let speakerDatabase: SpeakerDatabase
    private let statsDatabase: StatsDatabase
    private let downloader: MeetingModelDownloader

    private var cancellables: Set<AnyCancellable> = []
    private var modelPreparationTask: Task<Result<Void, Error>, Never>?
    private var retryingFailedMeetingIDs: Set<UUID> = []
    private var queuedTranscriptionJobs: [QueuedTranscriptionJob] = []
    private var lastTerminalTranscriptionOutcome: TerminalTranscriptionOutcome?

    // MARK: - Init

    /// Construct the full Core stack with app-owned storage isolation.
    ///
    /// - Parameter parakeet: The app's shared ParakeetEngine instance. Shared
    ///   with STTRouter so we do not spin up a second AsrManager.
    init(parakeet: ParakeetEngine) {
        self.parakeetEngine = parakeet
        // Ensure the capture library and app-owned directories exist on disk before use.
        _ = MeetingStoragePaths.root
        _ = MeetingStoragePaths.stateFolder
        _ = MeetingStoragePaths.logsFolder
        _ = MeetingStoragePaths.recordingsScratch

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

        // STT: wrap the app's ParakeetEngine in the Core-facing adapter.
        self.sttAdapter = MeetingSTTAdapter(engine: parakeet)

        // Diarization: Core's concrete DiarizationService already conforms to
        // DiarizationEngine via an empty extension (see DiarizationService.swift).
        self.diarization = DiarizationService()

        // Speaker store: app-owned SQLite file under state/.
        self.speakerDatabase = SpeakerDatabase(path: storagePaths.speakerDB.path)
        self.statsDatabase = StatsDatabase(path: storagePaths.statsDB.path)

        // Failed-queue manager: takes CoreStoragePaths so its JSON file lives
        // under app-owned state, not the capture library.
        // TODO: Phase 2 ships without failed-transcription recovery for meeting
        // mode — we construct the manager because TranscriptionTaskManager
        // requires it, but nothing in the app currently drains the failed queue
        // or exposes retry UI. Follow-up work lands in a later phase.
        self.failedManager = FailedTranscriptionManager(paths: storagePaths)

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
            statsStore: statsDatabase
        )

        // Model downloader — coordinates Parakeet + PyAnnote readiness.
        self.downloader = MeetingModelDownloader(stt: sttAdapter, diarization: diarization)

        wireSubscriptions()
    }

    // MARK: - Public API

    /// Load STT + diarization models. Call once before the first recording.
    /// Transitions state: idle → loadingModels → ready, or → error(String).
    ///
    func prepareModels(showLoadingUI: Bool = true) async {
        if case .ready = state { return }

        if showLoadingUI, case .loadingModels = state {
            if let task = modelPreparationTask {
                _ = await task.value
                return
            }
        }

        if showLoadingUI {
            state = .loadingModels
            refreshWarmupStatus()
        }

        if let task = modelPreparationTask {
            let result = await task.value
            applyModelPreparationResult(result, showLoadingUI: showLoadingUI)
            return
        }

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
        modelPreparationTask = nil
        applyModelPreparationResult(result, showLoadingUI: showLoadingUI)
    }

    /// Begin a new meeting recording. Safe to call from UI buttons. If a prior
    /// meeting is still transcribing, the new capture starts immediately and
    /// the older transcript continues in the background.
    func startRecording(trigger: StartTrigger = .unknown) async {
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
            return
        case .idle, .loadingModels, .ready, .transcribing, .error:
            break
        }

        let startDecision = MeetingRecordingStartGate.evaluate(
            microphoneGranted: TranscriptedPermissionAccess.isGranted(.microphone),
            systemAudioRecordingGranted: TranscriptedPermissionAccess.isGranted(.systemAudioRecording)
        )
        guard startDecision.canStart else {
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
            return
        }

        switch state {
        case .idle, .loadingModels, .error:
            await prepareModels()
            guard case .ready = state else {
                DiagnosticsTrail.record(
                    level: .warning,
                    engine: "meeting",
                    event: "meeting_start_blocked",
                    message: "Meeting could not start because models were not ready",
                    context: baseDiagnosticsContext(extra: ["trigger": trigger.rawValue])
                )
                return
            }
        case .ready, .transcribing:
            break
        case .recording:
            return
        }

        capture.startRecording()
        state = .recording
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_recording_started",
            message: "Meeting recording started",
            context: baseDiagnosticsContext(extra: ["trigger": trigger.rawValue])
        )
        AnalyticsReporter.track(
            "meeting_recording_started",
            properties: [
                "trigger": trigger.rawValue,
            ]
        )
    }

    /// Stop capture and queue the finished meeting for background transcription.
    /// Returns once the finished audio has either started transcribing or been
    /// placed behind the current background task.
    func stopRecording(reason: StopReason = .unknown) async {
        guard case .recording = state else { return }

        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_stop_requested",
            message: "Meeting stop requested",
            context: baseDiagnosticsContext(
                extra: [
                    "reason": reason.rawValue,
                    "duration_ms": "\(Int(recordingDuration * 1000))"
                ]
            )
        )

        let files = await capture.stopAndAwaitFiles()
        let healthInfo = capture.healthInfo()
        let durationMs = Int(recordingDuration * 1000)
        state = .transcribing

        DiagnosticsTrail.record(
            level: capture.systemAudioStatus.isWarning ? .warning : .info,
            engine: "meeting",
            event: "meeting_recording_stopped",
            message: "Meeting recording stopped",
            context: baseDiagnosticsContext(
                extra: [
                    "reason": reason.rawValue,
                    "duration_ms": "\(durationMs)",
                    "mic_file_present": boolString(files.micURL != nil),
                    "system_file_present": boolString(files.systemURL != nil),
                    "capture_quality": healthInfo.captureQuality.rawValue,
                    "audio_gaps": "\(healthInfo.audioGaps)",
                    "device_switches": "\(healthInfo.deviceSwitches)"
                ]
            )
        )

        guard let micURL = files.micURL else {
            DiagnosticsTrail.record(
                level: .error,
                engine: "meeting",
                event: "meeting_recording_missing_mic_audio",
                message: "Meeting recording stopped without a microphone file",
                context: baseDiagnosticsContext(extra: ["reason": reason.rawValue])
            )
            state = .error("No microphone audio was captured.")
            return
        }

        let outcome = enqueueTranscriptionJob(
            micURL: micURL,
            systemURL: files.systemURL,
            healthInfo: healthInfo
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
                    "reason": reason.rawValue,
                    "duration_ms": "\(durationMs)",
                    "queue_depth": "\(queueDepth)"
                ]
            )
        )
        AnalyticsReporter.track(
            "meeting_recording_stopped",
            properties: [
                "capture_quality": healthInfo.captureQuality.rawValue,
                "duration_bucket": AnalyticsReporter.durationBucket(seconds: recordingDuration),
                "reason": reason.rawValue,
                "system_stream_present": boolString(files.systemURL != nil),
            ]
        )
    }

    /// Cancel any in-progress pipeline. Does not cancel an active recording —
    /// use stopRecording() for that.
    func cancelActiveTranscription(reason: TranscriptionCancelReason = .unknown) {
        let queuedJobs = queuedTranscriptionJobs
        queuedTranscriptionJobs.removeAll()
        lastTerminalTranscriptionOutcome = nil

        for job in queuedJobs {
            failedManager.addFailedTranscription(
                micAudioURL: job.micURL,
                systemAudioURL: job.systemURL,
                errorMessage: "Transcription cancelled"
            )
        }

        taskManager.cancelAll()
        state = .ready
        DiagnosticsTrail.record(
            level: .warning,
            engine: "meeting",
            event: "meeting_transcription_cancelled",
            message: "Meeting transcription cancelled",
            context: baseDiagnosticsContext(extra: ["reason": reason.rawValue])
        )
    }

    func retryFailedMeeting(id: UUID) {
        guard !isRecording, !hasBackgroundTranscriptionWork else { return }
        guard !retryingFailedMeetingIDs.contains(id) else { return }

        retryingFailedMeetingIDs.insert(id)
        refreshFailedMeetings()

        Task { [weak self] in
            guard let self else { return }
            _ = await self.taskManager.retryFailedTranscription(
                failedId: id,
                outputFolder: self.storagePaths.transcripts
            )
            self.retryingFailedMeetingIDs.remove(id)
            self.refreshFailedMeetings()
        }
    }

    func dismissFailedMeeting(id: UUID) {
        retryingFailedMeetingIDs.remove(id)
        failedManager.removeFailedTranscription(id: id)
        refreshFailedMeetings()
    }

    func deleteFailedMeeting(id: UUID) {
        retryingFailedMeetingIDs.remove(id)
        failedManager.deleteFailedTranscription(id: id)
        refreshFailedMeetings()
    }

    // MARK: - Subscriptions

    private func wireSubscriptions() {
        capture.$isRecording
            .assign(to: &$isRecording)

        capture.$audioLevel
            .assign(to: &$audioLevel)

        capture.$systemLevel
            .assign(to: &$systemLevel)

        capture.$recordingDuration
            .assign(to: &$recordingDuration)

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
            .sink { [weak self] _, _ in
                self?.handleBackgroundTranscriptionWorkChanged()
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
                    self.lastSavedTranscriptURL = nil
                    self.lastSavedTitle = nil
                    return
                }

                let styled = MeetingTranscriptStyler.restyleTranscript(at: url)
                self.lastSavedTranscriptURL = styled.url
                self.lastSavedTitle = styled.title
                DiagnosticsTrail.record(
                    engine: "meeting",
                    event: "meeting_transcript_artifact_ready",
                    message: "Meeting transcript artifact is ready",
                    context: self.baseDiagnosticsContext()
                )
            }
            .store(in: &cancellables)

        failedManager.$failedTranscriptions
            .sink { [weak self] _ in
                self?.refreshFailedMeetings()
            }
            .store(in: &cancellables)

        parakeetEngine.$modelDownloadState
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

    private func refreshWarmupStatus() {
        let dictationState = parakeetEngine.modelDownloadState
        let meetingState = diarization.modelState
        let isMeetingWarmupInFlight = modelPreparationTask != nil || state == .loadingModels
        let hasMeetingWarmupFailure: Bool
        if case .failed = meetingState {
            hasMeetingWarmupFailure = true
        } else {
            hasMeetingWarmupFailure = false
        }
        let shouldSurfaceMeetingWarmup = isMeetingWarmupInFlight || hasMeetingWarmupFailure

        if case .ready = dictationState, case .ready = meetingState {
            warmupStatus = .ready
            return
        }

        switch dictationState {
        case .downloading(let progress):
            warmupStatus = ModelWarmupStatus(
                title: "Getting Transcripted ready",
                subtitle: "Downloading local dictation model",
                detail: "Transcripted is downloading the on-device voice model used for dictation. This can take a minute or two on first launch.",
                progress: max(0.08, min(0.62, 0.08 + progress * 0.54)),
                dictationStatus: "Downloading \(Int(progress * 100))%",
                meetingsStatus: "Waiting"
            )
        case .loading:
            warmupStatus = ModelWarmupStatus(
                title: "Getting Transcripted ready",
                subtitle: "Loading local dictation model",
                detail: "Transcripted has the model files and is loading dictation into memory.",
                progress: 0.68,
                dictationStatus: "Loading",
                meetingsStatus: "Waiting"
            )
        case .failed(let message):
            warmupStatus = ModelWarmupStatus(
                title: "Couldn’t start dictation",
                subtitle: "The local dictation model failed to load",
                detail: message,
                progress: 0,
                dictationStatus: "Failed",
                meetingsStatus: "Waiting"
            )
        case .ready:
            guard shouldSurfaceMeetingWarmup else {
                warmupStatus = .ready
                return
            }

            switch meetingState {
            case .ready:
                warmupStatus = .ready
            case .failed(let message):
                warmupStatus = ModelWarmupStatus(
                    title: "Couldn’t load meetings",
                    subtitle: "Meeting transcription models failed to load",
                    detail: message,
                    progress: 0.72,
                    dictationStatus: "Ready",
                    meetingsStatus: "Failed"
                )
            case .loading:
                warmupStatus = ModelWarmupStatus(
                    title: "Getting Transcripted ready",
                    subtitle: "Loading meeting transcription",
                    detail: "Dictation is ready. Transcripted is still warming up meeting transcription in the background.",
                    progress: 0.86,
                    dictationStatus: "Ready",
                    meetingsStatus: "Loading"
                )
            case .notLoaded:
                warmupStatus = ModelWarmupStatus(
                    title: "Getting Transcripted ready",
                    subtitle: "Preparing meeting transcription",
                    detail: "Dictation is ready. Meeting transcription is still starting up.",
                    progress: 0.76,
                    dictationStatus: "Ready",
                    meetingsStatus: "Starting"
                )
            }
        case .notLoaded:
            warmupStatus = ModelWarmupStatus(
                title: "Getting Transcripted ready",
                subtitle: "Starting local dictation",
                detail: "Transcripted is waking up the on-device dictation model.",
                progress: 0.05,
                dictationStatus: "Starting",
                meetingsStatus: "Waiting"
            )
        }
    }

    private func applyModelPreparationResult(_ result: Result<Void, Error>, showLoadingUI: Bool) {
        switch result {
        case .success:
            switch state {
            case .recording, .transcribing:
                break
            default:
                state = .ready
            }
        case .failure(let error):
            if showLoadingUI {
                state = .error(error.localizedDescription)
            }
        }

        refreshWarmupStatus()
    }

    private enum QueueInsertionOutcome: Equatable {
        case startedImmediately
        case queued(position: Int)
    }

    private var hasBackgroundTranscriptionWork: Bool {
        taskManager.activeCount > 0 || taskManager.speakerNamingRequest != nil || !queuedTranscriptionJobs.isEmpty
    }

    private var hasVisibleBackgroundTranscriptionWork: Bool {
        MeetingSessionUIPolicy.shouldShowTranscribing(
            activeTranscriptions: taskManager.activeCount,
            queuedTranscriptions: queuedTranscriptionJobs.count
        )
    }

    private var canStartQueuedTranscriptionImmediately: Bool {
        taskManager.activeCount == 0 && taskManager.speakerNamingRequest == nil
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
        healthInfo: RecordingHealthInfo
    ) -> QueueInsertionOutcome {
        let job = QueuedTranscriptionJob(
            micURL: micURL,
            systemURL: systemURL,
            healthInfo: healthInfo
        )

        if canStartQueuedTranscriptionImmediately {
            startQueuedTranscription(job)
            return .startedImmediately
        }

        queuedTranscriptionJobs.append(job)
        return .queued(position: queuedTranscriptionJobs.count)
    }

    private func startQueuedTranscription(_ job: QueuedTranscriptionJob) {
        lastTerminalTranscriptionOutcome = nil

        if !isCaptureSessionActive {
            state = .transcribing
        }

        taskManager.startTranscription(
            micURL: job.micURL,
            systemURL: job.systemURL,
            outputFolder: storagePaths.transcripts,
            healthInfo: job.healthInfo
        )
    }

    private func handleBackgroundTranscriptionWorkChanged() {
        if canStartQueuedTranscriptionImmediately {
            if let nextJob = popNextQueuedTranscriptionJob() {
                startQueuedTranscription(nextJob)
                return
            }

            finalizeBackgroundTranscriptionStateIfNeeded()
            return
        }

        if !hasVisibleBackgroundTranscriptionWork {
            finalizeBackgroundTranscriptionStateIfNeeded()
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
        guard !hasVisibleBackgroundTranscriptionWork else { return }
        guard !isCaptureSessionActive else { return }

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

    private func handleDisplayStatusChange(from previousStatus: DisplayStatus, to status: DisplayStatus) {
        switch status {
        case .transcriptSaved:
            lastTerminalTranscriptionOutcome = .transcriptSaved
            DiagnosticsTrail.record(
                engine: "meeting",
                event: "meeting_transcript_saved",
                message: "Meeting transcript saved",
                context: baseDiagnosticsContext(
                    extra: [
                        "queue_depth": "\(queuedTranscriptionJobs.count)"
                    ]
                )
            )
            AnalyticsReporter.track(
                "meeting_transcript_saved",
                properties: [
                    "queue_depth_bucket": AnalyticsReporter.queueDepthBucket(queuedTranscriptionJobs.count),
                ]
            )
            AppSoundPlayer.shared.play(.meetingTranscriptComplete)
        case .failed(let message):
            lastTerminalTranscriptionOutcome = .failed(message)
            DiagnosticsTrail.record(
                level: .error,
                engine: "meeting",
                event: "meeting_transcript_failed",
                message: "Meeting transcription failed",
                context: baseDiagnosticsContext(
                    extra: [
                        "error": message,
                        "queue_depth": "\(queuedTranscriptionJobs.count)"
                    ]
                )
            )
            AnalyticsReporter.track(
                "meeting_transcript_failed",
                properties: [
                    "failure_kind": analyticsFailureKind(from: message),
                    "queue_depth_bucket": AnalyticsReporter.queueDepthBucket(queuedTranscriptionJobs.count),
                ]
            )
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

    private func analyticsFailureKind(from message: String) -> String {
        let normalized = message.lowercased()

        if normalized.contains("system audio") || normalized.contains("screen recording") {
            return "system_audio"
        }
        if normalized.contains("recording too short") {
            return "recording_too_short"
        }
        if normalized.contains("save") {
            return "save_failed"
        }
        if normalized.contains("model") || normalized.contains("load") {
            return "model_load"
        }

        return "other"
    }

    private func baseDiagnosticsContext(extra: [String: String] = [:]) -> [String: String] {
        var context: [String: String] = [
            "session_state": state.diagnosticName,
            "display_status": displayStatus.diagnosticName,
            "dictation_model_state": parakeetEngine.modelDownloadState.diagnosticName,
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
        switch status {
        case .unknown:
            return "System audio status reset"
        case .healthy:
            return "System audio capture is healthy"
        case .reconnecting:
            return "System audio capture is reconnecting"
        case .silent:
            return "System audio capture is silent"
        case .failed:
            return "System audio capture failed"
        }
    }

    private func boolString(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    private func refreshFailedMeetings() {
        let failedTranscriptions = failedManager.failedTranscriptions
        retryingFailedMeetingIDs.formIntersection(Set(failedTranscriptions.map(\.id)))

        failedMeetings = failedTranscriptions
            .sorted(by: { $0.timestamp > $1.timestamp })
            .map { failed in
                FailedMeetingPresentation.item(
                    from: failed,
                    isRetrying: retryingFailedMeetingIDs.contains(failed.id)
                )
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

private extension ParakeetModelState {
    var diagnosticName: String {
        switch self {
        case .notLoaded: return "not_loaded"
        case .downloading: return "downloading"
        case .loading: return "loading"
        case .ready: return "ready"
        case .failed: return "failed"
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
