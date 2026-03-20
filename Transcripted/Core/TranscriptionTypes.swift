// TranscriptionTypes.swift
// Engine-agnostic transcription result types.
// Engine-agnostic types for local Parakeet + Sortformer transcription pipeline.

import Foundation

/// A single utterance in the transcript (one speaker saying something)
struct TranscriptionUtterance {
    let start: Double           // seconds
    let end: Double             // seconds
    let channel: Int            // 0 = mic, 1 = system
    let speakerId: Int          // from Sortformer (0 for mic unless multiple mic speakers)
    let persistentSpeakerId: UUID?  // from SpeakerDatabase (nil if not matched)
    let matchSimilarity: Double?    // cosine similarity from SpeakerDatabase match (nil if new/unmatched)
    let transcript: String      // text from Parakeet
}

/// Complete transcription result from the local pipeline
struct TranscriptionResult {
    let micUtterances: [TranscriptionUtterance]
    let systemUtterances: [TranscriptionUtterance]
    let duration: TimeInterval
    let processingTime: TimeInterval
    let droppedSegments: Int

    init(micUtterances: [TranscriptionUtterance], systemUtterances: [TranscriptionUtterance], duration: TimeInterval, processingTime: TimeInterval, droppedSegments: Int = 0) {
        self.micUtterances = micUtterances
        self.systemUtterances = systemUtterances
        self.duration = duration
        self.processingTime = processingTime
        self.droppedSegments = droppedSegments
    }

    /// All utterances merged and sorted by start time
    var allUtterances: [TranscriptionUtterance] {
        (micUtterances + systemUtterances).sorted { $0.start < $1.start }
    }

    var micUtteranceCount: Int { micUtterances.count }
    var systemUtteranceCount: Int { systemUtterances.count }

    /// Word count estimates (split by whitespace)
    var micWordCount: Int {
        micUtterances.reduce(0) { $0 + $1.transcript.split(separator: " ").count }
    }

    var systemWordCount: Int {
        systemUtterances.reduce(0) { $0 + $1.transcript.split(separator: " ").count }
    }

    /// Unique speaker IDs in system audio
    var systemSpeakerIds: Set<String> {
        Set(systemUtterances.map { String($0.speakerId) })
    }

    /// Speaker count per channel
    var micSpeakerCount: Int {
        Set(micUtterances.map { $0.speakerId }).count
    }

    var systemSpeakerCount: Int {
        Set(systemUtterances.map { $0.speakerId }).count
    }

    /// Persistent speaker IDs that appeared in system audio utterances.
    /// Profiles are looked up separately via SpeakerDatabase.
    var persistentSpeakerIds: Set<UUID> {
        Set(systemUtterances.compactMap { $0.persistentSpeakerId })
    }
}

// MARK: - Pipeline Errors

/// Typed errors for the transcription pipeline.
/// Replaces stringly-typed NSError so retry logic can make structured decisions.
enum PipelineError: LocalizedError {
    // Audio errors (permanent — bad data won't improve on retry)
    case emptyAudioFile
    case recordingTooShort(duration: TimeInterval)
    case invalidAudioFormat(detail: String)

    // Permission errors (permanent until user acts)
    case missingSystemAudio

    // Model errors (transient — reload may fix)
    case modelNotLoaded(model: String)
    case modelInferenceFailed(model: String, underlying: String)

    // Storage errors (transient — disk space may free up)
    case saveFailed(detail: String)

    // Wrapped unknown error (transient by default)
    case unknown(underlying: String)

    var errorDescription: String? {
        switch self {
        case .emptyAudioFile:
            return "Empty audio file — no samples recorded."
        case .recordingTooShort(let duration):
            return "Recording too short (\(String(format: "%.1f", duration))s). At least 2 seconds required."
        case .invalidAudioFormat(let detail):
            return "Invalid audio format: \(detail)"
        case .missingSystemAudio:
            return "System audio is required. Please grant Screen Recording permission in System Settings."
        case .modelNotLoaded(let model):
            return "\(model) model not loaded"
        case .modelInferenceFailed(let model, let underlying):
            return "\(model) inference failed: \(underlying)"
        case .saveFailed(let detail):
            return "Failed to save transcript: \(detail)"
        case .unknown(let underlying):
            return underlying
        }
    }

    /// Whether this error could succeed on retry.
    /// Audio data errors are permanent. Model/storage errors may be transient.
    var isRetryable: Bool {
        switch self {
        case .emptyAudioFile, .recordingTooShort, .invalidAudioFormat, .missingSystemAudio:
            return false
        case .modelNotLoaded, .modelInferenceFailed, .saveFailed, .unknown:
            return true
        }
    }
}

/// Speaker confidence level from voice fingerprint matching
enum SpeakerConfidence: String, Codable {
    case high
    case medium
}

/// Result of Qwen speaker name inference on transcript text
enum QwenInferenceResult {
    case notAttempted
    case noNameFound
    case suggested(name: String)
}

/// Result of speaker identification from voice fingerprint matching
struct SpeakerIdentificationResult: Codable {
    let speakers: [IdentifiedSpeaker]
    let userSpeakerId: String?
}

/// Individual speaker identified in the call
struct IdentifiedSpeaker: Codable {
    let name: String
    let speakerId: String?
    let confidence: SpeakerConfidence
    let evidence: String
}

/// Metadata about the transcription engines used
struct TranscriptionMetadata {
    let transcriptionEngine: String     // "parakeet_local"
    let diarizationEngine: String       // "pyannote_offline"
    let micWordCount: Int
    let systemWordCount: Int
    let micSpeakerCount: Int
    let systemSpeakerCount: Int
    let duration: Double
}

// MARK: - Speaker Naming Flow Types

/// Request to show the speaker naming UI after transcription completes
struct SpeakerNamingRequest {
    let speakers: [SpeakerNamingEntry]
    let transcriptURL: URL
    let systemAudioURL: URL
    let micAudioURL: URL
    let onComplete: ([SpeakerNameUpdate]) -> Void
}

/// A single speaker needing naming or confirmation
struct SpeakerNamingEntry: Identifiable {
    let id: UUID                     // persistent speaker ID from SpeakerDatabase
    let sortformerSpeakerId: String  // "0", "1" — for transcript string matching
    let clipURL: URL                 // temporary WAV clip for playback
    let sampleText: String           // representative quote from transcript
    let currentName: String?         // nil if unknown speaker
    let matchSimilarity: Double?     // cosine similarity score
    let needsNaming: Bool            // true = unknown speaker (show text field)
    let needsConfirmation: Bool      // true = known but low confidence (show confirm/deny)
    let qwenResult: QwenInferenceResult  // result of Qwen name inference
}

/// Result of user naming/confirming a speaker
struct SpeakerNameUpdate {
    let persistentSpeakerId: UUID
    let sortformerSpeakerId: String
    let newName: String
    let action: NamingAction

    enum NamingAction {
        case named      // user typed a name for unknown speaker
        case confirmed  // user confirmed suggested name
        case corrected  // user rejected suggestion and typed correct name
        case merged(targetProfileId: UUID)  // user linked this speaker to an existing profile
    }
}
