import Foundation

/// Orders review-sheet entries so the most informative question comes first.
///
/// A confirm/deny on a doubtful suggestion teaches the matcher the most — it
/// is exactly the case the auto-accept gates could not decide — so suggested
/// matches sort first, lowest similarity first. Unknown voices (enrollment)
/// follow, and everything else keeps its original order. The sort is stable
/// so equal-priority rows never jump around between sessions.
public enum SpeakerReviewPrioritizer {
    public static func ranked(_ entries: [SpeakerNamingEntry]) -> [SpeakerNamingEntry] {
        entries.enumerated()
            .sorted { lhs, rhs in
                let lhsScore = score(lhs.element)
                let rhsScore = score(rhs.element)
                if lhsScore != rhsScore { return lhsScore < rhsScore }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func score(_ entry: SpeakerNamingEntry) -> Double {
        if entry.needsConfirmation {
            // Doubtful suggestions first: lower similarity = more informative answer.
            // Similarity lives in [0, 1], so suggestions always sort ahead of the
            // fixed scores below.
            return entry.matchSimilarity ?? 1.0
        }
        return entry.needsNaming ? 2.0 : 3.0
    }
}
