// MeetingSessionController.swift
// Top-level @MainActor ObservableObject that wires TranscriptedCore into Draft.
// Owns Core's DI container (AppServices), the capture bridge, the task manager,
// and the model downloader. Exposes @Published state for Draft's meeting UI to
// bind against.
//
// Boot sequence:
//   1. init() constructs all Core services with Draft-flavored CoreStoragePaths
//      so transcripts, speakers DB, stats DB, failed-queue, clips, and logs all
//      live under ~/Library/Application Support/Draft/meetings/.
//   2. prepareModels() loads Parakeet + PyAnnote/WeSpeaker/Sortformer. Safe to
//      call multiple times — each engine is idempotent.
//   3. startRecording() begins capture via MeetingCaptureBridge.
//   4. stopRecording() awaits capture files, hands them to Core's
//      TranscriptionTaskManager, which runs the full diarize→transcribe→save
//      pipeline and writes a .md to MeetingStoragePaths.transcriptsFolder.
//
// The session controller does NOT own a hotkey or UI — Lane C (meeting-ui)
// wires those up.

import Combine
import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class MeetingSessionController: ObservableObject {
    struct ModelWarmupStatus: Equatable {
        let title: String
        let subtitle: String
        let detail: String
        let progress: Double
        let dictationStatus: String
        let meetingsStatus: String

        static let ready = ModelWarmupStatus(
            title: "Draft is ready",
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
        let subtitle: String
        let isRetryable: Bool
    }

    // MARK: - Published state (for meeting UI bindings)

    /// High-level session state for the meeting UI.
    enum State: Equatable {
        case idle                // Models not loaded, no recording
        case loadingModels       // ensureModelsReady() in flight
        case ready               // Models loaded, ready to record
        case recording           // Capture in progress
        case transcribing        // Recording stopped, pipeline running
        case error(String)       // Fatal error — see message
    }

    @Published private(set) var state: State = .idle

    // Pass-throughs for UI convenience (updated via Combine subscriptions below).
    @Published private(set) var isRecording: Bool = false
    @Published private(set) var audioLevel: Float = 0          // mic-only level
    @Published private(set) var systemLevel: Float = 0         // system audio level
    @Published private(set) var recordingDuration: TimeInterval = 0
    @Published private(set) var displayStatus: DisplayStatus = .idle
    @Published private(set) var lastSavedTranscriptURL: URL? = nil
    @Published private(set) var lastSavedTitle: String? = nil

    @Published private(set) var failedMeetings: [FailedMeetingItem] = []
    @Published private(set) var warmupStatus: ModelWarmupStatus = .ready

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
    private let downloader: MeetingModelDownloader

    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Init

    /// Construct the full Core stack with Draft storage isolation.
    ///
    /// - Parameter parakeet: Draft's existing ParakeetEngine instance. Shared
    ///   with STTRouter so we do not spin up a second AsrManager.
    init(parakeet: ParakeetEngine) {
        self.parakeetEngine = parakeet
        // Ensure the Draft meetings directory exists on disk before anyone
        // tries to write to it. MeetingStoragePaths.root is idempotent.
        _ = MeetingStoragePaths.root

        // Build a Draft-flavored CoreStoragePaths. Every Core component that
        // accepts a `paths:` parameter gets this instance so nothing leaks to
        // ~/Documents/Transcripted.
        self.storagePaths = CoreStoragePaths(
            transcripts: MeetingStoragePaths.transcriptsFolder,
            speakerDB: MeetingStoragePaths.speakersDatabase,
            statsDB: MeetingStoragePaths.root.appendingPathComponent("stats.sqlite"),
            failedQueue: MeetingStoragePaths.root.appendingPathComponent("failed_transcriptions.json"),
            speakerClips: MeetingStoragePaths.speakerClipsFolder,
            audioCaptures: MeetingStoragePaths.recordingsScratch,
            logs: FileManager.default.draftAppSupportDir
                .appendingPathComponent("logs", isDirectory: true)
        )

        // Capture bridge owns an `Audio` instance with our storage paths so
        // raw mic/system WAV captures land in the Draft scratch folder.
        self.capture = MeetingCaptureBridge(audio: Audio(paths: storagePaths))

        // STT: wrap Draft's ParakeetEngine in the Core-facing adapter.
        self.sttAdapter = MeetingSTTAdapter(engine: parakeet)

        // Diarization: Core's concrete DiarizationService already conforms to
        // DiarizationEngine via an empty extension (see DiarizationService.swift).
        self.diarization = DiarizationService()

        // Speaker store: Draft-owned SQLite file under meetings/.
        self.speakerDatabase = SpeakerDatabase(path: storagePaths.speakerDB.path)

        // Failed-queue manager: takes CoreStoragePaths so its JSON file lives
        // under our meetings directory, not ~/Documents/Transcripted.
        // TODO: Phase 2 ships without failed-transcription recovery for meeting
        // mode — we construct the manager because TranscriptionTaskManager
        // requires it, but nothing in Draft currently drains the failed queue
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
            speakerStore: services.speakerStore
        )

        // Model downloader — coordinates Parakeet + PyAnnote readiness.
        self.downloader = MeetingModelDownloader(stt: sttAdapter, diarization: diarization)

        wireSubscriptions()
    }

    // MARK: - Public API

    /// Load STT + diarization models. Call once before the first recording.
    /// Transitions state: idle → loadingModels → ready, or → error(String).
    ///
    func prepareModels() async {
        state = .loadingModels
        do {
            try await downloader.ensureModelsReady()

            state = .ready
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    /// Begin a new meeting recording. Requires `state == .ready` (or .idle —
    /// in which case we load models first). Safe to call from UI buttons.
    func startRecording() async {
        if state == .idle {
            await prepareModels()
            guard case .ready = state else { return }
        }
        guard case .ready = state else { return }

        capture.startRecording()
        state = .recording
    }

    /// Stop capture and hand off to the Core pipeline. Returns once the task
    /// has been *started* (not when it completes — observers watch
    /// `displayStatus` / `lastSavedTranscriptURL` for that).
    func stopRecording() async {
        guard case .recording = state else { return }

        let files = await capture.stopAndAwaitFiles()
        state = .transcribing

        guard let micURL = files.micURL else {
            state = .error("No microphone audio was captured.")
            return
        }

        taskManager.startTranscription(
            micURL: micURL,
            systemURL: files.systemURL,
            outputFolder: storagePaths.transcripts,
            healthInfo: capture.healthInfo()
        )
    }

    /// Cancel any in-progress pipeline. Does not cancel an active recording —
    /// use stopRecording() for that.
    func cancelActiveTranscription() {
        taskManager.cancelAll()
        state = .ready
    }

    func retryFailedMeeting(id: UUID) {
        Task {
            let succeeded = await taskManager.retryFailedTranscription(failedId: id)
            if succeeded {
                refreshFailedMeetings()
            }
        }
    }

    func dismissFailedMeeting(id: UUID) {
        failedManager.removeFailedTranscription(id: id)
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

        taskManager.$displayStatus
            .sink { [weak self] status in
                guard let self else { return }
                self.displayStatus = status
                // Pipeline completion: reset state to .ready for next meeting.
                if case .transcribing = self.state {
                    switch status {
                    case .transcriptSaved:
                        self.state = .ready
                    case .failed(let message):
                        self.state = .error(message)
                    default:
                        break
                    }
                }
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

        if case .ready = dictationState, case .ready = meetingState {
            warmupStatus = .ready
            return
        }

        switch dictationState {
        case .downloading(let progress):
            warmupStatus = ModelWarmupStatus(
                title: "Getting Draft ready",
                subtitle: "Downloading the dictation model",
                detail: "This can take a minute or two on first launch.",
                progress: max(0.08, min(0.62, 0.08 + progress * 0.54)),
                dictationStatus: "Downloading \(Int(progress * 100))%",
                meetingsStatus: "Waiting"
            )
        case .loading:
            warmupStatus = ModelWarmupStatus(
                title: "Getting Draft ready",
                subtitle: "Preparing dictation",
                detail: "Loading the local voice model into memory.",
                progress: 0.68,
                dictationStatus: "Loading",
                meetingsStatus: "Waiting"
            )
        case .failed(let message):
            warmupStatus = ModelWarmupStatus(
                title: "Couldn’t load Draft",
                subtitle: "The dictation model failed to load",
                detail: message,
                progress: 0,
                dictationStatus: "Failed",
                meetingsStatus: "Waiting"
            )
        case .ready:
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
                    title: "Getting Draft ready",
                    subtitle: "Loading meeting transcription",
                    detail: "Preparing speaker diarization and meeting understanding.",
                    progress: 0.86,
                    dictationStatus: "Ready",
                    meetingsStatus: "Loading"
                )
            case .notLoaded:
                warmupStatus = ModelWarmupStatus(
                    title: "Getting Draft ready",
                    subtitle: "Preparing meeting transcription",
                    detail: "Setting up speaker diarization and meeting transcription.",
                    progress: 0.76,
                    dictationStatus: "Ready",
                    meetingsStatus: "Starting"
                )
            }
        case .notLoaded:
            warmupStatus = ModelWarmupStatus(
                title: "Getting Draft ready",
                subtitle: "Preparing dictation",
                detail: "Loading dictation and meeting models.",
                progress: 0.05,
                dictationStatus: "Starting",
                meetingsStatus: "Waiting"
            )
        }
    }

    private func refreshFailedMeetings() {
        failedMeetings = failedManager.failedTranscriptions
            .sorted(by: { $0.timestamp > $1.timestamp })
            .map { failed in
                FailedMeetingItem(
                    id: failed.id,
                    timestamp: failed.timestamp,
                    title: failedMeetingTitle(for: failed),
                    subtitle: failedMeetingSubtitle(for: failed),
                    isRetryable: failed.isRetryable
                )
            }
    }

    private func failedMeetingTitle(for failed: FailedTranscription) -> String {
        let message = failed.errorMessage.lowercased()

        if message.contains("system audio is required") || message.contains("screen recording") {
            return "Turn on Screen Recording"
        }

        if message.contains("recording too short") || message.contains("at least") {
            return "Recording was too short"
        }

        if message.contains("no samples recorded") || message.contains("empty audio") {
            return "No audio was captured"
        }

        if message.contains("failed to save") {
            return "Couldn't save the transcript"
        }

        return failed.isRetryable ? "Transcript needs retry" : "Recording needs attention"
    }

    private func failedMeetingSubtitle(for failed: FailedTranscription) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "MMM d 'at' h:mm a"

        let dateText = formatter.string(from: failed.timestamp)
        if failed.audioFilesExist() {
            return "\(dateText) • Audio kept"
        }
        return dateText
    }
}
