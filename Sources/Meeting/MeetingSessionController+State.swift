// MeetingSessionController+State.swift
// The class declaration: stored and published state, init, and the single
// state writers (transition, updateDisplayStatus). Behavior lives in
// MeetingSessionController.swift (start/stop) and the other +*.swift files.
//
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
//      TranscriptedAppState runs it quietly at launch. Optional streaming
//      diarization warms only when bundled and never blocks the current
//      meeting transcript path.
//   3. startRecording() begins capture via MeetingCaptureBridge. It never waits
//      on step 2; models that are still loading catch up in the background.
//   4. stopRecording() awaits capture files, then either starts a background
//      transcription immediately or enqueues it behind the current one.
//      TranscriptionTaskManager still runs one diarize→transcribe→save
//      pipeline at a time and writes a .md to MeetingStoragePaths.transcriptsFolder.
//
// The session controller does NOT own a hotkey or UI — Lane C (meeting-ui)
// wires those up.

import AppKit
import Combine
import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class MeetingSessionController: ObservableObject {
    static var runtimeDiagnosticsRecorder: RuntimeDiagnostics?

    typealias ModelWarmupStatus = MeetingWarmupStatus

    // Moved to FailedMeetingStore.swift / TranscriptionQueueCoordinator.swift
    // (audit 2026-07-08 wave 2, W2-B). Typealiases keep every existing
    // reference — including `MeetingSessionController.FailedMeetingItem` in
    // UI files — resolving unchanged.
    typealias FailedMeetingItem = FailedMeetingStore.FailedMeetingItem
    typealias QueuedTranscriptionJob = TranscriptionQueueCoordinator.QueuedTranscriptionJob
    typealias BackgroundTranscriptionWorkSnapshot = TranscriptionQueueCoordinator.BackgroundTranscriptionWorkSnapshot

    // Members without `private` below are internal only so the
    // MeetingSessionController+*.swift extensions can reach them. Not API:
    // UI code reads the published state and calls the public methods.

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
    var isStartingRecording: Bool {
        if case .startingRecording = state { return true }
        return false
    }

    /// A stop/cancel/termination teardown is in flight.
    var isStoppingRecording: Bool {
        if case .stoppingRecording = state { return true }
        return false
    }

    // Pass-throughs for UI convenience (updated via Combine subscriptions below).
    @Published var audioLevel: Float = 0          // mic-only level
    @Published var systemLevel: Float = 0         // system audio level
    @Published var recordingDuration: TimeInterval = 0
    @Published private(set) var displayStatus: DisplayStatus = .idle
    @Published var lastSavedTranscriptURL: URL? = nil
    @Published var lastSavedTitle: String? = nil
    @Published var savedMeetingReplacementCommitCount: Int = 0
    @Published var audioInactivityWarning: MeetingAudioInactivityWarning?
    @Published var isMicBoostPromptVisible = false
    @Published var audioRouteWarning: CaptureRouteStabilizationOutcome?
    @Published var systemAudioDegradationWarning: MeetingSystemAudioDegradationWarning?
    /// The start failed because macOS denied System Audio Recording (a typed
    /// missing grant or an observed capture denial, never a silent or
    /// timed-out probe). The overlays offer Grant System Audio Access for it.
    /// Set with the `.error` it belongs to; message matching is not proof.
    private(set) var systemAudioPermissionRecoveryNeeded = false
    /// The quiet "Mic only" note on the recording pill, set for a recording
    /// that never built the system-audio tap. See `MeetingMicOnlyNotice`.
    @Published var micOnlyNotice: MeetingMicOnlyNotice?
    /// The Notch island asks about call audio during this meeting: the start
    /// recorded the mic only and asks while it records. Raised from the
    /// start's outcome and tied to that start (`MeetingCallAudioAsk`).
    @Published private(set) var asksAboutCallAudioWhileRecording = false
    var callAudioAsk = MeetingCallAudioAsk() {
        didSet {
            if asksAboutCallAudioWhileRecording != callAudioAsk.isAsking {
                asksAboutCallAudioWhileRecording = callAudioAsk.isAsking
            }
        }
    }
    @Published private(set) var artifactRecoveryAlert: MeetingArtifactRecoveryAlert?

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
    let services: AppServices
    let taskManager: TranscriptionTaskManager
    let failedManager: FailedTranscriptionManager
    let diarization: DiarizationService
    let sttAdapter: MeetingSTTAdapter
    let speakerDatabase: SpeakerDatabase
    /// Closed while saved people move into a new voiceprint model's database
    /// (MeetingVoiceprintMigrationLaunch). Transcription and speaker edits
    /// wait on it, so none of them write that database mid-move.
    let voiceprintMigrationGate = SpeakerVoiceprintMigrationGate()
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

    var cancellables: Set<AnyCancellable> = []
    var modelPreparationTask: Task<Result<Void, Error>, Never>?
    var savedTranscriptRestyleTask: Task<StyledMeetingTranscript, Never>?
    var importPreparationTask: Task<PreparedImportedMeetingAudio, Error>?
    var importPreparationToken: UUID?
    var lastTerminalTranscriptionOutcome: TerminalTranscriptionOutcome?
    var activeTranscriptionCaptureDiagnostics: [String: String]?
    var activeDetectedPromptRecordingTelemetryProperties: [String: String]?
    var activeDetectedPromptRecordingStartedAt: Date?
    var activeDetectedPromptTranscriptionTelemetryProperties: [String: String]?
    var activeDetectedPromptTranscriptionRecordingStartedAt: Date?
    var activeRecordingTrigger: StartTrigger = .unknown
    var activeRecordingIdentity: UUID?
    var micBoostPromptRecordingIdentity: UUID?
    var micBoostPromptOutcome: MeetingMicBoostPromptOutcome = .notShown
    /// The recording an accepted Boost is still trying to arm. Stop doesn't
    /// clear it, so a Boost that never applied before Stop is saved as
    /// `shown`, not `accepted`.
    var micBoostArmPendingIdentity: UUID?
    /// When the current "can't hear the call" stretch began. Wall clock, not
    /// `recordingDuration`, which reads 0 once an unexpected stop reset it.
    var unheardPlaybackWarningStartedAt: Date?
    var activeRecordingSuggestedTitle: String?
    /// The user chose "Record Just My Mic" for this recording, so a silent
    /// system track is expected and must not raise the unverified banner.
    var activeRecordingIsMicOnlyByChoice = false
    /// macOS's System Audio Recording answer, read once per recording the
    /// first time the "not verified" notice would show. When macOS says
    /// access is on, a tap with no signal is a quiet Mac (most often an
    /// in-person meeting), so that notice stays hidden; a call playing that
    /// the tap can't hear gets its own warning instead. Nil until read.
    var activeRecordingSystemAudioAccessConfirmed: Bool?
    /// Re-reads macOS's System Audio Recording answer after the "Mic only"
    /// note sent the user to turn it on, so the note can say it worked.
    var micOnlyAccessRecheckTask: Task<Void, Never>?
    /// True while a click on the note is waiting on the macOS box, so a
    /// second click can't raise another request or open Settings under it.
    var micOnlyAccessRequestInFlight = false
    /// How the last start decided system audio access: `system` (macOS's own
    /// answer), `probe` (that answer was unavailable, so the tap probe ran),
    /// or `none` (no check was needed). Reported on meeting_recording_started.
    var lastSystemAudioPermissionCheck = "none"
    /// Whether the speech and speaker models were already loaded when the
    /// last start began capture (the launch warmup's job).
    var meetingModelsWarmAtStart = false
    /// Asks before a meeting starts when macOS says system audio is off.
    /// Swappable so tests and harnesses can answer without a modal alert.
    var systemAudioAccessPrompter: @MainActor (MeetingSystemAudioAccessPromptCopy) async -> MeetingSystemAudioAccessChoice = {
        await MeetingSystemAudioAccessAlert.ask($0)
    }
    /// True when the prompter asks while the meeting records (the Notch
    /// island) instead of blocking the start. Then a mic-only start is never
    /// remembered, so every meeting asks again about call audio.
    var systemAudioAccessAsksWhileRecording: @MainActor () -> Bool = { false }
    var activeRecordingStartedAt: Date?
    /// System-audio status and degradation warning as they stood the moment
    /// capture stopped underneath the controller (state still `.recording`).
    /// That same moment resets capture's status to `.unknown` and clears the
    /// warning, so the unexpected-stop snapshot reads these instead.
    var unexpectedCaptureStopEvidence: (
        systemAudioStatus: SystemAudioStatus,
        degradationWarning: MeetingSystemAudioDegradationWarning?
    )?
    /// How long "can't hear the call" had been open at that same moment. A
    /// later warning refresh can clear the live timer before the snapshot.
    var unheardSecondsAtCaptureStop: TimeInterval?
    var activeTranscriptionTrigger: StartTrigger = .unknown
    // Whole-function reentrancy guard for startRecording() — deliberately
    // NOT derived from `state` (see the comment at its use site). Everything
    // else that used to read `isStartingRecording`/`isFinishingRecording`
    // reads `state` directly now.
    var startRecordingCallInFlight = false
    var recordingLanguageSelection: TranscriptionLanguageSelection = .automatic
    var recordingSTTModel: TranscriptionModelChoice = TranscriptionModelPreferences.defaultModel
    var shouldSurfaceMeetingWarmupFailure = false
    var audioInactivityDetector = MeetingAudioInactivityDetector()
    var latestMicLevel: Float = 0
    var latestSystemLevel: Float = 0
    var activeQueuedTranscriptionJobID: UUID?
    var activeStoppedAudioRecovery: DictationStoppedAudioRecovery?
    var stoppedAudioRecoveryRetryRegistry = DictationStoppedAudioRecoveryRetryRegistry()
    private var acknowledgedArtifactRecoveryJournalDirectories: Set<String> = []

    var shouldConfirmQuitForActiveCapture: Bool {
        isCaptureSessionActive
    }

    func clearArtifactRecoveryAlert(_ alert: MeetingArtifactRecoveryAlert) {
        guard artifactRecoveryAlert == alert else { return }
        if case .journalUnavailable(let directory) = alert {
            acknowledgedArtifactRecoveryJournalDirectories.insert(directory.standardizedFileURL.path)
        }
        artifactRecoveryAlert = nil
    }

    func reportArtifactRecoveryJournalUnavailable(_ directory: URL) {
        let directory = directory.standardizedFileURL
        guard !acknowledgedArtifactRecoveryJournalDirectories.contains(directory.path) else { return }
        let alert = MeetingArtifactRecoveryAlert.journalUnavailable(directory)
        guard artifactRecoveryAlert != alert else { return }
        artifactRecoveryAlert = alert
    }

    func addArtifactRecoveryNotice(_ notice: MeetingArtifactRecoveryNotice) {
        switch artifactRecoveryAlert {
        case nil:
            artifactRecoveryAlert = .artifacts([notice])
        case .some(.artifacts(var notices)):
            guard !notices.contains(notice) else { return }
            notices.append(notice)
            artifactRecoveryAlert = .artifacts(notices)
        case .some(.journalUnavailable):
            break
        }
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
    ///
    /// Mints the `SharedMeetingMicClaim` dictation will hold for the
    /// lifetime of the borrow: `activeRecordingIdentity` is always non-nil
    /// here because it is coined before `.startingRecording` and only
    /// cleared when this session leaves `.recording` (see
    /// `clearActiveRecordingIdentity()` call sites), i.e. exactly the window
    /// `canShareMicWithDictation` covers. `isSessionAlive` closes over
    /// `self` weakly so Speech never needs a reference to
    /// `MeetingSessionController` itself, and delegates to
    /// `SharedMeetingMicClaimPolicy.isClaimSessionAlive`, which requires
    /// BOTH `isCaptureSessionActive` — the broader "is the capture pipeline
    /// live for this recording" check that also covers this session's own
    /// teardown window, rather than `isRecording`/`canShareMicWithDictation`,
    /// which would go false the instant this session starts stopping and
    /// make every claim look stale during completely normal teardown — AND
    /// that `activeRecordingIdentity` is still the exact identity minted
    /// below (`mintedIdentity`), captured by value here so a later
    /// recording on this same controller (a fresh identity) cannot make an
    /// orphaned claim from an earlier, already-ended recording read as
    /// alive just because something is active again.
    func startDictationFromActiveMeetingMic() -> Bool {
        guard canShareMicWithDictation, let activeRecordingIdentity else { return false }
        let mintedIdentity = activeRecordingIdentity
        let claim = SharedMeetingMicClaim(
            sessionIdentity: mintedIdentity,
            isSessionAlive: { [weak self] in
                guard let self else { return false }
                return SharedMeetingMicClaimPolicy.isClaimSessionAlive(
                    mintedIdentity: mintedIdentity,
                    currentIdentity: self.activeRecordingIdentity,
                    isCaptureSessionActive: self.isCaptureSessionActive
                )
            }
        )
        return sttRouter.startRecordingFromSharedMeetingMic(claim: claim)
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
    func transition(
        to newState: State,
        reason: StaticString,
        systemAudioPermissionRecoveryNeeded: Bool = false
    ) {
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
        self.systemAudioPermissionRecoveryNeeded = systemAudioPermissionRecoveryNeeded
        state = newState
        switch newState {
        case .startingRecording, .recording:
            callAudioAsk.meetingStateChanged(isStartingOrRecording: true)
        default:
            callAudioAsk.meetingStateChanged(isStartingOrRecording: false)
        }
    }

    /// Reports a failure that is NOT about this session's own live capture
    /// pipeline — a rejected user action (import/retranscribe blocked by
    /// something unrelated to capture), a background job's outcome (queued
    /// model-prep, a different meeting's queued transcript finishing with no
    /// speech) — as a visible `.error`, but ONLY when capture isn't
    /// currently live. Before the 2026-08 state collapse this guard wasn't
    /// needed: `isCaptureSessionActive` OR'd in a capture-bridge-derived
    /// `isRecording` mirror independent of `state`, so even a call site that
    /// stomped `state` to `.error` for an unrelated reason left the gates
    /// reading true because the mirror still reflected the real, physically
    /// -still-running capture. Now that `isRecording`/`isCaptureSessionActive`
    /// are both derived purely from `state`, an unguarded transition here
    /// would silently clear every gate that reads them (quit-confirm,
    /// dictation-block, mic-share, menubar, force-quit) for a capture that
    /// is still actually running — see
    /// `MeetingSessionStateMachine.mayReportUnrelatedFailureAsError`. When
    /// capture is live, this is a silent no-op: the diagnostics event that
    /// led here already ran at the call site, and the recording lifecycle
    /// keeps driving `state` normally.
    func reportUnrelatedFailure(
        _ message: String,
        reason: StaticString,
        systemAudioPermissionRecoveryNeeded: Bool = false
    ) {
        guard MeetingSessionStateMachine.mayReportUnrelatedFailureAsError(while: state) else { return }
        transition(
            to: .error(message),
            reason: reason,
            systemAudioPermissionRecoveryNeeded: systemAudioPermissionRecoveryNeeded
        )
    }

    /// `displayStatus`'s single writer. `source` only distinguishes the two
    /// callers for behavior that was already conditional on the caller: the
    /// `taskManager.$displayStatus` mirror also runs `handleDisplayStatusChange`
    /// (it is the only place that ever did, before this change), while
    /// controller/coordinator-driven phase updates (getting ready, prep
    /// failed) do not. This preserves existing effective behavior — last
    /// write wins, in call order — just through one function instead of
    /// three separate write sites.
    enum DisplayStatusSource {
        case taskManagerMirror
        case controllerPhase
    }

    func updateDisplayStatus(_ newStatus: DisplayStatus, source: DisplayStatusSource) {
        let previousStatus = displayStatus
        displayStatus = newStatus
        if source == .taskManagerMirror {
            handleDisplayStatusChange(from: previousStatus, to: newStatus)
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
        // a SpeakerProfile row must never mix dimensions. makeEmbedder loads nothing
        // here on the main actor: it picks the model (and so the DB path) from
        // model-file presence and returns an embedder that loads in the background;
        // the diarizer's warmup, each meeting and the voiceprint migration await it.
        // A missing model, or one that failed to load on this build, returns nil:
        // native WeSpeaker embedding AND the default speakers.sqlite. A load that
        // fails later yields no vectors, so 256-d vectors never land in a 192-d DB.
        let embedderChoice = SpeakerEmbedderPreferences.effectiveChoice()
        let segmentEmbedder = SpeakerEmbedderFactory.makeEmbedder(for: embedderChoice)
        // Nemotron by default, with a hidden switch back to pyannote
        // (DiarizationBackendPreferences). Read once here, so a change takes
        // effect on the next launch.
        let diarizationBackend = SpeakerEmbedderFactory.activeDiarizationBackend()

        // Build app-owned CoreStoragePaths so captures and internal state stay split.
        self.storagePaths = CoreStoragePaths(
            transcripts: MeetingStoragePaths.transcriptsFolder,
            speakerDB: SpeakerEmbedderFactory.speakerDBURL(for: segmentEmbedder, diarizationBackend: diarizationBackend),
            statsDB: MeetingStoragePaths.statsDatabase,
            failedQueue: MeetingStoragePaths.failedTranscriptionsFile,
            speakerClips: MeetingStoragePaths.speakerClipsFolder,
            audioCaptures: MeetingStoragePaths.recordingsScratch,
            logs: MeetingStoragePaths.logsFolder
        )

        // Capture bridge owns an `Audio` instance with our storage paths so
        // raw mic/system WAV captures land in the app scratch folder.
        // Core's `.macOSWorkspace` default listens on `NotificationCenter.default`,
        // which never receives NSWorkspace sleep/wake. Pass the workspace center
        // explicitly — same wiring MeetingCaptureBridge uses when it builds Audio.
        self.capture = MeetingCaptureBridge(
            audio: Audio(
                paths: storagePaths,
                sleepWakeNotifications: AudioSleepWakeNotifications(
                    center: MeetingSleepWakeNotificationSource.center,
                    willSleepName: MeetingSleepWakeNotificationSource.willSleepName,
                    didWakeName: MeetingSleepWakeNotificationSource.didWakeName
                )
            )
        )

        // STT: wrap the app's selected speech router in the Core-facing adapter.
        self.sttAdapter = MeetingSTTAdapter(router: sttRouter)

        // Diarization: Core's concrete DiarizationService already conforms to
        // DiarizationEngine via an empty extension (see DiarizationService.swift).
        // When a segment embedder is present, the diarizer re-embeds each segment
        // with it (e.g. ERes2Net) before the speaker identity stack runs.
        self.diarization = DiarizationService(segmentEmbedder: segmentEmbedder, backend: diarizationBackend)

        // Speaker store: app-owned SQLite file under state/. It holds one voiceprint
        // model's vectors, so it uses that model's cosine bars.
        self.speakerDatabase = SpeakerDatabase(
            path: storagePaths.speakerDB.path,
            thresholds: diarization.activeSpeakerThresholds
        )
        self.statsDatabase = StatsDatabase(path: storagePaths.statsDB.path)

        // Failed-queue manager: takes CoreStoragePaths so its JSON file lives
        // under app-owned state, not the capture library. The queue is drained
        // by `refreshFailedMeetings()` (subscribed to
        // `failedManager.$failedTranscriptions`) and surfaced in Settings →
        // Meetings → "Needs Attention", with retry / delete actions wired
        // through `retryFailedMeeting` and `deleteFailedMeeting`.
        self.failedManager = FailedTranscriptionManager(paths: storagePaths)
        // The failed queue holds the only copy of a meeting that never got a
        // transcript, so the user's audio-retention choice applies here too,
        // but the queue stays bounded. A 7- or 30-day window never prunes
        // failed audio sooner than the 30-day floor; "Never delete audio"
        // (the shipped default) keeps failed rows for the longer cap instead
        // of forever, so Needs Attention and disk use cannot grow unbounded.
        let failedMeetingRetentionDays = AudioStoragePreferences.deleteAudioAfter().days
            .map { max($0, TranscriptedConstants.failedMeetingAudioRetentionDays) }
            ?? TranscriptedConstants.failedMeetingAudioRetentionCapDays
        self.failedManager.cleanupOldFailedTranscriptions(
            olderThanDays: failedMeetingRetentionDays
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
            // Obsidian metadata was retired with the Draft-era toggle
            // (docs/capture-format.md), but the bundle id never changed, so
            // a Draft-era `enableObsidianFormat = true` was still adding
            // nested frontmatter and wiki-linked speakers to every new
            // transcript with no UI to turn it off. Always write the plain
            // contract the MCP/CLI parsers are built against.
            transcriptFormatOptionsProvider: { TranscriptFormatOptions() },
            statsStore: statsDatabase
        )

        // Model downloader — coordinates selected STT + PyAnnote readiness.
        self.downloader = MeetingModelDownloader(stt: sttAdapter, diarization: diarization)

        // Transcription-queue bookkeeping (audit 2026-07-08 wave 2, W2-B).
        // Constructed last because it still holds an unowned controller
        // reference. `failedMeetingStore` initializes lazily when
        // `wireSubscriptions()` first needs it.
        self.transcriptionQueue = TranscriptionQueueCoordinator(controller: self)
        do {
            let notices = try MeetingArtifactRecoveryStore.pendingNotices()
            self.artifactRecoveryAlert = notices.isEmpty ? nil : .artifacts(notices)
        } catch {
            self.artifactRecoveryAlert = .journalUnavailable(
                MeetingArtifactRecoveryStore.defaultDirectory
            )
        }

        // Core cannot see the app-side transcription queue, so tell it which
        // audio is already spoken for. Without this, orphaned-recording
        // recovery can archive and unlink the audio of a job that is queued but
        // has not started yet — it has no entry in Core's `tasks` until then.
        taskManager.reservedAudioURLsProvider = { [weak self] in
            self?.transcriptionQueue.reservedAudioURLs ?? []
        }
        // Tuned for the backend that actually loaded (pyannote when Nemotron failed
        // to), read per meeting, and the voiceprint model picked at launch
        // (MeetingSpeakerSeparation, MeetingSpeakerSeparationProvider).
        let speakerThresholds = diarization.activeSpeakerThresholds
        let diarizer = diarization
        taskManager.speakerSeparationProvider = MeetingSpeakerSeparationProvider.make(
            activeBackend: { await diarizer.activeBackend }
        ) { backend, recordingDate in
            await MeetingSpeakerSeparation.resolve(
                backend: backend,
                thresholds: speakerThresholds,
                recordingStart: recordingDate
            )
        }
        // Expected people get named sooner (MeetingCalendarNaming).
        taskManager.lineupNamingProvider = { recordingDate in
            await MeetingCalendarNaming.lineupRequest(recordingStart: recordingDate)
        }

        capture.onUnexpectedRecordingComplete = { [weak self] result in
            Task { @MainActor [weak self] in
                await self?.handleUnexpectedCaptureStop(result)
            }
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

        // A new voiceprint model starts with an empty database: carry the
        // people saved under WeSpeaker into it, off the main actor. Started
        // before any queued job can run, since those wait on the gate.
        MeetingVoiceprintMigrationLaunch.start(
            voiceprintMigrationGate,
            embedder: segmentEmbedder,
            targetDatabase: speakerDatabase,
            speakerClipsDirectory: storagePaths.speakerClips
        )

        wireSubscriptions()
        transcriptionQueue.recoverImportedAudioJobs()

        // Recover recordings orphaned by a crash before any failed-queue entry
        // existed — they become visible, retryable items on Home.
        let scratchDirectory = storagePaths.audioCaptures
        Task { [taskManager] in
            await taskManager.recoverOrphanedRecordings(in: scratchDirectory)
        }
    }

    func clearActiveRecordingIdentity() {
        if let identity = activeRecordingIdentity {
            LiveMeetingTranscriptService.shared.finishCapture(sessionID: identity)
        }
        activeRecordingIdentity = nil
        micBoostPromptRecordingIdentity = nil
        audioRouteWarning = nil
        systemAudioDegradationWarning = nil
        activeRecordingIsMicOnlyByChoice = false
        activeRecordingSystemAudioAccessConfirmed = nil
        clearMicOnlyNotice()
    }

    func clearMicOnlyNotice() {
        micOnlyAccessRecheckTask?.cancel()
        micOnlyAccessRecheckTask = nil
        if micOnlyNotice != nil { micOnlyNotice = nil }
    }

    func refreshWarmupStatus() {
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

    var hasBackgroundTranscriptionWork: Bool {
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

    /// A speaker review is waiting on answers. The island's "who was on the
    /// call" list for a meeting where everyone was recognized doesn't count:
    /// nothing in it needs an answer, so it never blocks a failed-meeting
    /// retry or defers an update install.
    var isSpeakerReviewPending: Bool {
        taskManager.hasSpeakerReviewAwaitingAnswers
    }

    var hasVisibleBackgroundTranscriptionWork: Bool {
        transcriptionQueue.hasVisibleBackgroundTranscriptionWork(snapshot: transcriptionQueue.currentBackgroundTranscriptionWorkSnapshot)
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

    // recordQueuedTranscriptionRuntimeDiagnosticsIfSafe,
    // clearQueuedTranscriptionRuntimeDiagnosticsIfOwned,
    // canStartQueuedTranscriptionImmediately(snapshot:),
    // hasVisibleBackgroundTranscriptionWork(snapshot:),
    // handleBackgroundTranscriptionWorkChanged, popNextQueuedTranscriptionJob,
    // and finalizeBackgroundTranscriptionStateIfNeeded moved to
    // TranscriptionQueueCoordinator.swift (audit 2026-07-08 wave 2, W2-B).

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

    func boolString(_ value: Bool) -> String {
        value ? "true" : "false"
    }

    /// Recomputes and assigns the published failed-meeting list. Kept on the
    /// controller (rather than moved wholesale) because `failedMeetings` is
    /// `@Published` here — the store computes the list, the controller owns
    /// the publish.
    func refreshFailedMeetings(_ updatedFailedTranscriptions: [FailedTranscription]? = nil) {
        failedMeetings = failedMeetingStore.refreshFailedMeetings(updatedFailedTranscriptions)
    }
}
