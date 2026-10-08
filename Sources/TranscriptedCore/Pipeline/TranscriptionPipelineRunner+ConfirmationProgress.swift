import Foundation

// MARK: - Review rows: progress toward silent naming

extension TranscriptionTaskManager {

    /// Adds `confirmationProgress` to each "Is this …?" row so the review can
    /// say how close that person is to being named on its own. The count is
    /// the person's distinct confirmed meetings before this review; the bar is
    /// the one this meeting's auto-accept gate used for them: the lower lineup
    /// bar when their name is on a live meeting's lineup, else
    /// `SpeakerNamingPolicy.requiredConfirmedMeetings` (imports never have a
    /// lineup). Rows already at or past the bar, and rows that ask for a name,
    /// get no progress.
    nonisolated static func withConfirmationProgress(
        _ entries: [SpeakerNamingEntry],
        profile: (UUID) -> SpeakerProfile?,
        invited invitedNameKeys: Set<String>,
        fromInvite lineupIsFromInvite: Bool,
        thresholds: SpeakerEmbeddingThresholds
    ) -> [SpeakerNamingEntry] {
        entries.map { entry in
            var entry = entry
            entry.confirmationProgress = nil
            let name = entry.currentName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard entry.needsConfirmation, !name.isEmpty, let saved = profile(entry.id) else { return entry }
            let required = SpeakerNamingPolicy.inviteeBars(
                for: saved,
                invitedNameKeys: invitedNameKeys,
                lineupIsFromInvite: lineupIsFromInvite,
                thresholds: thresholds
            )?.requiredConfirmedMeetings ?? SpeakerNamingPolicy.requiredConfirmedMeetings
            guard required > 0, saved.confirmedMeetingCount < required else { return entry }
            entry.confirmationProgress = SpeakerNamingConfirmationProgress(
                confirmedMeetings: max(0, saved.confirmedMeetingCount),
                requiredMeetings: required
            )
            return entry
        }
    }
}
