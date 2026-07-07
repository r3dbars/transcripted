import Foundation

/// Multi-exemplar voiceprint maintenance (additive to the single running-average fingerprint).
///
/// A person's clean in-person mic and their compressed remote/Zoom mic produce systematically
/// different embeddings. Blending both into one running average (`SpeakerProfile.embedding` via the
/// EMA in `SpeakerDatabase.addOrUpdateSpeaker`) yields a mediocre centroid that fits neither
/// condition well, depressing match similarity in both. Multi-exemplar voiceprints instead keep a
/// small set of representative embeddings per person — the K most distinct-yet-confirmed session
/// means — so a returning voice is compared against the BEST-fitting exemplar rather than a single
/// blended vector (see `SpeakerVectorMath.bestSimilarity`).
///
/// This policy is pure and deterministic (no randomness, no clock) so the eval harness and unit
/// tests can exercise it directly. The profile's blended average always participates as an implicit
/// always-present representative at match time and is never stored here, so:
///   - a legacy profile with an empty exemplar set matches EXACTLY as it did before (max over the
///     single average), and
///   - a stored exemplar only ever *adds* a candidate vector, so per-profile similarity is
///     monotonically non-decreasing — the change cannot lower a true match's score.
///
/// Exemplar writes reuse the write-path quality gate: the caller only updates exemplars when the
/// matched write-back alpha is > 0 (a confident/cautious, well-separated match), so an ambiguous or
/// weak match that freezes the average can never seed or drift an exemplar either. Exemplars and the
/// average share one contamination guard.
public enum SpeakerExemplarPolicy {

    /// Maximum representative exemplars stored per profile, in addition to the blended average.
    /// Small on purpose: enough to cover the common clean-vs-compressed split (plus one) without
    /// letting a profile balloon or a stray condition dominate. Tune on the SpeakerEvalHarness.
    public static let maxExemplars = 3

    /// At or above this cosine to an existing representative (the average or a stored exemplar), a
    /// new confirmed session mean is treated as the SAME capture condition and folded into that
    /// nearest exemplar (denoise) instead of being stored as a near-duplicate. Below it, the mean is
    /// a distinct condition and earns its own exemplar slot. Mirrors
    /// `SpeakerWritePathPolicy.confidentWriteBackSimilarity` (0.80) — the point at which a match is
    /// "clearly the same voice, same context."
    public static let sameConditionSimilarity: Double = 0.80

    /// EMA weight for folding a same-condition mean into its exemplar. Higher than the profile
    /// average's 0.15 because each exemplar tracks ONE condition, so it should adapt to that
    /// condition quickly rather than lag behind it the way the all-conditions average must.
    public static let exemplarBlendAlpha: Float = 0.30

    /// One stored representative embedding plus how many session means built it.
    public struct Exemplar: Sendable, Equatable {
        public var embedding: [Float]
        public var segmentCount: Int

        public init(embedding: [Float], segmentCount: Int) {
            self.embedding = embedding
            self.segmentCount = segmentCount
        }
    }

    /// Pure update of a profile's exemplar set given a new confirmed session mean and the profile's
    /// (post-blend) average embedding.
    ///
    /// - `current`: the profile's existing exemplars (authoritative, from storage).
    /// - `newMean`: the L2-normalized session mean that just confidently matched this profile.
    /// - `average`: the profile's blended `embedding` — always an implicit representative, never
    ///   stored in `current`; passing it in lets a mean already covered by the average be dropped
    ///   rather than duplicated.
    ///
    /// Returns the new exemplar set (≤ `maxExemplars`). Diversity is non-decreasing: an eviction only
    /// happens when the incoming mean is strictly more distinct than the most-redundant existing
    /// exemplar, so the stored set never gets *less* spread.
    public static func updated(
        current: [Exemplar],
        newMean: [Float],
        average: [Float]
    ) -> [Exemplar] {
        guard !newMean.isEmpty, newMean.count == average.count else { return current }

        // Only compare against same-dimension representatives (defensive — exemplars always share
        // the profile dimension, but never mix 192-d and 256-d geometry).
        let usable = current.filter { $0.embedding.count == newMean.count }

        // Best representative already covering this mean: the average (index -1) or an exemplar.
        let simToAverage = SpeakerVectorMath.cosineSimilarity(newMean, average)
        var bestRepSim = simToAverage
        var bestExemplarIndex: Int? = nil  // nil ⇒ the average is the best representative
        for (i, exemplar) in usable.enumerated() {
            let sim = SpeakerVectorMath.cosineSimilarity(newMean, exemplar.embedding)
            if sim > bestRepSim {
                bestRepSim = sim
                bestExemplarIndex = i
            }
        }

        // Same condition as an existing representative → denoise, don't duplicate.
        if bestRepSim >= sameConditionSimilarity {
            guard let i = bestExemplarIndex else {
                // Already covered by the average (which is EMA-updated separately). Nothing to add.
                return usable
            }
            var updated = usable
            let blended = blend(updated[i].embedding, newMean, alpha: exemplarBlendAlpha)
            updated[i] = Exemplar(embedding: blended, segmentCount: updated[i].segmentCount + 1)
            return updated
        }

        // Distinct condition. Grow the set, or evict the most-redundant exemplar if it is more
        // redundant than the incoming mean is — which keeps the retained set at least as diverse.
        if usable.count < maxExemplars {
            return usable + [Exemplar(embedding: newMean, segmentCount: 1)]
        }

        let (victim, victimRedundancy) = mostRedundantExemplar(usable, average: average)
        guard let victim, victimRedundancy > bestRepSim else {
            // Incoming mean is no more distinct than what we already hold — keep the set.
            return usable
        }
        var updated = usable
        updated[victim] = Exemplar(embedding: newMean, segmentCount: 1)
        return updated
    }

    /// Index of the exemplar whose removal loses the least coverage (highest cosine to any other
    /// representative — average or another exemplar), and that redundancy value. `nil` if empty.
    private static func mostRedundantExemplar(
        _ exemplars: [Exemplar],
        average: [Float]
    ) -> (index: Int?, redundancy: Double) {
        var victim: Int? = nil
        var maxRedundancy = -Double.infinity
        for (i, exemplar) in exemplars.enumerated() {
            var redundancy = SpeakerVectorMath.cosineSimilarity(exemplar.embedding, average)
            for (j, other) in exemplars.enumerated() where j != i {
                redundancy = max(redundancy, SpeakerVectorMath.cosineSimilarity(exemplar.embedding, other.embedding))
            }
            if redundancy > maxRedundancy {
                maxRedundancy = redundancy
                victim = i
            }
        }
        return (victim, maxRedundancy)
    }

    private static func blend(_ existing: [Float], _ incoming: [Float], alpha: Float) -> [Float] {
        let a = max(0, min(1, alpha))
        let mixed = zip(existing, incoming).map { old, new in old * (1 - a) + new * a }
        return SpeakerVectorMath.l2Normalize(mixed)
    }
}
