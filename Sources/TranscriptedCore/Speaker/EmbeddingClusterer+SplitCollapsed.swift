// EmbeddingClusterer+SplitCollapsed.swift
// Unsupervised split of one diarizer ID that contains two voices.
//
// The diarizer (VBx or Nemotron slots) sometimes labels two people as one
// cluster. `dbInformedSplit` can only pull them apart when the speaker DB
// already has both profiles — import with `--no-speaker-identification` never
// does. Per-segment embeddings still differ, so a 2-means here recovers the
// second person from the geometry alone.
//
// Bars are the same as `SpeakerEmbeddingBimodality`: between-centroid cosine
// below the consolidation bar, plus a cohesion gap. Each side also needs
// enough talk time and at least two turns, so a single noisy pair does not
// invent a speaker. Recurses so three collapsed people can come apart across
// rounds. Does not look at this fixture's voices or talk-time ratios.

import Foundation

extension EmbeddingClusterer {
    static let collapsedSplitMinSeparation: Float = SpeakerEmbeddingBimodality.defaultMinSeparation
    static let collapsedSplitMinSegmentsPerGroup = 2
    static let collapsedSplitMinSecondsPerGroup = 8.0
    static let collapsedSplitMaxRounds = 4

    /// Split speaker IDs whose per-segment embeddings are bimodal.
    static func splitCollapsedSpeakers(
        segments: [SpeakerSegment],
        maxBetween: Float,
        minSeparation: Float = collapsedSplitMinSeparation,
        minSegmentsPerGroup: Int = collapsedSplitMinSegmentsPerGroup,
        minSecondsPerGroup: Double = collapsedSplitMinSecondsPerGroup,
        maxRounds: Int = collapsedSplitMaxRounds
    ) -> [SpeakerSegment] {
        guard segments.count >= minSegmentsPerGroup * 2 else { return segments }
        var result = segments
        var nextSpeakerId = (segments.map(\.speakerId).max() ?? 0) + 1

        for _ in 0..<maxRounds {
            let groups = Dictionary(grouping: result.indices, by: { result[$0].speakerId })
            var didSplit = false
            for speakerId in groups.keys.sorted() {
                guard let indices = groups[speakerId] else { continue }
                let usable = usableMembers(indices: indices, segments: result, minCount: minSegmentsPerGroup * 2)
                guard usable.count >= minSegmentsPerGroup * 2 else { continue }
                let embeddings = usable.map(\.embedding)
                let weights = usable.map(\.duration)
                guard let part = SpeakerEmbeddingBimodality.partition(
                    embeddings: embeddings,
                    maxBetween: maxBetween,
                    minSeparation: minSeparation,
                    minCount: minSegmentsPerGroup,
                    weights: weights
                ) else { continue }

                let leftSeconds = part.left.reduce(0.0) { $0 + usable[$1].duration }
                let rightSeconds = part.right.reduce(0.0) { $0 + usable[$1].duration }
                guard leftSeconds >= minSecondsPerGroup, rightSeconds >= minSecondsPerGroup else { continue }

                let (keep, splitOff) = part.left.count >= part.right.count
                    ? (part.left, part.right)
                    : (part.right, part.left)
                let newId = nextSpeakerId
                nextSpeakerId += 1
                for local in splitOff {
                    let index = usable[local].index
                    result[index] = result[index].withSpeakerId(newId)
                }
                didSplit = true
                AppLogger.transcription.info("Split collapsed speaker cluster", [
                    "originalSpk": "spk\(speakerId)",
                    "newSpk": "spk\(newId)",
                    "kept": "\(keep.count)",
                    "split": "\(splitOff.count)",
                    "between": String(format: "%.3f", part.between),
                    "separation": String(format: "%.3f", part.separation)
                ])
            }
            if !didSplit { break }
        }
        return result
    }

    private struct Member {
        let index: Int
        let embedding: [Float]
        let duration: Double
    }

    /// Prefer quality-filtered segments (same gate as the mean-embedding
    /// helpers). Fall back to every embedded segment when too few pass, so a
    /// collapsed pair of slightly-short turns can still split.
    private static func usableMembers(
        indices: [Int],
        segments: [SpeakerSegment],
        minCount: Int
    ) -> [Member] {
        func collect(_ qualityOnly: Bool) -> [Member] {
            indices.compactMap { index in
                let segment = segments[index]
                guard let embedding = segment.embedding, !embedding.isEmpty else { return nil }
                if qualityOnly {
                    guard segment.qualityScore >= 0.3, segment.duration >= 1.0 else { return nil }
                }
                return Member(index: index, embedding: embedding, duration: segment.duration)
            }
        }
        let quality = collect(true)
        if quality.count >= minCount { return quality }
        return collect(false)
    }
}
