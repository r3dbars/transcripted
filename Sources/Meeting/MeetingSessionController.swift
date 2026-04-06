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

    // Live transcription preview (dual-stream). Populated by a pair of
    // StreamingEouAsrManager-backed transcribers during recording, cleared on
    // stop. Best-effort — the authoritative transcript still comes from the
    // offline pipeline in Core's TranscriptionTaskManager.
    @Published private(set) var liveMicTranscript: String = ""
    @Published private(set) var liveSystemTranscript: String = ""

    // MARK: - Core services (owned)

    private let storagePaths: CoreStoragePaths
    let capture: MeetingCaptureBridge
    let services: AppServices
    let taskManager: TranscriptionTaskManager
    private let failedManager: FailedTranscriptionManager
    private let diarization: DiarizationService
    private let sttAdapter: MeetingSTTAdapter
    private let speakerDatabase: SpeakerDatabase
    private let downloader: MeetingModelDownloader

    // Dual-stream live preview transcribers (one per audio source).
    // Each wraps its own StreamingEouAsrManager instance (~120MB CoreML
    // model, loaded once during prepareModels()). If model discovery or
    // loading fails, these stay inert and the recording proceeds normally
    // without a live preview.
    private let micLiveTranscriber: MeetingLiveTranscriber?
    private let systemLiveTranscriber: MeetingLiveTranscriber?

    private var cancellables: Set<AnyCancellable> = []

    // MARK: - Init

    /// Construct the full Core stack with Draft storage isolation.
    ///
    /// - Parameter parakeet: Draft's existing ParakeetEngine instance. Shared
    ///   with STTRouter so we do not spin up a second AsrManager.
    init(parakeet: ParakeetEngine) {
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

        // Dual-stream live preview transcribers. We locate the EOU model
        // directory at construction time (bundled-in-app or cached in
        // ~/Library/Application Support/FluidAudio/Models). If it doesn't
        // exist yet (e.g., first launch before Draft's dictation path has
        // downloaded it), live preview stays disabled for this session;
        // recording + offline transcription still work.
        if let modelDir = Self.locateEouModelDir() {
            self.micLiveTranscriber = MeetingLiveTranscriber(source: .mic, modelDir: modelDir)
            self.systemLiveTranscriber = MeetingLiveTranscriber(source: .system, modelDir: modelDir)
        } else {
            self.micLiveTranscriber = nil
            self.systemLiveTranscriber = nil
            print("⚠️ MEETING | EOU model not found — live preview disabled for this session")
        }

        wireSubscriptions()
    }

    /// Locate the Parakeet EOU 120M model on disk. Returns nil if neither
    /// the bundled copy nor the FluidAudio cache has it. Same lookup order
    /// as ParakeetEngine.initializeEouModel() — if dictation has been run
    /// at least once, the cache will be populated.
    private static func locateEouModelDir() -> URL? {
        // 1. App bundle (shipped via build.sh)
        if let resourcePath = Bundle.main.resourcePath {
            let bundled = URL(fileURLWithPath: resourcePath)
                .appendingPathComponent("parakeet-models")
                .appendingPathComponent("parakeet-eou-120m-coreml")
            if FileManager.default.fileExists(
                atPath: bundled.appendingPathComponent("streaming_encoder.mlmodelc").path
            ) {
                return bundled
            }
        }

        // 2. FluidAudio cache (downloaded by Draft's dictation path)
        if let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first {
            let cached = appSupport
                .appendingPathComponent("FluidAudio/Models/parakeet-eou-streaming/320ms", isDirectory: true)
            if FileManager.default.fileExists(
                atPath: cached.appendingPathComponent("streaming_encoder.mlmodelc").path
            ) {
                return cached
            }
        }

        return nil
    }

    // MARK: - Public API

    /// Load STT + diarization models. Call once before the first recording.
    /// Transitions state: idle → loadingModels → ready, or → error(String).
    ///
    /// Also loads the dual-stream live-preview EOU models in parallel —
    /// these are non-fatal (a failure here keeps the meeting flow working,
    /// it just disables the live transcript preview in the expanded overlay).
    func prepareModels() async {
        state = .loadingModels
        do {
            try await downloader.ensureModelsReady()

            // Kick off live-preview model loads in parallel. We wait for
            // them so the overlay's first chunk isn't dropped, but we don't
            // propagate their errors — they're best-effort.
            await withTaskGroup(of: Void.self) { group in
                if let mic = micLiveTranscriber {
                    group.addTask { await mic.start() }
                }
                if let sys = systemLiveTranscriber {
                    group.addTask { await sys.start() }
                }
            }

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

        // Wire up live-preview buffer routing before starting capture so
        // no buffers are missed. Each transcriber's ingest is nonisolated
        // and runs on the CoreAudio capture thread — copies + resamples +
        // hands off to Task.detached internally, matching ParakeetEngine's
        // dictation streaming path.
        liveMicTranscript = ""
        liveSystemTranscript = ""
        if let mic = micLiveTranscriber {
            capture.setMicLivePreviewHandler { [weak mic] buffer in
                mic?.ingest(buffer: buffer)
            }
        }
        if let sys = systemLiveTranscriber {
            capture.setSystemLivePreviewHandler { [weak sys] buffer in
                sys?.ingest(buffer: buffer)
            }
        }

        capture.startRecording()
        state = .recording
    }

    /// Stop capture and hand off to the Core pipeline. Returns once the task
    /// has been *started* (not when it completes — observers watch
    /// `displayStatus` / `lastSavedTranscriptURL` for that).
    func stopRecording() async {
        guard case .recording = state else { return }

        // Unwire live-preview handlers before stopping capture so any
        // in-flight buffer from the audio thread can't reach a reset
        // transcriber.
        capture.setMicLivePreviewHandler(nil)
        capture.setSystemLivePreviewHandler(nil)

        let files = await capture.stopAndAwaitFiles()
        state = .transcribing

        // Clear live-preview state. The offline pipeline will produce the
        // authoritative transcript and save it to disk; the live text is
        // preview-only and doesn't need to be preserved.
        await micLiveTranscriber?.stop()
        await systemLiveTranscriber?.stop()

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
            .assign(to: &$lastSavedTranscriptURL)

        taskManager.$lastSavedTitle
            .assign(to: &$lastSavedTitle)

        // Live-preview text forwarding. Each transcriber publishes its
        // own liveText on the MainActor; we mirror it here so the meeting
        // overlay only needs to subscribe to the session controller.
        if let mic = micLiveTranscriber {
            mic.$liveText
                .assign(to: &$liveMicTranscript)
        }
        if let sys = systemLiveTranscriber {
            sys.$liveText
                .assign(to: &$liveSystemTranscript)
        }
    }
}
