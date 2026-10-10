import SwiftUI
import TranscriptedCore

/// The review stack's naming helpers: who to offer as one-tap names, and
/// naming a voice from the list by picking someone already saved.
extension SpeakerPeopleSettingsViewModel {
    /// Saved people still learning (named, not yet named on their own, no
    /// recent correction), the closest to a full print first, so picking one
    /// for a voice is a yes that moves them along. At most `limit`.
    func savedPeopleStillLearning(excluding names: [String], limit: Int = 2) -> [SpeakerProfile] {
        let skip = Set(names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        return profiles
            .compactMap { profile -> (SpeakerProfile, SpeakerNamingStanding)? in
                guard let standing = namingStanding(for: profile),
                      standing.tier != .auto, standing.isTrusted,
                      let name = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !skip.contains(name.lowercased())
                else { return nil }
                return (profile, standing)
            }
            .sorted { $0.1.confirmedMeetings > $1.1.confirmedMeetings }
            .prefix(max(0, limit))
            .map(\.0)
    }

    /// The saved person a name belongs to, when exactly one has it.
    func uniqueSavedPerson(named name: String, excluding id: UUID) -> SpeakerProfile? {
        SpeakerNameSelectionPolicy.uniqueSavedPerson(
            named: name,
            among: profiles,
            excluding: id,
            id: \.id,
            displayName: \.displayName
        )
    }

    /// Whether an unnamed voice in the list can join a saved person the way
    /// its review card would (it still has a queued meeting to confirm).
    func canJoinSavedPerson(_ voice: SpeakerProfile) -> Bool {
        SpeakerReviewStack.reviewItemForRename(of: voice, in: reviewQueueItems) != nil
    }

    /// An unnamed voice in the list joins `person`, exactly as picking them
    /// on its review card does: each queued meeting records a confirmation
    /// for them. Their print in the list then plays the match animation.
    func joinSavedPerson(_ voice: SpeakerProfile, into person: SpeakerProfile,
                         completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        guard let item = SpeakerReviewStack.reviewItemForRename(of: voice, in: reviewQueueItems) else {
            completion?(false)
            return
        }
        let personID = person.id
        mergePendingReviewItem(item, into: person) { [weak self] didSave in
            if didSave { self?.celebrate(personID) }
            completion?(didSave)
        }
    }
}
