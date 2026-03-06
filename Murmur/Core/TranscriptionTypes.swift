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

    /// Matched speaker profiles from the speaker database
    var speakerProfiles: [UUID: SpeakerProfile] {
        var profiles: [UUID: SpeakerProfile] = [:]
        for utterance in systemUtterances {
            if let id = utterance.persistentSpeakerId {
                // Profile will be looked up separately — this just tracks which IDs appeared
                profiles[id] = profiles[id] // placeholder
            }
        }
        return profiles
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
    let diarizationEngine: String       // "sortformer_local"
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
