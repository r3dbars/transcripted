import Foundation

// MARK: - Speaker Matching

@available(macOS 14.0, *)
extension SpeakerDatabase {

    /// Match an embedding against all stored speakers.
    /// Delegates to `Transcription.matchAgainstProfiles` — the same matcher the live
    /// transcription pipeline uses — so persistent-store callers (this) and in-memory-snapshot
    /// callers (the pipeline, the offline eval harness) never drift onto two different algorithms.
    /// Returns the best match above threshold with similarity score, or nil for a new speaker.
    public func matchSpeaker(embedding: [Float], threshold: Double = 0.6) -> SpeakerMatchResult? {
        return queue.sync {
            matchSpeakerImpl(embedding: embedding, threshold: threshold)
        }
    }

    private func matchSpeakerImpl(embedding: [Float], threshold: Double) -> SpeakerMatchResult? {
        let allSpeakers = allSpeakersImpl()
        guard !allSpeakers.isEmpty else { return nil }

        // Fetched once (in-queue, no re-entrant queue.sync) so the shared matcher can veto profiles
        // whose rejected samples this embedding resembles. Empty until a correction records one,
        // keeping matching identical to the positive-only behavior for stores without negative
        // exemplars.
        let negativeExemplarsByProfile = allNegativeExemplarsImpl()

        guard let match = Transcription.matchAgainstProfiles(
            embedding,
            profiles: allSpeakers,
            threshold: threshold,
            negativeExemplarsByProfile: negativeExemplarsByProfile
        ) else { return nil }

        // matchAgainstProfiles returns a profile id against the snapshot passed in, so resolve it
        // back to the SpeakerProfile from that same snapshot rather than re-fetching (which could
        // race a concurrent write outside this queue.sync).
        guard let profile = allSpeakers.first(where: { $0.id == match.profileId }) else { return nil }

        AppLogger.speakers.info("Matched speaker", ["name": profile.displayName ?? profile.id.uuidString, "similarity": String(format: "%.3f", match.similarity)])
        return SpeakerMatchResult(profile: profile, similarity: match.similarity)
    }
}
