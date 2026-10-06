import SwiftUI
import AppKit
import Combine
import TranscriptedCore

@MainActor
final class SpeakerPeopleSettingsViewModel: ObservableObject {
    @Published var profiles: [SpeakerProfile] = []
    @Published var searchText: String = ""
    @Published private(set) var reviewQueueItems: [SpeakerPendingReviewItem] = [] {
        didSet { reviewQueueTranscriptPaths = Self.transcriptPaths(of: reviewQueueItems); rebuildReviewStack() }
    }
    /// Lets each Meetings row's "has a review" check skip scanning the queue.
    private(set) var reviewQueueTranscriptPaths: Set<String> = []
    /// The "Name these people" cards and what they hide from Everyone,
    /// rebuilt only when the queue, a skip, or Later changes it. The page,
    /// the Everyone list, and Home's attention row all read this one value.
    @Published private(set) var reviewStack = SpeakerReviewStack.empty
    @Published private(set) var hasLoadedProfiles = false
    /// Bumped to ask the "Search speakers" field to take focus (⌘F).
    @Published private(set) var searchFocusRequestToken = 0
    /// Voice groups the user dismissed with "Skip". Session-only (not
    /// persisted): there is no existing skip/dismiss field on the transcript
    /// frontmatter or `SpeakerProfile` this could route through, so a skipped
    /// row simply drops out of `reviewStack` for the rest of this
    /// launch and reappears on next relaunch or once genuinely renamed.
    @Published private(set) var skippedVoiceGroupIDs: Set<UUID> = [] {
        didSet { rebuildReviewStack() }
    }
    /// Calls skipped with "Skip this call". Saved, so they stay skipped.
    @Published private(set) var skippedCallKeys: Set<String> = SpeakerReviewSkippedCalls.load() {
        didSet { rebuildReviewStack() }
    }
    /// Calendar invitees per call, offered as one-tap names on its card.
    @Published private(set) var inviteesByCallKey: [String: [String]] = [:]
    private var inviteeLookupsStarted: Set<String> = []

    /// Mirrors the meeting controller's voiceprint migration gate: saved people
    /// moving into a new voice model's database. Edits made meanwhile wait in
    /// `editsWaitingForVoiceprintMigration` and run once it ends.
    @Published private(set) var voiceprintMigrationPhase: SpeakerVoiceprintMigrationGate.Phase = .idle
    private var voiceprintMigrationObservation: AnyCancellable?
    private var editsWaitingForVoiceprintMigration: [() -> Void] = []

    private let speakerDatabase: SpeakerDatabase
    private let transcriptDirectory: URL
    private let preferredClipsDirectory: URL
    private let legacyClipsDirectory: URL
    private(set) var duplicateCandidates: [SpeakerDuplicateCandidate] = []
    private var duplicateProfileIDs: Set<UUID> = []
    private var duplicateCountsByProfileID: [UUID: Int] = [:]
    private var mergeTargetIndex = SpeakerMergeTargetIndex.empty
    private var clipURLsByProfileID: [UUID: URL] = [:]
    private var undoableMergesByTargetID: [UUID: SpeakerMergeRecord] = [:]
    private var snapshotPublication = RefreshPublicationOrder()
    private var refreshState = CoalescedRefreshState()
    private let snapshotQueue = DispatchQueue(label: "Transcripted.SpeakerPeople.snapshot", qos: .userInitiated)
    private let duplicateCache = SpeakerDuplicateSnapshotCache()

    private struct Snapshot {
        let profiles: [SpeakerProfile]
        let duplicateCandidates: [SpeakerDuplicateCandidate]
        let duplicateProfileIDs: Set<UUID>
        let duplicateCountsByProfileID: [UUID: Int]
        let mergeTargetIndex: SpeakerMergeTargetIndex
        let clipURLsByProfileID: [UUID: URL]
        let reviewQueueItems: [SpeakerPendingReviewItem]
        let undoableMergesByTargetID: [UUID: SpeakerMergeRecord]
    }

    init(
        speakerDatabase: SpeakerDatabase,
        transcriptDirectory: URL = TranscriptSaver.defaultSaveDirectory,
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL = CoreStoragePaths.default.speakerClips,
        voiceprintMigrationGate: SpeakerVoiceprintMigrationGate? = nil
    ) {
        self.speakerDatabase = speakerDatabase
        self.transcriptDirectory = transcriptDirectory
        self.preferredClipsDirectory = preferredClipsDirectory
        self.legacyClipsDirectory = legacyClipsDirectory
        if let voiceprintMigrationGate {
            voiceprintMigrationPhase = voiceprintMigrationGate.phase
            // Synchronous on purpose: the mirror changes in the same step as
            // the gate, so an edit can never slip between the two.
            voiceprintMigrationObservation = voiceprintMigrationGate.$phase
                .dropFirst()
                .sink { [weak self] phase in
                    self?.voiceprintMigrationPhaseChanged(to: phase)
                }
        }
        refresh()
    }

    // MARK: - Voice model migration

    private func voiceprintMigrationPhaseChanged(to phase: SpeakerVoiceprintMigrationGate.Phase) {
        voiceprintMigrationPhase = phase
        guard !isMovingPeopleToNewVoiceModel else { return }
        refresh()
        let edits = editsWaitingForVoiceprintMigration
        editsWaitingForVoiceprintMigration.removeAll()
        edits.forEach { $0() }
    }

    /// Speaker edits never race the migration's writes: while it runs, `edit`
    /// is kept and run as soon as it ends. True when it was kept, so the caller
    /// stops here; false to go ahead now.
    private func deferUntilVoiceprintMigrationEnds(_ edit: @escaping () -> Void) -> Bool {
        guard isMovingPeopleToNewVoiceModel else { return false }
        editsWaitingForVoiceprintMigration.append(edit)
        return true
    }

    private func rebuildReviewStack() {
        let voices = SpeakerReviewQueueScanner.groupedByVoice(reviewQueueItems)
            .filter { !skippedVoiceGroupIDs.contains($0.id) }
        reviewStack = SpeakerReviewStack(
            voices: voices,
            skippedCallKeys: skippedCallKeys,
            laterCallKeys: laterCallKeys
        )
    }

    /// Dismisses a queued voice from its review card for this session without
    /// touching its saved profile or transcripts. See `skippedVoiceGroupIDs`.
    func skip(_ group: SpeakerPendingVoiceGroup) {
        skippedVoiceGroupIDs.insert(group.id)
    }

    /// Later on the top card: it goes to the back of the stack for now.
    @Published private(set) var laterCallKeys: [String] = [] {
        didSet { rebuildReviewStack() }
    }

    func sendCallToBack(_ group: SpeakerPendingMeetingGroup) {
        laterCallKeys.removeAll { $0 == group.id }
        laterCallKeys.append(group.id)
    }

    /// Skips a whole call. Its voices move to Everyone (still unnamed, still
    /// mergeable) and the card stays gone after a restart.
    func skipCall(_ group: SpeakerPendingMeetingGroup) {
        SpeakerReviewSkippedCalls.add(group.id)
        skippedCallKeys.insert(group.id)
    }

    /// Looks up who was invited to this call, once, for its name chips.
    /// Never asks for calendar access; imported recordings have no slot.
    func loadInvitees(for group: SpeakerPendingMeetingGroup) {
        guard !group.isImported, let start = group.recordedAt,
              inviteeLookupsStarted.insert(group.id).inserted else { return }
        let key = group.id
        Task { @MainActor [weak self] in
            let names = await MeetingInviteeCalendarReader.shared.inviteeNames(recordingStart: start)
            guard let self, !names.isEmpty else { return }
            self.inviteesByCallKey[key] = names
        }
    }

    /// The "Everyone" directory: every voice except the ones on the open
    /// review card right above it (named, deleted, or "This is me" there).
    /// Voices on cards further down the stack stay here, badged "Waiting in
    /// review", so they can be renamed, merged, or deleted without cycling
    /// the stack, and a search never hides a match.
    /// See `SpeakerReviewStack.directory`.
    var directoryProfiles: [SpeakerProfile] {
        reviewStack.directory(filteredProfiles, isSearching: isSearching)
    }

    /// Directory membership count independent of the search filter, used for
    /// the "N people" trailing label and to decide whether the Everyone
    /// section renders at all.
    var directoryCount: Int {
        reviewStack.directory(profiles, isSearching: false).count
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var filteredProfiles: [SpeakerProfile] {
        let duplicateIds = duplicateProfileIDs
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SpeakerPeopleReviewPolicy.sortedForPeopleSettings(profiles, duplicateIds: duplicateIds)
        }

        let query = trimmed.lowercased()
        let matches = profiles.filter { profile in
            if let name = profile.displayName?.lowercased(), name.contains(query) {
                return true
            }
            return profile.id.uuidString.lowercased().contains(query)
        }
        return SpeakerPeopleReviewPolicy.sortedForPeopleSettings(matches, duplicateIds: duplicateIds)
    }

    /// Asks the "Search speakers" field to take keyboard focus. Drives the ⌘F
    /// "Find Speaker" menu command.
    func requestSearchFocus() {
        searchFocusRequestToken += 1
    }

    func setShown(_ shown: Bool) {
        refreshState.isEnabled = shown
    }

    func refresh() {
        guard refreshState.request() else { return }
        startRefresh()
    }

    private func startRefresh() {
        let revision = snapshotPublication.beginRead()
        let speakerDatabase = self.speakerDatabase
        let preferredClipsDirectory = self.preferredClipsDirectory
        let legacyClipsDirectory = self.legacyClipsDirectory
        let duplicateCache = self.duplicateCache
        snapshotQueue.async { [weak self] in
            let snapshot = Self.snapshot(
                from: speakerDatabase,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory,
                duplicateCache: duplicateCache
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applySnapshot(snapshot, revision: revision)
                if self.refreshState.finished() { self.startRefresh() }
            }
        }
    }

    /// Reads through to the canonical store when the async UI snapshot has
    /// not loaded yet. Meeting rename validation must distinguish a genuinely
    /// deleted profile from a merely-not-yet-rendered one.
    func currentProfile(id: UUID) -> SpeakerProfile? {
        speakerDatabase.getSpeaker(id: id)
    }

    func clipURL(for speakerId: UUID) -> URL? {
        clipURLsByProfileID[speakerId]
    }

    func playSample(for speakerId: UUID) {
        guard let url = clipURL(for: speakerId) else { return }
        SpeakerClipPlayback.play(url)
    }

    func namePendingReviewItem(
        _ item: SpeakerPendingReviewItem,
        to newName: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        if deferUntilVoiceprintMigrationEnds({ [weak self] in
            self?.namePendingReviewItem(item, to: newName, completion: completion)
        }) { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion?(false)
            return
        }

        let speakerId = item.speakerId
        let queuedReviewItems = reviewQueueItems.filter { $0.speakerId == speakerId }
        let matchingReviewItems = queuedReviewItems.isEmpty ? [item] : queuedReviewItems
        let speakerDatabase = self.speakerDatabase
        runEditInBackground(completion: completion) {
            let allTranscriptUpdatesSucceeded: Bool
            do {
                allTranscriptUpdatesSucceeded = try TranscriptSaver.updateDeferredSpeakerNames(
                    matchingReviewItems.map { reviewItem in
                        TranscriptSaver.DeferredSpeakerNameUpdate(
                            transcriptURL: reviewItem.transcriptURL,
                            dbId: speakerId,
                            diarizerSpeakerId: reviewItem.diarizerSpeakerId,
                            channel: reviewItem.channel
                        )
                    },
                    newName: trimmed,
                    persistIdentity: {
                        try speakerDatabase.performMutationBatch {
                            try speakerDatabase.requireDisplayNameUpdate(
                                id: speakerId,
                                name: trimmed,
                                source: NameSource.userManual
                            )
                            speakerDatabase.resetDisputeCount(id: speakerId)
                            try speakerDatabase.recordUserConfirmations(
                                matchingReviewItems.compactMap { reviewItem in
                                    reviewItem.transcriptId.map {
                                        SpeakerUserConfirmation(
                                            profileId: speakerId,
                                            transcriptId: $0,
                                            kind: .named
                                        )
                                    }
                                }
                            )
                        }
                    }
                )
            } catch {
                AppLogger.speakers.error("Deferred speaker rename transaction failed", [
                    "profileId": speakerId.uuidString,
                    "error": error.localizedDescription
                ])
                allTranscriptUpdatesSucceeded = false
            }
            return allTranscriptUpdatesSucceeded
        }
    }

    /// A queued voice was given the name of a person already saved (an invitee
    /// chip or a typed "Alice"), so it joins them instead of becoming a second
    /// Alice. One transaction does what naming the voice and merging it would:
    /// each queued row is named with a `user_manual` source, every reference
    /// moves to the kept person, and each queued meeting records a confirmation
    /// for them, the same as a `.merged` answer in the island or review window.
    /// Transcripts roll back if the database step fails.
    func mergePendingReviewItem(
        _ item: SpeakerPendingReviewItem,
        into target: SpeakerProfile,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        if deferUntilVoiceprintMigrationEnds({ [weak self] in
            self?.mergePendingReviewItem(item, into: target, completion: completion)
        }) { return }
        let sourceId = item.speakerId
        let targetId = target.id
        guard sourceId != targetId else {
            completion?(false)
            return
        }
        let queuedReviewItems = reviewQueueItems.filter { $0.speakerId == sourceId }
        let matchingReviewItems = queuedReviewItems.isEmpty ? [item] : queuedReviewItems
        let reviewedRows = matchingReviewItems.map { reviewItem in
            TranscriptSaver.DeferredSpeakerNameUpdate(
                transcriptURL: reviewItem.transcriptURL,
                dbId: sourceId,
                diarizerSpeakerId: reviewItem.diarizerSpeakerId,
                channel: reviewItem.channel
            )
        }
        let confirmedTranscriptIds = matchingReviewItems.compactMap(\.transcriptId)
        let speakerDatabase = self.speakerDatabase
        let transcriptDirectory = self.transcriptDirectory
        let preferredClipsDirectory = self.preferredClipsDirectory
        let legacyClipsDirectory = self.legacyClipsDirectory

        runEditInBackground(completion: completion) {
            var didMerge = false
            do {
                let outcome = try SpeakerIdentityMutationService.apply(
                    .mergeReviewedVoice(
                        sourceId: sourceId,
                        targetId: targetId,
                        reviewedRows: reviewedRows,
                        confirmedTranscriptIds: confirmedTranscriptIds
                    ),
                    speakerDB: speakerDatabase,
                    directory: transcriptDirectory,
                    clipSideEffects: SpeakerIdentityMutationService.ClipSideEffects(
                        onMergeCommitted: { sourceId, targetId in
                            Self.promoteClipIfNeeded(
                                from: sourceId,
                                to: targetId,
                                preferredClipsDirectory: preferredClipsDirectory,
                                legacyClipsDirectory: legacyClipsDirectory
                            )
                            Self.deleteClips(
                                for: sourceId,
                                preferredClipsDirectory: preferredClipsDirectory,
                                legacyClipsDirectory: legacyClipsDirectory
                            )
                        }
                    )
                )
                if !outcome.succeeded {
                    AppLogger.speakers.error("Queued voice merge into saved person failed", [
                        "sourceId": sourceId.uuidString,
                        "targetId": targetId.uuidString
                    ])
                }
                didMerge = outcome.succeeded
            } catch {
                Self.reportMutationFailure(error, engine: "speakers", profileId: sourceId)
            }
            return didMerge
        }
    }

    /// "This is me" for a queued voice: assigns the shared owner identity
    /// (`SpeakerNameSelectionPolicy.ownerLabel`, "You") used consistently
    /// across Settings and the post-meeting naming sheet.
    ///
    /// There is no `collapsedToMe`/"Keep as You" mechanism reachable from
    /// this model — that logic lives in `SpeakerNamingCoordinator`, and only
    /// runs against a single in-progress meeting's `SpeakerNamingSheet`
    /// review (it deletes or restores one specific mic-channel profile
    /// created *during that meeting*). This queue instead scans *saved*
    /// transcripts across every past meeting (`SpeakerReviewQueueScanner`),
    /// so there is no coordinator instance to hand this off to. Per the task
    /// spec's fallback, this reuses the confirmed existing "You" semantic
    /// (`SpeakerNameSelectionPolicy.ownerLabel`, already used by the naming
    /// sheet's autocomplete for local-mic entries) through the model's own
    /// existing rename write path — the same thing that happens if the user
    /// types "You" into the field and presses Enter — and then folds the
    /// result into any other profile already named "You" so the identity
    /// stays singular instead of leaving two "You" profiles behind.
    func markPendingReviewItemAsMe(
        _ item: SpeakerPendingReviewItem,
        completion: ((Bool) -> Void)? = nil
    ) {
        let existingOwnerProfile = profiles.first {
            $0.id != item.speakerId && SpeakerNameSelectionPolicy.isOwnerLabel($0.displayName ?? "")
        }
        namePendingReviewItem(item, to: SpeakerNameSelectionPolicy.ownerLabel) { [weak self] didRename in
            guard didRename else {
                completion?(false)
                return
            }
            guard let self, let existingOwnerProfile else {
                completion?(true)
                return
            }
            // `namePendingReviewItem` already refreshed `profiles` on the main
            // actor before invoking this completion, so the just-renamed
            // profile (now displayName == "You") is findable here.
            guard let renamedProfile = self.profiles.first(where: { $0.id == item.speakerId }) else {
                completion?(true)
                return
            }
            // The rename to the owner label already succeeded, which is what
            // justifies completing the queue row. The fold-into-"You" merge
            // below is async cleanup; if it fails, the duplicate stays
            // visible in the directory with the normal duplicate badge and
            // Merge Into tools, so nothing is silently lost.
            self.merge(source: renamedProfile, into: existingOwnerProfile)
            completion?(true)
        }
    }

    /// Rename from an Everyone row. A voice still waiting for a name goes
    /// through the same path as naming it on its review card; see
    /// `SpeakerReviewStack.reviewItemForRename`.
    func renameFromEveryone(_ profile: SpeakerProfile, to newName: String) {
        if let item = SpeakerReviewStack.reviewItemForRename(of: profile, in: reviewQueueItems) {
            // Same as naming it on its card: a name one saved person already
            // has adds the voice to them instead of making a second one.
            if let existing = SpeakerNameSelectionPolicy.uniqueSavedPerson(
                named: newName,
                among: profiles,
                excluding: profile.id,
                id: \.id,
                displayName: \.displayName
            ) {
                mergePendingReviewItem(item, into: existing)
            } else {
                namePendingReviewItem(item, to: newName)
            }
        } else {
            rename(profile: profile, to: newName)
        }
    }

    func rename(
        profile: SpeakerProfile,
        to newName: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        if deferUntilVoiceprintMigrationEnds({ [weak self] in
            self?.rename(profile: profile, to: newName, completion: completion)
        }) { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion?(false)
            return
        }

        let profileId = profile.id
        let speakerDatabase = self.speakerDatabase
        let transcriptDirectory = self.transcriptDirectory
        runEditInBackground(completion: completion) {
            var didRename = false
            // Routed through the canonical mutation service (audit 2026-08-04): this used
            // to write the DB first and best-effort-scan transcripts second with no
            // rollback, so a transcript write failure left the DB and saved transcripts
            // disagreeing about the speaker's name. The service snapshots and rewrites
            // transcripts first and only commits the DB change once every rewrite has
            // succeeded, rolling transcripts back if the DB transaction itself fails.
            do {
                let outcome = try SpeakerIdentityMutationService.apply(
                    .rename(profileId: profileId, newName: trimmed),
                    speakerDB: speakerDatabase,
                    directory: transcriptDirectory
                )
                didRename = outcome.succeeded
                if !outcome.succeeded {
                    AppLogger.speakers.error("Manual speaker rename failed", ["profileId": profileId.uuidString])
                }
            } catch {
                Self.reportMutationFailure(error, engine: "speakers", profileId: profileId)
            }
            return didRename
        }
    }

    /// Surfaces a `SpeakerIdentityMutationService.MutationError` beyond the local log —
    /// specifically `.transcriptRestoreFailed`, where the DB and a saved transcript may now
    /// permanently disagree and a caller that only checked `outcome.succeeded` would never
    /// see it (this path throws instead of returning a plain `Outcome`). Privacy-safe:
    /// only a profile id (opaque UUID, not a name) and a file count go out, never a path or
    /// display name.
    nonisolated private static func reportMutationFailure(
        _ error: Error,
        engine: String,
        profileId: UUID
    ) {
        AppLogger.speakers.error("Manual speaker identity mutation failed", [
            "profileId": profileId.uuidString,
            "error": error.localizedDescription
        ])
        guard case SpeakerIdentityMutationService.MutationError.transcriptRestoreFailed(let fileCount) = error else {
            return
        }
        DispatchQueue.main.async {
            EventReporter.shared.capture(
                level: .error,
                engine: engine,
                event: "speaker_identity_transcript_restore_failed",
                message: "Speaker identity rollback could not restore one or more transcripts",
                context: [
                    "profileId": profileId.uuidString,
                    "fileCount": "\(fileCount)",
                ]
            )
        }
    }

    func merge(
        source: SpeakerProfile,
        into target: SpeakerProfile,
        completion: ((Bool) -> Void)? = nil
    ) {
        if deferUntilVoiceprintMigrationEnds({ [weak self] in
            self?.merge(source: source, into: target, completion: completion)
        }) { return }
        guard source.id != target.id else {
            completion?(false)
            return
        }

        let sourceId = source.id
        let targetId = target.id
        let speakerDatabase = self.speakerDatabase
        let transcriptDirectory = self.transcriptDirectory
        let preferredClipsDirectory = self.preferredClipsDirectory
        let legacyClipsDirectory = self.legacyClipsDirectory

        runEditInBackground(completion: completion) {
            // Routed through the canonical mutation service (audit 2026-08-04), replacing
            // SpeakerProfileMergeSideEffectCoordinator (DB + clips only, no transcript
            // rollback) plus a separate un-rolled-back TranscriptSaver.retroactivelyMergeSpeaker
            // scan. The service snapshots and rewrites transcripts first, commits the DB
            // merge inside a real transaction, rolls transcripts back if that transaction
            // throws, and only then runs clip promotion/deletion. Same-id merges are
            // rejected by the service itself now (MutationError.sameSourceAndTarget), so the
            // `source.id != target.id` guard above is defense in depth, not the only guard.
            var didMerge = false
            do {
                let outcome = try SpeakerIdentityMutationService.apply(
                    .merge(sourceId: sourceId, targetId: targetId),
                    speakerDB: speakerDatabase,
                    directory: transcriptDirectory,
                    clipSideEffects: SpeakerIdentityMutationService.ClipSideEffects(
                        onMergeCommitted: { sourceId, targetId in
                            Self.promoteClipIfNeeded(
                                from: sourceId,
                                to: targetId,
                                preferredClipsDirectory: preferredClipsDirectory,
                                legacyClipsDirectory: legacyClipsDirectory
                            )
                            Self.deleteClips(
                                for: sourceId,
                                preferredClipsDirectory: preferredClipsDirectory,
                                legacyClipsDirectory: legacyClipsDirectory
                            )
                        }
                    )
                )
                if !outcome.succeeded {
                    AppLogger.speakers.error("Manual speaker merge failed", [
                        "sourceId": sourceId.uuidString,
                        "targetId": targetId.uuidString
                    ])
                }
                didMerge = outcome.succeeded
            } catch {
                Self.reportMutationFailure(error, engine: "speakers", profileId: sourceId)
            }
            return didMerge
        }
    }

    /// Deletes the voice behind a pending review group. Thin wrapper over
    /// `delete(profile:)` so the "voices to name" overflow menu shares the same
    /// real deletion path as the all-speakers list.
    func deleteVoice(_ group: SpeakerPendingVoiceGroup, completion: ((Bool) -> Void)? = nil) {
        delete(profile: group.representative.profile, completion: completion)
    }

    func delete(profile: SpeakerProfile, completion: ((Bool) -> Void)? = nil) {
        if deferUntilVoiceprintMigrationEnds({ [weak self] in
            self?.delete(profile: profile, completion: completion)
        }) { return }
        let profileId = profile.id
        let speakerDatabase = self.speakerDatabase
        let preferredClipsDirectory = self.preferredClipsDirectory
        let legacyClipsDirectory = self.legacyClipsDirectory

        runEditInBackground(completion: completion) {
            speakerDatabase.deleteSpeaker(id: profileId)
            Self.deleteClips(
                for: profileId,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory
            )
            // Confirm the row is actually gone before reporting success so a
            // failed delete surfaces an error instead of silently no-opping.
            return speakerDatabase.getSpeaker(id: profileId) == nil
        }
    }

    func duplicateCount(for profile: SpeakerProfile) -> Int {
        duplicateCountsByProfileID[profile.id] ?? 0
    }

    /// O(1) view over the snapshot's shared merge order; rows call this on every body pass.
    func mergeTargets(for profile: SpeakerProfile) -> SpeakerMergeTargetList {
        mergeTargetIndex.targets(for: profile.id)
    }

    /// The most recent merge into this profile that can still be undone, if any.
    func undoableMerge(for profile: SpeakerProfile) -> SpeakerMergeRecord? {
        undoableMergesByTargetID[profile.id]
    }

    /// Reverse the most recent merge into `profile`, reconstructing the two distinct
    /// voice profiles from the embeddings retained at merge time. Past transcripts keep
    /// the merged name — un-merge restores future voice matching, not transcript text.
    func unmerge(into profile: SpeakerProfile, completion: ((Bool) -> Void)? = nil) {
        if deferUntilVoiceprintMigrationEnds({ [weak self] in
            self?.unmerge(into: profile, completion: completion)
        }) { return }
        let targetId = profile.id
        let speakerDatabase = self.speakerDatabase

        runEditInBackground(completion: completion) {
            speakerDatabase.unmergeMostRecent(forTargetId: targetId)
        }
    }

    /// Runs one speaker edit on a background queue, then applies a fresh
    /// snapshot and calls `completion` with the edit's result on the main
    /// actor, even if this model is gone by then. `completion` stays on the
    /// main actor the whole way, so callers can pass any main-thread closure.
    /// `Task.immediate` hands the edit to the queue before this returns, so it
    /// starts right after the caller's voiceprint-migration check, not a turn later.
    private func runEditInBackground(
        completion: (@MainActor (Bool) -> Void)?,
        _ edit: @escaping @Sendable () -> Bool
    ) {
        let speakerDatabase = self.speakerDatabase
        let preferredClipsDirectory = self.preferredClipsDirectory
        let legacyClipsDirectory = self.legacyClipsDirectory
        let duplicateCache = self.duplicateCache
        let snapshotQueue = self.snapshotQueue
        let revision = snapshotPublication.beginRead()
        Task.immediate { @MainActor [weak self] in
            let (didSucceed, snapshot) = await withCheckedContinuation { continuation in
                snapshotQueue.async {
                    let didSucceed = edit()
                    let snapshot = Self.snapshot(
                        from: speakerDatabase,
                        preferredClipsDirectory: preferredClipsDirectory,
                        legacyClipsDirectory: legacyClipsDirectory,
                        duplicateCache: duplicateCache
                    )
                    continuation.resume(returning: (didSucceed, snapshot))
                }
            }
            self?.applySnapshot(snapshot, revision: revision)
            completion?(didSucceed)
        }
    }

    private func applySnapshot(_ snapshot: Snapshot, revision: UInt64) {
        guard snapshotPublication.accept(revision) else { return }
        duplicateCandidates = snapshot.duplicateCandidates
        duplicateProfileIDs = snapshot.duplicateProfileIDs
        duplicateCountsByProfileID = snapshot.duplicateCountsByProfileID
        mergeTargetIndex = snapshot.mergeTargetIndex
        clipURLsByProfileID = snapshot.clipURLsByProfileID
        reviewQueueItems = snapshot.reviewQueueItems
        undoableMergesByTargetID = snapshot.undoableMergesByTargetID
        hasLoadedProfiles = true
        profiles = snapshot.profiles
    }

    nonisolated private static func snapshot(
        from speakerDatabase: SpeakerDatabase,
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL,
        duplicateCache: SpeakerDuplicateSnapshotCache
    ) -> Snapshot {
        let profiles = sortedProfiles(from: speakerDatabase)
        // Look up each visible speaker's newest still-undoable merge directly (indexed
        // per-target query) so undo never disappears once merge history grows past a cap.
        var undoableMergesByTargetID: [UUID: SpeakerMergeRecord] = [:]
        for profile in profiles {
            if let record = speakerDatabase.undoableMerge(forTargetId: profile.id) {
                undoableMergesByTargetID[profile.id] = record
            }
        }
        return snapshot(
            from: profiles,
            preferredClipsDirectory: preferredClipsDirectory,
            legacyClipsDirectory: legacyClipsDirectory,
            undoableMergesByTargetID: undoableMergesByTargetID,
            duplicateCache: duplicateCache
        )
    }

    nonisolated private static func snapshot(
        from profiles: [SpeakerProfile],
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL,
        undoableMergesByTargetID: [UUID: SpeakerMergeRecord],
        duplicateCache: SpeakerDuplicateSnapshotCache
    ) -> Snapshot {
        let duplicateCandidates = duplicateCache.candidates(from: profiles, build: duplicateCandidates)
        var duplicateCountsByProfileID: [UUID: Int] = [:]
        var duplicatePeerIDsByProfileID: [UUID: Set<UUID>] = [:]

        for candidate in duplicateCandidates {
            let sourceID = candidate.source.id
            let targetID = candidate.target.id
            duplicateCountsByProfileID[sourceID, default: 0] += 1
            duplicateCountsByProfileID[targetID, default: 0] += 1
            duplicatePeerIDsByProfileID[sourceID, default: []].insert(targetID)
            duplicatePeerIDsByProfileID[targetID, default: []].insert(sourceID)
        }

        let duplicateProfileIDs = Set(duplicateCountsByProfileID.keys)
        let mergeTargetIndex = SpeakerMergeTargetIndex(
            profiles: profiles,
            duplicatePeerIDsByProfileID: duplicatePeerIDsByProfileID
        )

        var clipURLsByProfileID: [UUID: URL] = [:]
        for profile in profiles {
            if let url = clipURL(
                for: profile.id,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory
            ) {
                clipURLsByProfileID[profile.id] = url
            }
        }

        let reviewQueueItems = SpeakerReviewQueueScanner.loadPendingItems(
            profiles: profiles,
            clipURLsByProfileID: clipURLsByProfileID
        )

        return Snapshot(
            profiles: profiles,
            duplicateCandidates: duplicateCandidates,
            duplicateProfileIDs: duplicateProfileIDs,
            duplicateCountsByProfileID: duplicateCountsByProfileID,
            mergeTargetIndex: mergeTargetIndex,
            clipURLsByProfileID: clipURLsByProfileID,
            reviewQueueItems: reviewQueueItems,
            undoableMergesByTargetID: undoableMergesByTargetID
        )
    }

    nonisolated private static func sortedProfiles(from speakerDatabase: SpeakerDatabase) -> [SpeakerProfile] {
        speakerDatabase.allSpeakers().sorted { lhs, rhs in
            let lhsNamed = (lhs.displayName?.isEmpty == false)
            let rhsNamed = (rhs.displayName?.isEmpty == false)
            if lhsNamed != rhsNamed { return lhsNamed && !rhsNamed }
            if lhs.callCount != rhs.callCount { return lhs.callCount > rhs.callCount }
            return lhs.lastSeen > rhs.lastSeen
        }
    }
}
