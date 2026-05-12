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
        if !parakeet.isReady {
            await parakeet.initialize()
        }
        if !diarization.isReady {
            await diarization.initialize()
        }

        guard parakeet.isReady else {
            throw PipelineError.modelNotLoaded(model: parakeet.transcriptionEngineDescriptor.displayName)
        }
        guard diarization.isReady else {
            throw PipelineError.modelNotLoaded(model: "Diarization")
        }
    }
}
