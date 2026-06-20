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

        // L2 normalize
        var norm: Float = 0
        vDSP_dotpr(mean, 1, mean, 1, &norm, vDSP_Length(mean.count))
        norm = sqrt(norm)
        if norm > 0 {
            vDSP_vsdiv(mean, 1, &norm, &mean, 1, vDSP_Length(mean.count))
        }
        return mean
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
    struct CrossClusterLinkPlan: Equatable {
        /// `other speakerId -> canonical speakerId`: genuine over-segmentation, fuse into one row.
        var remaps: [Int: Int] = [:]
        /// speakerIds whose shared-profile match should be discarded and replaced with a fresh
        /// profile — a distinct voice that only coincidentally matched the same profile.
        var spinOffs: [Int] = []
    }

    /// Decide, for clusters that matched the same DB profile, which are genuine over-segmentation of
    /// one voice (fuse) and which are distinct voices that merely resemble the profile (spin off).
    ///
    /// Decouples the link/merge decision from the per-utterance attach floor (#8): a cluster
    /// attaches to a profile at the loose adaptive floor (0.70), but two clusters only FUSE when
    /// they are directly similar to each other (cross-cluster cosine ≥
    /// `SpeakerWritePathPolicy.crossClusterLinkFloor`). The largest cluster keeps the matched
    /// identity; smaller distinct voices are spun off.
    ///
    /// Pure and deterministic so the eval/unit tests can exercise the two-people-one-profile case
    /// directly without the full audio pipeline.
    nonisolated static func planCrossClusterLinks(
        matchedProfileBySpeaker: [Int: UUID],
        meanBySpeaker: [Int: [Float]],
        segmentCountBySpeaker: [Int: Int]
    ) -> CrossClusterLinkPlan {
        var plan = CrossClusterLinkPlan()
        let byProfile = Dictionary(grouping: matchedProfileBySpeaker.keys) { matchedProfileBySpeaker[$0] }
        for (profileId, speakerIds) in byProfile where profileId != nil && speakerIds.count >= 2 {
            // Largest cluster (most segments) claims the identity; ties broken by speakerId for
            // deterministic output.
            let sorted = speakerIds.sorted { a, b in
                let ca = segmentCountBySpeaker[a] ?? 0
                let cb = segmentCountBySpeaker[b] ?? 0
                return ca == cb ? a < b : ca > cb
            }
            let canonical = sorted[0]
            guard let canonicalMean = meanBySpeaker[canonical] else { continue }
            for other in sorted.dropFirst() {
                guard let otherMean = meanBySpeaker[other] else {
                    plan.spinOffs.append(other)
                    continue
                }
                let crossSim = cosineSimilarityStatic(canonicalMean, otherMean)
                if SpeakerWritePathPolicy.shouldFuseMatchedClusters(crossClusterSimilarity: crossSim) {
                    plan.remaps[other] = canonical
                } else {
                    plan.spinOffs.append(other)
                }
            }
        }
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

        // L2 normalize
        var norm: Float = 0
        vDSP_dotpr(mean, 1, mean, 1, &norm, vDSP_Length(mean.count))
        norm = sqrt(norm)
        if norm > 0 {
            vDSP_vsdiv(mean, 1, &norm, &mean, 1, vDSP_Length(mean.count))
        }
        return mean
    }

    /// Static cosine similarity (no instance needed — used in nonisolated static context)
    nonisolated static func cosineSimilarityStatic(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        vDSP_dotpr(a, 1, a, 1, &normA, vDSP_Length(a.count))
        vDSP_dotpr(b, 1, b, 1, &normB, vDSP_Length(b.count))

        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }

        return Double(dotProduct / denom)
    }
}
