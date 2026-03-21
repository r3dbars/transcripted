import Foundation

// MARK: - Speaker Database Protocol
// Conformer: SpeakerDatabase

protocol SpeakerStore {
    /// Match a voice embedding against known speaker profiles
    func matchSpeaker(embedding: [Float], threshold: Double) -> SpeakerMatchResult?

    /// Add a new speaker or update an existing profile with a new embedding
    func addOrUpdateSpeaker(embedding: [Float], existingId: UUID?) -> SpeakerProfile

    /// Get a specific speaker profile by ID
    func getSpeaker(id: UUID) -> SpeakerProfile?

    /// Get all speaker profiles
    func allSpeakers() -> [SpeakerProfile]

    /// Set the display name for a speaker
    func setDisplayName(id: UUID, name: String, source: String)

    /// Delete a speaker profile
    func deleteSpeaker(id: UUID)

    /// Merge two speaker profiles (source absorbed into target)
    func mergeProfiles(sourceId: UUID, into targetId: UUID)

    /// Merge profiles that share the same display name
    func mergeProfilesByName()

    /// Merge obviously duplicate profiles (high cosine similarity)
    func mergeDuplicates()

    /// Remove weak/unnamed profiles with low confidence
    func pruneWeakProfiles()

    /// Reset dispute count for a confirmed speaker
    func resetDisputeCount(id: UUID)

    /// Find profiles matching a name (fuzzy, with name variants)
    func findProfilesByName(_ name: String) -> [SpeakerProfile]
}
