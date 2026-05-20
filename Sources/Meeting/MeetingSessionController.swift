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
                meetingTitle: String?
            )
            case imported(
                audioURL: URL,
                suggestedTitle: String
            )
        }

        let id = UUID()
        let kind: Kind
        let startTrigger: StartTrigger
        let sttModel: TranscriptionModelChoice
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
    @Published private(set) var audioInactivityWarning: MeetingAudioInactivityWarning?

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
    var calendarSuggestedTitleProvider: (() -> String?)?

    private var cancellables: Set<AnyCancellable> = []
    private var modelPreparationTask: Task<Result<Void, Error>, Never>?
    private var retryingFailedMeetingIDs: Set<UUID> = []
    private var queuedTranscriptionJobs: [QueuedTranscriptionJob] = []
    private var preparingQueuedTranscriptionJob: QueuedTranscriptionJob?
    private var queuedTranscriptionStartTask: Task<Void, Never>?
    private var lastTerminalTranscriptionOutcome: TerminalTranscriptionOutcome?
    private var activeRecordingTrigger: StartTrigger = .unknown
    private var activeRecordingSuggestedTitle: String?
    private var activeTranscriptionTrigger: StartTrigger = .unknown
    private var isFinishingRecording = false
    private var shouldSurfaceMeetingWarmupFailure = false
    private var audioInactivityDetector = MeetingAudioInactivityDetector()
    private var latestMicLevel: Float = 0
    private var latestSystemLevel: Float = 0

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

        let started = await capture.startRecording()
        guard started else {
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
            state = .error(failureMessage)
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "start_failed")
            return false
        }

        activeRecordingTrigger = trigger
        activeRecordingSuggestedTitle = MeetingRecordingTitlePolicy.resolve(
            explicitTitle: suggestedTitle,
            calendarTitle: calendarSuggestedTitleProvider?()
        )
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
        Self.runtimeDiagnosticsRecorder?.recordSession(kind: "meeting", stage: "stop_requested")
        _ = audioInactivityDetector.stopRecording()
        audioInactivityWarning = nil

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

        let stopResult = await capture.stopAndAwaitFiles()
        let files = (micURL: stopResult.micURL, systemURL: stopResult.systemURL)
        let afterStopVolumeContext = capture.routeVolumeDiagnosticsContext(currentPhase: "after")
        let stopCaptureDiagnostics = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: meetingCaptureAnalyticsProperties(snapshot: recordingSnapshot.pipelineSnapshot),
            afterStopContext: afterStopVolumeContext
        )
        activeRecordingTrigger = .unknown
        activeRecordingSuggestedTitle = nil
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
            properties: meetingCaptureHealthSnapshotProperties(
                captureDiagnostics: stopCaptureDiagnostics,
                healthInfo: recordingSnapshot.healthInfo,
                trigger: recordingSnapshot.trigger.rawValue,
                reason: reason.rawValue,
                durationSeconds: recordingSnapshot.durationSeconds,
                systemStreamPresent: files.systemURL != nil,
                stopTimedOut: stopResult.didTimeOut
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
                meetingTitle: recordingSnapshot.suggestedTitle
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
                micAudioURL: micURL,
                systemAudioURL: files.systemURL,
                errorMessage: "Recording stop timed out before audio files were finalized.",
                meetingTitle: recordingSnapshot.suggestedTitle
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

        let outcome = enqueueTranscriptionJob(
            micURL: micURL,
            systemURL: files.systemURL,
            healthInfo: recordingSnapshot.healthInfo,
            meetingTitle: recordingSnapshot.suggestedTitle,
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

    func endRecordingFromAudioInactivityPrompt(automatic: Bool) async {
        guard audioInactivityWarning != nil else { return }
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
        let afterStopVolumeContext = capture.routeVolumeDiagnosticsContext(currentPhase: "after")
        let cancelCaptureDiagnostics = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: meetingCaptureAnalyticsProperties(snapshot: recordingSnapshot.pipelineSnapshot),
            afterStopContext: afterStopVolumeContext
        )
        activeRecordingTrigger = .unknown
        activeRecordingSuggestedTitle = nil
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
        AnalyticsReporter.track(
            "meeting_capture_health_snapshot",
            properties: meetingCaptureHealthSnapshotProperties(
                captureDiagnostics: cancelCaptureDiagnostics,
                healthInfo: recordingSnapshot.healthInfo,
                trigger: recordingSnapshot.trigger.rawValue,
                reason: reason.rawValue,
                durationSeconds: recordingSnapshot.durationSeconds,
                systemStreamPresent: files.systemURL != nil,
                stopTimedOut: stopResult.didTimeOut
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
            return false
        }

        let preparedAudio: PreparedImportedMeetingAudio
        do {
            preparedAudio = try await Task.detached(priority: .utility) {
                try MeetingImportedAudioPreparer.prepareImportedAudio(from: sourceURL)
            }.value
        } catch {
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
            state = .error(displayMessage)
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "file_import_failed")
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
        let queuedJobs = queuedTranscriptionJobs
        queuedTranscriptionJobs.removeAll()
        let preparingJob = preparingQueuedTranscriptionJob
        queuedTranscriptionStartTask?.cancel()
        queuedTranscriptionStartTask = nil
        preparingQueuedTranscriptionJob = nil
        lastTerminalTranscriptionOutcome = nil
        activeTranscriptionTrigger = .unknown

        for job in queuedJobs + [preparingJob].compactMap({ $0 }) {
            switch job.kind {
            case .recorded(let micURL, let systemURL, _, let meetingTitle):
                preserveFailedMeetingForRetry(
                    micAudioURL: micURL,
                    systemAudioURL: systemURL,
                    errorMessage: "Transcription cancelled",
                    meetingTitle: meetingTitle
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
        Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "transcription_cancelled")
    }

    func prepareForTermination() async {
        var didPreserveRecording = false
        var recordingTrigger = activeRecordingTrigger
        var stoppedFiles: (micURL: URL?, systemURL: URL?) = (nil, nil)

        if isFinishingRecording {
            await waitForRecordingFinishBeforeTermination()
        }

        if case .recording = state, !isFinishingRecording {
            isFinishingRecording = true
            defer { isFinishingRecording = false }

            _ = audioInactivityDetector.stopRecording()
            audioInactivityWarning = nil

            let files = await capture.stopAndAwaitFiles()
            stoppedFiles = (micURL: files.micURL, systemURL: files.systemURL)
            let meetingTitle = activeRecordingSuggestedTitle
            activeRecordingTrigger = .unknown
            activeRecordingSuggestedTitle = nil

            if files.micURL != nil || files.systemURL != nil {
                didPreserveRecording = preserveFailedMeetingForRetry(
                    micAudioURL: files.micURL,
                    systemAudioURL: files.systemURL,
                    errorMessage: "Meeting saved before quit. Audio is safe; finish the transcript from Home after reopening.",
                    meetingTitle: meetingTitle
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
            case .recorded(let micURL, let systemURL, _, let meetingTitle):
                if preserveFailedMeetingForRetry(
                    micAudioURL: micURL,
                    systemAudioURL: systemURL,
                    errorMessage: errorMessage,
                    meetingTitle: meetingTitle
                ) {
                    preservedCount += 1
                }
            case .imported(let audioURL, _):
                try? FileManager.default.removeItem(at: audioURL)
            }
        }
        return preservedCount
    }

    func retryFailedMeeting(id: UUID) {
        guard !isRecording, !hasBackgroundTranscriptionWork, !isSpeakerReviewPending else { return }
        guard !retryingFailedMeetingIDs.contains(id) else { return }

        retryingFailedMeetingIDs.insert(id)
        activeTranscriptionTrigger = .unknown
        refreshFailedMeetings()

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
                return
            }

            _ = await self.taskManager.retryFailedTranscription(
                failedId: id,
                outputFolder: MeetingStoragePaths.transcriptsFolder
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
            .sink { [weak self] isRecording in
                guard let self else { return }
                self.isRecording = isRecording
                let event: MeetingAudioInactivityDetector.Event
                if isRecording {
                    event = self.audioInactivityDetector.startRecording(at: self.recordingDuration)
                } else {
                    event = self.audioInactivityDetector.stopRecording()
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
                self?.handleBackgroundTranscriptionWorkChanged(
                    snapshot: BackgroundTranscriptionWorkSnapshot(
                        activeCount: activeCount,
                        speakerNamingRequest: speakerNamingRequest
                    )
                )
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
                let transcriptURL = styled.url
                Task.detached(priority: .utility) {
                    await MeetingAudioStorageManager.processSavedTranscript(at: transcriptURL)
                }
                DiagnosticsTrail.record(
                    engine: "meeting",
                    event: "meeting_transcript_artifact_ready",
                    message: "Meeting transcript artifact is ready",
                    context: self.baseDiagnosticsContext()
                )
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

    private func applyAudioInactivityEvent(_ event: MeetingAudioInactivityDetector.Event) {
        switch event {
        case .none:
            return
        case .warningStarted(let warning):
            audioInactivityWarning = warning
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "meeting_audio_inactivity_warning_started",
                message: "No meeting audio detected",
                context: baseDiagnosticsContext(
                    extra: [
                        "inactive_ms": "\(Int(warning.inactiveDuration * 1000))",
                        "countdown_seconds": "\(warning.countdownSeconds)",
                        "duration_ms": "\(Int(recordingDuration * 1000))"
                    ]
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
        meetingTitle: String?,
        startTrigger: StartTrigger
    ) -> QueueInsertionOutcome {
        let job = QueuedTranscriptionJob(
            kind: .recorded(
                micURL: micURL,
                systemURL: systemURL,
                healthInfo: healthInfo,
                meetingTitle: meetingTitle
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
        preparingQueuedTranscriptionJob = job

        if !isCaptureSessionActive {
            state = .transcribing
        }

        displayStatus = .gettingReady
        queuedTranscriptionStartTask?.cancel()
        queuedTranscriptionStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareAndStartQueuedTranscription(job)
        }
    }

    private func prepareAndStartQueuedTranscription(_ job: QueuedTranscriptionJob) async {
        let modelsReady = await ensureModelsReadyForQueuedTranscription(job)
        guard preparingQueuedTranscriptionJob?.id == job.id else { return }

        queuedTranscriptionStartTask = nil
        preparingQueuedTranscriptionJob = nil

        guard !Task.isCancelled else { return }

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

        return ready
    }

    private func runPreparedQueuedTranscription(_ job: QueuedTranscriptionJob) {
        sttAdapter.selectPreparedModel(job.sttModel)

        switch job.kind {
        case .recorded(let micURL, let systemURL, let healthInfo, let meetingTitle):
            taskManager.startTranscription(
                micURL: micURL,
                systemURL: systemURL,
                outputFolder: MeetingStoragePaths.transcriptsFolder,
                healthInfo: healthInfo,
                meetingTitle: meetingTitle,
                splitLocalSpeakers: LocalSpeakerPreferences.isEnabled()
            )
        case .imported(let audioURL, let suggestedTitle):
            taskManager.startImportedTranscription(
                audioURL: audioURL,
                outputFolder: MeetingStoragePaths.transcriptsFolder,
                meetingTitle: suggestedTitle
            )
        }
    }

    private func failQueuedTranscriptionJobAfterModelRecovery(_ job: QueuedTranscriptionJob) {
        let message = "Meeting transcription models were not ready. Try again after models finish loading."
        lastTerminalTranscriptionOutcome = .failed(message)
        state = .error(message)
        displayStatus = .failed(message: message)

        switch job.kind {
        case .recorded(let micURL, let systemURL, _, let meetingTitle):
            preserveFailedMeetingForRetry(
                micAudioURL: micURL,
                systemAudioURL: systemURL,
                errorMessage: message,
                meetingTitle: meetingTitle
            )
        case .imported(let audioURL, _):
            try? FileManager.default.removeItem(at: audioURL)
        }
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
            hasTerminalOutcome: lastTerminalTranscriptionOutcome != nil
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
            AnalyticsReporter.track(
                "meeting_transcript_saved",
                properties: savedTranscriptAnalyticsProperties().merging(
                    [
                    "queue_depth_bucket": AnalyticsReporter.queueDepthBucket(queuedTranscriptionJobs.count),
                    "trigger": transcriptionTrigger.rawValue,
                    ],
                    uniquingKeysWith: { _, new in new }
                )
            )
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "transcript_saved")
            AppSoundPlayer.shared.play(.meetingTranscriptComplete)
        case .failed(let message):
            lastTerminalTranscriptionOutcome = .failed(message)
            let transcriptionTrigger = activeTranscriptionTrigger
            let diagnosticMessage = taskManager.lastFailureDiagnosticMessage ?? message
            let failureKind = MeetingFailureKind.classify(message: diagnosticMessage)
            if failureKind == .recordingTooShort {
                DiagnosticsTrail.record(
                    engine: "meeting",
                    event: "meeting_transcript_skipped",
                    message: "Meeting transcription skipped because the recording was too short",
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
                    properties: meetingCaptureAnalyticsProperties(snapshot: capture.pipelineDiagnosticsSnapshot()).merging(
                        [
                            "failure_kind": failureKind.rawValue,
                            "queue_depth_bucket": AnalyticsReporter.queueDepthBucket(queuedTranscriptionJobs.count),
                            "trigger": transcriptionTrigger.rawValue,
                        ],
                        uniquingKeysWith: { _, new in new }
                    )
                )
                Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "recording_too_short")
                finalizeBackgroundTranscriptionStateIfNeeded()
                return
            }

            if failureKind == .speakerFinalizationFailed || failureKind == .speakerNameFinalizationFailed {
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
                Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "speaker_finalization_failed")
                finalizeBackgroundTranscriptionStateIfNeeded()
                return
            }

            DiagnosticsTrail.record(
                level: .error,
                engine: "meeting",
                event: "meeting_transcript_failed",
                message: "Meeting transcription failed",
                context: baseDiagnosticsContext(
                    extra: [
                        "error": message,
                        "diagnostic_error": diagnosticMessage,
                        "failure_kind": failureKind.rawValue,
                        "queue_depth": "\(queuedTranscriptionJobs.count)",
                        "trigger": transcriptionTrigger.rawValue
                    ]
                )
            )
            AnalyticsReporter.track(
                "meeting_transcript_failed",
                properties: meetingCaptureAnalyticsProperties(snapshot: capture.pipelineDiagnosticsSnapshot()).merging(
                        [
                        "failure_kind": failureKind.rawValue,
                        "queue_depth_bucket": AnalyticsReporter.queueDepthBucket(queuedTranscriptionJobs.count),
                        "trigger": transcriptionTrigger.rawValue,
                        ],
                    uniquingKeysWith: { _, new in new }
                )
            )
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
        let normalized = message.lowercased()
        if normalized.contains("permission") { return "permission_missing" }
        if normalized.contains("timeout") || normalized.contains("timed out") { return "start_timeout" }
        if normalized.contains("system audio") { return "system_stream_unavailable" }
        if normalized.contains("microphone") || normalized.contains("mic") { return "mic_unavailable" }
        return "unexpected"
    }

    private func meetingCaptureAnalyticsProperties(snapshot: AudioPipelineDiagnosticsSnapshot) -> [String: String] {
        var properties = snapshot.privacySafeContext
        properties["gap_count_bucket"] = AnalyticsReporter.countBucket(snapshot.gapCount)
        properties["route_change_count_bucket"] = AnalyticsReporter.countBucket(snapshot.routeChangeCount)
        properties["recovery_attempt_bucket"] = AnalyticsReporter.countBucket(snapshot.recoveryAttemptCount)
        return properties
    }

    private func meetingCaptureHealthSnapshotProperties(
        captureDiagnostics: [String: String],
        healthInfo: RecordingHealthInfo,
        trigger: String,
        reason: String,
        durationSeconds: Double,
        systemStreamPresent: Bool,
        stopTimedOut: Bool
    ) -> [String: String] {
        captureDiagnostics.merging(
            [
                "capture_quality": healthInfo.captureQuality.rawValue,
                "duration_bucket": AnalyticsReporter.durationBucket(seconds: durationSeconds),
                "gap_count_bucket": AnalyticsReporter.countBucket(healthInfo.audioGaps),
                "reason": reason,
                "route_change_count_bucket": AnalyticsReporter.countBucket(healthInfo.deviceSwitches),
                "system_stream_present": boolString(systemStreamPresent),
                "stop_timed_out": boolString(stopTimedOut),
                "trigger": trigger,
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
        let shouldReport =
            stopTimedOut ||
            files.micURL == nil ||
            healthInfo.captureQuality == .degraded ||
            snapshot.systemFailed ||
            snapshot.systemStatus == "failed"
        guard shouldReport else { return }

        var context = captureDiagnostics
        context["capture_quality"] = healthInfo.captureQuality.rawValue
        context["duration_bucket"] = AnalyticsReporter.durationBucket(seconds: durationSeconds)
        context["gap_count"] = "\(healthInfo.audioGaps)"
        context["mic_file_available"] = boolString(files.micURL != nil)
        context["reason"] = reason.rawValue
        context["route_change_count"] = "\(healthInfo.deviceSwitches)"
        context["stop_timed_out"] = boolString(stopTimedOut)
        context["system_stream_present"] = boolString(files.systemURL != nil)
        context["trigger"] = trigger.rawValue

        DiagnosticsTrail.record(
            level: .error,
            engine: "meeting",
            event: "recording_capture_degraded",
            message: "Meeting capture health degraded",
            context: baseDiagnosticsContext(extra: context)
        )
    }

    private func savedTranscriptAnalyticsProperties() -> [String: String] {
        guard let url = taskManager.lastSavedTranscriptURL ?? lastSavedTranscriptURL,
              let raw = try? String(contentsOf: url, encoding: .utf8),
              let values = TranscriptFrontmatter.values(in: raw) else {
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
            suggestedTitle: activeRecordingSuggestedTitle
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

    @discardableResult
    private func preserveFailedMeetingForRetry(
        micAudioURL: URL?,
        systemAudioURL: URL?,
        errorMessage: String,
        meetingTitle: String?
    ) -> Bool {
        let preserved = taskManager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: micAudioURL,
            systemAudioURL: systemAudioURL,
            errorMessage: errorMessage,
            meetingTitle: meetingTitle
        )
        if preserved {
            refreshFailedMeetings()
        }
        return preserved
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

private extension ParakeetModelState {
    var diagnosticName: String {
        switch self {
        case .notLoaded: return "not_loaded"
        case .downloading: return "downloading"
        case .cached: return "cached"
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
