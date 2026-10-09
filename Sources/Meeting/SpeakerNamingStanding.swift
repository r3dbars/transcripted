import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// How far one saved person is toward a full voice print (one ring per
/// confirmed meeting) in Settings › Speakers, as plain values the UI can draw. Meeting computes it
/// because profile health reads the match-outcome store, which Settings
/// may not name; `SpeakerSettingsStore.namingStandings(for:)` reads that off
/// the main actor with the rest of the Speakers snapshot.
struct SpeakerNamingStanding: Equatable, Sendable {
    let tier: SpeakerNamingTier
    /// `SpeakerProfileHealth` is trusted: no open dispute or recent correction.
    let isTrusted: Bool
    let confirmedMeetings: Int
    let requiredMeetings: Int

    /// Nil for a voice with no name yet: unnamed voices get an empty print.
    /// `recentOutcomes` is most-recent-first, as the outcome store returns it.
    static func of(
        _ profile: SpeakerProfile,
        recentOutcomes: [SpeakerMatchOutcomeKind],
        requiredMeetings: Int = SpeakerNamingPolicy.requiredConfirmedMeetings
    ) -> SpeakerNamingStanding? {
        let name = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { return nil }
        let confirmed = max(0, profile.confirmedMeetingCount)
        let isTrusted = SpeakerProfileHealth.assess(
            disputeCount: profile.disputeCount,
            recentOutcomes: recentOutcomes
        ) == .trusted
        return SpeakerNamingStanding(
            tier: SpeakerNamingTier.tier(
                confirmedMeetings: confirmed,
                requiredMeetings: requiredMeetings,
                isTrusted: isTrusted
            ),
            isTrusted: isTrusted,
            confirmedMeetings: confirmed,
            requiredMeetings: requiredMeetings
        )
    }
}
