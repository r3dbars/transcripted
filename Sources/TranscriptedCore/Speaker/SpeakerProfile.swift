import Foundation

/// Source values for SpeakerProfile.nameSource
public enum NameSource {
    public static let userManual = "user_manual"
}

/// A persistent speaker profile with voice fingerprint
public struct SpeakerProfile: Identifiable, Sendable {
    public let id: UUID
    public var displayName: String?        // "Nate", "Travis", or nil if unnamed
    public var nameSource: String?         // NameSource.userManual or nil
    public var embedding: [Float]          // 256-dim average voice vector
    /// Additional representative voiceprints ("exemplars") for this person, beyond the blended
    /// `embedding` average — e.g. one for clean in-person mic and one for compressed remote audio.
    /// Empty for legacy single-average profiles, which then match exactly as before. Matching scores
    /// a candidate against the best-fitting exemplar (see `SpeakerVectorMath.bestSimilarity`).
    /// Populated as a read-side cache when profiles are loaded from `SpeakerDatabase`; the
    /// authoritative rows live in the `speaker_exemplars` table.
    public var exemplars: [[Float]]
    public var firstSeen: Date
    public var lastSeen: Date
    public var callCount: Int
    public var confidence: Double          // Improves with more data points
    public var disputeCount: Int           // Times inference disagreed with DB name

    public init(
        id: UUID,
        displayName: String?,
        nameSource: String?,
        embedding: [Float],
        firstSeen: Date,
        lastSeen: Date,
        callCount: Int,
        confidence: Double,
        disputeCount: Int,
        exemplars: [[Float]] = []
    ) {
        self.id = id
        self.displayName = displayName
        self.nameSource = nameSource
        self.embedding = embedding
        self.exemplars = exemplars
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.callCount = callCount
        self.confidence = confidence
        self.disputeCount = disputeCount
    }
}

/// Result of matching an embedding against the speaker database
public struct SpeakerMatchResult: Sendable {
    public let profile: SpeakerProfile
    public let similarity: Double          // Cosine similarity score (0.0–1.0)

    public init(profile: SpeakerProfile, similarity: Double) {
        self.profile = profile
        self.similarity = similarity
    }
}
