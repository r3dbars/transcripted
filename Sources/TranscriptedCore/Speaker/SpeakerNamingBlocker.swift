import Foundation

/// One reason a matched person wasn't named silently. `SpeakerNamingPolicy.silentNamingBlockers`
/// lists them for a match; the list is empty exactly when `shouldAutoAccept` (no lineup bars)
/// is true, so explaining a numbered speaker can never disagree with the decision itself.
public enum SpeakerNamingBlocker: Sendable, Equatable {
    /// The matched profile has no name.
    case unnamed
    /// Confirmed in `have` distinct meetings; silent naming needs `need`.
    case needsConfirmations(have: Int, need: Int)
    /// Recent corrections or a dispute put the profile on probation.
    case recentCorrections
    /// Best similarity is not above the model's silent-naming bar.
    case similarityBelowBar(similarity: Double, bar: Double)
    /// The runner-up wasn't recorded (utterance-only fallback), so the margin is unknown.
    case runnerUpUnknown
    /// Another saved person scored too close.
    case runnerUpTooClose(margin: Double, needed: Double)
}

extension SpeakerNamingPolicy {
    /// Every silent-naming gate this match fails, in a stable order: name, confirmations,
    /// health, similarity, margin. Mirrors the no-lineup `shouldAutoAccept` exactly (a Core
    /// test checks the two agree); imports never use lineup bars.
    public static func silentNamingBlockers(
        profile: SpeakerProfile,
        similarity: Double,
        secondBestSimilarity: Double?,
        recentOutcomes: [SpeakerMatchOutcomeKind],
        marginSimilarities: (best: Double, secondBest: Double)? = nil,
        thresholds: SpeakerEmbeddingThresholds = .weSpeaker
    ) -> [SpeakerNamingBlocker] {
        var blockers: [SpeakerNamingBlocker] = []
        if profile.displayName?.isEmpty != false {
            blockers.append(.unnamed)
        }
        if profile.confirmedMeetingCount < requiredConfirmedMeetings {
            blockers.append(.needsConfirmations(have: profile.confirmedMeetingCount, need: requiredConfirmedMeetings))
        }
        if SpeakerProfileHealth.assess(disputeCount: profile.disputeCount, recentOutcomes: recentOutcomes) != .trusted {
            blockers.append(.recentCorrections)
        }
        if !(similarity > thresholds.autoAcceptSimilarity) {
            blockers.append(.similarityBelowBar(similarity: similarity, bar: thresholds.autoAcceptSimilarity))
        }
        let marginTop = marginSimilarities?.best ?? similarity
        let runnerUp: Double? = marginSimilarities.map { $0.secondBest } ?? secondBestSimilarity
        switch runnerUp {
        case .none:
            blockers.append(.runnerUpUnknown)
        case .some(let second) where second < 0:
            break
        case .some(let second):
            let margin = marginTop - second
            if !(margin >= thresholds.autoAcceptMarginMin) {
                blockers.append(.runnerUpTooClose(margin: margin, needed: thresholds.autoAcceptMarginMin))
            }
        }
        return blockers
    }
}
