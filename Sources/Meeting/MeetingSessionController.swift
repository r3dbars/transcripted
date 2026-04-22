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
    enum StartTrigger: String {
        case hotkey = "hotkey"
        case menu = "menu"
        case onboarding = "onboarding"
        case detectedPrompt = "detected_prompt"
        case fileImport = "file_import"
        case unknown = "unknown"
    }

    enum StopReason: String {
        case hotkeyToggle = "hotkey_toggle"
        case overlayStopButton = "overlay_stop_button"
        case unknown = "unknown"
    }

    enum RecordingCancelReason: String {
        case discardButton = "discard_button"
        case onboardingDryRun = "onboarding_dry_run"
        case unknown = "unknown"
    }

    enum TranscriptionCancelReason: String {
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
    }

    private struct QueuedTranscriptionJob {
        enum Kind {
            case recorded(
                micURL: URL,
                systemURL: URL?,
                healthInfo: RecordingHealthInfo
            )
            case imported(
                audioURL: URL,
                suggestedTitle: String
            )
        }

        let kind: Kind
        let startTrigger: StartTrigger
        let sttModel: TranscriptionModelChoice
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
    private let sttRouter: STTRouter
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
    private var activeRecordingTrigger: StartTrigger = .unknown
    private var activeTranscriptionTrigger: StartTrigger = .unknown
    private var isFinishingRecording = false
    private var shouldSurfaceMeetingWarmupFailure = false

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
            retainedAudioDirectory: MeetingStoragePaths.audioArchiveFolder,
            statsStore: statsDatabase
        )

        // Model downloader — coordinates selected STT + PyAnnote readiness.
        self.downloader = MeetingModelDownloader(stt: sttAdapter, diarization: diarization)

        wireSubscriptions()
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
    }

    /// Begin a new meeting recording. Safe to call from UI buttons. If a prior
    /// meeting is still transcribing, the new capture starts immediately and
    /// the older transcript continues in the background.
    @discardableResult
    func startRecording(trigger: StartTrigger = .unknown) async -> Bool {
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
            return false
        }

        guard await ensureModelsReadyForRecording(trigger: trigger) else {
            return false
        }

        let started = await capture.startRecording()
        guard started else {
            let failureMessage = capture.errorMessage ?? "Meeting recording couldn't start. Check Transcripted's permissions and audio setup, then try again."
            DiagnosticsTrail.record(
                level: .error,
                engine: "meeting",
                event: "meeting_start_failed",
                message: failureMessage,
                context: baseDiagnosticsContext(extra: ["trigger": trigger.rawValue])
            )
            state = .error(failureMessage)
            return false
        }

        activeRecordingTrigger = trigger
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

        let recordingTrigger = activeRecordingTrigger

        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_stop_requested",
            message: "Meeting stop requested",
            context: baseDiagnosticsContext(
                extra: [
                    "trigger": recordingTrigger.rawValue,
                    "reason": reason.rawValue,
                    "duration_ms": "\(Int(recordingDuration * 1000))"
                ]
            )
        )

        // Snapshot capture health before stop resets system-audio status/stats during cleanup.
        let healthInfo = capture.healthInfo()
        let finalSystemAudioStatus = capture.systemAudioStatus
        let files = await capture.stopAndAwaitFiles()
        let durationMs = Int(recordingDuration * 1000)
        activeRecordingTrigger = .unknown
        state = .transcribing

        DiagnosticsTrail.record(
            level: finalSystemAudioStatus.isWarning ? .warning : .info,
            engine: "meeting",
            event: "meeting_recording_stopped",
            message: "Meeting recording stopped",
            context: baseDiagnosticsContext(
                extra: [
                    "trigger": recordingTrigger.rawValue,
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
            MeetingRecordingCleanup.discardFiles(micURL: nil, systemURL: files.systemURL)
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
            healthInfo: healthInfo,
            startTrigger: recordingTrigger
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
                    "trigger": recordingTrigger.rawValue,
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
                "trigger": recordingTrigger.rawValue,
            ]
        )
    }

    /// Cancel capture after an explicit confirmation, without queueing
    /// transcription or saving a transcript.
    func cancelRecording(reason: RecordingCancelReason = .unknown) async {
        guard case .recording = state else { return }
        guard !isFinishingRecording else { return }
        isFinishingRecording = true
        defer { isFinishingRecording = false }

        let recordingTrigger = activeRecordingTrigger
        let durationMs = Int(recordingDuration * 1000)

        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_cancel_requested",
            message: "Meeting cancellation requested",
            context: baseDiagnosticsContext(
                extra: [
                    "trigger": recordingTrigger.rawValue,
                    "reason": reason.rawValue,
                    "duration_ms": "\(durationMs)"
                ]
            )
        )

        let files = await capture.stopAndDiscardFiles()
        activeRecordingTrigger = .unknown
        restoreStateAfterRecordingEndedWithoutNewWork()
        AppSoundPlayer.shared.play(.dictationCancelled)

        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_recording_cancelled",
            message: "Meeting recording cancelled",
            context: baseDiagnosticsContext(
                extra: [
                    "trigger": recordingTrigger.rawValue,
                    "reason": reason.rawValue,
                    "duration_ms": "\(durationMs)",
                    "mic_file_present": boolString(files.micURL != nil),
                    "system_file_present": boolString(files.systemURL != nil)
                ]
            )
        )
        AnalyticsReporter.track(
            "meeting_recording_cancelled",
            properties: [
                "duration_bucket": AnalyticsReporter.durationBucket(seconds: Double(durationMs) / 1000),
                "reason": reason.rawValue,
                "system_stream_present": boolString(files.systemURL != nil),
                "trigger": recordingTrigger.rawValue,
            ]
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
            return false
        }

        let preparedAudio: PreparedImportedMeetingAudio
        do {
            preparedAudio = try await Task.detached(priority: .utility) {
                try MeetingImportedAudioPreparer.prepareImportedAudio(from: sourceURL)
            }.value
        } catch {
            DiagnosticsTrail.record(
                level: .error,
                engine: "meeting",
                event: "meeting_file_import_failed",
                message: "Imported meeting audio could not be prepared",
                context: baseDiagnosticsContext(extra: ["error": error.localizedDescription])
            )
            state = .error(error.localizedDescription)
            return false
        }

        let outcome = enqueueImportedAudioJob(
            audioURL: preparedAudio.copiedAudioURL,
            suggestedTitle: preparedAudio.suggestedTitle,
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
                    "file": preparedAudio.copiedAudioURL.lastPathComponent,
                    "queue_depth": "\(queuedTranscriptionJobs.count)",
                    "title": preparedAudio.suggestedTitle
                ]
            )
        )
        AnalyticsReporter.track(
            "meeting_file_imported",
            properties: [
                "queue_depth_bucket": AnalyticsReporter.queueDepthBucket(queuedTranscriptionJobs.count),
            ]
        )
        return true
    }

    /// Cancel any in-progress pipeline. Does not cancel an active recording —
    /// use stopRecording() for that.
    func cancelActiveTranscription(reason: TranscriptionCancelReason = .unknown) {
        let queuedJobs = queuedTranscriptionJobs
        queuedTranscriptionJobs.removeAll()
        lastTerminalTranscriptionOutcome = nil
        activeTranscriptionTrigger = .unknown

        for job in queuedJobs {
            switch job.kind {
            case .recorded(let micURL, let systemURL, _):
                failedManager.addFailedTranscription(
                    micAudioURL: micURL,
                    systemAudioURL: systemURL,
                    errorMessage: "Transcription cancelled"
                )
            case .imported(let audioURL, _):
                try? FileManager.default.removeItem(at: audioURL)
            }
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
        activeTranscriptionTrigger = .unknown
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

    private func refreshWarmupStatus() {
        let isMeetingWarmupInFlight = modelPreparationTask != nil || state == .loadingModels
        warmupStatus = MeetingWarmupStatusPolicy.status(
            dictationState: MeetingWarmupDictationState(sttRouter.modelDownloadState),
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
        taskManager.activeCount > 0 || taskManager.speakerNamingRequest != nil || !queuedTranscriptionJobs.isEmpty
    }

    private var hasVisibleBackgroundTranscriptionWork: Bool {
        MeetingSessionUIPolicy.shouldShowTranscribing(
            activeTranscriptions: taskManager.activeCount,
            queuedTranscriptions: queuedTranscriptionJobs.count
        )
    }

    private var isSpeechModelPreparedForSelection: Bool {
        sttAdapter.transcriptionEngineDescriptor.identifier == sttRouter.selectedModel.transcriptionEngineIdentifier
            && sttAdapter.isReady
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
        healthInfo: RecordingHealthInfo,
        startTrigger: StartTrigger
    ) -> QueueInsertionOutcome {
        let job = QueuedTranscriptionJob(
            kind: .recorded(
                micURL: micURL,
                systemURL: systemURL,
                healthInfo: healthInfo
            ),
            startTrigger: startTrigger,
            sttModel: sttRouter.selectedModel
        )

        return enqueue(job)
    }

    private func enqueueImportedAudioJob(
        audioURL: URL,
        suggestedTitle: String,
        startTrigger: StartTrigger
    ) -> QueueInsertionOutcome {
        let job = QueuedTranscriptionJob(
            kind: .imported(
                audioURL: audioURL,
                suggestedTitle: suggestedTitle
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
        sttAdapter.selectPreparedModel(job.sttModel)

        if !isCaptureSessionActive {
            state = .transcribing
        }

        switch job.kind {
        case .recorded(let micURL, let systemURL, let healthInfo):
            taskManager.startTranscription(
                micURL: micURL,
                systemURL: systemURL,
                outputFolder: storagePaths.transcripts,
                healthInfo: healthInfo,
                splitLocalSpeakers: LocalSpeakerPreferences.isEnabled()
            )
        case .imported(let audioURL, let suggestedTitle):
            taskManager.startImportedTranscription(
                audioURL: audioURL,
                outputFolder: storagePaths.transcripts,
                meetingTitle: suggestedTitle
            )
        }
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
        activeTranscriptionTrigger = .unknown

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
            AnalyticsReporter.track(
                "meeting_transcript_saved",
                properties: [
                    "queue_depth_bucket": AnalyticsReporter.queueDepthBucket(queuedTranscriptionJobs.count),
                    "trigger": transcriptionTrigger.rawValue,
                ]
            )
            AppSoundPlayer.shared.play(.meetingTranscriptComplete)
        case .failed(let message):
            lastTerminalTranscriptionOutcome = .failed(message)
            let transcriptionTrigger = activeTranscriptionTrigger
            DiagnosticsTrail.record(
                level: .error,
                engine: "meeting",
                event: "meeting_transcript_failed",
                message: "Meeting transcription failed",
                context: baseDiagnosticsContext(
                    extra: [
                        "error": message,
                        "queue_depth": "\(queuedTranscriptionJobs.count)",
                        "trigger": transcriptionTrigger.rawValue
                    ]
                )
            )
            AnalyticsReporter.track(
                "meeting_transcript_failed",
                properties: [
                    "failure_kind": analyticsFailureKind(from: message),
                    "queue_depth_bucket": AnalyticsReporter.queueDepthBucket(queuedTranscriptionJobs.count),
                    "trigger": transcriptionTrigger.rawValue,
                ]
            )
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

    private func analyticsFailureKind(from message: String) -> String {
        MeetingFailureKind.classify(message: message).rawValue
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

private extension MeetingWarmupDictationState {
    init(_ state: ParakeetModelState) {
        switch state {
        case .notLoaded:
            self = .notLoaded
        case .downloading(let progress):
            self = .downloading(progress: progress)
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
