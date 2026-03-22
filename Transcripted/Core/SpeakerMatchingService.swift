import Foundation
import Accelerate

// MARK: - In-Memory Speaker Matching

@available(macOS 26.0, *)
extension Transcription {

    /// Result of matching against an in-memory snapshot of profiles
    struct SnapshotMatchResult {
        let profileId: UUID
        let similarity: Double
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

        let scale = Float(embeddings.count)
        var mean = sum.map { $0 / scale }

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
    nonisolated static func matchAgainstProfiles(
        _ embedding: [Float],
        profiles: [SpeakerProfile],
        threshold: Double
    ) -> SnapshotMatchResult? {
        guard !profiles.isEmpty, !embedding.isEmpty else { return nil }

        var bestId: UUID?
        var bestSimilarity: Double = -1

        for profile in profiles {
            guard profile.embedding.count == embedding.count else { continue }
            let similarity = cosineSimilarityStatic(embedding, profile.embedding)
            if similarity > bestSimilarity && similarity >= threshold {
                bestSimilarity = similarity
                bestId = profile.id
            }
        }

        if let id = bestId {
            return SnapshotMatchResult(profileId: id, similarity: bestSimilarity)
        }
        return nil
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
