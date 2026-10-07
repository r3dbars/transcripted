import Foundation
import TranscriptedCore

/// Which saved people the Speakers page flags for review, and the order it lists
/// them in. Only Settings uses it, so it lives in Meeting rather than Core.

enum SpeakerPeopleReviewPolicy {
    static func needsReview(profile: SpeakerProfile, duplicateIds: Set<UUID>) -> Bool {
        duplicateIds.contains(profile.id)
            || !hasDisplayName(profile)
            || profile.disputeCount > 0
    }

    static func sortedForPeopleSettings(
        _ profiles: [SpeakerProfile],
        duplicateIds: Set<UUID>
    ) -> [SpeakerProfile] {
        // Work out each profile's review and named flags once, up front. The
        // comparator used to trim the display name on every comparison
        // (O(n log n) trims); the keys give the same answers in the same
        // input order, so the sort makes the same choices.
        let keyed = profiles.map { profile -> SortKey in
            let named = hasDisplayName(profile)
            return SortKey(
                needsReview: duplicateIds.contains(profile.id) || !named || profile.disputeCount > 0,
                named: named,
                profile: profile
            )
        }
        return keyed.sorted { lhs, rhs in
            if lhs.needsReview != rhs.needsReview {
                return lhs.needsReview && !rhs.needsReview
            }
            if lhs.named != rhs.named { return !lhs.named && rhs.named }
            if lhs.profile.callCount != rhs.profile.callCount {
                return lhs.profile.callCount > rhs.profile.callCount
            }
            return lhs.profile.lastSeen > rhs.profile.lastSeen
        }.map(\.profile)
    }

    private struct SortKey {
        let needsReview: Bool
        let named: Bool
        let profile: SpeakerProfile
    }

    private static func hasDisplayName(_ profile: SpeakerProfile) -> Bool {
        profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}
