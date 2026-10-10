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
// invent a speaker. A two-run split (everyone on one side, then everyone on
// the other) needs a wider gap than an interleaved A-B-A pattern: one person
// talking across a long meeting drifts early-vs-late, and that is 2 runs, not
// two people. Distinct people who happen to talk in two blocks still clear
// the wider gap. Each starting ID is split at most once in a pass, so a smear
// cannot fragment into a tree of new speakers. Does not look at a particular
// file's voices or talk-time ratios.

import Foundation

extension EmbeddingClusterer {
    static let collapsedSplitMinSeparation: Float = SpeakerEmbeddingBimodality.defaultMinSeparation
    /// Extra cohesion gap when the two sides are sequential in time (early vs
    /// late) instead of interleaved. Hour-scale drift of one voice often
    /// clears the default 0.10 hole; two real people still sit well above
    /// this even if they never overlap.
    static let collapsedSplitSegregatedMinSeparation: Float = 0.22
    /// A-B-A (or more) is interleaved. A then B is two runs.
    static let collapsedSplitInterleavedRunCount = 3
    static let collapsedSplitMinSegmentsPerGroup = 2
    static let collapsedSplitMinSecondsPerGroup = 8.0
    /// One pass over the IDs that already exist. Newly created IDs and an ID
    /// that just split are not visited again, so one collapsed cluster cannot
    /// fragment into 3–5 speakers across rounds.
    static let collapsedSplitMaxRounds = 1

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
        var alreadySplit: Set<Int> = []

        for _ in 0..<maxRounds {
            let groups = Dictionary(grouping: result.indices, by: { result[$0].speakerId })
            var didSplit = false
            for speakerId in groups.keys.sorted() {
                guard !alreadySplit.contains(speakerId) else { continue }
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

                let runs = temporalRunCount(
                    left: part.left,
                    right: part.right,
                    members: usable,
                    segments: result
                )
                let requiredSeparation = runs >= collapsedSplitInterleavedRunCount
                    ? minSeparation
                    : max(minSeparation, collapsedSplitSegregatedMinSeparation)
                guard part.separation >= requiredSeparation else { continue }

                let (keep, splitOff) = part.left.count >= part.right.count
                    ? (part.left, part.right)
                    : (part.right, part.left)
                let newId = nextSpeakerId
                nextSpeakerId += 1
                for local in splitOff {
                    let index = usable[local].index
                    result[index] = result[index].withSpeakerId(newId)
                }
                alreadySplit.insert(speakerId)
                alreadySplit.insert(newId)
                didSplit = true
                AppLogger.transcription.info("Split collapsed speaker cluster", [
                    "originalSpk": "spk\(speakerId)",
                    "newSpk": "spk\(newId)",
                    "kept": "\(keep.count)",
                    "split": "\(splitOff.count)",
                    "between": String(format: "%.3f", part.between),
                    "separation": String(format: "%.3f", part.separation),
                    "runs": "\(runs)"
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

    /// How many times the two 2-means sides switch as the meeting plays.
    /// Early-block then late-block is 2. A-B-A is 3.
    private static func temporalRunCount(
        left: [Int],
        right: [Int],
        members: [Member],
        segments: [SpeakerSegment]
    ) -> Int {
        let leftSet = Set(left)
        var labeled: [(start: Double, index: Int, group: Int)] = []
        labeled.reserveCapacity(members.count)
        for (local, member) in members.enumerated() {
            let group = leftSet.contains(local) ? 0 : 1
            labeled.append((segments[member.index].startTime, member.index, group))
        }
        labeled.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.index < $1.index
        }
        guard let first = labeled.first else { return 0 }
        var runs = 1
        var current = first.group
        for item in labeled.dropFirst() where item.group != current {
            runs += 1
            current = item.group
        }
        return runs
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
