import Foundation

// MARK: - Speaker Matching

@available(macOS 14.0, *)
extension SpeakerDatabase {

    /// Match an embedding against all stored speakers using cosine similarity.
    /// Returns the best match above threshold with similarity score, or nil for a new speaker.
    public func matchSpeaker(embedding: [Float], threshold: Double = 0.6) -> SpeakerMatchResult? {
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
            let similarity = SpeakerVectorMath.cosineSimilarity(embedding, speaker.embedding)
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
}
