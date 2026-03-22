import Foundation

/// A persistent speaker profile with voice fingerprint
struct SpeakerProfile: Identifiable {
    let id: UUID
    var displayName: String?        // "Nate", "Travis", or nil if unnamed
    var nameSource: String?         // "user_manual", "qwen_inferred", nil
    var embedding: [Float]          // 256-dim average voice vector
    var firstSeen: Date
    var lastSeen: Date
    var callCount: Int
    var confidence: Double          // Improves with more data points
    var disputeCount: Int           // Times inference disagreed with DB name
}

/// Result of matching an embedding against the speaker database
struct SpeakerMatchResult {
    let profile: SpeakerProfile
    let similarity: Double          // Cosine similarity score (0.0–1.0)
}
