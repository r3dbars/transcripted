// SpeakerTurnWindowSplitter.swift
// Split a long diarized turn that contains two voices in one time range.
//
// Nemotron (and occasionally VBx) will emit one exclusive turn that actually
// covers A then B — slot identity flickers away, or a dropped blip was
// absorbed before this splitter existed. One embedding for the whole span
// cannot recover the second person. Sliding windows can: 2 s embeds at a 1 s
// hop, then the same 2-means test as collapsed-cluster split.
//
// The duration floor (6 s) is "longer than a typical conversational turn,"
// not a number fitted to the synthetic set. A unimodal 20 s monologue stays
// one turn because the windows fail the cohesion-gap test. Band-limited
// (AirPods / 16 kHz) audio is not special-cased here; if the voiceprint
// still separates the two people in 2 s windows, the split fires, and if it
// does not, we do not invent a speaker from noise.

import Foundation

enum SpeakerTurnWindowSplitter {
    static let minSegmentSeconds: Double = 6
    static let windowSeconds: Double = 2
    static let hopSeconds: Double = 1
    static let minWindowsPerGroup = 2
    static let minPieceSeconds: Double = 1

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
        var result: [SpeakerSegment] = []
        result.reserveCapacity(segments.count)

        for segment in segments {
            guard segment.duration >= minSegmentSeconds else {
                result.append(segment)
                continue
            }
            let windows = windowEmbeddings(
                segment: segment,
                samples: samples,
                sampleRate: sampleRate,
                using: embedder
            )
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
                result.append(contentsOf: pieces.map { piece in
                    reembedded(piece, samples: samples, sampleRate: sampleRate, using: embedder)
                })
            } else {
                result.append(contentsOf: pieces)
            }
        }
        return result
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

    private static func windowEmbeddings(
        segment: SpeakerSegment,
        samples: [Float],
        sampleRate: Int,
        using embedder: any SpeakerSegmentEmbedder
    ) -> [(start: Double, end: Double, embedding: [Float])] {
        let total = samples.count
        var startTime = segment.startTime
        var windows: [(start: Double, end: Double, embedding: [Float])] = []
        while startTime + windowSeconds <= segment.endTime + 1e-9 {
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
            startTime += hopSeconds
        }
        return windows
    }

    private static func reembedded(
        _ segment: SpeakerSegment,
        samples: [Float],
        sampleRate: Int,
        using embedder: any SpeakerSegmentEmbedder
    ) -> SpeakerSegment {
        let startSample = max(0, Int(segment.startTime * Double(sampleRate)))
        let endSample = min(samples.count, Int(segment.endTime * Double(sampleRate)))
        guard let embedding = embedSlice(
            samples: samples,
            sampleRate: sampleRate,
            startSample: startSample,
            endSample: endSample,
            using: embedder
        ) else { return segment }
        return SpeakerSegment(
            speakerId: segment.speakerId,
            startTime: segment.startTime,
            endTime: segment.endTime,
            embedding: embedding,
            qualityScore: segment.qualityScore
        )
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

    /// Fold pieces shorter than `minSeconds` into the neighbour so a 0.4 s
    /// flicker does not become its own speaker.
    static func absorbShortPieces(_ pieces: [Piece], minSeconds: Double) -> [Piece] {
        guard pieces.count >= 2 else { return pieces }
        var result = pieces
        var index = 0
        while index < result.count {
            let duration = result[index].end - result[index].start
            if duration + 1e-9 < minSeconds, result.count > 1 {
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
