import Foundation

// MARK: - Speaker Database Protocol
// Conformer: SpeakerDatabase

public protocol SpeakerStore: Sendable {
    /// Match a voice embedding against known speaker profiles
    func matchSpeaker(embedding: [Float], threshold: Double) -> SpeakerMatchResult?

    /// Add a new speaker or update an existing profile with a new embedding
    func addOrUpdateSpeaker(embedding: [Float], existingId: UUID?) -> SpeakerProfile

    /// Add a new speaker or update an existing matched profile with an explicit EMA blend weight.
    ///
    /// `blendAlpha == 0` records the appearance (call-count / last-seen) **without** altering the
    /// stored voiceprint — used by the write-time contamination gate when a match is too marginal
    /// or ambiguous to safely adapt the fingerprint. Higher alpha blends as normal. See
    /// `SpeakerWritePathPolicy.voiceprintBlendAlpha`.
    func addOrUpdateSpeaker(embedding: [Float], existingId: UUID?, blendAlpha: Float) -> SpeakerProfile

    /// Get a specific speaker profile by ID
    func getSpeaker(id: UUID) -> SpeakerProfile?

    /// Get all speaker profiles
    func allSpeakers() -> [SpeakerProfile]

    /// Set the display name for a speaker
    func setDisplayName(id: UUID, name: String, source: String)

    /// Restore a profile to a previously snapshotted state.
    func restoreProfile(_ profile: SpeakerProfile)

    /// Delete a speaker profile
    func deleteSpeaker(id: UUID)

    /// Merge two speaker profiles (source absorbed into target)
    func mergeProfiles(sourceId: UUID, into targetId: UUID)

    /// Merge profiles that share the same display name
    func mergeProfilesByName()

    /// Merge obviously duplicate profiles (high cosine similarity)
    func mergeDuplicates()

    /// Merge obvious duplicates while preserving profiles that are still tied to pending review rows
    func mergeDuplicates(protecting protectedIds: Set<UUID>)

    /// Remove weak/unnamed profiles with low confidence
    func pruneWeakProfiles()

    /// Record that a match suggestion was rejected by the user.
    func incrementDisputeCount(id: UUID)

    /// Reset dispute count for a confirmed speaker
    func resetDisputeCount(id: UUID)

    /// Find profiles matching a name (fuzzy, with name variants)
    func findProfilesByName(_ name: String) -> [SpeakerProfile]

    /// Record one auto-accept or review verdict in the speaker's recognition lifeline
    func recordMatchOutcome(_ outcome: SpeakerMatchOutcome)

    /// Record a batch of lifeline outcomes (one review submit / one saved meeting)
    func recordMatchOutcomes(_ outcomes: [SpeakerMatchOutcome])

    /// Most-recent-first lifeline outcomes for a profile, for health/demotion decisions
    func recentMatchOutcomes(profileId: UUID, limit: Int) -> [SpeakerMatchOutcome]
}

public extension SpeakerStore {
    func mergeDuplicates(protecting protectedIds: Set<UUID>) {
        guard protectedIds.isEmpty else { return }
        mergeDuplicates()
    }

    /// Back-compat default: conformers that don't model an EMA blend weight (test doubles, simple
    /// stores) fall back to the standard write-back, ignoring `blendAlpha`. `SpeakerDatabase`
    /// provides a real implementation that honours the gate.
    func addOrUpdateSpeaker(embedding: [Float], existingId: UUID?, blendAlpha: Float) -> SpeakerProfile {
        addOrUpdateSpeaker(embedding: embedding, existingId: existingId)
    }

    /// Back-compat defaults: stores that don't persist the recognition lifeline (test doubles,
    /// simple stores) drop outcomes and report none, which keeps health assessment permissive.
    /// `SpeakerDatabase` provides the real SQLite-backed implementations.
    func recordMatchOutcome(_ outcome: SpeakerMatchOutcome) {}

    func recordMatchOutcomes(_ outcomes: [SpeakerMatchOutcome]) {
        for outcome in outcomes { recordMatchOutcome(outcome) }
    }

    func recentMatchOutcomes(profileId: UUID, limit: Int) -> [SpeakerMatchOutcome] { [] }
}
