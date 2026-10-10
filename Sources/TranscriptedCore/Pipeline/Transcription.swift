import Foundation
@preconcurrency import AVFoundation
import Accelerate

// MARK: - Transcription Service (Local Pipeline)

@available(macOS 14.0, *)
@MainActor
public class Transcription: ObservableObject {
    @Published public var isProcessing: Bool = false
    @Published public var error: String?
    @Published public var processingStatus: String = ""
    @Published public var lastSavedFileURL: URL?

    public let parakeet: any SpeechToTextEngine
    public let diarization: any DiarizationEngine
    public let speakerDB: any SpeakerStore
    public let speakerClipsDirectory: URL

    public init(
        speechToText: any SpeechToTextEngine,
        diarization: any DiarizationEngine,
        speakerStore: any SpeakerStore,
        speakerClipsDirectory: URL = CoreStoragePaths.default.speakerClips
    ) {
        self.parakeet = speechToText
        self.diarization = diarization
        self.speakerDB = speakerStore
        self.speakerClipsDirectory = speakerClipsDirectory
    }

    private var hasInitialized = false

    /// Transcribe an existing audio file through the meeting diarization and
    /// speaker-matching pipeline, with no microphone capture or app lifecycle.
    ///
    /// The file is treated as the sole system-audio track. This method returns
    /// the result without saving a transcript, archiving audio, or deleting the
    /// input. Hosts own those steps and must serialize calls on this instance.
    ///
    /// Speaker matching can mutate the injected `SpeakerStore`, including
    /// creating profiles and updating voiceprints. Hosts that must preserve an
    /// existing database should inject an isolated snapshot store. Model loading
    /// (including whether downloads are allowed) remains the injected engines'
    /// responsibility.
    ///
    /// File import uses the same tuned speaker-separation options as a live
    /// meeting with no calendar invite (`SpeakerSeparationOptions.tuned`), so
    /// CLI `import-audio` and the app's "Transcribe a file" path split as
    /// generously as a recorded call. Callers that need the raw diarizer
    /// labels can still pass `speakerSeparation: nil` to `transcribeMultichannel`.
    public nonisolated func transcribeAudioFile(
        at audioURL: URL,
        languageSelection: TranscriptionLanguageSelection = .automatic,
        onProgress: ((Double) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        try await ensureModelsReadyForPipeline()
        let (backend, thresholds) = await MainActor.run {
            (self.diarization.activeRunDescriptor.backend, self.diarization.activeSpeakerThresholds)
        }
        return try await transcribeMultichannel(
            micURL: nil,
            systemURL: audioURL,
            languageSelection: languageSelection,
            speakerSeparation: .tuned(for: backend, invitedPeople: nil, thresholds: thresholds),
            onProgress: onProgress
        )
    }

    /// Initialize local models. Call once at app startup.
    public func initializeModels() async {
        do {
            try await ensureModelsReadyForPipeline()
        } catch {
            AppLogger.transcription.error("Model initialization finished without ready models", [
                "error": error.localizedDescription
            ])
        }
    }

    func ensureModelsReadyForPipeline() async throws {
        let readyStart = ProcessInfo.processInfo.systemUptime
        defer {
            MeetingPipelineTimings.current?.add(
                .modelsReady,
                seconds: ProcessInfo.processInfo.systemUptime - readyStart
            )
        }
        if parakeet.isReady && diarization.isReady {
            hasInitialized = true
            AppLogger.transcription.debug("Models already initialized, skipping")
            return
        }

        if hasInitialized {
            AppLogger.transcription.warning("Reloading local transcription models before pipeline", [
                "speechReady": "\(parakeet.isReady)",
                "diarizationReady": "\(diarization.isReady)"
            ])
        }

        hasInitialized = true
        // Load both at once, like `MeetingModelDownloader` does. Each engine
        // is idempotent and owns its own progress state.
        async let speechReady: Void = Self.initializeIfNeeded(parakeet)
        async let diarizationReady: Void = Self.initializeIfNeeded(diarization)
        _ = await (speechReady, diarizationReady)

        guard parakeet.isReady else {
            throw PipelineError.modelNotLoaded(model: parakeet.transcriptionEngineDescriptor.displayName)
        }
        guard diarization.isReady else {
            throw PipelineError.modelNotLoaded(model: "Diarization")
        }
    }

    private static func initializeIfNeeded(_ engine: any SpeechToTextEngine) async {
        if !engine.isReady { await engine.initialize() }
    }

    private static func initializeIfNeeded(_ engine: any DiarizationEngine) async {
        if !engine.isReady { await engine.initialize() }
    }
}
