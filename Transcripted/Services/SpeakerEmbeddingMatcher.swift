import Foundation
import Accelerate

// MARK: - Speaker Matching

@available(macOS 14.0, *)
extension SpeakerDatabase {

    /// Match an embedding against all stored speakers using cosine similarity.
    /// Returns the best match above threshold with similarity score, or nil for a new speaker.
    func matchSpeaker(embedding: [Float], threshold: Double = 0.6) -> SpeakerMatchResult? {
        return queue.sync {
            matchSpeakerImpl(embedding: embedding, threshold: threshold)
        }
    }

    private func matchSpeakerImpl(embedding: [Float], threshold: Double) -> SpeakerMatchResult? {
        let allSpeakers = allSpeakersImpl()
        guard !allSpeakers.isEmpty else { return nil }

        var bestMatch: SpeakerProfile?
        var bestSimilarity: Double = -1

        for speaker in allSpeakers {
            let similarity = cosineSimilarity(embedding, speaker.embedding)
            if similarity > bestSimilarity && similarity >= threshold {
                bestSimilarity = similarity
                bestMatch = speaker
            }
        }

        if let match = bestMatch {
            AppLogger.speakers.info("Matched speaker", ["name": match.displayName ?? match.id.uuidString, "similarity": String(format: "%.3f", bestSimilarity)])
            return SpeakerMatchResult(profile: match, similarity: bestSimilarity)
        }

        return nil
    }

    // MARK: - Math Utilities

    /// Cosine similarity between two vectors
    func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
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

    /// L2 normalize a vector
    func l2Normalize(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_dotpr(v, 1, v, 1, &norm, vDSP_Length(v.count))
        norm = sqrt(norm)
        guard norm > 0 else { return v }

        var result = [Float](repeating: 0, count: v.count)
        var divisor = norm
        vDSP_vsdiv(v, 1, &divisor, &result, 1, vDSP_Length(v.count))
        return result
    }
}
