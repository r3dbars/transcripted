import Foundation
@preconcurrency import AVFoundation
import Accelerate

/// Maps speaker labels to identified names from voice fingerprint matching
public struct SpeakerMapping {
    public let speakerId: String           // "0", "1", "2" for speaker IDs
    public var identifiedName: String?     // "John Smith" or nil if unidentified
    public var confidence: SpeakerConfidence?
    public var isConfirmedIdentity: Bool

    /// Display name used in persisted artifacts.
    /// Suggested identities remain generic until the user confirms them.
    public var displayName: String {
        if isConfirmedIdentity, let name = identifiedName {
            return name
        }
        return "Speaker \(speakerId)"
    }

    public var suggestedName: String? {
        guard !isConfirmedIdentity else { return nil }
        return identifiedName
    }

    public init(
        speakerId: String,
        identifiedName: String? = nil,
        confidence: SpeakerConfidence? = nil,
        isConfirmedIdentity: Bool = false
    ) {
        self.speakerId = speakerId
        self.identifiedName = identifiedName
        self.confidence = confidence
        self.isConfirmedIdentity = isConfirmedIdentity
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
        guard !hasInitialized else {
            AppLogger.transcription.debug("Models already initialized, skipping")
            return
        }
        hasInitialized = true
        await parakeet.initialize()
        await diarization.initialize()
    }
}
