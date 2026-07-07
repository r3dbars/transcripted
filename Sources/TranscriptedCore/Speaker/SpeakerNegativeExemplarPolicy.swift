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

    /// How far to transport a rejected sample along one of a profile's observed condition shifts when
    /// deriving a cross-condition negative representation (see the transported `maxNegativeSimilarity`
    /// overload). `1.0` moves the rejected sample by one full observed shift (e.g. clean → the telephone
    /// offset the owner's own exemplars exhibit); `0.75` is a mild transport that lifts cross-condition
    /// veto coverage on real degraded audio while keeping owner-collateral flat (tuned on
    /// `SpeakerExemplarDeltaEvalTests`).
    public static let crossConditionTransportScale: Double = 0.75

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

    /// Cross-condition negative similarity: the max cosine of `embedding` against each stored negative
    /// exemplar **and** against each negative *transported* along the profile's own observed condition
    /// shifts.
    ///
    /// The positive side already fixed the condition gap with multi-exemplar voiceprints — a returning
    /// owner is scored against its best-fitting capture condition, not one blended centroid. The
    /// negative side had no analog: a single rejected in-room sample and a later telephone/VoIP sample
    /// of the *same* rejected impostor sit too far apart in embedding space for the raw cosine to clear
    /// the veto floor, so a correction made in one condition failed to protect the owner in another
    /// (see `docs/speaker-eval-exemplar-delta-2026-07.md`, "regime-limited"). This gives the negative
    /// side the same multi-condition treatment.
    ///
    /// Channel/condition shifts (clean → compressed remote → telephone) are largely speaker-independent,
    /// and the profile has already *observed* several of them as the offset between each of its positive
    /// exemplars and its blended average (`positiveExemplar − average`). Transporting a rejected sample
    /// by `crossConditionTransportScale ×` one of those offsets synthesizes "the same rejected voice, in
    /// a condition this profile has actually seen", so a cross-condition return of that impostor still
    /// resembles one derived negative ≥ the floor.
    ///
    /// It is deliberately conservative and owner-safe:
    ///   - **Only real, forward shifts.** Transport is along `+(exemplar − average)` — conditions the
    ///     profile genuinely exhibits — never arbitrary directions. A profile with **no** positive
    ///     exemplars (single-condition, e.g. a one-utterance profile) derives nothing and this reduces
    ///     *exactly* to `maxNegativeSimilarity`, so those profiles are byte-for-byte unchanged.
    ///   - **The owner gate is untouched.** Callers still require the resulting similarity to clear the
    ///     0.80 floor *and* beat the candidate's own positive similarity (`shouldVeto`), so a genuine
    ///     owner — closer to its own fingerprint than to a transported *impostor* sample — is never
    ///     vetoed. Transport widens which *impostor* returns are caught; it does not relax the floor.
    public static func maxNegativeSimilarity(
        _ embedding: [Float],
        negativeExemplars: [[Float]],
        profileAverage: [Float],
        positiveExemplars: [[Float]]
    ) -> Double {
        guard !embedding.isEmpty else { return -1 }

        // Baseline: raw resemblance to any stored negative (identical to the two-arg overload).
        var best = maxNegativeSimilarity(embedding, negativeExemplars: negativeExemplars)

        // Observed condition shifts: unit(exemplar) − average, for each same-dimension positive
        // exemplar. Empty ⇒ no transport ⇒ `best` is exactly the raw negative similarity above.
        let shifts = conditionShifts(average: profileAverage, positiveExemplars: positiveExemplars)
        guard !shifts.isEmpty else { return best }

        for exemplar in negativeExemplars where exemplar.count == embedding.count {
            let base = SpeakerVectorMath.l2Normalize(exemplar)
            for shift in shifts where shift.count == base.count {
                var transported = base
                for i in 0..<transported.count {
                    transported[i] += Float(crossConditionTransportScale) * shift[i]
                }
                best = max(best, SpeakerVectorMath.cosineSimilarity(embedding, transported))
            }
        }
        return best
    }

    /// The profile's observed condition-shift directions: `unit(exemplar) − average` for each
    /// same-dimension positive exemplar. `average` is already the L2-normalized blended fingerprint;
    /// exemplars are normalized here so a shift is a pure direction between two unit representatives.
    private static func conditionShifts(
        average: [Float],
        positiveExemplars: [[Float]]
    ) -> [[Float]] {
        guard !average.isEmpty else { return [] }
        var shifts: [[Float]] = []
        for exemplar in positiveExemplars where exemplar.count == average.count {
            let unit = SpeakerVectorMath.l2Normalize(exemplar)
            var shift = unit
            for i in 0..<shift.count {
                shift[i] -= average[i]
            }
            shifts.append(shift)
        }
        return shifts
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

    /// Cross-condition-aware veto: same rule as above, but the negative similarity is computed with
    /// condition transport (see `maxNegativeSimilarity(_:negativeExemplars:profileAverage:positiveExemplars:)`),
    /// so a rejected impostor returning in a different audio condition the profile has seen is still
    /// caught. The owner gate is unchanged — the floor and the `≥ positiveSimilarity` comparison still
    /// protect the genuine returning owner — so a profile with no positive exemplars, or a candidate
    /// that resembles its own fingerprint more than any (transported) rejected sample, behaves exactly
    /// as the raw overload. Used by the matchers, which have the profile's average and exemplars in hand.
    public static func shouldVeto(
        candidate embedding: [Float],
        positiveSimilarity: Double,
        negativeExemplars: [[Float]],
        profileAverage: [Float],
        positiveExemplars: [[Float]]
    ) -> Bool {
        guard !negativeExemplars.isEmpty else { return false }
        let negativeSimilarity = maxNegativeSimilarity(
            embedding,
            negativeExemplars: negativeExemplars,
            profileAverage: profileAverage,
            positiveExemplars: positiveExemplars
        )
        return shouldVeto(positiveSimilarity: positiveSimilarity, negativeSimilarity: negativeSimilarity)
    }
}
