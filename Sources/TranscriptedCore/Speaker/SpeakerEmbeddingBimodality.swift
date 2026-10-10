// SpeakerEmbeddingBimodality.swift
// Shared 2-means test for "this bag of embeddings is two voices, not one."
//
// Used by EmbeddingClusterer's collapsed-ID split and by
// SpeakerTurnWindowSplitter on long mixed turns. The bars are geometric, not
// tuned to a fixture: split only when the two centroids sit below the
// same-voice consolidation bar *and* each side is tighter around its own
// centroid than that between-centroid cosine by `minSeparation`.
//
// That generalizes past synthetic `say` voices. Real distinct people land
// well under the consolidation bar (typically < 0.6 cosine). A single
// person's noisy turns stay unimodal, so a long monologue or an
// over-segmented same voice does not split.

import Foundation

enum SpeakerEmbeddingBimodality {
    static let defaultMinSeparation: Float = 0.10
    static let maxIterations = 16

    struct Partition: Equatable, Sendable {
        /// Indices into the input embedding array.
        let left: [Int]
        /// Indices into the input embedding array.
        let right: [Int]
        /// Cosine similarity of the two centroids.
        let between: Float
        /// `min(withinLeft, withinRight) - between`.
        let separation: Float
    }

    /// 2-means on L2-normalized embeddings. `weights` (when present and the
    /// same length as `embeddings`) scale the centroid. Returns nil when the
    /// cloud is unimodal, too small, or the two sides fail the bars.
    static func partition(
        embeddings: [[Float]],
        maxBetween: Float,
        minSeparation: Float = defaultMinSeparation,
        minCount: Int,
        weights: [Double]? = nil
    ) -> Partition? {
        let usable = usableEmbeddings(embeddings)
        guard usable.count >= minCount * 2 else { return nil }
        let vectors = usable.map(\.vector)
        let sourceIndex = usable.map(\.index)
        let pointWeights: [Float] = {
            guard let weights, weights.count == embeddings.count else {
                return [Float](repeating: 1, count: usable.count)
            }
            return usable.map { Float(max(weights[$0.index], 1e-3)) }
        }()

        guard let seeds = seedPair(vectors) else { return nil }
        var centroidA = vectors[seeds.0]
        var centroidB = vectors[seeds.1]
        var assignment = [Int](repeating: 0, count: vectors.count)

        for _ in 0..<maxIterations {
            var changed = false
            for i in 0..<vectors.count {
                let group = nearerGroup(vectors[i], centroidA, centroidB)
                if assignment[i] != group {
                    assignment[i] = group
                    changed = true
                }
            }
            let nextA = weightedCentroid(vectors: vectors, weights: pointWeights, group: 0, assignment: assignment)
            let nextB = weightedCentroid(vectors: vectors, weights: pointWeights, group: 1, assignment: assignment)
            guard let nextA, let nextB else { return nil }
            centroidA = nextA
            centroidB = nextB
            if !changed { break }
        }

        var leftLocal: [Int] = []
        var rightLocal: [Int] = []
        for i in 0..<assignment.count {
            if assignment[i] == 0 {
                leftLocal.append(i)
            } else {
                rightLocal.append(i)
            }
        }
        guard leftLocal.count >= minCount, rightLocal.count >= minCount else { return nil }

        let between = Float(SpeakerVectorMath.cosineSimilarity(centroidA, centroidB))
        guard between < maxBetween else { return nil }

        let withinLeft = meanSimilarity(to: centroidA, indices: leftLocal, vectors: vectors)
        let withinRight = meanSimilarity(to: centroidB, indices: rightLocal, vectors: vectors)
        let separation = min(withinLeft, withinRight) - between
        guard separation >= minSeparation else { return nil }

        return Partition(
            left: leftLocal.map { sourceIndex[$0] },
            right: rightLocal.map { sourceIndex[$0] },
            between: between,
            separation: separation
        )
    }

    // MARK: - Internals

    private struct Usable {
        let index: Int
        let vector: [Float]
    }

    private static func usableEmbeddings(_ embeddings: [[Float]]) -> [Usable] {
        guard let dim = embeddings.first(where: { !$0.isEmpty })?.count, dim > 0 else { return [] }
        return embeddings.enumerated().compactMap { index, vector in
            guard vector.count == dim, vector.contains(where: { $0 != 0 }) else { return nil }
            return Usable(index: index, vector: vector)
        }
    }

    /// Furthest-from-mean, then furthest from that. Both deterministic (lowest
    /// index on a tie). Nil when every pair is essentially the same vector.
    private static func seedPair(_ vectors: [[Float]]) -> (Int, Int)? {
        let mean = Transcription.computeMeanEmbedding(vectors)
        guard !mean.isEmpty else { return nil }
        let first = furthest(from: mean, in: vectors)
        let second = furthest(from: vectors[first], in: vectors)
        guard first != second else { return nil }
        let seedSimilarity = Float(SpeakerVectorMath.cosineSimilarity(vectors[first], vectors[second]))
        guard seedSimilarity < 0.999 else { return nil }
        return (first, second)
    }

    private static func furthest(from target: [Float], in vectors: [[Float]]) -> Int {
        var best = 0
        var bestSimilarity = Float.greatestFiniteMagnitude
        for (index, vector) in vectors.enumerated() {
            let similarity = Float(SpeakerVectorMath.cosineSimilarity(vector, target))
            if similarity < bestSimilarity {
                bestSimilarity = similarity
                best = index
            }
        }
        return best
    }

    private static func nearerGroup(_ vector: [Float], _ a: [Float], _ b: [Float]) -> Int {
        let toA = SpeakerVectorMath.cosineSimilarity(vector, a)
        let toB = SpeakerVectorMath.cosineSimilarity(vector, b)
        return toA >= toB ? 0 : 1
    }

    private static func weightedCentroid(
        vectors: [[Float]],
        weights: [Float],
        group: Int,
        assignment: [Int]
    ) -> [Float]? {
        var chosen: [[Float]] = []
        var chosenWeights: [Float] = []
        for i in 0..<assignment.count where assignment[i] == group {
            chosen.append(vectors[i])
            chosenWeights.append(weights[i])
        }
        guard !chosen.isEmpty else { return nil }
        let centroid = Transcription.computeWeightedMeanEmbedding(chosen, weights: chosenWeights)
        return centroid.isEmpty ? nil : centroid
    }

    private static func meanSimilarity(to centroid: [Float], indices: [Int], vectors: [[Float]]) -> Float {
        guard !indices.isEmpty else { return 0 }
        var sum: Double = 0
        for index in indices {
            sum += SpeakerVectorMath.cosineSimilarity(vectors[index], centroid)
        }
        return Float(sum / Double(indices.count))
    }
}
