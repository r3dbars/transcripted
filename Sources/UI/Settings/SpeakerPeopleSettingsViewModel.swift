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
    /// The "Who spoke?" cards and what they hide from Everyone, rebuilt only
    /// when the queue, a skip, Later, or the visit's state changes it. The
    /// page, the Everyone list, and Home's attention row all read this one value.
    @Published private(set) var reviewStack = SpeakerReviewStack.empty
    /// Per saved meeting (transcript path): voices still to name and the card
    /// that holds them, for the Meetings page.
    private(set) var meetingNamingByTranscriptPath: [String: SpeakerReviewStack.MeetingNaming] = [:]
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
    @Published private(set) var skippedCallKeys: Set<String> {
        didSet { rebuildReviewStack() }
    }
    /// Calendar invitees per call, offered as one-tap names on its card.
    @Published private(set) var inviteesByCallKey: [String: [String]] = [:]
    /// This visit to the "Who spoke?" cards: meetings done, the card just
    /// finished (Undo), cards saving, and a card the Meetings page asked for.
    /// See `+MeetingReview.swift`.
    @Published var meetingReview = SpeakerMeetingReviewState() {
        didSet { if meetingReview.heldOutCallKeys != oldValue.heldOutCallKeys || meetingReview.focusedCallKey != oldValue.focusedCallKey { rebuildReviewStack() } }
    }
    /// The finished card's saves, waiting out its Undo.
    var pendingMeetingSaves: [UUID: (call: SpeakerPendingMeetingGroup, steps: [SpeakerMeetingReviewPolicy.Step])] = [:]
    var meetingSaveTask: Task<Void, Never>?
    /// Meeting saves run one meeting at a time, each after the snapshot the
    /// one before it left, so two meetings naming the same new person make
    /// one person, not two.
    /// Answers from a "Who spoke?" card that didn't save, said once under
    /// the headline until the next Done or Skip.
    @Published var meetingSaveError: String?
    var waitingMeetingSaves: [(@escaping @MainActor () -> Void) -> Void] = []
    var isRunningMeetingSave = false
    /// Quit waits here for the meeting saves to finish.
    var meetingSavesIdleWaiters: [CheckedContinuation<Void, Never>] = []
    /// The window's model, so Quit can finish its meeting saves without
    /// building one.
    static weak var live: SpeakerPeopleSettingsViewModel?
    /// Bumped per person when a yes for them lands from this page, so their
    /// print in the list plays the match animation. See `celebrate(_:)`.
    @Published private(set) var celebrationTokens: [UUID: Int] = [:]
    private var inviteeLookupsStarted: Set<String> = []


    /// Mirrors the meeting controller's voiceprint migration gate: saved people
    /// moving into a new voice model's database. Edits made meanwhile wait in
    /// `editsWaitingForVoiceprintMigration` and run once it ends.
    @Published private(set) var voiceprintMigrationPhase: SpeakerSettingsMigrationPhase = .idle
    private var voiceprintMigrationObservation: AnyCancellable?
    private var editsWaitingForVoiceprintMigration: [() -> Void] = []

    private let speakerDatabase: SpeakerSettingsStore
    private let transcriptDirectory: URL
    private let reviewDefaults: UserDefaults
    private let preferredClipsDirectory: URL
    private let legacyClipsDirectory: URL
    private(set) var duplicateCandidates: [SpeakerDuplicateCandidate] = []
    private var duplicateProfileIDs: Set<UUID> = []
    private var duplicateCountsByProfileID: [UUID: Int] = [:]
    private var mergeTargetIndex = SpeakerMergeTargetIndex.empty
    private var clipURLsByProfileID: [UUID: URL] = [:]
    private var clipQuotesByProfileID: [UUID: String] = [:]
    private var undoableMergesByTargetID: [UUID: SpeakerSettingsStore.MergeRecord] = [:]
    private var namingStandingsByProfileID: [UUID: SpeakerNamingStanding] = [:]
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
        let clipQuotesByProfileID: [UUID: String]
        let reviewQueueItems: [SpeakerPendingReviewItem]
        let undoableMergesByTargetID: [UUID: SpeakerSettingsStore.MergeRecord]
        let namingStandingsByProfileID: [UUID: SpeakerNamingStanding]
    }

    init(
        speakerDatabase: SpeakerSettingsStore,
        transcriptDirectory: URL = SpeakerSettingsStore.defaultTranscriptDirectory,
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL = SpeakerSettingsStore.defaultLegacyClipsDirectory,
        voiceprintMigrationGate: SpeakerSettingsMigration? = nil,
        reviewDefaults: UserDefaults = .standard
    ) {
        self.speakerDatabase = speakerDatabase.configured(
            transcriptDirectory: transcriptDirectory, preferredClipsDirectory: preferredClipsDirectory,
            legacyClipsDirectory: legacyClipsDirectory
        )
        self.preferredClipsDirectory = preferredClipsDirectory
        self.legacyClipsDirectory = legacyClipsDirectory
        self.transcriptDirectory = transcriptDirectory
        self.reviewDefaults = reviewDefaults
        self.skippedCallKeys = SpeakerReviewSkippedCalls.load(defaults: reviewDefaults)
        Self.live = self
        if let voiceprintMigrationGate {
            voiceprintMigrationPhase = voiceprintMigrationGate.phase
            // Synchronous on purpose: the mirror changes in the same step as
            // the gate, so an edit can never slip between the two.
            voiceprintMigrationObservation = voiceprintMigrationGate.phases
                .dropFirst()
                .sink { [weak self] phase in
                    self?.voiceprintMigrationPhaseChanged(to: phase)
                }
        }
        refresh()
    }

    nonisolated private static func reviewRow(_ item: SpeakerPendingReviewItem) -> SpeakerSettingsStore.ReviewRow {
        .init(transcriptURL: item.transcriptURL, transcriptId: item.transcriptId,
              diarizerSpeakerId: item.diarizerSpeakerId, channel: item.channel.utteranceChannel)
    }

    // MARK: - Voice model migration

    private func voiceprintMigrationPhaseChanged(to phase: SpeakerSettingsMigrationPhase) {
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
            laterCallKeys: laterCallKeys,
            heldOutCallKeys: meetingReview.heldOutCallKeys,
            focusedCallKey: meetingReview.focusedCallKey
        )
        meetingNamingByTranscriptPath = reviewStack.meetingNaming(items: reviewQueueItems)
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
        SpeakerReviewSkippedCalls.add(group.id, defaults: reviewDefaults)
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
    /// "Who spoke?" card right above it (and a card just finished). Voices on
    /// cards further down the stack stay here, badged "Waiting in review", so
    /// they can be renamed, merged, or deleted without cycling the stack, and
    /// a search never hides a match. See `SpeakerReviewStack.directory`.
    var directoryProfiles: [SpeakerProfile] {
        reviewStack.directory(filteredProfiles, isSearching: isSearching)
    }

    /// Directory membership count independent of the search filter, used to
    /// decide whether the search field and the voice-print sections render
    /// at all.
    var directoryCount: Int {
        reviewStack.directory(profiles, isSearching: false).count
    }

    /// Plays `personID`'s match animation in the list (after their new
    /// confirmation is in the snapshot, so the print grows to the new count).
    func celebrate(_ personID: UUID) {
        celebrationTokens[personID, default: 0] += 1
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var filteredProfiles: [SpeakerProfile] {
        let duplicateIds = duplicateProfileIDs
        let matches = SpeakerNameSelectionPolicy.matchingProfiles(
            profiles,
            query: searchText,
            id: { $0.id },
            displayName: { $0.displayName }
        )
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
        let transcriptDirectory = self.transcriptDirectory
        let preferredClipsDirectory = self.preferredClipsDirectory
        let legacyClipsDirectory = self.legacyClipsDirectory
        let duplicateCache = self.duplicateCache
        snapshotQueue.async { [weak self] in
            let snapshot = Self.snapshot(
                from: speakerDatabase,
                transcriptDirectory: transcriptDirectory,
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

    func clipSampleText(for speakerId: UUID) -> String? {
        clipQuotesByProfileID[speakerId]
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
            speakerDatabase.nameReviewedVoice(speakerId: speakerId, trimmed: trimmed, matchingReviewItems: matchingReviewItems.map(Self.reviewRow))
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
        let confirmedTranscriptIds = matchingReviewItems.compactMap(\.transcriptId)
        let speakerDatabase = self.speakerDatabase

        runEditInBackground(completion: completion) {
            speakerDatabase.mergeReviewedVoice(sourceId: sourceId, targetId: targetId, rows: matchingReviewItems.map(Self.reviewRow), confirmedTranscriptIds: confirmedTranscriptIds)
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
    /// existing naming write paths: when a "You" profile already exists the
    /// voice joins it in one transaction (`mergePendingReviewItem`, the same
    /// path as naming a voice after a saved person), so the identity stays
    /// singular; otherwise it is named "You" like typing it and pressing Enter.
    func markPendingReviewItemAsMe(
        _ item: SpeakerPendingReviewItem,
        completion: (@MainActor @Sendable (Bool) -> Void)? = nil
    ) {
        let existingOwnerProfile = profiles.first {
            $0.id != item.speakerId && SpeakerNameSelectionPolicy.isOwnerLabel($0.displayName ?? "")
        }
        if let owner = existingOwnerProfile {
            mergePendingReviewItem(item, into: owner, completion: completion)
            return
        }
        namePendingReviewItem(item, to: SpeakerNameSelectionPolicy.ownerLabel) { completion?($0) }
    }

    /// Rename from an Everyone row. A voice still waiting for a name goes
    /// through the same path as naming it on its review card; see
    /// `SpeakerReviewStack.reviewItemForRename`.
    func renameFromEveryone(_ profile: SpeakerProfile, to newName: String,
                            completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
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
                mergePendingReviewItem(item, into: existing, completion: completion)
            } else {
                namePendingReviewItem(item, to: newName) { didSave in completion?(didSave) }
            }
        } else {
            rename(profile: profile, to: newName) { didSave in completion?(didSave) }
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
        runEditInBackground(completion: completion) {
            speakerDatabase.rename(profileId: profileId, trimmed: trimmed)
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

        runEditInBackground(completion: completion) {
            speakerDatabase.merge(sourceId: sourceId, targetId: targetId)
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
            // A closed database reads as missing, so require the row first.
            guard speakerDatabase.getSpeaker(id: profileId) != nil else { return false }
            speakerDatabase.deleteSpeaker(id: profileId)
            // Confirm the row is actually gone before reporting success so a
            // failed delete surfaces an error and keeps the person's review clips.
            guard speakerDatabase.getSpeaker(id: profileId) == nil else { return false }
            SpeakerClipLibrary.deleteClips(
                for: profileId,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory
            )
            return true
        }
    }

    /// How far a named person is toward a full voice print; nil for an unnamed voice.
    func namingStanding(for profile: SpeakerProfile) -> SpeakerNamingStanding? {
        namingStandingsByProfileID[profile.id]
    }

    /// A meeting's Name speakers moved silently named voices to someone else.
    /// Queued on the snapshot queue ahead of the edit itself, so the outcome
    /// rows are read before the merge moves them.
    func prepareSilentNameCorrections(transcriptId: UUID?, voices: [SpeakerSilentNameCorrectionTelemetry.Voice], completion: @escaping @MainActor @Sendable ([[String: String]]) -> Void) {
        guard !voices.isEmpty else { completion([]); return }
        let speakerDatabase = self.speakerDatabase
        snapshotQueue.async {
            let properties = speakerDatabase.silentNameCorrectionProperties(transcriptId: transcriptId, voices: voices)
            DispatchQueue.main.async { completion(properties) }
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
    func undoableMerge(for profile: SpeakerProfile) -> SpeakerSettingsStore.MergeRecord? {
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
        let transcriptDirectory = self.transcriptDirectory
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
                        transcriptDirectory: transcriptDirectory,
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
        clipQuotesByProfileID = snapshot.clipQuotesByProfileID
        reviewQueueItems = snapshot.reviewQueueItems
        undoableMergesByTargetID = snapshot.undoableMergesByTargetID
        namingStandingsByProfileID = snapshot.namingStandingsByProfileID
        hasLoadedProfiles = true
        profiles = snapshot.profiles
    }

    nonisolated private static func snapshot(
        from speakerDatabase: SpeakerSettingsStore,
        transcriptDirectory: URL,
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL,
        duplicateCache: SpeakerDuplicateSnapshotCache
    ) -> Snapshot {
        let profiles = sortedProfiles(from: speakerDatabase)
        // Look up each visible speaker's newest still-undoable merge directly (indexed
        // per-target query) so undo never disappears once merge history grows past a cap.
        var undoableMergesByTargetID: [UUID: SpeakerSettingsStore.MergeRecord] = [:]
        for profile in profiles {
            if let record = speakerDatabase.undoableMerge(forTargetId: profile.id) {
                undoableMergesByTargetID[profile.id] = record
            }
        }
        return snapshot(
            from: profiles,
            transcriptDirectory: transcriptDirectory,
            preferredClipsDirectory: preferredClipsDirectory,
            legacyClipsDirectory: legacyClipsDirectory,
            undoableMergesByTargetID: undoableMergesByTargetID,
            namingStandingsByProfileID: speakerDatabase.namingStandings(for: profiles),
            duplicateCache: duplicateCache
        )
    }

    nonisolated private static func snapshot(
        from profiles: [SpeakerProfile],
        transcriptDirectory: URL,
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL,
        undoableMergesByTargetID: [UUID: SpeakerSettingsStore.MergeRecord],
        namingStandingsByProfileID: [UUID: SpeakerNamingStanding],
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
        var clipQuotesByProfileID: [UUID: String] = [:]
        for profile in profiles {
            if let url = SpeakerClipLibrary.clipURL(
                for: profile.id,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory
            ) {
                clipURLsByProfileID[profile.id] = url
                if let quote = SpeakerClipLibrary.sampleText(nextTo: url) {
                    clipQuotesByProfileID[profile.id] = quote
                }
            }
        }

        let reviewQueueItems = SpeakerReviewQueueScanner.loadPendingItems(
            transcriptsDirectory: transcriptDirectory,
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
            clipQuotesByProfileID: clipQuotesByProfileID,
            reviewQueueItems: reviewQueueItems,
            undoableMergesByTargetID: undoableMergesByTargetID,
            namingStandingsByProfileID: namingStandingsByProfileID
        )
    }

    nonisolated private static func sortedProfiles(from speakerDatabase: SpeakerSettingsStore) -> [SpeakerProfile] {
        speakerDatabase.allSpeakers().sorted { lhs, rhs in
            let lhsNamed = (lhs.displayName?.isEmpty == false)
            let rhsNamed = (rhs.displayName?.isEmpty == false)
            if lhsNamed != rhsNamed { return lhsNamed && !rhsNamed }
            if lhs.callCount != rhs.callCount { return lhs.callCount > rhs.callCount }
            return lhs.lastSeen > rhs.lastSeen
        }
    }
}
