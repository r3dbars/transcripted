import Foundation
@preconcurrency import AVFoundation
import Accelerate

/// Maps speaker labels to identified names from voice fingerprint matching
public struct SpeakerMapping {
    public let speakerId: String           // "0", "1", "2" for speaker IDs
    public var identifiedName: String?     // "John Smith" or nil if unidentified
    public var confidence: SpeakerConfidence?

    /// Display name: uses identified name if available, otherwise "Speaker X"
    public var displayName: String {
        if let name = identifiedName {
            return confidence == .medium ? "\(name)?" : name
        }
        return "Speaker \(speakerId)"
    }

    public init(speakerId: String, identifiedName: String? = nil, confidence: SpeakerConfidence? = nil) {
        self.speakerId = speakerId
        self.identifiedName = identifiedName
        self.confidence = confidence
    }
}

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

    public init(
        speechToText: any SpeechToTextEngine,
        diarization: any DiarizationEngine,
        speakerStore: any SpeakerStore
    ) {
        self.parakeet = speechToText
        self.diarization = diarization
        self.speakerDB = speakerStore
    }

    private var hasInitialized = false

    /// Initialize local models. Call once at app startup.
    public func initializeModels() async {
        guard !hasInitialized else {
            AppLogger.transcription.debug("Models already initialized, skipping")
            return
        }
        hasInitialized = true
        await parakeet.initialize()
        await diarization.initialize()
    }
}
