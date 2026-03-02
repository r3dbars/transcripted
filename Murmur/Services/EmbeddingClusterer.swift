// EmbeddingClusterer.swift
// Agglomerative Hierarchical Clustering (AHC) for speaker embeddings.
//
// Sortformer is good at detecting WHEN someone speaks (segment boundaries)
// but mediocre at deciding WHO is speaking (speaker grouping), especially
// for similar-sounding voices. This module re-clusters the per-segment
// WeSpeaker embeddings using AHC with cosine similarity + average linkage,
// producing more accurate speaker assignments.
//
// The hybrid pattern (neural segmentation + classical clustering) is the
// approach that wins diarization competitions (CHiME-7, CHiME-8).

import Foundation
import Accelerate

enum EmbeddingClusterer {

    /// Re-cluster speaker segments based on their WeSpeaker embeddings.
    ///
    /// Ignores Sortformer's original speaker IDs and assigns new ones
    /// based on AHC with cosine similarity and average linkage.
    ///
    /// - Parameters:
    ///   - segments: Speaker segments from Sortformer (with embeddings)
    ///   - threshold: Cosine similarity threshold for merging clusters.
    ///     Higher = more aggressive merging (fewer speakers).
    ///     Lower = less merging (more speakers).
    ///     Typical range: 0.55-0.75. Default 0.55.
    /// - Returns: Segments with reassigned speaker IDs
    static func recluster(
        segments: [SpeakerSegment],
        threshold: Float = 0.55
    ) -> [SpeakerSegment] {
        // Filter to segments that have embeddings
        let withEmbeddings = segments.filter { $0.embedding != nil && !($0.embedding?.isEmpty ?? true) }
        let withoutEmbeddings = segments.filter { $0.embedding == nil || ($0.embedding?.isEmpty ?? true) }

        guard withEmbeddings.count >= 2 else {
            // Nothing to re-cluster — return as-is
            return segments
        }

        let embeddings = withEmbeddings.map { $0.embedding! }
        let n = embeddings.count

        // Step 1: Compute pairwise cosine similarity matrix (upper triangle)
        let similarities = computeSimilarityMatrix(embeddings: embeddings)

        // Log similarity distribution so we can find the right threshold empirically
        logSimilarityDistribution(similarities: similarities, segments: withEmbeddings)

        // Step 2: AHC with average linkage
        let clusterAssignments = agglomerativeClustering(
            similarities: similarities,
            count: n,
            threshold: threshold
        )

        // Step 3: Reassign speaker IDs (sequential from 0)
        let uniqueClusters = Array(Set(clusterAssignments)).sorted()
        let clusterToSpeakerId = Dictionary(uniqueKeysWithValues: uniqueClusters.enumerated().map { ($1, $0) })

        var result: [SpeakerSegment] = []

        for (i, segment) in withEmbeddings.enumerated() {
            let newSpeakerId = clusterToSpeakerId[clusterAssignments[i]] ?? 0
            result.append(SpeakerSegment(
                speakerId: newSpeakerId,
                startTime: segment.startTime,
                endTime: segment.endTime,
                embedding: segment.embedding,
                qualityScore: segment.qualityScore
            ))
        }

        // Segments without embeddings get assigned to speaker 0 (fallback)
        for segment in withoutEmbeddings {
            result.append(SpeakerSegment(
                speakerId: 0,
                startTime: segment.startTime,
                endTime: segment.endTime,
                embedding: segment.embedding,
                qualityScore: segment.qualityScore
            ))
        }

        // Sort by start time to maintain chronological order
        result.sort { $0.startTime < $1.startTime }

        return result
    }

    // MARK: - Similarity Matrix

    /// Compute NxN cosine similarity matrix.
    /// L2-normalizes each embedding first, then dot product = cosine similarity.
    private static func computeSimilarityMatrix(embeddings: [[Float]]) -> [[Float]] {
        let n = embeddings.count
        let dim = embeddings[0].count

        // L2-normalize all embeddings (don't assume they're pre-normalized)
        let normalized = embeddings.map { emb -> [Float] in
            var norm: Float = 0
            vDSP_dotpr(emb, 1, emb, 1, &norm, vDSP_Length(dim))
            norm = sqrt(norm)
            guard norm > 0 else { return emb }
            var result = emb
            vDSP_vsdiv(result, 1, &norm, &result, 1, vDSP_Length(dim))
            return result
        }

        var matrix = [[Float]](repeating: [Float](repeating: 0, count: n), count: n)

        for i in 0..<n {
            matrix[i][i] = 1.0  // self-similarity
            for j in (i + 1)..<n {
                var similarity: Float = 0
                vDSP_dotpr(normalized[i], 1, normalized[j], 1, &similarity, vDSP_Length(dim))
                matrix[i][j] = similarity
                matrix[j][i] = similarity
            }
        }

        return matrix
    }

    // MARK: - Agglomerative Hierarchical Clustering

    /// AHC with average linkage. Merges clusters until max inter-cluster
    /// similarity falls below threshold.
    ///
    /// Returns an array of cluster IDs (one per input embedding).
    private static func agglomerativeClustering(
        similarities: [[Float]],
        count n: Int,
        threshold: Float
    ) -> [Int] {
        // Each element starts in its own cluster
        var clusterOf = Array(0..<n)  // clusterOf[i] = cluster ID for element i
        var nextClusterId = n

        // Track which elements belong to each cluster
        var clusterMembers: [Int: [Int]] = [:]
        for i in 0..<n {
            clusterMembers[i] = [i]
        }

        // Track active clusters
        var activeClusters = Set(0..<n)

        // Average linkage similarity cache between active cluster pairs
        // Key: (min(a,b), max(a,b)), Value: average similarity
        var linkageCache: [Int64: Float] = [:]

        func cacheKey(_ a: Int, _ b: Int) -> Int64 {
            let lo = min(a, b)
            let hi = max(a, b)
            return Int64(lo) << 32 | Int64(hi)
        }

        // Initialize linkage cache from raw similarities
        for i in 0..<n {
            for j in (i + 1)..<n {
                linkageCache[cacheKey(i, j)] = similarities[i][j]
            }
        }

        // Iteratively merge the most similar pair of clusters
        while activeClusters.count > 1 {
            // Find the most similar pair of active clusters
            var bestSim: Float = -Float.infinity
            var bestA = -1
            var bestB = -1

            let sorted = activeClusters.sorted()
            for (idx, a) in sorted.enumerated() {
                for b in sorted[(idx + 1)...] {
                    let key = cacheKey(a, b)
                    if let sim = linkageCache[key], sim > bestSim {
                        bestSim = sim
                        bestA = a
                        bestB = b
                    }
                }
            }

            // Stop if best similarity is below threshold
            guard bestSim >= threshold, bestA >= 0, bestB >= 0 else { break }

            // Merge bestB into bestA
            let mergedId = nextClusterId
            nextClusterId += 1

            let membersA = clusterMembers[bestA]!
            let membersB = clusterMembers[bestB]!
            let mergedMembers = membersA + membersB

            clusterMembers[mergedId] = mergedMembers
            clusterMembers.removeValue(forKey: bestA)
            clusterMembers.removeValue(forKey: bestB)

            // Update cluster assignments
            for i in mergedMembers {
                clusterOf[i] = mergedId
            }

            // Remove old clusters from active set, add new one
            activeClusters.remove(bestA)
            activeClusters.remove(bestB)

            // Compute average linkage between new merged cluster and all remaining active clusters
            for other in activeClusters {
                let otherMembers = clusterMembers[other]!
                var totalSim: Float = 0
                var count = 0
                for mi in mergedMembers {
                    for mj in otherMembers {
                        totalSim += similarities[mi][mj]
                        count += 1
                    }
                }
                let avgSim = count > 0 ? totalSim / Float(count) : 0
                linkageCache[cacheKey(mergedId, other)] = avgSim
            }

            activeClusters.insert(mergedId)
        }

        return clusterOf
    }

    // MARK: - Diagnostic Logging

    /// Log pairwise similarity distribution to help tune the threshold.
    /// Shows min/max/mean, histogram buckets, and the 5 lowest pairs (most likely different speakers).
    private static func logSimilarityDistribution(similarities: [[Float]], segments: [SpeakerSegment]) {
        let n = similarities.count
        guard n >= 2 else { return }

        // Collect upper triangle values
        var allSims: [Float] = []
        for i in 0..<n {
            for j in (i + 1)..<n {
                allSims.append(similarities[i][j])
            }
        }

        guard !allSims.isEmpty else { return }
        let sorted = allSims.sorted()

        let minSim = sorted.first!
        let maxSim = sorted.last!
        let meanSim = sorted.reduce(0, +) / Float(sorted.count)

        AppLogger.transcription.info("AHC similarity matrix", [
            "pairs": "\(sorted.count)",
            "min": String(format: "%.3f", minSim),
            "max": String(format: "%.3f", maxSim),
            "mean": String(format: "%.3f", meanSim)
        ])

        // Histogram: 0.5-0.6, 0.6-0.7, 0.7-0.8, 0.8-0.9, 0.9-1.0
        let buckets: [(String, ClosedRange<Float>)] = [
            ("<0.5", -1.0...0.499),
            ("0.5-0.6", 0.5...0.599),
            ("0.6-0.7", 0.6...0.699),
            ("0.7-0.8", 0.7...0.799),
            ("0.8-0.9", 0.8...0.899),
            ("0.9-1.0", 0.9...1.0)
        ]
        var histData: [String: String] = [:]
        for (label, range) in buckets {
            let count = sorted.filter { range.contains($0) }.count
            if count > 0 { histData[label] = "\(count)" }
        }
        AppLogger.transcription.info("AHC similarity histogram", histData)

        // Log the 5 lowest-similarity pairs with timestamps
        struct SimPair: Comparable {
            let i: Int, j: Int, sim: Float
            static func < (lhs: SimPair, rhs: SimPair) -> Bool { lhs.sim < rhs.sim }
        }
        var pairs: [SimPair] = []
        for i in 0..<n {
            for j in (i + 1)..<n {
                pairs.append(SimPair(i: i, j: j, sim: similarities[i][j]))
            }
        }
        pairs.sort()
        let lowestPairs = pairs.prefix(5)
        for (idx, pair) in lowestPairs.enumerated() {
            let si = segments[pair.i]
            let sj = segments[pair.j]
            AppLogger.transcription.info("AHC lowest pair \(idx + 1)", [
                "sim": String(format: "%.3f", pair.sim),
                "segA": String(format: "%.1fs-%.1fs (spk%d)", si.startTime, si.endTime, si.speakerId),
                "segB": String(format: "%.1fs-%.1fs (spk%d)", sj.startTime, sj.endTime, sj.speakerId)
            ])
        }
    }
}
