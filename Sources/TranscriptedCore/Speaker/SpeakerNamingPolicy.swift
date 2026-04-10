import Foundation

/// Maps speaker labels to identified names from voice fingerprint matching.
public struct SpeakerMapping: Sendable {
    public let speakerId: String           // "0", "1", "2" for speaker IDs
    public var identifiedName: String?     // "John Smith" or nil if unidentified
    public var confidence: SpeakerConfidence?

    /// Display name: uses identified name if available, otherwise "Speaker X"
    public var displayName: String {
        if let name = identifiedName {
            return confidence == .medium ? "\(name)?" : name
        }
        return "Speaker \(speakerId)"
    }

    public init(speakerId: String, identifiedName: String? = nil, confidence: SpeakerConfidence? = nil) {
        self.speakerId = speakerId
        self.identifiedName = identifiedName
        self.confidence = confidence
    }
}

enum SpeakerNamingPolicy {
    static func shouldAutoAccept(profile: SpeakerProfile, similarity: Double) -> Bool {
        profile.displayName != nil
            && profile.disputeCount == 0
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
            // Keep the diarizer label until the user explicitly confirms the suggestion.
            return SpeakerMapping(speakerId: speakerId)
        }

        return SpeakerMapping(
            speakerId: speakerId,
            identifiedName: name,
            confidence: confidence(similarity: similarity, callCount: profile.callCount)
        )
    }
}
