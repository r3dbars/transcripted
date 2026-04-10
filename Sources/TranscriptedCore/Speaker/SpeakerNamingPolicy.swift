import Foundation

/// Maps speaker labels to identified names from voice fingerprint matching.
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

enum SpeakerNamingPolicy {
    static func shouldAutoAccept(profile: SpeakerProfile, similarity: Double) -> Bool {
        profile.displayName != nil
            && similarity > 0.88
            && profile.callCount > 4
    }

    static func confidence(similarity: Double, callCount: Int) -> SpeakerConfidence {
        similarity > 0.85 && callCount > 3 ? .high : .medium
    }

    static func initialMapping(
        speakerId: String,
        profile: SpeakerProfile,
        similarity: Double
    ) -> SpeakerMapping {
        guard shouldAutoAccept(profile: profile, similarity: similarity),
              let name = profile.displayName,
              !name.isEmpty else {
            return SpeakerMapping(speakerId: speakerId)
        }

        return SpeakerMapping(
            speakerId: speakerId,
            identifiedName: name,
            confidence: confidence(similarity: similarity, callCount: profile.callCount),
            isConfirmedIdentity: true
        )
    }
}
