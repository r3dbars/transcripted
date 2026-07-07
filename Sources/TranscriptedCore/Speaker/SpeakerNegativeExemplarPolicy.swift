import Foundation

/// Read-side gate that turns a user's correction into a durable "this voice is NOT this person"
/// signal.
///
/// The positive side of the speaker subsystem answers "does this embedding *sound like* a stored
/// profile" (cosine to the profile's fingerprint clears an adaptive floor). Corrections carry the
/// complementary, explicit signal — the user looked at a suggestion and said *no*. Today that
/// signal only freezes the wrongly-suggested profile (dispute count) and teaches the correct one;
/// the rejected embedding itself is discarded. `SpeakerNegativeExemplarStore` persists that
/// rejected embedding as a *negative exemplar* against the profile it was wrongly matched to, and
/// this policy decides when a later embedding is close enough to a rejected sample to be excluded
/// from re-matching that same profile.
///
/// It is deliberately an **additional** gate, orthogonal to the positive floors, the maturity
/// bonus, the ambiguity separation check, and the write-path contamination gate. It only ever
/// *removes* a profile from candidacy — it never lowers a floor or promotes a match — so it can
/// only make matching more conservative, never less. A profile with no negative exemplars behaves
/// exactly as before.
///
/// Composability note: negative exemplars ("explicitly not this person") are the mirror image of
/// the positive multi-exemplar voiceprint work ("sounds like this person"). They compose cleanly —
/// a candidate is scored against a profile's positive fingerprint(s) as usual, and this gate then
/// vetoes the profile if the candidate resembles one of that profile's rejected samples at least as
/// much as it resembles the profile itself.
public enum SpeakerNegativeExemplarPolicy {

    /// A candidate this close (cosine) to a previously-rejected sample is treated as "probably that
    /// rejected voice again". Set high — near the strictest positive match floors — so only a strong
    /// resemblance to an *explicitly rejected* sample can veto. Coincidental similarity never fires.
    public static let vetoFloor: Double = 0.80

    /// Highest cosine similarity between `embedding` and any of a profile's negative exemplars.
    /// Dimension-mismatched exemplars are skipped (same guard the positive matchers use), and an
    /// empty list yields `-1` (no signal), so a profile without negative exemplars never vetoes.
    public static func maxNegativeSimilarity(
        _ embedding: [Float],
        negativeExemplars: [[Float]]
    ) -> Double {
        guard !embedding.isEmpty else { return -1 }
        var best = -1.0
        for exemplar in negativeExemplars where exemplar.count == embedding.count {
            best = max(best, SpeakerVectorMath.cosineSimilarity(embedding, exemplar))
        }
        return best
    }

    /// Whether a candidate embedding should be excluded from matching a profile because it too
    /// closely resembles a sample the user already rejected for that profile.
    ///
    /// Vetoes only when the candidate resembles a rejected sample **(a)** above an absolute floor
    /// *and* **(b)** at least as much as it resembles the profile's own fingerprint. Condition (b) is
    /// what protects the genuine returning owner: their voice is, by definition, closer to their own
    /// fingerprint than to a *different* voice that was corrected off the profile, so `negativeSimilarity
    /// < positiveSimilarity` and no veto fires. The target case — the *same* wrongly-matched voice
    /// returning — has `negativeSimilarity ≈ 1.0`, far above `positiveSimilarity`, so it is reliably
    /// vetoed. There is deliberately no margin/handicap that could drop a legitimate (if marginal)
    /// owner match and spawn a duplicate profile.
    ///
    /// - Parameters:
    ///   - positiveSimilarity: cosine of the candidate to the profile's fingerprint (the score the
    ///     positive floors already accepted).
    ///   - negativeSimilarity: `maxNegativeSimilarity` of the candidate against the profile's
    ///     rejected samples, or a negative value when the profile has no usable negative exemplars.
    /// - Returns: `true` to drop the profile from candidacy entirely (best *and* runner-up).
    public static func shouldVeto(
        positiveSimilarity: Double,
        negativeSimilarity: Double
    ) -> Bool {
        guard negativeSimilarity >= vetoFloor else { return false }
        return negativeSimilarity >= positiveSimilarity
    }

    /// Convenience: fetch-and-decide against a profile's raw negative exemplars in one call, used by
    /// the matchers so the veto rule lives in exactly one place.
    public static func shouldVeto(
        candidate embedding: [Float],
        positiveSimilarity: Double,
        negativeExemplars: [[Float]]
    ) -> Bool {
        guard !negativeExemplars.isEmpty else { return false }
        let negativeSimilarity = maxNegativeSimilarity(embedding, negativeExemplars: negativeExemplars)
        return shouldVeto(positiveSimilarity: positiveSimilarity, negativeSimilarity: negativeSimilarity)
    }
}
