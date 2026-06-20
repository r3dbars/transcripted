// SpeakerEmbeddingThresholds.swift
// Per-model cosine thresholds for the speaker identity stack. Different embedding
// models have different cosine geometry, so the matcher / clusterer thresholds
// must be model-specific. WeSpeaker (the diarizer's built-in 256-d model) keeps
// the production-tuned values; ERes2Net (192-d) uses values calibrated on AMI
// ground truth — see scripts/recalibrate_eres2net_groundtruth.py.
//
// Calibration method: for each WeSpeaker operating point we measured its true
// false-accept rate on AMI (RTTM ground truth), then chose the ERes2Net threshold
// that achieves the SAME false-accept rate. ERes2Net separates speakers far better
// cross-call (EER 0% vs WeSpeaker 5.2%; different-speaker p95 cosine 0.40 vs 0.62),
// so its thresholds are lower while *reducing* false merges and false rejects.

import Foundation

public struct SpeakerEmbeddingThresholds: Sendable, Equatable {
    /// Cross-call DB match, adaptive by how many segments backed the mean embedding
    /// (fewer segments → noisier mean → stricter threshold).
    public let matchOneSegment: Double      // 1 segment
    public let matchFewSegments: Double     // 2–3 segments
    public let matchManySegments: Double    // 4+ segments
    /// Floor for force-merging a low-quality "ghost" speaker into the closest real one.
    public let ghostMergeFloor: Double
    /// Within-meeting clustering thresholds.
    public let consolidation: Float         // merge over-segmented same-voice clusters
    public let absorb: Float                // absorb a small cluster into a large one
    public let microAbsorb: Float           // absorb a very short cluster
    public let perSegmentSplit: Float       // DB-informed split of a mixed cluster
    public let knownProfileConflict: Float  // "these centroids may be different known people"

    public init(matchOneSegment: Double, matchFewSegments: Double, matchManySegments: Double,
                ghostMergeFloor: Double, consolidation: Float, absorb: Float, microAbsorb: Float,
                perSegmentSplit: Float, knownProfileConflict: Float) {
        self.matchOneSegment = matchOneSegment
        self.matchFewSegments = matchFewSegments
        self.matchManySegments = matchManySegments
        self.ghostMergeFloor = ghostMergeFloor
        self.consolidation = consolidation
        self.absorb = absorb
        self.microAbsorb = microAbsorb
        self.perSegmentSplit = perSegmentSplit
        self.knownProfileConflict = knownProfileConflict
    }

    /// Adaptive DB-match threshold for a speaker whose mean embedding came from
    /// `count` segments.
    public func adaptiveMatch(forSegmentCount count: Int) -> Double {
        switch count {
        case 1: return matchOneSegment
        case 2...3: return matchFewSegments
        default: return matchManySegments
        }
    }

    /// WeSpeaker (256-d) — the diarizer's built-in model. Exactly the production
    /// values the matcher/clusterer used before per-model thresholds existed, so
    /// the default path is unchanged.
    public static let weSpeaker = SpeakerEmbeddingThresholds(
        matchOneSegment: 0.85, matchFewSegments: 0.78, matchManySegments: 0.70,
        ghostMergeFloor: 0.72,
        consolidation: 0.88, absorb: 0.72, microAbsorb: 0.62,
        perSegmentSplit: 0.62, knownProfileConflict: 0.70)

    /// ERes2Net (192-d) — calibrated on AMI ground truth (equal-false-accept-rate
    /// remap of the WeSpeaker operating points). Lower absolute values because
    /// ERes2Net's different-speaker cosines are much tighter.
    public static let eRes2Net = SpeakerEmbeddingThresholds(
        matchOneSegment: 0.70, matchFewSegments: 0.62, matchManySegments: 0.55,
        ghostMergeFloor: 0.55,
        consolidation: 0.65, absorb: 0.55, microAbsorb: 0.45,
        perSegmentSplit: 0.50, knownProfileConflict: 0.55)
}
