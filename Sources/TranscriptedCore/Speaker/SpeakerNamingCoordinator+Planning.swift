import Foundation

// MARK: - Speaker Naming Planning

extension TranscriptionTaskManager {

    /// What a saved person becomes once one review's planned mutations have run.
    private enum PlannedProfileFate: Equatable {
        /// Still exists afterward. Another row may reuse it only under the same name.
        case kept(nameKey: String)
        /// Absorbed into another saved person and deleted.
        case mergedInto(UUID)
    }

    /// Planning state for one review. It is built from one snapshot of the people
    /// database taken at Save, so every row is planned against what actually exists
    /// then, and it records what earlier rows already decided for each person so a
    /// later row can never undo or contradict them.
    private struct NamingPlanState {
        let speakerDB: any SpeakerStore
        /// Saved people when planning started, in `allSpeakers()` order.
        let profiles: [SpeakerProfile]
        let profilesById: [UUID: SpeakerProfile]
        var fates: [UUID: PlannedProfileFate] = [:]
        /// The name each kept person ends up with, when this plan decided it.
        var plannedNames: [UUID: String] = [:]
        /// People this plan creates (new ids, or re-created ids that vanished).
        var createdIds: Set<UUID> = []
        var manualNameTargets: [String: (id: UUID, displayName: String)] = [:]
        private var databaseSurvivors: [UUID: UUID?] = [:]

        init(speakerDB: any SpeakerStore) {
            self.speakerDB = speakerDB
            profiles = speakerDB.allSpeakers()
            profilesById = Dictionary(profiles.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }

        /// The person is in the database (or created by this plan) before the batch runs.
        func isInDatabase(_ id: UUID) -> Bool {
            profilesById[id] != nil || createdIds.contains(id)
        }

        /// The person will still exist after this plan's merges.
        func willExist(_ id: UUID) -> Bool {
            guard isInDatabase(id) else { return false }
            if case .mergedInto = fates[id] { return false }
            return true
        }

        /// The person's name after the rows planned so far: the name an earlier row
        /// gave them, else their saved name. Nil when they have neither.
        func displayName(of id: UUID) -> String? {
            for name in [plannedNames[id], profilesById[id]?.displayName] {
                if let name, !TranscriptionTaskManager.normalizeSpeakerName(name).isEmpty {
                    return name
                }
            }
            return nil
        }

        /// Follows a person who is gone to whoever absorbed them: first through this
        /// plan's own merges, then through the database's merge log (another meeting's
        /// duplicate cleanup, or a merge the user made in Speakers). Nil when the person
        /// was deleted outright.
        mutating func survivingProfile(for id: UUID) -> UUID? {
            var current = id
            var visited: Set<UUID> = []
            while visited.insert(current).inserted {
                if willExist(current) { return current }
                if case .mergedInto(let next)? = fates[current] {
                    current = next
                    continue
                }
                guard !isInDatabase(current), let next = databaseSurvivor(of: current) else {
                    return nil
                }
                current = next
            }
            return nil
        }

        /// Only the database's merge log, never this plan's own merges.
        mutating func databaseSurvivor(of id: UUID) -> UUID? {
            if let cached = databaseSurvivors[id] { return cached }
            let survivor = speakerDB.mergeSurvivorId(of: id)
            databaseSurvivors[id] = survivor
            return survivor
        }

        func exactNamedTarget(named rawName: String, excluding excludedIds: Set<UUID>) -> SpeakerProfile? {
            let targetName = TranscriptionTaskManager.normalizeSpeakerName(rawName)
            guard !targetName.isEmpty else { return nil }

            return profiles
                .filter { profile in
                    !excludedIds.contains(profile.id)
                        && willExist(profile.id)
                        && TranscriptionTaskManager.normalizeSpeakerName(displayName(of: profile.id) ?? "") == targetName
                }
                .sorted { $0.callCount > $1.callCount }
                .first
        }

        /// Records that `id` stays, under `name`, unless an earlier row already decided it.
        /// `writesName` is true only when the row also emits `setDisplayName`, so a
        /// later row never sees a planned name that nothing writes.
        mutating func claimKept(_ id: UUID, name: String, writesName: Bool = false) {
            if writesName {
                plannedNames[id] = name
            }
            guard fates[id] == nil else { return }
            fates[id] = .kept(nameKey: TranscriptionTaskManager.normalizeSpeakerName(name))
        }

        private mutating func keep(_ id: UUID, name: String) {
            fates[id] = .kept(nameKey: TranscriptionTaskManager.normalizeSpeakerName(name))
            plannedNames[id] = name
        }

        mutating func registerManualName(_ nameKey: String, id: UUID, displayName: String) {
            guard !nameKey.isEmpty, manualNameTargets[nameKey] == nil else { return }
            manualNameTargets[nameKey] = (id, displayName)
        }

        /// Moves a row's own profile into `target`. Only the first row that decides a
        /// profile's fate merges it. When the profile is already gone, or an earlier row
        /// kept it under a name or sent it to a different person (mic and system rows,
        /// or two diarizer rows, can share one profile), the earlier decision stands and
        /// only this row's voice is taught to `target`. Merging it anyway used to delete
        /// a profile an earlier row still needed and fail the whole save.
        mutating func absorb(
            _ sourceId: UUID,
            into targetId: UUID,
            embedding: [Float]?
        ) -> [PlannedSpeakerMutation] {
            guard sourceId != targetId else { return [] }
            switch fates[sourceId] {
            case .mergedInto(let existingTarget)? where existingTarget == targetId:
                return []
            case nil where isInDatabase(sourceId):
                fates[sourceId] = .mergedInto(targetId)
                return [.merge(sourceId: sourceId, into: targetId)]
            default:
                guard let embedding else { return [] }
                return [.teachVoice(embedding: embedding, profileId: targetId)]
            }
        }

        /// Gives `profileId` the name when this review has not already committed it to
        /// something else. Otherwise the voice becomes a new saved person with that name.
        /// With no voice to build a person from, the name is saved in the transcript only
        /// and the returned id is not in the database (`willExist` is false for it).
        /// `allowNewProfile` is false for rows with no dialog: a speaker who never spoke
        /// in the transcript does not become a new saved person.
        mutating func claimNamedIdentity(
            _ profileId: UUID,
            name: String,
            embedding: [Float]?,
            allowNewProfile: Bool = true
        ) -> (profileId: UUID, mutations: [PlannedSpeakerMutation]) {
            let nameKey = TranscriptionTaskManager.normalizeSpeakerName(name)
            if willExist(profileId) {
                let isFreeForThisName: Bool
                switch fates[profileId] {
                case nil:
                    isFreeForThisName = true
                case .kept(let claimedNameKey)?:
                    isFreeForThisName = claimedNameKey == nameKey
                case .mergedInto?:
                    isFreeForThisName = false
                }
                if isFreeForThisName {
                    keep(profileId, name: name)
                    return (profileId, [
                        .setDisplayName(id: profileId, name: name),
                        .resetDisputeCount(profileId),
                    ])
                }
            } else if !isInDatabase(profileId) {
                // Deleted outside this review (for example pruned while the review sat
                // open). Re-create it under the same id so the transcript link stays valid.
                guard allowNewProfile, let embedding else {
                    AppLogger.speakers.warning("Speaker profile is gone and has no voice sample; saving the name in the transcript only", [
                        "speakerId": profileId.uuidString
                    ])
                    return (profileId, [])
                }
                createdIds.insert(profileId)
                keep(profileId, name: name)
                return (profileId, [
                    .addOrUpdateEmbedding(embedding: embedding, existingId: profileId),
                    .setDisplayName(id: profileId, name: name),
                    .resetDisputeCount(profileId),
                ])
            }

            guard allowNewProfile, let embedding else {
                // Another row already decided who this profile is. Linking this name to it
                // would put the wrong person in the transcript, and failing would lose every
                // name in the review, so the name goes in the transcript only.
                AppLogger.speakers.warning("Speaker row conflicts with another row for the same profile and has no voice sample; saving the name in the transcript only", [
                    "speakerId": profileId.uuidString
                ])
                return (UUID(), [])
            }
            let newProfileId = UUID()
            createdIds.insert(newProfileId)
            keep(newProfileId, name: name)
            return (newProfileId, [
                .addOrUpdateEmbedding(embedding: embedding, existingId: newProfileId),
                .setDisplayName(id: newProfileId, name: name),
                .resetDisputeCount(newProfileId),
            ])
        }
    }

    private struct PlannedNamingRow {
        let update: SpeakerNameUpdate
        let mutations: [PlannedSpeakerMutation]
    }

    /// Internal (not private) only so the naming flow can span files.
    nonisolated static func planNamingUpdates(
        _ updates: [SpeakerNameUpdate],
        clipsBySpeakerId: [String: SpeakerNamingEntry],
        noDialogSpeakerKeys: Set<String> = [],
        speakerDB: any SpeakerStore
    ) -> PlannedNamingChanges? {
        guard !updates.isEmpty else {
            return PlannedNamingChanges(resolvedUpdates: [], mutations: [])
        }

        var state = NamingPlanState(speakerDB: speakerDB)
        var resolvedUpdates: [SpeakerNameUpdate] = []
        resolvedUpdates.reserveCapacity(updates.count)
        var mutations: [PlannedSpeakerMutation] = []

        for update in updates {
            let speakerKey = update.channel.speakerKey(diarizerSpeakerId: update.diarizerSpeakerId)
            guard let row = planNamingRow(
                update,
                entry: clipsBySpeakerId[speakerKey],
                hasDialog: !noDialogSpeakerKeys.contains(speakerKey),
                state: &state
            ) else {
                return nil
            }

            AppLogger.speakers.info("Speaker named", [
                "originalId": update.persistentSpeakerId.uuidString,
                "resolvedId": (row.update.resolvedPersistentSpeakerId ?? update.persistentSpeakerId).uuidString,
                "name": row.update.newName,
                "action": "\(row.update.action)"
            ])
            resolvedUpdates.append(row.update)
            mutations.append(contentsOf: row.mutations)
        }

        // A name saved in the transcript only joins the saved person another row of
        // this review created or picked under the same typed name, so one name never
        // ends up with two links in one transcript.
        var transcriptOnlySpeakerKeys = Set<String>()
        for index in resolvedUpdates.indices {
            let update = resolvedUpdates[index]
            guard let resolvedId = update.resolvedPersistentSpeakerId,
                  !state.willExist(resolvedId) else {
                continue
            }
            let speakerKey = update.channel.speakerKey(diarizerSpeakerId: update.diarizerSpeakerId)
            // Rows with no dialog have nothing in the transcript to link, and repointing
            // them would record their verdicts and clips against someone else.
            if !noDialogSpeakerKeys.contains(speakerKey),
               let target = state.manualNameTargets[normalizeSpeakerName(update.newName)],
               state.willExist(target.id) {
                resolvedUpdates[index] = resolvedUpdate(
                    update,
                    name: target.displayName,
                    action: update.action,
                    profileId: target.id
                )
            } else {
                transcriptOnlySpeakerKeys.insert(speakerKey)
            }
        }

        return PlannedNamingChanges(
            resolvedUpdates: resolvedUpdates,
            mutations: mutations,
            transcriptOnlySpeakerKeys: transcriptOnlySpeakerKeys
        )
    }

    nonisolated private static func planNamingRow(
        _ update: SpeakerNameUpdate,
        entry: SpeakerNamingEntry?,
        hasDialog: Bool,
        state: inout NamingPlanState
    ) -> PlannedNamingRow? {
        switch update.action {
        case .merged(let requestedTargetId):
            if isMatchedPersonRelabel(update, entry: entry, targetProfileId: requestedTargetId) {
                // The row was recognized as one saved person and the user picked a
                // different saved person. Merging would fold the recognized person's
                // whole history into the pick and delete them. Treat it as the
                // correction it is: undo the match and teach the voice to the pick.
                return planCorrection(
                    update,
                    entry: entry,
                    explicitTargetId: requestedTargetId,
                    hasDialog: hasDialog,
                    state: &state
                )
            }
            guard let targetId = state.survivingProfile(for: requestedTargetId) else {
                guard hasDialog else {
                    // Nothing in the transcript to name, and naming the row's own profile
                    // would give a speaker who never spoke the picked person's name.
                    AppLogger.speakers.warning("Picked speaker profile no longer exists and the row has no dialog; skipping it", [
                        "targetId": requestedTargetId.uuidString
                    ])
                    return PlannedNamingRow(
                        update: resolvedUpdate(update, name: update.newName, action: update.action, profileId: requestedTargetId),
                        mutations: []
                    )
                }
                AppLogger.speakers.warning("Picked speaker profile no longer exists; saving the row as a typed name", [
                    "targetId": requestedTargetId.uuidString
                ])
                return planNamed(update, entry: entry, state: &state)
            }
            let resolvedName = targetId == requestedTargetId
                ? update.newName
                : (state.displayName(of: targetId) ?? update.newName)
            var mutations = state.absorb(
                update.persistentSpeakerId,
                into: targetId,
                embedding: entry?.sessionEmbedding
            )
            mutations.append(.resetDisputeCount(targetId))
            // A merge does not rename the target, so it stays under the name it has.
            state.claimKept(targetId, name: state.displayName(of: targetId) ?? resolvedName)
            return PlannedNamingRow(
                update: resolvedUpdate(update, name: resolvedName, action: .merged(targetProfileId: targetId), profileId: targetId),
                mutations: mutations
            )

        case .confirmed:
            return planConfirmed(update, entry: entry, hasDialog: hasDialog, state: &state)

        case .named:
            return planNamed(update, entry: entry, state: &state)

        case .corrected:
            return planCorrection(update, entry: entry, explicitTargetId: nil, hasDialog: hasDialog, state: &state)

        case .collapsedToMe, .discardedFromDatabase:
            // Handled upstream in handleNamingComplete: collapse rewrites transcript text and
            // deletes only newly-created mic profiles; discard removes transcript DB links and
            // either deletes a new profile or restores an existing matched profile snapshot.
            return PlannedNamingRow(
                update: resolvedUpdate(update, name: update.newName, action: update.action, profileId: update.persistentSpeakerId),
                mutations: []
            )
        }
    }

    /// A recognized, named person relabeled to a different saved person by name.
    /// Picking the same person (or a same-named duplicate) is still a merge.
    nonisolated private static func isMatchedPersonRelabel(
        _ update: SpeakerNameUpdate,
        entry: SpeakerNamingEntry?,
        targetProfileId: UUID
    ) -> Bool {
        guard let snapshot = entry?.matchedProfileSnapshot,
              snapshot.id == update.persistentSpeakerId,
              targetProfileId != snapshot.id else {
            return false
        }
        let recognizedName = normalizeSpeakerName(snapshot.displayName)
        return !recognizedName.isEmpty && recognizedName != normalizeSpeakerName(update.newName)
    }

    nonisolated private static func planConfirmed(
        _ update: SpeakerNameUpdate,
        entry: SpeakerNamingEntry?,
        hasDialog: Bool,
        state: inout NamingPlanState
    ) -> PlannedNamingRow? {
        let profileId = update.persistentSpeakerId
        if !state.willExist(profileId), let survivorId = state.survivingProfile(for: profileId) {
            let survivorName = state.displayName(of: survivorId)
            // Another meeting's cleanup (or a merge in Speakers) absorbed the confirmed
            // person before Save: confirm whoever holds them now, keeping that name.
            // An earlier row of this review merging the shared profile away only
            // carries this row along when it went to someone with the same name (or no
            // name); otherwise this voice is someone else and gets its own person below.
            let absorbedBeforeSave = !state.isInDatabase(profileId)
            let survivorHasSameName = survivorName.map {
                normalizeSpeakerName($0) == normalizeSpeakerName(update.newName)
            } ?? true
            if absorbedBeforeSave || survivorHasSameName {
                var mutations: [PlannedSpeakerMutation] = []
                if survivorName == nil {
                    mutations.append(.setDisplayName(id: survivorId, name: update.newName))
                }
                mutations.append(.resetDisputeCount(survivorId))
                let resolvedName = survivorName ?? update.newName
                state.claimKept(survivorId, name: resolvedName, writesName: survivorName == nil)
                return PlannedNamingRow(
                    update: resolvedUpdate(update, name: resolvedName, action: .confirmed, profileId: survivorId),
                    mutations: mutations
                )
            }
        }

        let identity = state.claimNamedIdentity(
            profileId,
            name: update.newName,
            embedding: entry?.sessionEmbedding ?? entry?.matchedProfileSnapshot?.embedding,
            allowNewProfile: hasDialog
        )
        return PlannedNamingRow(
            update: resolvedUpdate(update, name: update.newName, action: .confirmed, profileId: identity.profileId),
            mutations: identity.mutations
        )
    }

    nonisolated private static func planNamed(
        _ update: SpeakerNameUpdate,
        entry: SpeakerNamingEntry?,
        state: inout NamingPlanState
    ) -> PlannedNamingRow? {
        let sourceId = update.persistentSpeakerId
        let embedding = entry?.sessionEmbedding
        let nameKey = normalizeSpeakerName(update.newName)

        // Rows typed with the same name are one person: every row lands on the
        // profile the first of them resolved to.
        if let existing = state.manualNameTargets[nameKey] {
            var mutations = state.absorb(sourceId, into: existing.id, embedding: embedding)
            mutations.append(.resetDisputeCount(existing.id))
            return PlannedNamingRow(
                update: resolvedUpdate(update, name: existing.displayName, action: .named, profileId: existing.id),
                mutations: mutations
            )
        }

        if let target = state.exactNamedTarget(named: update.newName, excluding: [sourceId]) {
            var mutations = state.absorb(sourceId, into: target.id, embedding: embedding)
            mutations.append(.resetDisputeCount(target.id))
            state.claimKept(target.id, name: state.displayName(of: target.id) ?? update.newName)
            state.registerManualName(nameKey, id: target.id, displayName: update.newName)
            return PlannedNamingRow(
                update: resolvedUpdate(update, name: update.newName, action: .named, profileId: target.id),
                mutations: mutations
            )
        }

        let identity = state.claimNamedIdentity(sourceId, name: update.newName, embedding: embedding)
        if state.willExist(identity.profileId) {
            // A transcript-only name has no saved person for later rows to join.
            state.registerManualName(nameKey, id: identity.profileId, displayName: update.newName)
        }
        return PlannedNamingRow(
            update: resolvedUpdate(update, name: update.newName, action: .named, profileId: identity.profileId),
            mutations: identity.mutations
        )
    }

    nonisolated private static func planCorrection(
        _ update: SpeakerNameUpdate,
        entry: SpeakerNamingEntry?,
        explicitTargetId: UUID?,
        hasDialog: Bool,
        state: inout NamingPlanState
    ) -> PlannedNamingRow? {
        let embedding = entry?.sessionEmbedding
        let rejectedProfile = entry?.matchedProfileSnapshot
        var mutations: [PlannedSpeakerMutation] = []
        if let rejectedProfile {
            if state.willExist(rejectedProfile.id) {
                mutations.append(.restoreProfile(rejectedProfile))
                mutations.append(.incrementDisputeCount(rejectedProfile.id))
                // The rejected embedding becomes a negative exemplar against the wrongly-suggested
                // profile: "this voice is explicitly not this person", used to veto future matches.
                // Every target below excludes the rejected profile, so the same id is never
                // written a positive embedding and a negative exemplar for one correction.
                if let embedding {
                    mutations.append(.recordNegativeExemplar(profileId: rejectedProfile.id, embedding: embedding))
                }
                // Keep the rejected person as they are for the rest of this review, so a
                // later row sharing the profile cannot merge them away (and drop the
                // exemplar just written) or rename them.
                if let rejectedName = state.displayName(of: rejectedProfile.id) {
                    state.claimKept(rejectedProfile.id, name: rejectedName)
                }
            } else {
                AppLogger.speakers.warning("Correction skipped restoring a matched profile that no longer exists", [
                    "profileId": rejectedProfile.id.uuidString
                ])
            }
        }

        let excludedIds = Set([update.persistentSpeakerId, rejectedProfile?.id].compactMap { $0 })
        let nameKey = normalizeSpeakerName(update.newName)
        let resolvedName: String
        let targetId: UUID
        var writesName = true

        if let explicitTargetId,
           let survivorId = state.survivingProfile(for: explicitTargetId),
           !excludedIds.contains(survivorId) {
            // A saved person the user picked: teach them the voice, keep their name.
            targetId = survivorId
            resolvedName = explicitTargetId == survivorId
                ? update.newName
                : (state.displayName(of: survivorId) ?? update.newName)
            writesName = false
            if let embedding {
                mutations.append(.teachVoice(embedding: embedding, profileId: targetId))
            }
            mutations.append(.resetDisputeCount(targetId))
        } else if let existing = state.manualNameTargets[nameKey], !excludedIds.contains(existing.id) {
            targetId = existing.id
            resolvedName = existing.displayName
            if let embedding {
                mutations.append(.teachVoice(embedding: embedding, profileId: targetId))
            }
            mutations.append(.setDisplayName(id: targetId, name: resolvedName))
            mutations.append(.resetDisputeCount(targetId))
        } else if let target = state.exactNamedTarget(named: update.newName, excluding: excludedIds) {
            targetId = target.id
            resolvedName = update.newName
            if let embedding {
                mutations.append(.teachVoice(embedding: embedding, profileId: targetId))
            }
            mutations.append(.setDisplayName(id: targetId, name: resolvedName))
            mutations.append(.resetDisputeCount(targetId))
        } else if !hasDialog {
            // No saved person to teach and this speaker never spoke in the transcript:
            // keep the rejection, but do not turn a silent voice into a new saved person.
            AppLogger.speakers.warning("Correction row has no dialog and no existing person to teach; not creating a person", [
                "speakerId": update.persistentSpeakerId.uuidString
            ])
            return PlannedNamingRow(
                update: resolvedUpdate(update, name: update.newName, action: .corrected, profileId: explicitTargetId ?? UUID()),
                mutations: mutations
            )
        } else if let embedding {
            targetId = UUID()
            resolvedName = update.newName
            state.createdIds.insert(targetId)
            mutations.append(.addOrUpdateEmbedding(embedding: embedding, existingId: targetId))
            mutations.append(.setDisplayName(id: targetId, name: resolvedName))
            mutations.append(.resetDisputeCount(targetId))
        } else {
            AppLogger.speakers.error("Correction missing session embedding; refusing unsafe profile rewrite", [
                "speakerId": update.persistentSpeakerId.uuidString,
                "name": update.newName
            ])
            return nil
        }

        // A picked person is not renamed, so they stay under the name they have.
        let keptName = writesName
            ? resolvedName
            : (state.displayName(of: targetId) ?? resolvedName)
        state.claimKept(targetId, name: keptName, writesName: writesName)
        if explicitTargetId == nil {
            // Typed corrections coalesce with other typed rows of the same name.
            state.registerManualName(nameKey, id: targetId, displayName: resolvedName)
        }
        return PlannedNamingRow(
            update: resolvedUpdate(update, name: resolvedName, action: .corrected, profileId: targetId),
            mutations: mutations
        )
    }

    nonisolated private static func resolvedUpdate(
        _ update: SpeakerNameUpdate,
        name: String,
        action: SpeakerNameUpdate.NamingAction,
        profileId: UUID
    ) -> SpeakerNameUpdate {
        SpeakerNameUpdate(
            persistentSpeakerId: update.persistentSpeakerId,
            diarizerSpeakerId: update.diarizerSpeakerId,
            channel: update.channel,
            newName: name,
            previousName: update.previousName,
            action: action,
            resolvedPersistentSpeakerId: profileId
        )
    }

    nonisolated private static func normalizeSpeakerName(_ name: String?) -> String {
        (name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
