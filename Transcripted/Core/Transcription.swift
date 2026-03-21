import Foundation
@preconcurrency import AVFoundation
import Accelerate

/// Maps speaker labels to identified names from voice fingerprint matching
struct SpeakerMapping {
    let speakerId: String           // "0", "1", "2" for speaker IDs
    var identifiedName: String?     // "John Smith" or nil if unidentified
    var confidence: SpeakerConfidence?

    /// Display name: uses identified name if available, otherwise "Speaker X"
    var displayName: String {
        if let name = identifiedName {
            return confidence == .medium ? "\(name)?" : name
        }
        return "Speaker \(speakerId)"
    }

    init(speakerId: String, identifiedName: String? = nil, confidence: SpeakerConfidence? = nil) {
        self.speakerId = speakerId
        self.identifiedName = identifiedName
        self.confidence = confidence
    }
}

// MARK: - Transcription Service (Local Pipeline)

@available(macOS 26.0, *)
@MainActor
class Transcription: ObservableObject {
    @Published var isProcessing: Bool = false
    @Published var error: String?
    @Published var processingStatus: String = ""
    @Published var lastSavedFileURL: URL?

    let parakeet: ParakeetService
    let diarization: DiarizationService
    let speakerDB: SpeakerDatabase

    init() {
        self.parakeet = ParakeetService()
        self.diarization = DiarizationService()
        self.speakerDB = SpeakerDatabase.shared
    }

    private var hasInitialized = false

    /// Initialize local models. Call once at app startup.
    func initializeModels() async {
        guard !hasInitialized else {
            AppLogger.transcription.debug("Models already initialized, skipping")
            return
        }
        hasInitialized = true
        await parakeet.initialize()
        await diarization.initialize()
    }
}
