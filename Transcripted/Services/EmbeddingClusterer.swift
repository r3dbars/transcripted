// EmbeddingClusterer.swift
// Post-processes diarization speaker segments to fix two failure modes:
//
// Supports both Sortformer (streaming) and PyAnnote (offline) pipelines.
//
// 1. Fragmentation: Same speaker split across multiple diarizer IDs.
//    Fixed by pairwise merge — compare mean embeddings of every speaker pair
//    and merge those above a high cosine similarity threshold.
//    Note: Skipped for PyAnnote offline output, where VBx clustering already
//    handles speaker merging/fragmentation.
//
// 2. Merging: Different speakers collapsed into one diarizer ID.
//    Fixed by DB-informed split — compare per-segment embeddings against
//    known speaker profiles and split clusters that contain 2+ distinct voices.

import Foundation
import Accelerate

@available(macOS 26.0, *)
enum EmbeddingClusterer {

    /// Post-process diarization segments: merge fragmented speakers,
    /// absorb tiny orphan clusters, then split clusters that contain
    /// multiple known DB voices.
    ///
    /// - Parameter skipPairwiseMerge: Set `true` for PyAnnote offline output,
    ///   where VBx clustering already handles speaker merging. Default `false`
    ///   for Sortformer streaming output.
    static func postProcess(
        segments: [SpeakerSegment],
        existingProfiles: [SpeakerProfile],
        skipPairwiseMerge: Bool = false
    ) -> [SpeakerSegment] {
        guard segments.count >= 2 else { return segments }
        var result = skipPairwiseMerge ? segments : pairwiseMerge(segments: segments)
        result = absorbSmallClusters(segments: result)
        result = dbInformedSplit(segments: result, profiles: existingProfiles)
        return result
    }

    // MARK: - Pairwise Merge

    /// Merge speaker clusters whose mean embeddings are highly similar (>= threshold).
    /// Fixes Sortformer fragmentation where one person gets 2+ speaker IDs.
    ///
    /// Uses union-find for transitive merges: if A≈B and B≈C, all three merge.
    static func pairwiseMerge(
        segments: [SpeakerSegment],
        threshold: Float = 0.85
    ) -> [SpeakerSegment] {
        // Compute quality-filtered mean embedding per speaker
        let meanEmbeddings = computeMeanEmbeddingsPerSpeaker(segments: segments)
        let speakerIds = Array(meanEmbeddings.keys).sorted()
        guard speakerIds.count >= 2 else { return segments }

        // Union-find: parent[id] = id initially
        var parent = Dictionary(uniqueKeysWithValues: speakerIds.map { ($0, $0) })

        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root { root = parent[root]! }
            // Path compression
            var node = x
            while node != root {
                let next = parent[node]!
                parent[node] = root
                node = next
            }
            return root
        }

        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }

        // Compare every pair of speakers
        for i in 0..<speakerIds.count {
            for j in (i + 1)..<speakerIds.count {
                let idA = speakerIds[i], idB = speakerIds[j]
                guard let embA = meanEmbeddings[idA], let embB = meanEmbeddings[idB] else { continue }
                let sim = Transcription.cosineSimilarityStatic(embA, embB)
                if Float(sim) >= threshold {
                    union(idA, idB)
                }
            }
        }

        // Build merge map: old speaker ID → canonical speaker ID
        var mergeMap: [Int: Int] = [:]
        for id in speakerIds {
            mergeMap[id] = find(id)
        }

        // Check if any merges happened
        let mergedGroups = Dictionary(grouping: speakerIds, by: { find($0) }).filter { $0.value.count > 1 }
        guard !mergedGroups.isEmpty else { return segments }

        // Log merges
        for (canonical, members) in mergedGroups {
            let memberStr = members.map { "spk\($0)" }.joined(separator: "+")
            AppLogger.transcription.info("Pairwise merged speakers", [
                "merged": memberStr,
                "canonical": "spk\(canonical)"
            ])
        }

        // Reassign speaker IDs
        return segments.map { segment in
            let newId = mergeMap[segment.speakerId] ?? segment.speakerId
            guard newId != segment.speakerId else { return segment }
            return SpeakerSegment(
                speakerId: newId,
                startTime: segment.startTime,
                endTime: segment.endTime,
                embedding: segment.embedding,
                qualityScore: segment.qualityScore
            )
        }
    }

    // MARK: - Small Cluster Absorption

    /// Absorb tiny speaker clusters into the most similar larger cluster.
    ///
    /// Short interjections ("Mm-hmm", "Yeah") produce noisier embeddings that
    /// often don't meet the strict pairwise merge threshold (0.85). When a
    /// cluster's total speaking time is very small, it's almost certainly a
    /// fragment of a real speaker rather than a distinct person. We use a
    /// relaxed similarity threshold to merge these back.
    ///
    /// Safety: genuinely different speakers rarely exceed 0.6 cosine similarity,
    /// so the 0.72 threshold won't incorrectly merge distinct people.
    static func absorbSmallClusters(
        segments: [SpeakerSegment],
        minClusterDuration: Double = 30.0,
        absorptionThreshold: Float = 0.72
    ) -> [SpeakerSegment] {
        // Compute total speaking duration per speaker
        var durationPerSpeaker: [Int: Double] = [:]
        for seg in segments {
            durationPerSpeaker[seg.speakerId, default: 0] += seg.duration
        }

        let smallIds = Set(durationPerSpeaker.filter { $0.value < minClusterDuration }.map { $0.key })
        let largeIds = Set(durationPerSpeaker.filter { $0.value >= minClusterDuration }.map { $0.key })

        guard !smallIds.isEmpty, !largeIds.isEmpty else { return segments }

        // Quality-filtered mean embeddings for all clusters
        var embeddings = computeMeanEmbeddingsPerSpeaker(segments: segments)

        // Small clusters may have NO quality-filtered segments (all too short/quiet).
        // Fall back to unfiltered embeddings so we have something to compare.
        for smallId in smallIds where embeddings[smallId] == nil {
            let rawEmbeddings = segments
                .filter { $0.speakerId == smallId }
                .compactMap { $0.embedding }
                .filter { !$0.isEmpty }
            if !rawEmbeddings.isEmpty {
                embeddings[smallId] = Transcription.computeMeanEmbedding(rawEmbeddings)
            }
        }

        // Try to absorb each small cluster into the best-matching large one
        var mergeMap: [Int: Int] = [:]
        for smallId in smallIds {
            guard let smallEmb = embeddings[smallId] else { continue }

            var bestId: Int?
            var bestSim: Float = 0

            for largeId in largeIds {
                guard let largeEmb = embeddings[largeId] else { continue }
                let sim = Float(Transcription.cosineSimilarityStatic(smallEmb, largeEmb))
                if sim > bestSim {
                    bestSim = sim
                    bestId = largeId
                }
            }

            if let targetId = bestId, bestSim >= absorptionThreshold {
                mergeMap[smallId] = targetId
                AppLogger.transcription.info("Absorbing small cluster", [
                    "smallSpk": "spk\(smallId)",
                    "duration": String(format: "%.1fs", durationPerSpeaker[smallId] ?? 0),
                    "into": "spk\(targetId)",
                    "similarity": String(format: "%.3f", bestSim)
                ])
            } else {
                AppLogger.transcription.debug("Small cluster not absorbed", [
                    "smallSpk": "spk\(smallId)",
                    "duration": String(format: "%.1fs", durationPerSpeaker[smallId] ?? 0),
                    "bestSim": String(format: "%.3f", bestSim),
                    "threshold": String(format: "%.2f", absorptionThreshold)
                ])
            }
        }

        guard !mergeMap.isEmpty else { return segments }

        return segments.map { segment in
            guard let newId = mergeMap[segment.speakerId] else { return segment }
            return SpeakerSegment(
                speakerId: newId,
                startTime: segment.startTime,
                endTime: segment.endTime,
                embedding: segment.embedding,
                qualityScore: segment.qualityScore
            )
        }
    }

    // MARK: - DB-Informed Split

    /// Split clusters that contain 2+ known DB voices.
    ///
    /// When Sortformer merges different speakers into one cluster,
    /// the per-segment embeddings still differ. We match each segment
    /// against known DB profiles to detect and separate mixed clusters.
    static func dbInformedSplit(
        segments: [SpeakerSegment],
        profiles: [SpeakerProfile],
        perSegmentThreshold: Float = 0.62,
        minSegmentsPerProfile: Int = 8
    ) -> [SpeakerSegment] {
        guard !profiles.isEmpty else { return segments }

        // Group segments by speaker ID
        var segmentsBySpkId: [Int: [(index: Int, segment: SpeakerSegment)]] = [:]
        for (i, seg) in segments.enumerated() {
            segmentsBySpkId[seg.speakerId, default: []].append((i, seg))
        }

        // We'll need new speaker IDs for split-off groups.
        // Start above the max existing speaker ID.
        var nextSpeakerId = (segments.map { $0.speakerId }.max() ?? 0) + 1
        var result = segments

        for (speakerId, indexedSegments) in segmentsBySpkId {
            // Only attempt split on clusters with enough segments
            guard indexedSegments.count >= minSegmentsPerProfile * 2 else { continue }

            // Score each segment against each profile
            // profileId → list of segment indices that match
            var matchesByProfile: [UUID: [Int]] = [:]

            for (idx, seg) in indexedSegments {
                guard let embedding = seg.embedding, !embedding.isEmpty else { continue }
                // Skip very short/low-quality segments — too noisy for per-segment matching
                guard seg.duration >= 0.5, seg.qualityScore >= 0.2 else { continue }

                var bestProfileId: UUID?
                var bestSim: Float = 0

                for profile in profiles {
                    guard profile.embedding.count == embedding.count else { continue }
                    let sim = Float(Transcription.cosineSimilarityStatic(embedding, profile.embedding))
                    if sim >= perSegmentThreshold && sim > bestSim {
                        bestSim = sim
                        bestProfileId = profile.id
                    }
                }

                if let profileId = bestProfileId {
                    matchesByProfile[profileId, default: []].append(idx)
                }
            }

            // Check if 2+ profiles each have enough matching segments
            let significantProfiles = matchesByProfile.filter { $0.value.count >= minSegmentsPerProfile }
            guard significantProfiles.count >= 2 else { continue }

            // Split! Assign each significant profile's segments to a new speaker ID.
            // The first profile keeps the original speaker ID; others get new IDs.
            let sortedProfiles = significantProfiles.sorted { $0.value.count > $1.value.count }

            for (profileIdx, (profileId, segmentIndices)) in sortedProfiles.enumerated() {
                let assignedSpkId: Int
                if profileIdx == 0 {
                    // Largest group keeps original speaker ID
                    assignedSpkId = speakerId
                } else {
                    assignedSpkId = nextSpeakerId
                    nextSpeakerId += 1
                }

                for idx in segmentIndices {
                    let seg = result[idx]
                    if seg.speakerId != assignedSpkId {
                        result[idx] = SpeakerSegment(
                            speakerId: assignedSpkId,
                            startTime: seg.startTime,
                            endTime: seg.endTime,
                            embedding: seg.embedding,
                            qualityScore: seg.qualityScore
                        )
                    }
                }

                let profileName = profiles.first(where: { $0.id == profileId })?.displayName ?? profileId.uuidString.prefix(8).description
                AppLogger.transcription.info("DB-informed split", [
                    "originalSpkId": "spk\(speakerId)",
                    "profile": profileName,
                    "assignedSpkId": "spk\(assignedSpkId)",
                    "segments": "\(segmentIndices.count)"
                ])
            }

            // Unmatched segments stay on the original speaker ID (no change needed)
            let allMatchedIndices = Set(significantProfiles.values.flatMap { $0 })
            let unmatchedCount = indexedSegments.count - allMatchedIndices.count
            if unmatchedCount > 0 {
                AppLogger.transcription.info("DB-informed split unmatched segments remain on spk\(speakerId)", [
                    "count": "\(unmatchedCount)"
                ])
            }
        }

        return result
    }

    // MARK: - Helpers

    /// Compute quality-filtered mean embedding per speaker ID.
    /// Filters out low-quality (< 0.3) and short (< 1.0s) segments.
    private static func computeMeanEmbeddingsPerSpeaker(
        segments: [SpeakerSegment]
    ) -> [Int: [Float]] {
        var embeddingsPerSpeaker: [Int: [[Float]]] = [:]

        for segment in segments {
            guard let embedding = segment.embedding, !embedding.isEmpty else { continue }
            guard segment.qualityScore >= 0.3, segment.duration >= 1.0 else { continue }
            embeddingsPerSpeaker[segment.speakerId, default: []].append(embedding)
        }

        var result: [Int: [Float]] = [:]
        for (speakerId, embeddings) in embeddingsPerSpeaker {
            result[speakerId] = Transcription.computeMeanEmbedding(embeddings)
        }
        return result
    }
}
