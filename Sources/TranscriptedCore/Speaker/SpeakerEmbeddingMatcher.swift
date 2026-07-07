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

        // Fetched once (in-queue, no re-entrant queue.sync) so the loop can veto profiles whose
        // rejected samples this embedding resembles. Empty until a correction records one, keeping
        // matching identical to the positive-only behavior for stores without negative exemplars.
        let negativeExemplarsByProfile = allNegativeExemplarsImpl()

        var bestMatch: SpeakerProfile?
        var bestSimilarity: Double = -1

        for speaker in allSpeakers {
            guard speaker.embedding.count == embedding.count else { continue }
            // Best-fitting representative (blended average or any stored exemplar); identical to the
            // single cosine for legacy profiles whose exemplar set is empty.
            let similarity = SpeakerVectorMath.bestSimilarity(
                candidate: embedding, average: speaker.embedding, exemplars: speaker.exemplars)
            // Negative-exemplar veto — see matchAgainstProfiles for the shared rationale.
            if let negatives = negativeExemplarsByProfile[speaker.id],
               SpeakerNegativeExemplarPolicy.shouldVeto(
                   candidate: embedding,
                   positiveSimilarity: similarity,
                   negativeExemplars: negatives,
                   profileAverage: speaker.embedding,
                   positiveExemplars: speaker.exemplars
               ) {
                AppLogger.speakers.info("Match vetoed: negative exemplar", [
                    "name": speaker.displayName ?? speaker.id.uuidString,
                    "similarity": String(format: "%.3f", similarity)
                ])
                continue
            }
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
