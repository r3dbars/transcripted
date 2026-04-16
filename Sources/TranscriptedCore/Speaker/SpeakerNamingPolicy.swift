import Foundation

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
