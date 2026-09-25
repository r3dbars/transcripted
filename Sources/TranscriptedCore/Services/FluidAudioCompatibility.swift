// FluidAudioCompatibility.swift
// Keeps the FluidAudio 0.15.x -> 0.17 upgrade from changing what shipped:
// the pyannote model cache, and the tuned offline diarizer config.

import Foundation
@preconcurrency import FluidAudio

public enum FluidAudioCompatibility {

    /// Hugging Face repo that holds the pyannote segmentation / WeSpeaker / PLDA
    /// models (the offline pipeline) and the online WeSpeaker model.
    public static let diarizerRepoPath = "FluidInference/speaker-diarization-coreml"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var didKeepUnpinnedDiarizerCaches = false

    /// FluidAudio 0.17 pins the diarizer repo to one immutable commit and treats
    /// any cache folder without a matching `.fluidaudio-revision` marker as stale:
    /// it deletes the folder and downloads again. Every cache 0.15.x wrote has no
    /// marker, and neither does the `offline-diarizer-models` copy the release build
    /// bundles into the app. Deleting that bundled copy would break the app's code
    /// signature, or fail diarization for anyone offline.
    ///
    /// Resolving the repo at `main` (what 0.15.x always did) keeps markerless caches
    /// valid. Call before anything loads diarizer models. Idempotent, and it never
    /// replaces an override someone already set.
    public static func keepUnpinnedDiarizerCaches() {
        lock.lock()
        defer { lock.unlock() }
        guard !didKeepUnpinnedDiarizerCaches else { return }
        didKeepUnpinnedDiarizerCaches = true
        var overrides = ModelRegistry.revisionOverrides
        guard overrides[diarizerRepoPath] == nil else { return }
        overrides[diarizerRepoPath] = "main"
        ModelRegistry.revisionOverrides = overrides
    }

    /// 0.15.x read `clusteringThreshold` as a cosine similarity and cut the
    /// dendrogram at sqrt(2 - 2s). 0.17 reads it as that Euclidean distance
    /// directly. Same clamp as 0.15.x.
    public static func clusteringDistance(fromCosineSimilarity similarity: Double) -> Double {
        let clamped = min(1.0, max(-1.0, similarity))
        return max(0, 2 - 2 * clamped).squareRoot()
    }

    /// The grid-searched cosine threshold (0.6) as a 0.17 cut distance.
    public static let tunedClusteringDistanceThreshold: Double = clusteringDistance(fromCosineSimilarity: 0.6)

    /// The meeting diarizer's tuned config, with the two 0.17 changes undone so it
    /// matches the 0.15.x behavior the grid search was run against.
    ///
    /// Optimized config from DER grid search (v2, 100 iterations across 16 Zoom
    /// meetings). Key win: Fa 0.07 -> 0.25 (~halves DER by letting VBx reconsider
    /// speaker assignments).
    public static func tunedOfflineDiarizerConfig() -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig(
            clusteringThreshold: tunedClusteringDistanceThreshold,
            Fa: 0.25,
            Fb: 0.63,
            windowDuration: 10.0,
            segmentationStepRatio: 0.266,
            embeddingBatchSize: 32,
            embeddingExcludeOverlap: true,
            minSegmentDuration: 1.1821,
            minGapDuration: 0.2874,
            speechOnsetThreshold: 0.4472,
            speechOffsetThreshold: 0.4472,
            segmentationMinDurationOn: 0.0,
            segmentationMinDurationOff: 0.2738,
            maxVBxIterations: 24,
            convergenceTolerance: 0.0001
        )
        // 0.17 turned on pyannote-parity constrained assignment; 0.15.x assigned
        // each local speaker to its nearest centroid independently.
        config.clustering.constrainedAssignment = false
        return config
    }
}
