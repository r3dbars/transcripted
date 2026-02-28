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

    /// Unique speaker IDs in system audio (for Gemini speaker identification)
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
