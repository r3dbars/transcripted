import Foundation

public enum SpeakerPeopleReviewPolicy {
    public static func needsReview(profile: SpeakerProfile, duplicateIds: Set<UUID>) -> Bool {
        duplicateIds.contains(profile.id)
            || !hasDisplayName(profile)
            || profile.disputeCount > 0
    }

    public static func sortedForPeopleSettings(
        _ profiles: [SpeakerProfile],
        duplicateIds: Set<UUID>
    ) -> [SpeakerProfile] {
        profiles.sorted { lhs, rhs in
            let lhsNeedsReview = needsReview(profile: lhs, duplicateIds: duplicateIds)
            let rhsNeedsReview = needsReview(profile: rhs, duplicateIds: duplicateIds)
            if lhsNeedsReview != rhsNeedsReview {
                return lhsNeedsReview && !rhsNeedsReview
            }

            let lhsNamed = hasDisplayName(lhs)
            let rhsNamed = hasDisplayName(rhs)
            if lhsNamed != rhsNamed { return !lhsNamed && rhsNamed }
            if lhs.callCount != rhs.callCount { return lhs.callCount > rhs.callCount }
            return lhs.lastSeen > rhs.lastSeen
        }
    }

    private static func hasDisplayName(_ profile: SpeakerProfile) -> Bool {
        profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
