// SpeakerTurnWindowSplitter.swift
// Split a long diarized turn that contains two voices in one time range.
//
// Nemotron (and occasionally VBx) will emit one exclusive turn that actually
// covers A then B — slot identity flickers away, or a dropped blip was
// absorbed before this splitter existed. One embedding for the whole span
// cannot recover the second person. Sliding windows can: 2 s embeds at a 1 s
// hop, then the same 2-means test as collapsed-cluster split.
//
// Only suspect-long turns are windowed (≥8 s — two voices in one exclusive
// turn are rarely shorter). Hop grows so a turn pays at most 8 embeds, and
// a meeting pays at most 48, longest turns first. Split pieces reuse the
// window centroids; they are not re-embedded. A unimodal monologue stays
// one turn because the windows fail the cohesion-gap test. Band-limited
// (AirPods / 16 kHz) audio is not special-cased here.

import Foundation

enum SpeakerTurnWindowSplitter {
    static let minSegmentSeconds: Double = 8
    static let windowSeconds: Double = 2
    static let hopSeconds: Double = 1
    static let minWindowsPerGroup = 2
    /// A long monologue must not pay a 1 s grid. Eight 2 s probes are enough
    /// to see A-then-B; hop stretches so the last window still covers the end.
    static let maxWindowsPerSegment = 8
    /// Meeting-wide cap. Longest turns consume the budget first.
    static let maxWindowsPerRefine = 48
    /// Pieces at or under this length are flicker from a 1 s hop (one flipped
    /// window yields a 1.0 s piece). Fold them into the neighbour so a cough
    /// or laugh in a monologue cannot become its own speaker.
    static let minPieceSeconds: Double = 1
    /// After short pieces are folded, each remaining voice still needs this
    /// much talk time. Two isolated 1 s outliers must not become a speaker.
    static let minGroupSeconds: Double = 2

    /// Re-slice long turns whose window embeddings are bimodal. Short turns
    /// and a missing/failed embedder are left alone.
    static func refine(
        segments: [SpeakerSegment],
        samples: [Float],
        sampleRate: Int,
        using embedder: any SpeakerSegmentEmbedder
    ) -> [SpeakerSegment] {
        guard sampleRate > 0, !segments.isEmpty, !samples.isEmpty else { return segments }
        let maxBetween = embedder.thresholds.consolidation
        var nextSpeakerId = (segments.map(\.speakerId).max() ?? 0) + 1
        let minWindows = minWindowsPerGroup * 2

        // Longest first so a 40 s mixed turn is not starved by a pile of 10 s
        // monologues. Original order is restored when the pieces are flattened.
        let order = segments.indices.sorted { lhs, rhs in
            let left = segments[lhs].duration
            let right = segments[rhs].duration
            if left != right { return left > right }
            return lhs < rhs
        }

        var piecesByIndex = Array(repeating: [SpeakerSegment](), count: segments.count)
        var windowsUsed = 0

        for index in order {
            let segment = segments[index]
            let remaining = maxWindowsPerRefine - windowsUsed
            guard segment.duration >= minSegmentSeconds, remaining >= minWindows else {
                piecesByIndex[index] = [segment]
                continue
            }
            let windows = windowEmbeddings(
                segment: segment,
                samples: samples,
                sampleRate: sampleRate,
                using: embedder,
                maxWindows: min(maxWindowsPerSegment, remaining)
            )
            windowsUsed += windows.count
            let pieces = splitSegment(
                segment,
                windows: windows,
                nextSpeakerId: nextSpeakerId,
                maxBetween: maxBetween
            )
            if pieces.count > 1 {
                let newIds = Set(pieces.map(\.speakerId)).subtracting([segment.speakerId])
                nextSpeakerId = max(nextSpeakerId, (newIds.max() ?? nextSpeakerId - 1) + 1)
                AppLogger.transcription.info("Split mixed speaker turn", [
                    "originalSpk": "spk\(segment.speakerId)",
                    "pieces": "\(pieces.count)",
                    "ids": "\(Set(pieces.map(\.speakerId)).count)"
                ])
            }
            // Window centroids already live on the pieces. Do not re-embed.
            piecesByIndex[index] = pieces
        }
        return piecesByIndex.flatMap { $0 }
    }

    /// Split one turn from precomputed window embeddings. Exposed so tests can
    /// feed synthetic vectors without standing up an embedder.
    static func splitSegment(
        _ segment: SpeakerSegment,
        windows: [(start: Double, end: Double, embedding: [Float])],
        nextSpeakerId: Int,
        maxBetween: Float,
        minSeparation: Float = SpeakerEmbeddingBimodality.defaultMinSeparation
    ) -> [SpeakerSegment] {
        let ordered = windows
            .filter { !$0.embedding.isEmpty && $0.end > $0.start }
            .sorted { $0.start < $1.start }
        guard ordered.count >= minWindowsPerGroup * 2 else { return [segment] }

        let embeddings = ordered.map(\.embedding)
        guard let part = SpeakerEmbeddingBimodality.partition(
            embeddings: embeddings,
            maxBetween: maxBetween,
            minSeparation: minSeparation,
            minCount: minWindowsPerGroup
        ) else { return [segment] }

        var groupByWindow = [Int](repeating: 0, count: ordered.count)
        for index in part.right { groupByWindow[index] = 1 }

        let rawPieces = labeledPieces(
            segment: segment,
            windows: ordered,
            groups: groupByWindow
        )
        let pieces = absorbShortPieces(rawPieces, minSeconds: minPieceSeconds)
        let groupsPresent = Set(pieces.map(\.group))
        guard pieces.count >= 2, groupsPresent.count == 2 else { return [segment] }
        let secondsByGroup = Dictionary(grouping: pieces, by: \.group).mapValues { group in
            group.reduce(0.0) { $0 + ($1.end - $1.start) }
        }
        guard secondsByGroup.values.allSatisfy({ $0 + 1e-9 >= minGroupSeconds }) else {
            return [segment]
        }

        return pieces.map { piece in
            let speakerId = piece.group == 0 ? segment.speakerId : nextSpeakerId
            let embedding = windowCentroid(windows: ordered, groups: groupByWindow, group: piece.group)
                ?? segment.embedding
            return SpeakerSegment(
                speakerId: speakerId,
                startTime: piece.start,
                endTime: piece.end,
                embedding: embedding,
                qualityScore: segment.qualityScore
            )
        }
    }

    // MARK: - Windowing

    /// Window start times for one turn. Hop grows with duration so `maxWindows`
    /// is a hard cap and the last window still covers the end.
    static func windowStarts(
        startTime: Double,
        endTime: Double,
        maxWindows: Int = maxWindowsPerSegment
    ) -> [Double] {
        let duration = endTime - startTime
        guard duration + 1e-9 >= windowSeconds, maxWindows > 0 else { return [] }
        let span = max(duration - windowSeconds, 0)
        let hop = maxWindows == 1
            ? max(hopSeconds, span)
            : max(hopSeconds, span / Double(maxWindows - 1))
        var starts: [Double] = []
        starts.reserveCapacity(maxWindows)
        var time = startTime
        while starts.count < maxWindows, time + windowSeconds <= endTime + 1e-9 {
            starts.append(time)
            if hop <= 0 { break }
            time += hop
        }
        return starts
    }

    private static func windowEmbeddings(
        segment: SpeakerSegment,
        samples: [Float],
        sampleRate: Int,
        using embedder: any SpeakerSegmentEmbedder,
        maxWindows: Int
    ) -> [(start: Double, end: Double, embedding: [Float])] {
        let starts = windowStarts(
            startTime: segment.startTime,
            endTime: segment.endTime,
            maxWindows: maxWindows
        )
        let total = samples.count
        var windows: [(start: Double, end: Double, embedding: [Float])] = []
        windows.reserveCapacity(starts.count)
        for startTime in starts {
            let endTime = min(startTime + windowSeconds, segment.endTime)
            let startSample = max(0, Int(startTime * Double(sampleRate)))
            let endSample = min(total, Int(endTime * Double(sampleRate)))
            if let embedding = embedSlice(
                samples: samples,
                sampleRate: sampleRate,
                startSample: startSample,
                endSample: endSample,
                using: embedder
            ) {
                windows.append((startTime, endTime, embedding))
            }
        }
        return windows
    }

    private static func embedSlice(
        samples: [Float],
        sampleRate: Int,
        startSample: Int,
        endSample: Int,
        using embedder: any SpeakerSegmentEmbedder
    ) -> [Float]? {
        guard endSample > startSample else { return nil }
        return autoreleasepool { () -> [Float]? in
            if let contextual = embedder as? any ContextualSpeakerSegmentEmbedder {
                return contextual.embed(
                    audio: samples,
                    sampleRate: sampleRate,
                    startSample: startSample,
                    endSample: endSample
                )
            }
            return embedder.embed(samples: Array(samples[startSample..<endSample]), sampleRate: sampleRate)
        }
    }

    // MARK: - Change points

    private struct Piece {
        var group: Int
        var start: Double
        var end: Double
    }

    private static func labeledPieces(
        segment: SpeakerSegment,
        windows: [(start: Double, end: Double, embedding: [Float])],
        groups: [Int]
    ) -> [Piece] {
        var pieces: [Piece] = []
        var currentGroup = groups[0]
        var currentStart = segment.startTime
        for index in 1..<windows.count where groups[index] != currentGroup {
            let previous = windows[index - 1]
            let current = windows[index]
            let split = (previous.start + previous.end + current.start + current.end) / 4
            pieces.append(Piece(group: currentGroup, start: currentStart, end: split))
            currentGroup = groups[index]
            currentStart = split
        }
        pieces.append(Piece(group: currentGroup, start: currentStart, end: segment.endTime))
        return pieces
    }

    /// Fold pieces at or under `minSeconds` into the neighbour. A single
    /// flipped 2 s window at a 1 s hop produces a piece of exactly 1.0 s;
    /// that must not survive as its own speaker.
    private static func absorbShortPieces(_ pieces: [Piece], minSeconds: Double) -> [Piece] {
        guard pieces.count >= 2 else { return pieces }
        var result = pieces
        var index = 0
        while index < result.count {
            let duration = result[index].end - result[index].start
            if duration <= minSeconds + 1e-9, result.count > 1 {
                if index > 0 {
                    result[index - 1].end = result[index].end
                    result.remove(at: index)
                    index -= 1
                } else {
                    result[index + 1].start = result[index].start
                    result.remove(at: index)
                }
            } else {
                index += 1
            }
        }
        return mergeAdjacentSameGroup(result)
    }

    private static func mergeAdjacentSameGroup(_ pieces: [Piece]) -> [Piece] {
        var result: [Piece] = []
        for piece in pieces {
            if var last = result.last, last.group == piece.group {
                last.end = piece.end
                result[result.count - 1] = last
            } else {
                result.append(piece)
            }
        }
        return result
    }

    private static func windowCentroid(
        windows: [(start: Double, end: Double, embedding: [Float])],
        groups: [Int],
        group: Int
    ) -> [Float]? {
        let embeddings = zip(windows, groups).compactMap { window, assigned in
            assigned == group ? window.embedding : nil
        }
        let mean = Transcription.computeMeanEmbedding(embeddings)
        return mean.isEmpty ? nil : mean
    }
}
