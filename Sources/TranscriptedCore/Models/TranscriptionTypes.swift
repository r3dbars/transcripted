// TranscriptionTypes.swift
// Engine-agnostic transcription result types.
// Engine-agnostic types for local Parakeet + Sortformer transcription pipeline.

import Foundation

/// A single utterance in the transcript (one speaker saying something)
public struct TranscriptionUtterance: Sendable {
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
public struct TranscriptionResult: Sendable {
    public let micUtterances: [TranscriptionUtterance]
    public let systemUtterances: [TranscriptionUtterance]
    public let systemSpeakerContexts: [String: ChannelSpeakerContext]
    public let micSpeakerContexts: [String: ChannelSpeakerContext]
    public let newlyCreatedMicProfileIds: Set<UUID>
    public let duration: TimeInterval
    public let processingTime: TimeInterval
    public let droppedSegments: Int

    public init(
        micUtterances: [TranscriptionUtterance],
        systemUtterances: [TranscriptionUtterance],
        systemSpeakerContexts: [String: ChannelSpeakerContext] = [:],
        micSpeakerContexts: [String: ChannelSpeakerContext] = [:],
        newlyCreatedMicProfileIds: Set<UUID> = [],
        duration: TimeInterval,
        processingTime: TimeInterval,
        droppedSegments: Int = 0
    ) {
        self.micUtterances = micUtterances
        self.systemUtterances = systemUtterances
        self.systemSpeakerContexts = systemSpeakerContexts
        self.micSpeakerContexts = micSpeakerContexts
        self.newlyCreatedMicProfileIds = newlyCreatedMicProfileIds
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

    /// Unique speaker IDs in mic audio (only meaningful when mic diarization ran)
    public var micSpeakerIds: Set<String> {
        Set(micUtterances.map { String($0.speakerId) })
    }

    /// Speaker count per channel
    public var micSpeakerCount: Int {
        Set(micUtterances.map { $0.speakerId }).count
    }

    public var systemSpeakerCount: Int {
        Set(systemUtterances.map { $0.speakerId }).count
    }

    /// Persistent speaker IDs that appeared in utterances, across both channels.
    /// Profiles are looked up separately via SpeakerDatabase.
    public var persistentSpeakerIds: Set<UUID> {
        Set((systemUtterances + micUtterances).compactMap { $0.persistentSpeakerId })
    }

    /// Persistent speaker IDs seen only on the mic channel this run.
    public var micPersistentSpeakerIds: Set<UUID> {
        Set(micUtterances.compactMap { $0.persistentSpeakerId })
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
            return "System audio is required. Please grant System Audio Recording permission in System Settings."
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
public enum SpeakerConfidence: String, Codable, Sendable {
    case high
    case medium
}

/// Individual speaker identified in the call
public struct IdentifiedSpeaker: Codable, Sendable {
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

/// Which audio channel a diarized speaker came from.
/// Remote participants come in on `.system` (Zoom/Teams/etc. output captured via process tap).
/// People physically in the room come in on `.mic` when local diarization is enabled.
public enum UtteranceChannel: String, Sendable, Hashable {
    case mic
    case system

    /// Canonical key for speaker maps keyed by channel + diarizer ID (e.g. "system_0", "mic_2").
    func speakerKey(diarizerSpeakerId: String) -> String {
        "\(rawValue)_\(diarizerSpeakerId)"
    }
}

/// A named person the user can link a detected speaker to.
public struct SpeakerIdentityOption: Identifiable, Hashable {
    public let id: UUID
    public let displayName: String
    public let callCount: Int

    public init(id: UUID, displayName: String, callCount: Int) {
        self.id = id
        self.displayName = displayName
        self.callCount = callCount
    }
}

/// Request to show the speaker naming UI after transcription completes
public struct SpeakerNamingRequest {
    public let speakers: [SpeakerNamingEntry]
    public let knownPeople: [SpeakerIdentityOption]
    public let transcriptURL: URL
    public let systemAudioURL: URL
    public let micAudioURL: URL?
    public let shouldRemoveTemporaryAudioOnCleanup: Bool
    public let sourceFailedTranscriptionId: UUID?
    public let onComplete: ([SpeakerNameUpdate]) -> Void

    public init(
        speakers: [SpeakerNamingEntry],
        knownPeople: [SpeakerIdentityOption] = [],
        transcriptURL: URL,
        transcriptId: UUID,
        systemAudioURL: URL,
        micAudioURL: URL?,
        shouldRemoveTemporaryAudioOnCleanup: Bool = true,
        sourceFailedTranscriptionId: UUID? = nil,
        onComplete: @escaping ([SpeakerNameUpdate]) -> Void
    ) {
        self.speakers = speakers
        self.knownPeople = knownPeople
        self.transcriptURL = transcriptURL
        self.transcriptId = transcriptId
        self.systemAudioURL = systemAudioURL
        self.micAudioURL = micAudioURL
        self.shouldRemoveTemporaryAudioOnCleanup = shouldRemoveTemporaryAudioOnCleanup
        self.sourceFailedTranscriptionId = sourceFailedTranscriptionId
        self.onComplete = onComplete
    }

    public let transcriptId: UUID
}

/// A single speaker needing naming or confirmation
public struct SpeakerNamingEntry: Identifiable, Sendable {
    public let id: UUID                     // persistent speaker ID from SpeakerDatabase
    public let suggestedProfileId: UUID?    // existing person this row suggests, if any
    public let diarizerSpeakerId: String    // "0", "1" — from PyAnnote/Sortformer, for transcript string matching
    public let channel: UtteranceChannel    // .mic (local) vs .system (remote)
    public let clipURL: URL                 // temporary WAV clip for playback
    public let sampleText: String           // representative quote from transcript
    public let currentName: String?         // nil if unknown speaker
    public let matchSimilarity: Double?     // cosine similarity score
    public let callCount: Int               // how many times this profile has been seen
    public let needsNaming: Bool            // true = unknown speaker (show text field)
    public let needsConfirmation: Bool      // true = known but low confidence (show confirm/deny)
    public let sessionEmbedding: [Float]?   // mean embedding from the current meeting
    public let matchedProfileSnapshot: SpeakerProfile? // pre-meeting DB profile for correction rollback

    public init(
        id: UUID,
        suggestedProfileId: UUID? = nil,
        diarizerSpeakerId: String,
        channel: UtteranceChannel = .system,
        clipURL: URL,
        sampleText: String,
        currentName: String?,
        matchSimilarity: Double?,
        callCount: Int = 0,
        needsNaming: Bool,
        needsConfirmation: Bool,
        sessionEmbedding: [Float]? = nil,
        matchedProfileSnapshot: SpeakerProfile? = nil
    ) {
        self.id = id
        self.suggestedProfileId = suggestedProfileId
        self.diarizerSpeakerId = diarizerSpeakerId
        self.channel = channel
        self.clipURL = clipURL
        self.sampleText = sampleText
        self.currentName = currentName
        self.matchSimilarity = matchSimilarity
        self.callCount = callCount
        self.needsNaming = needsNaming
        self.needsConfirmation = needsConfirmation
        self.sessionEmbedding = sessionEmbedding
        self.matchedProfileSnapshot = matchedProfileSnapshot
    }
}

/// Per-speaker context captured during one transcription run for one channel.
/// Keeps enough information around to safely recover from a false-positive match.
public struct ChannelSpeakerContext: Sendable {
    public let persistentSpeakerId: UUID
    public let sessionEmbedding: [Float]?
    public let matchedProfileSnapshot: SpeakerProfile?
    public let matchSimilarity: Double?

    public init(
        persistentSpeakerId: UUID,
        sessionEmbedding: [Float]?,
        matchedProfileSnapshot: SpeakerProfile?,
        matchSimilarity: Double?
    ) {
        self.persistentSpeakerId = persistentSpeakerId
        self.sessionEmbedding = sessionEmbedding
        self.matchedProfileSnapshot = matchedProfileSnapshot
        self.matchSimilarity = matchSimilarity
    }
}

/// Result of user naming/confirming a speaker
public struct SpeakerNameUpdate: Sendable {
    public let persistentSpeakerId: UUID
    public let diarizerSpeakerId: String
    public let channel: UtteranceChannel
    public let newName: String
    public let previousName: String?
    public let action: NamingAction
    public let resolvedPersistentSpeakerId: UUID?

    public init(
        persistentSpeakerId: UUID,
        diarizerSpeakerId: String,
        channel: UtteranceChannel = .system,
        newName: String,
        previousName: String? = nil,
        action: NamingAction,
        resolvedPersistentSpeakerId: UUID? = nil
    ) {
        self.persistentSpeakerId = persistentSpeakerId
        self.diarizerSpeakerId = diarizerSpeakerId
        self.channel = channel
        self.newName = newName
        self.previousName = previousName
        self.action = action
        self.resolvedPersistentSpeakerId = resolvedPersistentSpeakerId
    }

    public enum NamingAction: Sendable {
        case named      // user typed a name for unknown speaker
        case confirmed  // user confirmed suggested name
        case corrected  // user rejected suggestion and typed correct name
        case merged(targetProfileId: UUID)  // user linked this speaker to an existing profile
        case collapsedToMe  // user clicked "Keep as You" — collapse this mic speaker into the single owner
        case discardedFromDatabase  // user kept this review row out of the speaker database
    }
}
