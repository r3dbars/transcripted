// TranscriptionTypes.swift
// Engine-agnostic transcription result types.
// Engine-agnostic types for local Parakeet + Sortformer transcription pipeline.

import Foundation

/// A single utterance in the transcript (one speaker saying something)
public struct TranscriptionUtterance {
    public let start: Double           // seconds
    public let end: Double             // seconds
    public let channel: Int            // 0 = mic, 1 = system
    public let speakerId: Int          // from Sortformer (0 for mic unless multiple mic speakers)
    public let persistentSpeakerId: UUID?  // from SpeakerDatabase (nil if not matched)
    public let matchSimilarity: Double?    // cosine similarity from SpeakerDatabase match (nil if new/unmatched)
    public let transcript: String      // text from Parakeet

    public init(
        start: Double,
        end: Double,
        channel: Int,
        speakerId: Int,
        persistentSpeakerId: UUID?,
        matchSimilarity: Double?,
        transcript: String
    ) {
        self.start = start
        self.end = end
        self.channel = channel
        self.speakerId = speakerId
        self.persistentSpeakerId = persistentSpeakerId
        self.matchSimilarity = matchSimilarity
        self.transcript = transcript
    }
}

/// Complete transcription result from the local pipeline
public struct TranscriptionResult {
    public let micUtterances: [TranscriptionUtterance]
    public let systemUtterances: [TranscriptionUtterance]
    public let duration: TimeInterval
    public let processingTime: TimeInterval
    public let droppedSegments: Int

    public init(micUtterances: [TranscriptionUtterance], systemUtterances: [TranscriptionUtterance], duration: TimeInterval, processingTime: TimeInterval, droppedSegments: Int = 0) {
        self.micUtterances = micUtterances
        self.systemUtterances = systemUtterances
        self.duration = duration
        self.processingTime = processingTime
        self.droppedSegments = droppedSegments
    }

    /// All utterances merged and sorted by start time
    public var allUtterances: [TranscriptionUtterance] {
        (micUtterances + systemUtterances).sorted { $0.start < $1.start }
    }

    public var micUtteranceCount: Int { micUtterances.count }
    public var systemUtteranceCount: Int { systemUtterances.count }

    /// Word count estimates (split by whitespace)
    public var micWordCount: Int {
        micUtterances.reduce(0) { $0 + $1.transcript.split(separator: " ").count }
    }

    public var systemWordCount: Int {
        systemUtterances.reduce(0) { $0 + $1.transcript.split(separator: " ").count }
    }

    /// Unique speaker IDs in system audio
    public var systemSpeakerIds: Set<String> {
        Set(systemUtterances.map { String($0.speakerId) })
    }

    /// Speaker count per channel
    public var micSpeakerCount: Int {
        Set(micUtterances.map { $0.speakerId }).count
    }

    public var systemSpeakerCount: Int {
        Set(systemUtterances.map { $0.speakerId }).count
    }

    /// Persistent speaker IDs that appeared in system audio utterances.
    /// Profiles are looked up separately via SpeakerDatabase.
    public var persistentSpeakerIds: Set<UUID> {
        Set(systemUtterances.compactMap { $0.persistentSpeakerId })
    }
}

// MARK: - Pipeline Errors

/// Typed errors for the transcription pipeline.
/// Replaces stringly-typed NSError so retry logic can make structured decisions.
public enum PipelineError: LocalizedError {
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

    public var errorDescription: String? {
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
    public var isRetryable: Bool {
        switch self {
        case .emptyAudioFile, .recordingTooShort, .invalidAudioFormat, .missingSystemAudio:
            return false
        case .modelNotLoaded, .modelInferenceFailed, .saveFailed, .unknown:
            return true
        }
    }
}

/// Speaker confidence level from voice fingerprint matching
public enum SpeakerConfidence: String, Codable {
    case high
    case medium
}

/// Individual speaker identified in the call
public struct IdentifiedSpeaker: Codable {
    public let name: String
    public let speakerId: String?
    public let confidence: SpeakerConfidence
    public let evidence: String

    public init(name: String, speakerId: String?, confidence: SpeakerConfidence, evidence: String) {
        self.name = name
        self.speakerId = speakerId
        self.confidence = confidence
        self.evidence = evidence
    }
}

/// Metadata about the transcription engines used
public struct TranscriptionMetadata {
    public let transcriptionEngine: String     // "parakeet_local"
    public let diarizationEngine: String       // "pyannote_offline"
    public let micWordCount: Int
    public let systemWordCount: Int
    public let micSpeakerCount: Int
    public let systemSpeakerCount: Int
    public let duration: Double

    public init(
        transcriptionEngine: String,
        diarizationEngine: String,
        micWordCount: Int,
        systemWordCount: Int,
        micSpeakerCount: Int,
        systemSpeakerCount: Int,
        duration: Double
    ) {
        self.transcriptionEngine = transcriptionEngine
        self.diarizationEngine = diarizationEngine
        self.micWordCount = micWordCount
        self.systemWordCount = systemWordCount
        self.micSpeakerCount = micSpeakerCount
        self.systemSpeakerCount = systemSpeakerCount
        self.duration = duration
    }
}

// MARK: - Speaker Naming Flow Types

/// Request to show the speaker naming UI after transcription completes
public struct SpeakerNamingRequest {
    public let speakers: [SpeakerNamingEntry]
    public let transcriptURL: URL
    public let systemAudioURL: URL
    public let micAudioURL: URL
    public let onComplete: ([SpeakerNameUpdate]) -> Void

    public init(
        speakers: [SpeakerNamingEntry],
        transcriptURL: URL,
        systemAudioURL: URL,
        micAudioURL: URL,
        onComplete: @escaping ([SpeakerNameUpdate]) -> Void
    ) {
        self.speakers = speakers
        self.transcriptURL = transcriptURL
        self.systemAudioURL = systemAudioURL
        self.micAudioURL = micAudioURL
        self.onComplete = onComplete
    }
}

/// A single speaker needing naming or confirmation
public struct SpeakerNamingEntry: Identifiable {
    public let id: UUID                     // persistent speaker ID from SpeakerDatabase
    public let sortformerSpeakerId: String  // "0", "1" — for transcript string matching
    public let clipURL: URL                 // temporary WAV clip for playback
    public let sampleText: String           // representative quote from transcript
    public let currentName: String?         // nil if unknown speaker
    public let matchSimilarity: Double?     // cosine similarity score
    public let needsNaming: Bool            // true = unknown speaker (show text field)
    public let needsConfirmation: Bool      // true = known but low confidence (show confirm/deny)

    public init(
        id: UUID,
        sortformerSpeakerId: String,
        clipURL: URL,
        sampleText: String,
        currentName: String?,
        matchSimilarity: Double?,
        needsNaming: Bool,
        needsConfirmation: Bool
    ) {
        self.id = id
        self.sortformerSpeakerId = sortformerSpeakerId
        self.clipURL = clipURL
        self.sampleText = sampleText
        self.currentName = currentName
        self.matchSimilarity = matchSimilarity
        self.needsNaming = needsNaming
        self.needsConfirmation = needsConfirmation
    }
}

/// Result of user naming/confirming a speaker
public struct SpeakerNameUpdate {
    public let persistentSpeakerId: UUID
    public let sortformerSpeakerId: String
    public let newName: String
    public let action: NamingAction

    public init(
        persistentSpeakerId: UUID,
        sortformerSpeakerId: String,
        newName: String,
        action: NamingAction
    ) {
        self.persistentSpeakerId = persistentSpeakerId
        self.sortformerSpeakerId = sortformerSpeakerId
        self.newName = newName
        self.action = action
    }

    public enum NamingAction {
        case named      // user typed a name for unknown speaker
        case confirmed  // user confirmed suggested name
        case corrected  // user rejected suggestion and typed correct name
        case merged(targetProfileId: UUID)  // user linked this speaker to an existing profile
    }
}
