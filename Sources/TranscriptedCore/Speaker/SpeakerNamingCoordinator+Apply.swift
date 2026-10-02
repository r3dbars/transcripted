import Foundation

// MARK: - Speaker Naming Apply

extension TranscriptionTaskManager {

    /// Map submitted review verdicts onto the recognition lifeline.
    ///
    /// Corrections attribute to the profile that was wrongly suggested (the
    /// pre-meeting matched snapshot) so the mistake lands on the profile that
    /// made it; everything else attributes to the resolved profile. Collapse
    /// and discard rows are user bookkeeping, not match verdicts, and are
    /// intentionally not recorded.
    nonisolated static func plannedMatchOutcomes(
        for updates: [SpeakerNameUpdate],
        clipsBySpeakerId: [String: SpeakerNamingEntry],
        transcriptId: UUID
    ) -> [SpeakerMatchOutcome] {
        updates.compactMap { update in
            guard let kind = SpeakerMatchOutcomeKind(reviewAction: update.action) else {
                return nil
            }

            let entry = clipsBySpeakerId[update.channel.speakerKey(diarizerSpeakerId: update.diarizerSpeakerId)]
            let profileId: UUID
            switch update.action {
            case .corrected:
                profileId = entry?.matchedProfileSnapshot?.id ?? update.persistentSpeakerId
            case .merged(let targetProfileId):
                profileId = targetProfileId
            default:
                profileId = update.resolvedPersistentSpeakerId ?? update.persistentSpeakerId
            }

            return SpeakerMatchOutcome(
                profileId: profileId,
                kind: kind,
                similarity: entry?.matchSimilarity,
                secondSimilarity: entry?.matchSecondSimilarity,
                callCountAtMatch: entry?.matchedProfileSnapshot?.callCount,
                channel: update.channel.rawValue,
                transcriptId: transcriptId
            )
        }
    }

    /// Canonical identity-learning proof. Unlike the recognition lifeline,
    /// corrections are attributed to the corrected-to profile. A unique
    /// profile/transcript constraint means multiple rows for one person in one
    /// meeting still count as exactly one confirmation.
    nonisolated static func plannedUserConfirmations(
        for updates: [SpeakerNameUpdate],
        transcriptId: UUID
    ) -> [SpeakerUserConfirmation] {
        updates.compactMap { update in
            guard let kind = SpeakerUserConfirmationKind(reviewAction: update.action) else {
                return nil
            }

            let profileId: UUID
            switch update.action {
            case .merged(let targetProfileId):
                profileId = targetProfileId
            case .named, .confirmed, .corrected:
                profileId = update.resolvedPersistentSpeakerId ?? update.persistentSpeakerId
            case .collapsedToMe, .discardedFromDatabase:
                return nil
            }
            return SpeakerUserConfirmation(
                profileId: profileId,
                transcriptId: transcriptId,
                kind: kind
            )
        }
    }

    /// Points each confirmation at the person who holds that profile after the planned
    /// mutations (following a merge another meeting made after Save), and drops the
    /// ones whose person no longer exists (for example a name saved only in the
    /// transcript). A confirmation is a maturity signal; losing one is harmless, while
    /// a missing row used to fail the entire save.
    /// Internal (not private) only so the naming flow can span files.
    nonisolated static func liveProfileConfirmations(
        _ confirmations: [SpeakerUserConfirmation],
        speakerDB: any SpeakerStore
    ) -> [SpeakerUserConfirmation] {
        confirmations.compactMap { confirmation in
            guard let liveId = liveProfileId(for: confirmation.profileId, speakerDB: speakerDB) else {
                AppLogger.speakers.warning("Skipped speaker confirmation for a profile that no longer exists", [
                    "profileId": confirmation.profileId.uuidString
                ])
                return nil
            }
            guard liveId != confirmation.profileId else { return confirmation }
            return SpeakerUserConfirmation(
                profileId: liveId,
                transcriptId: confirmation.transcriptId,
                kind: confirmation.kind,
                confirmedAt: confirmation.confirmedAt
            )
        }
    }

    /// Internal (not private) only so the naming flow can span files.
    nonisolated static func shouldApplyNoDialogDatabaseMutation(_ action: SpeakerNameUpdate.NamingAction) -> Bool {
        switch action {
        case .confirmed, .corrected, .merged:
            return true
        case .named, .collapsedToMe, .discardedFromDatabase:
            return false
        }
    }

    nonisolated static func applyPlannedNamingMutations(
        _ mutations: [PlannedSpeakerMutation],
        speakerDB: any SpeakerStore
    ) throws {
        for mutation in mutations {
            switch mutation {
            case .merge(let sourceId, let targetId):
                // The plan only merges profiles that existed at Save. If another meeting's
                // cleanup removed this one since, its voice already went elsewhere; failing
                // the whole save over it would lose every name the user typed.
                guard speakerDB.getSpeaker(id: sourceId) != nil else {
                    AppLogger.speakers.warning("Skipped merging a speaker profile that no longer exists", [
                        "sourceId": sourceId.uuidString,
                        "targetId": targetId.uuidString
                    ])
                    continue
                }
                // The same goes for the person it merges into: follow them to whoever
                // absorbed them, and leave the source alone if they were deleted.
                guard let liveTargetId = liveProfileId(for: targetId, speakerDB: speakerDB),
                      liveTargetId != sourceId else {
                    AppLogger.speakers.warning("Skipped merging into a speaker profile that no longer exists", [
                        "sourceId": sourceId.uuidString,
                        "targetId": targetId.uuidString
                    ])
                    continue
                }
                do {
                    try speakerDB.mergeProfiles(sourceId: sourceId, into: liveTargetId)
                } catch {
                    throw SpeakerFinalizationFailureReason.mergeError(
                        from: error,
                        sourceId: sourceId,
                        targetId: liveTargetId
                    )
                }
            case .setDisplayName(let id, let name):
                speakerDB.setDisplayName(id: id, name: name, source: NameSource.userManual)
            case .restoreProfile(let profile):
                speakerDB.restoreProfile(profile)
            case .addOrUpdateEmbedding(let embedding, let existingId):
                _ = speakerDB.addOrUpdateSpeaker(embedding: embedding, existingId: existingId)
            case .teachVoice(let embedding, let profileId):
                // Never re-create a person the user or another meeting removed after Save.
                guard let liveId = liveProfileId(for: profileId, speakerDB: speakerDB) else {
                    AppLogger.speakers.warning("Skipped teaching a voice to a speaker profile that no longer exists", [
                        "profileId": profileId.uuidString
                    ])
                    continue
                }
                _ = speakerDB.addOrUpdateSpeaker(embedding: embedding, existingId: liveId)
            // Verdicts about a person follow them if another meeting merged them after
            // Save. A display name does not: renaming whoever absorbed them would
            // override that merge's choice of name.
            case .incrementDisputeCount(let id):
                if let liveId = liveProfileId(for: id, speakerDB: speakerDB) {
                    speakerDB.incrementDisputeCount(id: liveId)
                }
            case .resetDisputeCount(let id):
                if let liveId = liveProfileId(for: id, speakerDB: speakerDB) {
                    speakerDB.resetDisputeCount(id: liveId)
                }
            case .recordNegativeExemplar(let profileId, let embedding):
                if let liveId = liveProfileId(for: profileId, speakerDB: speakerDB) {
                    speakerDB.recordNegativeExemplar(profileId: liveId, embedding: embedding)
                }
            }
        }
    }

    /// The id that holds this person right now: the id itself when it still exists,
    /// else whoever the merge log says absorbed it. Nil when the person was deleted.
    nonisolated private static func liveProfileId(for id: UUID, speakerDB: any SpeakerStore) -> UUID? {
        if speakerDB.getSpeaker(id: id) != nil { return id }
        return speakerDB.mergeSurvivorId(of: id)
    }
}
