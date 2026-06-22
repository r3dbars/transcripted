import Foundation
import Accelerate

// MARK: - In-Memory Speaker Matching

extension Transcription {

    /// Result of matching against an in-memory snapshot of profiles
    struct SnapshotMatchResult {
        let profileId: UUID
        let similarity: Double
        /// Similarity of the next-closest non-disputed profile that cleared the floor, or -1
        /// if there was no runner-up. Used by `SpeakerNamingPolicy.shouldAutoAccept` as the
        /// "clear winner" margin guard.
        let secondBestSimilarity: Double
    }

    // MARK: - Embedding Utilities

    /// Compute the L2-normalized mean of multiple embeddings.
    /// Averaging reduces per-segment noise, producing a more stable speaker fingerprint.
    nonisolated static func computeMeanEmbedding(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        let dim = first.count
        guard dim > 0 else { return [] }

        if embeddings.count == 1 { return first }

        var sum = [Float](repeating: 0, count: dim)
        for emb in embeddings {
            for i in 0..<min(dim, emb.count) {
                sum[i] += emb[i]
            }
        }

        var mean = sum
        var scale = Float(embeddings.count)
        vDSP_vsdiv(mean, 1, &scale, &mean, 1, vDSP_Length(mean.count))
        return SpeakerVectorMath.l2Normalize(mean)
    }

    /// Match an embedding against a frozen snapshot of speaker profiles.
    /// Same logic as SpeakerDatabase.matchSpeaker but operates on an in-memory array,
    /// preventing the matching loop from seeing profiles created during the same recording.
    ///
    /// Includes two safeguards against false positives:
    /// - **Maturity bonus**: Immature profiles (callCount ≤ 2) require +0.08 higher similarity
    /// - **Separation check**: Rejects match if two profiles are within 0.05 (ambiguous)
    nonisolated static func matchAgainstProfiles(
        _ embedding: [Float],
        profiles: [SpeakerProfile],
        threshold: Double
    ) -> SnapshotMatchResult? {
        guard !profiles.isEmpty, !embedding.isEmpty else { return nil }

        var bestProfile: SpeakerProfile?
        var bestSimilarity: Double = -1
        var secondBestSimilarity: Double = -1

        for profile in profiles {
            // A disputed profile was explicitly rejected by the user; don't
            // auto-match future recordings back into it until the user repairs it.
            guard profile.disputeCount == 0 else { continue }
            guard profile.embedding.count == embedding.count else { continue }
            let similarity = cosineSimilarityStatic(embedding, profile.embedding)
            if similarity >= threshold {
                if similarity > bestSimilarity {
                    secondBestSimilarity = bestSimilarity
                    bestSimilarity = similarity
                    bestProfile = profile
                } else if similarity > secondBestSimilarity {
                    secondBestSimilarity = similarity
                }
            }
        }

        guard let matched = bestProfile else { return nil }

        // Maturity bonus: immature profiles need higher similarity to match.
        let maturityBonus: Double = switch matched.callCount {
            case ...2: 0.08
            case 3...4: 0.04
            default: 0.0
        }
        let effectiveThreshold = threshold + maturityBonus

        if bestSimilarity < effectiveThreshold {
            AppLogger.transcription.info("Match rejected: immature profile", [
                "profile": matched.displayName ?? matched.id.uuidString.prefix(8).description,
                "callCount": "\(matched.callCount)",
                "similarity": String(format: "%.3f", bestSimilarity),
                "effectiveThreshold": String(format: "%.3f", effectiveThreshold)
            ])
            return nil
        }

        // Separation check: reject if two profiles are too close (ambiguous).
        if secondBestSimilarity >= threshold && (bestSimilarity - secondBestSimilarity) < 0.05 {
            AppLogger.transcription.info("Match rejected: ambiguous (two profiles too close)", [
                "bestProfile": matched.displayName ?? matched.id.uuidString.prefix(8).description,
                "bestSimilarity": String(format: "%.3f", bestSimilarity),
                "secondBestSimilarity": String(format: "%.3f", secondBestSimilarity)
            ])
            return nil
        }

        return SnapshotMatchResult(profileId: matched.id, similarity: bestSimilarity,
                                   secondBestSimilarity: secondBestSimilarity)
    }

    // MARK: - Cross-Cluster Link/Merge (#8)

    /// Plan for resolving multiple diarizer clusters that matched the same DB profile.
    public struct CrossClusterLinkPlan: Equatable {
        /// `member speakerId -> representative speakerId`: clusters that share one final identity
        /// (either genuine over-segmentation kept on the matched profile, or fragments of one
        /// spun-off distinct voice). The representative carries the identity for the whole group.
        public var remaps: [Int: Int] = [:]
        /// Representative speakerIds whose group should be discarded from the matched profile and
        /// given a *fresh* profile — a distinct voice (or fragments of one) that only coincidentally
        /// resembled the matched profile. Sorted for deterministic output.
        public var spinOffs: [Int] = []
        public init() {}
    }

    /// Decide, for clusters that matched the same DB profile, which are genuine over-segmentation of
    /// one voice (fuse) and which are distinct voices that merely resemble the profile (spin off).
    ///
    /// Decouples the link/merge decision from the per-utterance attach floor (#8): a cluster
    /// attaches to a profile at the loose adaptive floor (0.70), but two clusters only FUSE when
    /// they are directly similar *to each other* (cross-cluster cosine ≥
    /// `SpeakerWritePathPolicy.crossClusterLinkFloor`).
    ///
    /// Clusters on one profile are grouped by mutual cross-cluster similarity (union-find, so three
    /// fragments of one voice all collapse even if no single pair-with-the-largest holds). The group
    /// containing the cluster that *best matches the profile* keeps the identity; every other group
    /// is a distinct voice and is spun off to its own profile. Within each group the representative
    /// is the highest-similarity-to-profile cluster (ties: more segments, then lower id), so the
    /// real returning speaker keeps the name even when a longer distinct voice also matched.
    ///
    /// Pure and deterministic so the eval harness and unit tests exercise the two-people-one-profile
    /// (and N-people / 3-fragment) cases directly without the full audio pipeline.
    nonisolated public static func planCrossClusterLinks(
        matchedProfileBySpeaker: [Int: UUID],
        matchSimilarityBySpeaker: [Int: Double],
        meanBySpeaker: [Int: [Float]],
        segmentCountBySpeaker: [Int: Int]
    ) -> CrossClusterLinkPlan {
        var plan = CrossClusterLinkPlan()
        let byProfile = Dictionary(grouping: matchedProfileBySpeaker.keys) { matchedProfileBySpeaker[$0] }
        for (profileId, ids) in byProfile where profileId != nil && ids.count >= 2 {
            let clusters = ids.filter { meanBySpeaker[$0] != nil }
            guard clusters.count >= 2 else { continue }

            // Union-find over the same-profile clusters: fuse any pair similar enough to be one
            // voice, transitively (A≈B, B≈C ⇒ {A,B,C}).
            var parent = Dictionary(uniqueKeysWithValues: clusters.map { ($0, $0) })
            func find(_ x: Int) -> Int {
                var r = x
                while parent[r]! != r { r = parent[r]! }
                var n = x
                while n != r { let nx = parent[n]!; parent[n] = r; n = nx }
                return r
            }
            func union(_ a: Int, _ b: Int) {
                let ra = find(a), rb = find(b)
                if ra != rb { parent[rb] = ra }
            }
            for i in 0..<clusters.count {
                for j in (i + 1)..<clusters.count {
                    let s = cosineSimilarityStatic(meanBySpeaker[clusters[i]]!, meanBySpeaker[clusters[j]]!)
                    if SpeakerWritePathPolicy.shouldFuseMatchedClusters(crossClusterSimilarity: s) {
                        union(clusters[i], clusters[j])
                    }
                }
            }

            // Rank key: best match to the profile, then most segments, then lowest id (deterministic).
            func rank(_ c: Int) -> (Double, Int, Int) {
                (matchSimilarityBySpeaker[c] ?? -1, segmentCountBySpeaker[c] ?? 0, -c)
            }

            // The group that owns the profile = the one containing the overall best-matching cluster.
            let keeperRoot = clusters.max(by: { rank($0) < rank($1) }).map { find($0) }

            var components: [Int: [Int]] = [:]
            for c in clusters { components[find(c), default: []].append(c) }
            for (root, members) in components {
                let rep = members.max(by: { rank($0) < rank($1) })!
                for other in members where other != rep { plan.remaps[other] = rep }
                if root != keeperRoot { plan.spinOffs.append(rep) }
            }
        }
        plan.spinOffs.sort()
        return plan
    }

    /// Compute L2-normalized weighted mean of multiple embeddings.
    /// Higher-weight embeddings contribute more to the mean. Segments recorded while
    /// the local mic was active have lower weight (system audio contaminated by local voice).
    nonisolated static func computeWeightedMeanEmbedding(_ embeddings: [[Float]], weights: [Float]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        let dim = first.count
        guard dim > 0, embeddings.count == weights.count else { return computeMeanEmbedding(embeddings) }

        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return computeMeanEmbedding(embeddings) }

        var sum = [Float](repeating: 0, count: dim)
        for (emb, w) in zip(embeddings, weights) {
            for i in 0..<min(dim, emb.count) {
                sum[i] += emb[i] * w
            }
        }

        var mean = sum
        var scale = totalWeight
        vDSP_vsdiv(mean, 1, &scale, &mean, 1, vDSP_Length(mean.count))
        return SpeakerVectorMath.l2Normalize(mean)
    }

    /// Static cosine similarity (no instance needed — used in nonisolated static context)
    nonisolated static func cosineSimilarityStatic(_ a: [Float], _ b: [Float]) -> Double {
        SpeakerVectorMath.cosineSimilarity(a, b)
    }
}
