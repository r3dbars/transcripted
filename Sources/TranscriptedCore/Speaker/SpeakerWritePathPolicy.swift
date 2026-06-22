import Foundation

/// Write-path quality gates for the speaker subsystem.
///
/// The certified naming ladder (`SpeakerNamingPolicy.shouldAutoAccept`, 0.92 similarity / margin
/// 0.12) gates only the *display* decision — whether a returning speaker is silently NAMED. It
/// does **not** gate the two write-path decisions that quietly mutate persistent state:
///
///   1. **Voiceprint write-back** — every successful match EMA-blends the session mean into the
///      stored fingerprint (`SpeakerDatabase.addOrUpdateSpeaker`). With no quality gate a mature,
///      named profile blends a weak/ambiguous match straight into its identity, drifting it
///      permanently, compounding across meetings, invisible to the user. `voiceprintBlendAlpha`
///      is the gate: confident, well-separated matches adapt at the full historical rate; marginal
///      matches adapt slowly; weak or ambiguous matches *freeze* the voiceprint (alpha 0 — the
///      appearance is still recorded via call-count / last-seen, but the fingerprint is untouched).
///
///   2. **Cross-cluster link/merge** — when two diarizer clusters match the *same* profile they are
///      fused into a single transcript row. The adaptive 0.70 floor that ATTACHES a cluster's
///      utterances to a profile is too loose to *also* decide two clusters are the SAME person: two
///      distinct people who each merely resemble one profile get silently fused, and review then
///      names the fused row once. `shouldFuseMatchedClusters` decouples this — clusters only fuse
///      when they are directly similar *to each other* (cross-cluster cosine ≥ `crossClusterLinkFloor`),
///      which is what genuine over-segmentation of one voice looks like; distinct voices stay
///      separate and independently nameable.
///
/// Every threshold here is deliberately decoupled from the display ladder and is meant to be tuned
/// on the SpeakerEvalHarness (DER / fragmentation / false-merge / cross-meeting re-ID), **not** on
/// the auto-name bar. Raising the display bar must never silently change the write path, and a
/// write-path change must never trade silent contamination for silent under-adaptation — both are
/// observable only on the harness.
public enum SpeakerWritePathPolicy {

    // MARK: - #6 Voiceprint write-back gate

    /// Full adaptation rate — matches `SpeakerDatabase`'s historical EMA weight. Used for a
    /// confident, clearly-separated match writing back into the stored fingerprint.
    public static let confidentBlendAlpha: Float = 0.15

    /// Reduced rate for a decent-but-not-strong match: still tracks genuine session-to-session
    /// voice drift, but bounds how far any single mediocre session can pull the fingerprint.
    public static let cautiousBlendAlpha: Float = 0.05

    /// No adaptation — record the appearance (call-count / last-seen) but freeze the voiceprint.
    public static let frozenBlendAlpha: Float = 0.0

    /// Minimum margin to the runner-up before a match is trusted to *write back*. Reuses the
    /// certified ladder's margin (`SpeakerNamingPolicy.autoAcceptMarginMin`) but applies it to the
    /// write decision the ladder does not cover. The read-side match guard only rejects runner-ups
    /// within 0.05 (ambiguous), so a match in [0.05, 0.12) is still NAMED but must not CONTAMINATE.
    public static let writeBackMarginMin: Double = 0.12

    /// At or above this cosine a match adapts the fingerprint at the full rate. Deliberately below
    /// the 0.92 *display* auto-name bar so legitimate drift keeps the profile current — using the
    /// display bar here would freeze adaptation and trade contamination for under-adaptation.
    public static let confidentWriteBackSimilarity: Double = 0.80

    /// Between this and `confidentWriteBackSimilarity` a match adapts slowly. Below it, it freezes.
    public static let cautiousWriteBackSimilarity: Double = 0.72

    /// EMA weight to blend a matched session embedding into the persisted voiceprint.
    ///
    /// - Parameters:
    ///   - similarity: cosine of the session mean to the matched profile.
    ///   - secondBestSimilarity: next-closest profile that cleared the match floor, or `nil`/negative
    ///     when there was no confusable runner-up (treated as unambiguous).
    /// - Returns: `confidentBlendAlpha`, `cautiousBlendAlpha`, or `frozenBlendAlpha`.
    public static func voiceprintBlendAlpha(
        similarity: Double,
        secondBestSimilarity: Double?
    ) -> Float {
        // Ambiguity guard: a runner-up almost as close means we cannot be sure WHO this is, so
        // blending would risk contaminating the wrong profile. Freeze regardless of similarity.
        if let second = secondBestSimilarity, second >= 0,
           (similarity - second) < writeBackMarginMin {
            return frozenBlendAlpha
        }
        if similarity >= confidentWriteBackSimilarity { return confidentBlendAlpha }
        if similarity >= cautiousWriteBackSimilarity { return cautiousBlendAlpha }
        return frozenBlendAlpha
    }

    // MARK: - #8 Cross-cluster link/merge floor

    /// Minimum *cross-cluster* cosine (cluster-to-cluster, not cluster-to-profile) required to fuse
    /// two diarizer clusters that matched the same profile into one row. Stricter than the loosest
    /// per-utterance attach floor (0.70) so two distinct people who each merely resemble one profile
    /// are not silently merged, but below the within-meeting same-voice consolidation bar
    /// (`EmbeddingClusterer.sameVoiceConsolidationThreshold`, 0.88) so genuine over-segmented
    /// fragments of one voice that survived consolidation still fuse.
    public static let crossClusterLinkFloor: Double = 0.78

    /// Whether two clusters that matched the same profile are similar enough *to each other* to be
    /// the same person (genuine de-fragmentation) rather than two distinct people who both resemble
    /// the profile.
    public static func shouldFuseMatchedClusters(crossClusterSimilarity: Double) -> Bool {
        crossClusterSimilarity >= crossClusterLinkFloor
    }
}
