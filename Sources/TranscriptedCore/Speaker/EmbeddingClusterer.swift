// EmbeddingClusterer.swift
// Post-processes diarization speaker segments to fix three failure modes:
//
// Supports both Sortformer (streaming) and PyAnnote (offline) pipelines.
//
// 1. Fragmentation: Same speaker split across multiple diarizer IDs.
//    Fixed by pairwise merge — compare mean embeddings of every speaker pair
//    and merge those above a high cosine similarity threshold.
//    Note: Skipped for PyAnnote offline output, where VBx clustering already
//    handles speaker merging/fragmentation.
//
// 2. Over-segmentation: One real voice split across several clusters that each
//    accumulate enough speech to survive small-cluster absorption. This is why
//    a one-on-one call can surface 4-7 "speakers" to name for a single person.
//    Fixed by same-voice consolidation — agglomeratively merge clusters whose
//    mean embeddings are as similar as the "same known person" auto-accept bar,
//    recomputing centroids after each merge so genuinely distinct speakers in a
//    crowded meeting do not chain-collapse.
//
// 3. Merging: Different speakers collapsed into one diarizer ID.
//    Fixed by DB-informed split — compare per-segment embeddings against
//    known speaker profiles and split clusters that contain 2+ distinct voices.

import Foundation
import Accelerate

public enum EmbeddingClusterer {

    /// Cosine-similarity bar for the same-voice consolidation pass. Must equal
    /// `SpeakerNamingPolicy.autoAcceptSimilarityThreshold` (0.88): consolidation
    /// should only collapse two clusters into one person when they are at least as
    /// similar as we'd demand to silently auto-accept them as the same known person.
    /// `EmbeddingClustererTests.testConsolidationThresholdMatchesAutoAcceptBar`
    /// asserts the two stay equal, so changing one without the other fails CI
    /// instead of silently drifting.
    public static let sameVoiceConsolidationThreshold: Float = 0.88

    /// Lower bar used only to detect "these centroids may belong to different
    /// known speakers" before consolidation. This mirrors the lowest adaptive
    /// profile-match threshold used by `TranscriptionPipeline`, so we preserve
    /// plausible known-speaker conflicts for the later naming/review path.
    private static let knownProfileConflictThreshold: Float = 0.70

    /// Post-process diarization segments: merge fragmented speakers,
    /// absorb tiny orphan clusters, then split clusters that contain
    /// multiple known DB voices.
    ///
    /// - Parameter pairwiseMergeThreshold: Cosine similarity threshold for merging
    ///   fragmented speaker clusters. Pass `nil` to skip only the pairwise merge
    ///   phase; small-cluster absorption, same-voice consolidation, and
    ///   DB-informed split still run.
    ///   Sortformer default: 0.85 (conservative). Offline PyAnnote callers pass
    ///   `nil` because VBx already handles the base merge/fragmentation case.
    /// - Parameter consolidationThreshold: Cosine similarity threshold for the
    ///   same-voice consolidation pass that collapses over-segmented large
    ///   clusters of one speaker. Pass `nil` to skip it. Defaults to the
    ///   `SpeakerNamingPolicy` auto-accept bar (0.88) so two clusters only merge
    ///   when they are more similar than we'd demand to auto-accept them as the
    ///   same known person.
    public static func postProcess(
        segments: [SpeakerSegment],
        existingProfiles: [SpeakerProfile],
        pairwiseMergeThreshold: Float? = 0.85,
        consolidationThreshold: Float? = sameVoiceConsolidationThreshold,
        thresholds: SpeakerEmbeddingThresholds = .weSpeaker
    ) -> [SpeakerSegment] {
        guard segments.count >= 2 else { return segments }
        var result: [SpeakerSegment]
        if let threshold = pairwiseMergeThreshold {
            result = pairwiseMerge(segments: segments, threshold: threshold)
        } else {
            result = segments
        }
        result = absorbSmallClusters(
            segments: result,
            absorptionThreshold: thresholds.absorb,
            microAbsorptionThreshold: thresholds.microAbsorb
        )
        if let consolidationThreshold {
            result = consolidateSameVoiceClusters(
                segments: result,
                threshold: consolidationThreshold,
                existingProfiles: existingProfiles,
                knownProfileConflictThreshold: thresholds.knownProfileConflict
            )
        }
        result = dbInformedSplit(
            segments: result,
            profiles: existingProfiles,
            perSegmentThreshold: thresholds.perSegmentSplit
        )
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
    /// Two-tier thresholds:
    /// - Micro-clusters (< `microClusterDuration`): Threshold 0.62 — safely above the
    ///   codec-compressed voice similarity range (0.3-0.5), absorbs noise fragments
    ///   while preserving genuinely distinct speakers.
    /// - Small clusters (< `minClusterDuration`): Standard relaxed threshold
    ///   (0.72). Safety: genuinely different speakers rarely exceed 0.6 cosine
    ///   similarity, so this won't incorrectly merge distinct people.
    ///
    /// Additional safeguards:
    /// - Clusters with 3+ segments are never absorbed (multiple speaking turns = real person)
    /// - Absorption is aborted if it would reduce the total speaker count below 2
    static func absorbSmallClusters(
        segments: [SpeakerSegment],
        minClusterDuration: Double = 30.0,
        absorptionThreshold: Float = 0.72,
        microClusterDuration: Double = 10.0,
        microAbsorptionThreshold: Float = 0.62
    ) -> [SpeakerSegment] {
        // Compute total speaking duration per speaker
        var durationPerSpeaker: [Int: Double] = [:]
        var segmentCountPerSpeaker: [Int: Int] = [:]
        var rawEmbeddingsPerSpeaker: [Int: [[Float]]] = [:]
        for seg in segments {
            durationPerSpeaker[seg.speakerId, default: 0] += seg.duration
            segmentCountPerSpeaker[seg.speakerId, default: 0] += 1
            if let embedding = seg.embedding, !embedding.isEmpty {
                rawEmbeddingsPerSpeaker[seg.speakerId, default: []].append(embedding)
            }
        }

        let smallIds = Set(durationPerSpeaker.filter { $0.value < minClusterDuration }.map { $0.key })
        let largeIds = Set(durationPerSpeaker.filter { $0.value >= minClusterDuration }.map { $0.key })

        guard !smallIds.isEmpty, !largeIds.isEmpty else { return segments }

        // Quality-filtered mean embeddings for all clusters
        var embeddings = computeMeanEmbeddingsPerSpeaker(segments: segments)

        // Small clusters may have NO quality-filtered segments (all too short/quiet).
        // Fall back to unfiltered embeddings so we have something to compare.
        for smallId in smallIds where embeddings[smallId] == nil {
            let rawEmbeddings = rawEmbeddingsPerSpeaker[smallId] ?? []
            if !rawEmbeddings.isEmpty {
                embeddings[smallId] = Transcription.computeMeanEmbedding(rawEmbeddings)
            }
        }

        // Try to absorb each small cluster into the best-matching large one
        var mergeMap: [Int: Int] = [:]
        for smallId in smallIds {
            // Protect multi-utterance speakers: 3+ separate speaking turns means
            // a real participant, not noise — regardless of total duration.
            let segmentCount = segmentCountPerSpeaker[smallId] ?? 0
            if segmentCount >= 3 {
                AppLogger.transcription.info("Small cluster protected by segment count", [
                    "smallSpk": "spk\(smallId)",
                    "segments": "\(segmentCount)",
                    "duration": String(format: "%.1fs", durationPerSpeaker[smallId] ?? 0)
                ])
                continue
            }

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

            // Two-tier threshold: micro-clusters (very short) use a much lower
            // floor since they can't plausibly be a distinct speaker.
            let duration = durationPerSpeaker[smallId] ?? 0
            let isMicro = duration < microClusterDuration
            let effectiveThreshold = isMicro ? microAbsorptionThreshold : absorptionThreshold

            if let targetId = bestId, bestSim >= effectiveThreshold {
                mergeMap[smallId] = targetId
                AppLogger.transcription.info("Absorbing \(isMicro ? "micro" : "small") cluster", [
                    "smallSpk": "spk\(smallId)",
                    "duration": String(format: "%.1fs", duration),
                    "into": "spk\(targetId)",
                    "similarity": String(format: "%.3f", bestSim),
                    "threshold": String(format: "%.2f", effectiveThreshold)
                ])
            } else {
                AppLogger.transcription.debug("Small cluster not absorbed", [
                    "smallSpk": "spk\(smallId)",
                    "duration": String(format: "%.1fs", duration),
                    "bestSim": String(format: "%.3f", bestSim),
                    "threshold": String(format: "%.2f", effectiveThreshold),
                    "isMicro": "\(isMicro)"
                ])
            }
        }

        guard !mergeMap.isEmpty else { return segments }

        // Safety: never absorb all small clusters if it would leave only 1 speaker.
        // A single system speaker is almost always a diarization failure on multi-party calls.
        let allSpeakerIds = Set(durationPerSpeaker.keys)
        let survivingIds = allSpeakerIds.subtracting(mergeMap.keys)
        if survivingIds.count < 2 {
            AppLogger.transcription.info("Safety: aborting absorptions to prevent single-speaker collapse", [
                "wouldAbsorb": "\(mergeMap.count) clusters",
                "totalSpeakers": "\(allSpeakerIds.count)"
            ])
            return segments
        }

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

    // MARK: - Same-Voice Consolidation

    /// Consolidate clusters that are almost certainly the same voice, even when
    /// each cluster is large enough to survive `absorbSmallClusters`.
    ///
    /// Offline VBx clustering sometimes splits one remote participant across
    /// several speaker IDs that each accumulate well over `minClusterDuration`
    /// of speech. `absorbSmallClusters` never touches them because it only folds
    /// short clusters into large ones, so a one-on-one call can surface 4-7
    /// "speakers" the user has to name for a single person.
    ///
    /// This pass compares the mean embedding of every surviving cluster pair and
    /// merges those above `threshold`. Two safeguards keep genuine
    /// multi-speaker meetings intact:
    /// - The threshold is high (0.88 by default — the `SpeakerNamingPolicy`
    ///   auto-accept bar). Distinct speakers rarely exceed ~0.6 cosine
    ///   similarity, so only near-identical voices merge.
    /// - Merging is agglomerative with recomputed centroids: after A and B
    ///   merge, the combined centroid must still clear `threshold` against C
    ///   before C joins. This avoids the transitive A≈B, B≈C → A+B+C collapse
    ///   that made the broad pairwise merge unsafe on VBx output.
    static func consolidateSameVoiceClusters(
        segments: [SpeakerSegment],
        threshold: Float = sameVoiceConsolidationThreshold,
        existingProfiles: [SpeakerProfile] = [],
        knownProfileConflictThreshold conflictThreshold: Float = knownProfileConflictThreshold
    ) -> [SpeakerSegment] {
        let distinctIds = Set(segments.map { $0.speakerId })
        guard distinctIds.count >= 2 else { return segments }

        // Collect embeddings per speaker. Prefer quality-filtered samples but
        // fall back to all samples so every cluster has a centroid to compare.
        var qualityEmbeddings: [Int: [[Float]]] = [:]
        var allEmbeddings: [Int: [[Float]]] = [:]
        for segment in segments {
            guard let embedding = segment.embedding, !embedding.isEmpty else { continue }
            allEmbeddings[segment.speakerId, default: []].append(embedding)
            if segment.qualityScore >= 0.3, segment.duration >= 1.0 {
                qualityEmbeddings[segment.speakerId, default: []].append(embedding)
            }
        }

        // Live clusters: the raw embeddings backing each centroid, so we can
        // recompute the centroid after every merge.
        var clusterEmbeddings: [Int: [[Float]]] = [:]
        for id in distinctIds {
            let quality = qualityEmbeddings[id] ?? []
            let embeddings = quality.isEmpty ? (allEmbeddings[id] ?? []) : quality
            if !embeddings.isEmpty {
                clusterEmbeddings[id] = embeddings
            }
        }
        guard clusterEmbeddings.count >= 2 else { return segments }

        var centroids: [Int: [Float]] = [:]
        for (id, embeddings) in clusterEmbeddings {
            centroids[id] = Transcription.computeMeanEmbedding(embeddings)
        }

        // old speaker ID → canonical surviving ID (identity to start).
        var mergeMap: [Int: Int] = [:]
        for id in clusterEmbeddings.keys { mergeMap[id] = id }

        // Repeatedly merge the single most-similar pair above threshold,
        // recomputing the merged centroid each round until nothing qualifies.
        while centroids.count >= 2 {
            let liveIds = centroids.keys.sorted()
            var bestSim = threshold
            var bestPair: (keep: Int, drop: Int)?
            for i in 0..<liveIds.count {
                for j in (i + 1)..<liveIds.count {
                    let a = liveIds[i], b = liveIds[j]
                    guard let ea = centroids[a], let eb = centroids[b] else { continue }
                    let sim = Float(Transcription.cosineSimilarityStatic(ea, eb))
                    if hasKnownProfileConflict(
                        ea,
                        eb,
                        profiles: existingProfiles,
                        conflictThreshold: conflictThreshold
                    ) {
                        continue
                    }
                    if sim > bestSim {
                        bestSim = sim
                        bestPair = (keep: a, drop: b)  // liveIds sorted, so a < b
                    }
                }
            }

            guard let pair = bestPair else { break }
            clusterEmbeddings[pair.keep, default: []].append(contentsOf: clusterEmbeddings[pair.drop] ?? [])
            clusterEmbeddings[pair.drop] = nil
            centroids[pair.keep] = Transcription.computeMeanEmbedding(clusterEmbeddings[pair.keep] ?? [])
            centroids[pair.drop] = nil
            for (old, canonical) in mergeMap where canonical == pair.drop {
                mergeMap[old] = pair.keep
            }
            AppLogger.transcription.info("Consolidated same-voice clusters", [
                "merged": "spk\(pair.drop)",
                "into": "spk\(pair.keep)",
                "similarity": String(format: "%.3f", bestSim)
            ])
        }

        guard mergeMap.contains(where: { $0.key != $0.value }) else { return segments }

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

    private static func hasKnownProfileConflict(
        _ lhs: [Float],
        _ rhs: [Float],
        profiles: [SpeakerProfile],
        conflictThreshold: Float
    ) -> Bool {
        guard !profiles.isEmpty else { return false }
        let lhsMatches = knownProfileMatches(for: lhs, profiles: profiles, conflictThreshold: conflictThreshold)
        let rhsMatches = knownProfileMatches(for: rhs, profiles: profiles, conflictThreshold: conflictThreshold)
        guard !lhsMatches.isEmpty, !rhsMatches.isEmpty else { return false }

        return lhsMatches.union(rhsMatches).count > 1
    }

    private static func knownProfileMatches(
        for embedding: [Float],
        profiles: [SpeakerProfile],
        conflictThreshold: Float
    ) -> Set<UUID> {
        Set(profiles.compactMap { profile in
            guard profile.disputeCount == 0,
                  profile.embedding.count == embedding.count else {
                return nil
            }
            let similarity = Float(Transcription.cosineSimilarityStatic(embedding, profile.embedding))
            return similarity >= conflictThreshold ? profile.id : nil
        })
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
