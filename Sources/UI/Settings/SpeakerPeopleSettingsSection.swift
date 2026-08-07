import SwiftUI
import AppKit
import TranscriptedCore

enum SpeakerPeopleSettingsPolishContract {
    static let minimumHitTarget: CGFloat = 40
    /// Glyph point size for the quiet inline play/pause control. The old
    /// 36pt filled accent circle is gone — playing state reads through the
    /// pause glyph, accent ink, and the sweep under the sample it belongs to.
    static let quietPlayGlyphPointSize: CGFloat = 14
    static let compactIconVisibleDiameter: CGFloat = 28
}

private struct SpeakerCompactIconLabel: View {
    let systemName: String
    let foregroundColor: Color
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    var tone: SettingsInteractionTone = .neutral
    var normalFill: Color = Color.primary.opacity(0.025)
    var normalStroke: Color = Color.primary.opacity(0.06)
    var cornerRadius: CGFloat = 8

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: fontSize, weight: fontWeight))
            .foregroundStyle(foregroundColor)
            .frame(
                width: SpeakerPeopleSettingsPolishContract.compactIconVisibleDiameter,
                height: SpeakerPeopleSettingsPolishContract.compactIconVisibleDiameter
            )
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(strokeColor, lineWidth: 1)
            )
            .frame(
                width: SpeakerPeopleSettingsPolishContract.minimumHitTarget,
                height: SpeakerPeopleSettingsPolishContract.minimumHitTarget
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.55)
            .onHover { isHovering = $0 }
            .animation(SettingsInteractionPalette.animation, value: isHovering)
    }

    private var fillColor: Color {
        guard isEnabled else { return normalFill.opacity(0.65) }
        if isHovering { return SettingsInteractionPalette.hoverFill(for: tone) }
        return normalFill
    }

    private var strokeColor: Color {
        guard isEnabled else { return normalStroke.opacity(0.5) }
        if isHovering { return SettingsInteractionPalette.hoverStroke(for: tone) }
        return normalStroke
    }
}

enum SpeakerDuplicateReason: Int {
    case sameNameAndVoice
    case sameName
    case similarNameAndVoice
    case similarName
    case voiceMatch

    var title: String {
        switch self {
        case .sameNameAndVoice: return "Same name and voice"
        case .sameName: return "Same name"
        case .similarNameAndVoice: return "Similar name and voice"
        case .similarName: return "Similar names"
        case .voiceMatch: return "Voices match"
        }
    }

    var includesVoiceMatch: Bool {
        switch self {
        case .sameNameAndVoice, .similarNameAndVoice, .voiceMatch:
            return true
        case .sameName, .similarName:
            return false
        }
    }
}

struct SpeakerDuplicateCandidate: Identifiable {
    let source: SpeakerProfile
    let target: SpeakerProfile
    let reason: SpeakerDuplicateReason
    let voiceSimilarity: Double?

    var id: String {
        [source.id.uuidString, target.id.uuidString].sorted().joined(separator: "-")
    }

    var summaryLine: String {
        var parts = [reason.title]
        if let voiceSimilarity,
           let percent = Self.percentFormatter.string(from: NSNumber(value: voiceSimilarity)) {
            parts.append("\(percent) voice match")
        }
        parts.append("merging keeps \(Self.displayName(for: target))")
        return parts.joined(separator: " · ")
    }

    static func displayName(for profile: SpeakerProfile) -> String {
        profile.displayName ?? "Unknown voice"
    }

    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}

@MainActor
final class SpeakerPeopleSettingsViewModel: ObservableObject {
    @Published var profiles: [SpeakerProfile] = []
    @Published var searchText: String = ""
    @Published private(set) var reviewQueueItems: [SpeakerPendingReviewItem] = []
    @Published private(set) var hasLoadedProfiles = false
    /// Bumped to ask the "Search speakers" field to take focus (⌘F).
    @Published private(set) var searchFocusRequestToken = 0
    /// Voice groups the user dismissed with "Skip". Session-only (not
    /// persisted): there is no existing skip/dismiss field on the transcript
    /// frontmatter or `SpeakerProfile` this could route through, so a skipped
    /// row simply drops out of `pendingVoiceGroups` for the rest of this
    /// launch and reappears on next relaunch or once genuinely renamed.
    @Published private(set) var skippedVoiceGroupIDs: Set<UUID> = []

    private let speakerDatabase: SpeakerDatabase
    private let preferredClipsDirectory: URL
    private let legacyClipsDirectory: URL
    private(set) var duplicateCandidates: [SpeakerDuplicateCandidate] = []
    private var duplicateProfileIDs: Set<UUID> = []
    private var duplicateCountsByProfileID: [UUID: Int] = [:]
    private var mergeTargetsByProfileID: [UUID: [SpeakerProfile]] = [:]
    private var clipURLsByProfileID: [UUID: URL] = [:]
    private var undoableMergesByTargetID: [UUID: SpeakerMergeRecord] = [:]
    private var refreshGeneration = SupersessionEpoch()

    private struct Snapshot {
        let profiles: [SpeakerProfile]
        let duplicateCandidates: [SpeakerDuplicateCandidate]
        let duplicateProfileIDs: Set<UUID>
        let duplicateCountsByProfileID: [UUID: Int]
        let mergeTargetsByProfileID: [UUID: [SpeakerProfile]]
        let clipURLsByProfileID: [UUID: URL]
        let reviewQueueItems: [SpeakerPendingReviewItem]
        let undoableMergesByTargetID: [UUID: SpeakerMergeRecord]
    }

    init(
        speakerDatabase: SpeakerDatabase,
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL = CoreStoragePaths.default.speakerClips
    ) {
        self.speakerDatabase = speakerDatabase
        self.preferredClipsDirectory = preferredClipsDirectory
        self.legacyClipsDirectory = legacyClipsDirectory
        refresh()
    }

    var pendingVoiceGroups: [SpeakerPendingVoiceGroup] {
        SpeakerReviewQueueScanner.groupedByVoice(reviewQueueItems)
            .filter { !skippedVoiceGroupIDs.contains($0.id) }
    }

    /// Dismisses a queued voice from "Needs a name" for this session without
    /// touching its saved profile or transcripts. See `skippedVoiceGroupIDs`.
    func skip(_ group: SpeakerPendingVoiceGroup) {
        skippedVoiceGroupIDs.insert(group.id)
    }

    /// The "Everyone" directory: named voices, plus unnamed voices that are
    /// not currently sitting in the "Needs a name" queue above. A voice lives
    /// in exactly one section — it graduates to Everyone when named — but an
    /// unnamed voice with no queue row left (deleted transcripts, or skipped
    /// for this session) stays reachable here for merge/delete instead of
    /// vanishing from both sections.
    var directoryProfiles: [SpeakerProfile] {
        let queuedUnnamedIds = Set(pendingVoiceGroups.map(\.id))
        return filteredProfiles.filter { Self.isInDirectory($0, queuedUnnamedIds: queuedUnnamedIds) }
    }

    /// Directory membership count independent of the search filter, used for
    /// the "N people" trailing label and to decide whether the Everyone
    /// section renders at all.
    var directoryCount: Int {
        let queuedUnnamedIds = Set(pendingVoiceGroups.map(\.id))
        return profiles.count(where: { Self.isInDirectory($0, queuedUnnamedIds: queuedUnnamedIds) })
    }

    private static func isInDirectory(_ profile: SpeakerProfile, queuedUnnamedIds: Set<UUID>) -> Bool {
        let isNamed = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return isNamed || !queuedUnnamedIds.contains(profile.id)
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

    func refresh() {
        let generation = refreshGeneration.begin()
        let speakerDatabase = self.speakerDatabase
        let preferredClipsDirectory = self.preferredClipsDirectory
        let legacyClipsDirectory = self.legacyClipsDirectory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = Self.snapshot(
                from: speakerDatabase,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory
            )
            DispatchQueue.main.async {
                guard let self, self.refreshGeneration.finishIfCurrent(generation) else { return }
                self.applySnapshot(snapshot)
            }
        }
    }

    func clipURL(for speakerId: UUID) -> URL? {
        clipURLsByProfileID[speakerId]
    }

    func playSample(for speakerId: UUID) {
        guard let url = clipURL(for: speakerId) else { return }
        SpeakerClipPlayback.play(url)
    }

    func isPlayingSample(for speakerId: UUID) -> Bool {
        guard let url = clipURL(for: speakerId) else { return false }
        return SpeakerClipPlayback.isPlaying(url)
    }

    func playSample(for item: SpeakerPendingReviewItem) {
        guard let url = item.clipURL else { return }
        SpeakerClipPlayback.play(url)
    }

    func isPlayingSample(for item: SpeakerPendingReviewItem) -> Bool {
        guard let url = item.clipURL else { return false }
        return SpeakerClipPlayback.isPlaying(url)
    }

    func openTranscript(for item: SpeakerPendingReviewItem) {
        NSWorkspace.shared.open(item.transcriptURL)
    }

    func hasPendingReview(forTranscript transcriptURL: URL) -> Bool {
        let targetPath = transcriptURL.standardizedFileURL.path
        return reviewQueueItems.contains {
            $0.transcriptURL.standardizedFileURL.path == targetPath
        }
    }

    func namePendingReviewItem(
        _ item: SpeakerPendingReviewItem,
        to newName: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion?(false)
            return
        }

        let speakerId = item.speakerId
        let queuedReviewItems = reviewQueueItems.filter { $0.speakerId == speakerId }
        let matchingReviewItems = queuedReviewItems.isEmpty ? [item] : queuedReviewItems
        let speakerDatabase = self.speakerDatabase
        let preferredClipsDirectory = self.preferredClipsDirectory
        let legacyClipsDirectory = self.legacyClipsDirectory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var allTranscriptUpdatesSucceeded = true
            for reviewItem in matchingReviewItems {
                let didUpdate = TranscriptSaver.updateDeferredSpeakerName(
                    transcriptURL: reviewItem.transcriptURL,
                    dbId: speakerId,
                    diarizerSpeakerId: reviewItem.diarizerSpeakerId,
                    channel: reviewItem.channel,
                    newName: trimmed
                )
                allTranscriptUpdatesSucceeded = allTranscriptUpdatesSucceeded && didUpdate
            }

            if allTranscriptUpdatesSucceeded {
                speakerDatabase.setDisplayName(id: speakerId, name: trimmed, source: NameSource.userManual)
                speakerDatabase.resetDisputeCount(id: speakerId)
            }
            let snapshot = Self.snapshot(
                from: speakerDatabase,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory
            )
            DispatchQueue.main.async {
                self?.applySnapshot(snapshot)
                completion?(allTranscriptUpdatesSucceeded)
            }
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

    func rename(profile: SpeakerProfile, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let profileId = profile.id
        let speakerDatabase = self.speakerDatabase
        let preferredClipsDirectory = self.preferredClipsDirectory
        let legacyClipsDirectory = self.legacyClipsDirectory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Routed through the canonical mutation service (audit 2026-08-04): this used
            // to write the DB first and best-effort-scan transcripts second with no
            // rollback, so a transcript write failure left the DB and saved transcripts
            // disagreeing about the speaker's name. The service snapshots and rewrites
            // transcripts first and only commits the DB change once every rewrite has
            // succeeded, rolling transcripts back if the DB transaction itself fails.
            do {
                let outcome = try SpeakerIdentityMutationService.apply(
                    .rename(profileId: profileId, newName: trimmed),
                    speakerDB: speakerDatabase
                )
                if !outcome.succeeded {
                    AppLogger.speakers.error("Manual speaker rename failed", ["profileId": profileId.uuidString])
                }
            } catch {
                Self.reportMutationFailure(error, engine: "speakers", profileId: profileId)
            }
            let snapshot = Self.snapshot(
                from: speakerDatabase,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory
            )
            DispatchQueue.main.async {
                self?.applySnapshot(snapshot)
            }
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

    func merge(source: SpeakerProfile, into target: SpeakerProfile) {
        guard source.id != target.id else { return }

        let sourceId = source.id
        let targetId = target.id
        let speakerDatabase = self.speakerDatabase
        let preferredClipsDirectory = self.preferredClipsDirectory
        let legacyClipsDirectory = self.legacyClipsDirectory

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Routed through the canonical mutation service (audit 2026-08-04), replacing
            // SpeakerProfileMergeSideEffectCoordinator (DB + clips only, no transcript
            // rollback) plus a separate un-rolled-back TranscriptSaver.retroactivelyMergeSpeaker
            // scan. The service snapshots and rewrites transcripts first, commits the DB
            // merge inside a real transaction, rolls transcripts back if that transaction
            // throws, and only then runs clip promotion/deletion. Same-id merges are
            // rejected by the service itself now (MutationError.sameSourceAndTarget), so the
            // `source.id != target.id` guard above is defense in depth, not the only guard.
            do {
                let outcome = try SpeakerIdentityMutationService.apply(
                    .merge(sourceId: sourceId, targetId: targetId),
                    speakerDB: speakerDatabase,
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
            } catch {
                Self.reportMutationFailure(error, engine: "speakers", profileId: sourceId)
            }
            let snapshot = Self.snapshot(
                from: speakerDatabase,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory
            )
            DispatchQueue.main.async {
                self?.applySnapshot(snapshot)
            }
        }
    }

    /// Deletes the voice behind a pending review group. Thin wrapper over
    /// `delete(profile:)` so the "voices to name" overflow menu shares the same
    /// real deletion path as the all-speakers list.
    func deleteVoice(_ group: SpeakerPendingVoiceGroup, completion: ((Bool) -> Void)? = nil) {
        delete(profile: group.representative.profile, completion: completion)
    }

    func delete(profile: SpeakerProfile, completion: ((Bool) -> Void)? = nil) {
        let profileId = profile.id
        let speakerDatabase = self.speakerDatabase
        let preferredClipsDirectory = self.preferredClipsDirectory
        let legacyClipsDirectory = self.legacyClipsDirectory

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            speakerDatabase.deleteSpeaker(id: profileId)
            Self.deleteClips(
                for: profileId,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory
            )
            // Confirm the row is actually gone before reporting success so a
            // failed delete surfaces an error instead of silently no-opping.
            let didDelete = speakerDatabase.getSpeaker(id: profileId) == nil
            let snapshot = Self.snapshot(
                from: speakerDatabase,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory
            )
            DispatchQueue.main.async {
                self?.applySnapshot(snapshot)
                completion?(didDelete)
            }
        }
    }

    func duplicateCount(for profile: SpeakerProfile) -> Int {
        duplicateCountsByProfileID[profile.id] ?? 0
    }

    func mergeTargets(for profile: SpeakerProfile) -> [SpeakerProfile] {
        mergeTargetsByProfileID[profile.id] ?? []
    }

    /// The most recent merge into this profile that can still be undone, if any.
    func undoableMerge(for profile: SpeakerProfile) -> SpeakerMergeRecord? {
        undoableMergesByTargetID[profile.id]
    }

    /// Reverse the most recent merge into `profile`, reconstructing the two distinct
    /// voice profiles from the embeddings retained at merge time. Past transcripts keep
    /// the merged name — un-merge restores future voice matching, not transcript text.
    func unmerge(into profile: SpeakerProfile, completion: ((Bool) -> Void)? = nil) {
        let targetId = profile.id
        let speakerDatabase = self.speakerDatabase
        let preferredClipsDirectory = self.preferredClipsDirectory
        let legacyClipsDirectory = self.legacyClipsDirectory

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let didUnmerge = speakerDatabase.unmergeMostRecent(forTargetId: targetId)
            let snapshot = Self.snapshot(
                from: speakerDatabase,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory
            )
            DispatchQueue.main.async {
                self?.applySnapshot(snapshot)
                completion?(didUnmerge)
            }
        }
    }

    private func applySnapshot(_ snapshot: Snapshot) {
        duplicateCandidates = snapshot.duplicateCandidates
        duplicateProfileIDs = snapshot.duplicateProfileIDs
        duplicateCountsByProfileID = snapshot.duplicateCountsByProfileID
        mergeTargetsByProfileID = snapshot.mergeTargetsByProfileID
        clipURLsByProfileID = snapshot.clipURLsByProfileID
        reviewQueueItems = snapshot.reviewQueueItems
        undoableMergesByTargetID = snapshot.undoableMergesByTargetID
        hasLoadedProfiles = true
        profiles = snapshot.profiles
    }

    nonisolated private static func snapshot(
        from speakerDatabase: SpeakerDatabase,
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL
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
            undoableMergesByTargetID: undoableMergesByTargetID
        )
    }

    nonisolated private static func snapshot(
        from profiles: [SpeakerProfile],
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL,
        undoableMergesByTargetID: [UUID: SpeakerMergeRecord] = [:]
    ) -> Snapshot {
        let duplicateCandidates = duplicateCandidates(from: profiles)
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
        let mergeTargetsByProfileID = Dictionary(
            uniqueKeysWithValues: profiles.map { profile in
                (
                    profile.id,
                    sortedMergeTargets(
                        for: profile,
                        in: profiles,
                        duplicatePeerIds: duplicatePeerIDsByProfileID[profile.id] ?? []
                    )
                )
            }
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
            mergeTargetsByProfileID: mergeTargetsByProfileID,
            clipURLsByProfileID: clipURLsByProfileID,
            reviewQueueItems: reviewQueueItems,
            undoableMergesByTargetID: undoableMergesByTargetID
        )
    }

    nonisolated private static func sortedMergeTargets(
        for profile: SpeakerProfile,
        in profiles: [SpeakerProfile],
        duplicatePeerIds: Set<UUID>
    ) -> [SpeakerProfile] {
        profiles.filter { $0.id != profile.id }.sorted { lhs, rhs in
            let lhsIsDuplicate = duplicatePeerIds.contains(lhs.id)
            let rhsIsDuplicate = duplicatePeerIds.contains(rhs.id)
            if lhsIsDuplicate != rhsIsDuplicate {
                return lhsIsDuplicate && !rhsIsDuplicate
            }

            let lhsName = lhs.displayName ?? "Unknown voice"
            let rhsName = rhs.displayName ?? "Unknown voice"
            if lhsName == rhsName {
                return lhs.callCount > rhs.callCount
            }
            return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        }
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

    nonisolated private static func duplicateCandidates(from profiles: [SpeakerProfile]) -> [SpeakerDuplicateCandidate] {
        guard profiles.count > 1 else { return [] }

        var candidates: [SpeakerDuplicateCandidate] = []
        var seenPairs = Set<String>()

        for lhsIndex in profiles.indices {
            for rhsIndex in profiles.indices where rhsIndex > lhsIndex {
                let lhs = profiles[lhsIndex]
                let rhs = profiles[rhsIndex]
                let voiceSimilarity = cosineSimilarity(lhs.embedding, rhs.embedding)
                guard let reason = duplicateReason(lhs, rhs, voiceSimilarity: voiceSimilarity) else {
                    continue
                }

                let pairId = [lhs.id.uuidString, rhs.id.uuidString].sorted().joined(separator: "-")
                guard !seenPairs.contains(pairId) else { continue }
                seenPairs.insert(pairId)

                let target = suggestedMergeTarget(lhs, rhs)
                let source = target.id == lhs.id ? rhs : lhs
                candidates.append(SpeakerDuplicateCandidate(
                    source: source,
                    target: target,
                    reason: reason,
                    voiceSimilarity: reason.includesVoiceMatch ? voiceSimilarity : nil
                ))
            }
        }

        return candidates.sorted { lhs, rhs in
            if lhs.reason.rawValue != rhs.reason.rawValue {
                return lhs.reason.rawValue < rhs.reason.rawValue
            }
            let lhsSimilarity = lhs.voiceSimilarity ?? 0
            let rhsSimilarity = rhs.voiceSimilarity ?? 0
            if lhsSimilarity != rhsSimilarity {
                return lhsSimilarity > rhsSimilarity
            }
            let lhsCalls = lhs.source.callCount + lhs.target.callCount
            let rhsCalls = rhs.source.callCount + rhs.target.callCount
            return lhsCalls > rhsCalls
        }
    }

    nonisolated private static func duplicateReason(
        _ lhs: SpeakerProfile,
        _ rhs: SpeakerProfile,
        voiceSimilarity: Double?
    ) -> SpeakerDuplicateReason? {
        let lhsName = normalizedName(lhs.displayName)
        let rhsName = normalizedName(rhs.displayName)
        let sameName = lhsName != nil && lhsName == rhsName
        let similarName = !sameName && namesLookRelated(lhsName, rhsName)

        let nameConflict = lhsName != nil && rhsName != nil && !sameName && !similarName
        let voiceThreshold = nameConflict ? 0.96 : 0.90
        let voiceMatch = lhs.disputeCount == 0
            && rhs.disputeCount == 0
            && (voiceSimilarity ?? 0) >= voiceThreshold

        switch (sameName, similarName, voiceMatch) {
        case (true, _, true):
            return .sameNameAndVoice
        case (true, _, false):
            return .sameName
        case (false, true, true):
            return .similarNameAndVoice
        case (false, true, false):
            return .similarName
        case (false, false, true):
            return .voiceMatch
        default:
            return nil
        }
    }

    nonisolated private static func suggestedMergeTarget(_ lhs: SpeakerProfile, _ rhs: SpeakerProfile) -> SpeakerProfile {
        if lhs.callCount != rhs.callCount {
            return lhs.callCount > rhs.callCount ? lhs : rhs
        }

        let lhsNamed = normalizedName(lhs.displayName) != nil
        let rhsNamed = normalizedName(rhs.displayName) != nil
        if lhsNamed != rhsNamed {
            return lhsNamed ? lhs : rhs
        }

        return lhs.lastSeen >= rhs.lastSeen ? lhs : rhs
    }

    nonisolated private static func normalizedName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }

    nonisolated private static func namesLookRelated(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs, lhs != rhs else { return false }
        if lhs.count >= 3 && rhs.count >= 3 && (lhs.contains(rhs) || rhs.contains(lhs)) {
            return true
        }

        let lhsTokens = nameTokens(lhs)
        let rhsTokens = nameTokens(rhs)
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return false }
        return lhsTokens.isSubset(of: rhsTokens) || rhsTokens.isSubset(of: lhsTokens)
    }

    nonisolated private static func nameTokens(_ name: String) -> Set<String> {
        Set(name
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 })
    }

    nonisolated private static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }
        return SpeakerVectorMath.cosineSimilarity(lhs, rhs)
    }

    nonisolated private static func clipURL(
        for speakerId: UUID,
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL
    ) -> URL? {
        SpeakerClipExtractor.persistentClipURL(for: speakerId, clipsDirectory: preferredClipsDirectory)
            ?? SpeakerClipExtractor.persistentClipURL(for: speakerId, clipsDirectory: legacyClipsDirectory)
    }

    nonisolated private static func deleteClips(
        for speakerId: UUID,
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL
    ) {
        SpeakerClipExtractor.deletePersistedClip(for: speakerId, clipsDirectory: preferredClipsDirectory)
        if legacyClipsDirectory != preferredClipsDirectory {
            SpeakerClipExtractor.deletePersistedClip(for: speakerId, clipsDirectory: legacyClipsDirectory)
        }
    }

    nonisolated private static func promoteClipIfNeeded(
        from sourceId: UUID,
        to targetId: UUID,
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL
    ) {
        guard clipURL(
            for: targetId,
            preferredClipsDirectory: preferredClipsDirectory,
            legacyClipsDirectory: legacyClipsDirectory
        ) == nil,
        let sourceClip = clipURL(
            for: sourceId,
            preferredClipsDirectory: preferredClipsDirectory,
            legacyClipsDirectory: legacyClipsDirectory
        ) else { return }
        SpeakerClipExtractor.persistClip(
            from: sourceClip,
            speakerId: targetId,
            clipsDirectory: preferredClipsDirectory
        )
    }
}

struct SpeakerPeopleSettingsSection: View {
    enum ScrollTarget: Hashable {
        case reviewQueue
    }

    @ObservedObject var model: SpeakerPeopleSettingsViewModel
    /// Optional hook so the first-run empty state can offer a real next step.
    /// Defaults to nil to keep the initializer additive for existing call sites.
    var onStartMeeting: (() -> Void)? = nil
    @State private var playbackStateVersion = 0
    /// Which person row is expanded in place, if any. Lives here (not on the
    /// row) so opening one person always closes any other — one person open
    /// at a time, per spec.
    @State private var expandedPersonID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            let voiceGroups = model.pendingVoiceGroups

            if !voiceGroups.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        LibrarySectionLabel(text: "Needs a name")

                        Text("Play a clip. If you recognize the voice, type their name — it updates every meeting they're in.")
                            .font(LibraryTokens.meta)
                            .foregroundStyle(LibraryTokens.ink2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(voiceGroups.enumerated()), id: \.element.id) { index, group in
                            SpeakerVoiceToNameRow(group: group, model: model)

                            if index < voiceGroups.count - 1 {
                                Rectangle()
                                    .fill(LibraryTokens.hairline)
                                    .frame(height: 1)
                                    .padding(.vertical, 12)
                            }
                        }
                    }
                }
                .id(ScrollTarget.reviewQueue)
                .accessibilityIdentifier("transcripted.speakers.inbox")
            }

            // A voice appears in exactly one section: the queue above until
            // it's named, Everyone after. When every voice is still waiting
            // for a name the directory stays hidden entirely.
            if model.profiles.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    LibrarySectionLabel(text: "Everyone")
                    SpeakersEmptyStateView(onStartMeeting: onStartMeeting)
                }
            } else if model.directoryCount > 0 {
                VStack(alignment: .leading, spacing: 12) {
                    LibrarySectionLabel(text: "Everyone", trailing: everyoneTrailing)

                    SpeakerSearchRow(model: model)

                    if model.directoryProfiles.isEmpty {
                        Text(SpeakerPeopleEmptyState.noSearchMatches)
                            .font(LibraryTokens.meta)
                            .foregroundStyle(LibraryTokens.ink2)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(model.directoryProfiles, id: \.id) { profile in
                                SpeakerPersonRow(profile: profile, model: model, expandedPersonID: $expandedPersonID)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Clicking anywhere outside an open person card collapses it, same
        // click-away grammar as Meetings and Dictations. The card swallows
        // its own inside taps.
        .homeBackgroundTapCatcher {
            if expandedPersonID != nil {
                expandedPersonID = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SpeakerClipPlayback.stateDidChangeNotification)) { _ in
            playbackStateVersion += 1
        }
        .onDisappear {
            expandedPersonID = nil
            SpeakerClipPlayback.stop()
        }
    }

    private var everyoneTrailing: String? {
        let count = model.directoryCount
        guard count > 0 else { return nil }
        return count == 1 ? "1 person" : "\(count) people"
    }
}

// MARK: - Empty state copy + teaching view

/// Foundation-pure copy for the Speakers surface's empty states. Kept as
/// constants so the teaching first-run copy can be pinned by fast tests and can
/// never regress to bare gray placeholder text. Plain words, no exclamation
/// marks, per the repo voice convention.
enum SpeakerPeopleEmptyState {
    static let symbolName = "person.2"
    static let title = "No speakers yet"
    static let message = "Transcripted learns each voice as you record. After your first meeting, the people in it show up here, so you can name someone once and have them recognized in every meeting after."
    static let actionTitle = "Start a meeting"
    static let actionAutomationIdentifier = "transcripted.speakers.empty.start-meeting"
    static let noSearchMatches = "No speakers match your search."
}

/// First-run teaching empty state for the all-speakers list: it explains what
/// the screen will fill with and offers the one action that fills it.
private struct SpeakersEmptyStateView: View {
    var onStartMeeting: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: SpeakerPeopleEmptyState.symbolName)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)

            VStack(spacing: 5) {
                Text(SpeakerPeopleEmptyState.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.primary)

                Text(SpeakerPeopleEmptyState.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }

            if let onStartMeeting {
                Button(action: onStartMeeting) {
                    Text(SpeakerPeopleEmptyState.actionTitle)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier(SpeakerPeopleEmptyState.actionAutomationIdentifier)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 16)
    }
}

// MARK: - Voices to name

private struct SpeakerVoiceToNameRow: View {
    let group: SpeakerPendingVoiceGroup
    @ObservedObject var model: SpeakerPeopleSettingsViewModel

    @State private var nameDraft = ""
    @State private var isSaving = false
    @State private var saveErrorMessage: String?
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var deleteErrorMessage: String?
    @State private var isMarkingAsMe = false
    @State private var clipDuration = SpeakerClipProgressBar.fallbackDuration

    private var isPlaying: Bool {
        model.isPlayingSample(for: group.representative)
    }

    private var hasClip: Bool {
        group.representative.clipURL != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The quote is the playable object: a quiet play/pause glyph sits
            // inline with it, and while the clip plays an accent sweep runs
            // under the words being spoken. At rest there is no bar at all.
            HStack(alignment: .top, spacing: 4) {
                SpeakerQuietPlayButton(
                    hasClip: hasClip,
                    isPlaying: isPlaying,
                    action: { model.playSample(for: group.representative) }
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(quoteLine)
                        .font(LibraryTokens.body)
                        .foregroundStyle(group.sampleText == nil ? LibraryTokens.ink2 : Color.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    SpeakerClipProgressBar(isPlaying: isPlaying, duration: clipDuration)
                        .frame(maxWidth: 240)
                        .opacity(isPlaying ? 1 : 0)
                        .animation(.easeOut(duration: 0.18), value: isPlaying)

                    Text(metaLine)
                        .font(LibraryTokens.meta)
                        .monospacedDigit()
                        .foregroundStyle(LibraryTokens.ink2)
                        .lineLimit(2)
                }
                .padding(.top, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    nameField
                    saveHint
                    quietQueueActions
                    Spacer(minLength: 0)
                    overflowMenu
                }

                VStack(alignment: .leading, spacing: 8) {
                    nameField
                    HStack(spacing: 10) {
                        saveHint
                        quietQueueActions
                        Spacer(minLength: 0)
                        overflowMenu
                    }
                }
            }
            .padding(.leading, 44)

            if let saveErrorMessage {
                Text(saveErrorMessage)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 44)
            }

            if let deleteErrorMessage {
                Text(deleteErrorMessage)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 44)
            }
        }
        .padding(.vertical, 10)
        .onAppear {
            if nameDraft.isEmpty {
                nameDraft = group.representative.profile.displayName ?? ""
            }
            if let clipURL = group.representative.clipURL {
                clipDuration = probeClipDuration(clipURL)
            }
        }
        .onChange(of: nameDraft) { _, _ in
            saveErrorMessage = nil
        }
        .alert(
            SpeakerVoiceRowMenuPolicy.deleteConfirmationTitle,
            isPresented: $showDeleteConfirmation
        ) {
            Button("Delete", role: .destructive) {
                deleteVoice()
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(SpeakerVoiceRowMenuPolicy.deleteConfirmationMessage)
        }
    }

    private var nameSuggestions: [SpeakerIdentityOption] {
        SpeakerNameSuggestionSource.options(
            from: model.profiles,
            excluding: group.representative.speakerId
        )
    }

    private var nameField: some View {
        SpeakerNameAutocompleteField(
            text: $nameDraft,
            placeholder: "Who is this?",
            options: nameSuggestions,
            accessibilityIdentifier: "transcripted.speakers.voice-to-name.name",
            onSubmit: saveName
        )
        .frame(minWidth: 200)
    }

    /// Quiet ⏎-to-save hint replacing the old "Save Name" button — the field
    /// itself commits on Enter (`onSubmit: saveName`), matching the person
    /// card's "⏎ to rename" pattern.
    private var saveHint: some View {
        Text(isSaving ? "Saving…" : "⏎ to save")
            .font(.system(size: 11))
            .foregroundStyle(LibraryTokens.ink3)
            .fixedSize()
    }

    /// "This is me" / "Skip" — quiet text actions, not chips: matches the
    /// prototype's `<a>` affordances and the surface's "color only for
    /// action/attention" rule.
    private var quietQueueActions: some View {
        HStack(spacing: 6) {
            if SpeakerVoiceQueueRowActionPolicy.showsThisIsMe(channel: group.representative.channel) {
                SpeakerQuietLinkButton(
                    title: isMarkingAsMe ? "Saving…" : SpeakerVoiceQueueRowActionPolicy.thisIsMeTitle,
                    action: markAsMe
                )
                .disabled(isSaving || isMarkingAsMe)
                .accessibilityIdentifier("transcripted.speakers.voice-to-name.this-is-me")

                Text("·")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink3)
            }

            SpeakerQuietLinkButton(
                title: SpeakerVoiceQueueRowActionPolicy.skipTitle,
                action: { model.skip(group) }
            )
            .accessibilityIdentifier("transcripted.speakers.voice-to-name.skip")
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button(SpeakerVoiceRowMenuAction.showTranscript.title) {
                model.openTranscript(for: group.representative)
            }

            Divider()

            Button(SpeakerVoiceRowMenuAction.deleteVoice.title, role: .destructive) {
                showDeleteConfirmation = true
            }
            .disabled(isDeleting)
        } label: {
            SpeakerCompactIconLabel(
                systemName: "ellipsis",
                foregroundColor: .secondary,
                fontSize: 13,
                fontWeight: .semibold
            )
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show transcript or delete this voice")
        .accessibilityLabel("Voice actions")
        .accessibilityIdentifier("transcripted.speakers.voice-to-name.menu")
    }

    private var quoteLine: String {
        guard let sampleText = group.sampleText else {
            return "No transcript sample for this voice."
        }
        return "\u{201C}\(sampleText)\u{201D}"
    }

    private var metaLine: String {
        let item = group.representative
        var parts = [item.meetingTitle]
        if let dateText = Self.dateFormatter.stringIfAvailable(from: item.recordedAt ?? item.fallbackDate) {
            parts.append(dateText)
        }
        parts.append(item.channel == .mic ? "In the room" : "Remote")
        if group.meetingCount > 1 {
            let others = group.meetingCount - 1
            parts.append(others == 1 ? "+1 more meeting" : "+\(others) more meetings")
        }
        return parts.joined(separator: " · ")
    }

    private var canSave: Bool {
        !nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveName() {
        guard canSave, !isSaving else { return }
        isSaving = true
        saveErrorMessage = nil
        model.namePendingReviewItem(group.representative, to: nameDraft) { didSave in
            isSaving = false
            if didSave {
                nameDraft = ""
            } else {
                saveErrorMessage = "Couldn't save — the meeting file may have moved."
            }
        }
    }

    private func markAsMe() {
        guard !isSaving, !isMarkingAsMe else { return }
        isMarkingAsMe = true
        saveErrorMessage = nil
        model.markPendingReviewItemAsMe(group.representative) { didSave in
            isMarkingAsMe = false
            if !didSave {
                saveErrorMessage = "Couldn't save — the meeting file may have moved."
            }
        }
    }

    private func deleteVoice() {
        guard !isDeleting else { return }
        isDeleting = true
        deleteErrorMessage = nil
        model.deleteVoice(group) { didDelete in
            isDeleting = false
            // On success the row's voice group drops out of the refreshed
            // snapshot, so this view disappears. Only a failed delete keeps the
            // row around to show the surfaced error.
            deleteErrorMessage = SpeakerVoiceRowMenuPolicy.deleteErrorMessage(didDelete: didDelete)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

/// Quiet inline play/pause control — a bare glyph, no filled circle. Ink at
/// rest, accent while its clip is the one playing; the caller renders an
/// accent sweep under the sample the sound belongs to, so "what is playing"
/// reads from the content, not from button chrome. Keeps the full 40pt hit
/// target behind a 28pt visible hover fill.
private struct SpeakerQuietPlayButton: View {
    let hasClip: Bool
    let isPlaying: Bool
    let action: () -> Void
    var accessibilityIdentifier: String = "transcripted.speakers.voice-to-name.play"

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: SpeakerClipPlaybackPresentation.symbolName(isPlaying: isPlaying))
                .font(.system(size: SpeakerPeopleSettingsPolishContract.quietPlayGlyphPointSize, weight: .medium))
                .foregroundStyle(glyphColor)
                .frame(
                    width: SpeakerPeopleSettingsPolishContract.compactIconVisibleDiameter,
                    height: SpeakerPeopleSettingsPolishContract.compactIconVisibleDiameter
                )
                .background(
                    RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                        .fill(isHovering && hasClip ? LibraryTokens.rowHover : Color.clear)
                )
                .frame(
                    width: SpeakerPeopleSettingsPolishContract.minimumHitTarget,
                    height: SpeakerPeopleSettingsPolishContract.minimumHitTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasClip)
        .onHover { isHovering = $0 }
        .help(SpeakerClipPlaybackPresentation.helpText(hasClip: hasClip, isPlaying: isPlaying))
        .accessibilityLabel(SpeakerClipPlaybackPresentation.accessibilityLabel(isPlaying: isPlaying))
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var glyphColor: Color {
        guard hasClip else { return LibraryTokens.ink3 }
        return SpeakerClipPlaybackPresentation.isActiveHighlight(hasClip: hasClip, isPlaying: isPlaying)
            ? LibraryTokens.accent
            : LibraryTokens.ink2
    }
}

/// Quiet text-link action ("This is me", "Skip", "Merge into…") — ink3 at
/// rest, ink2 on hover, no fill or border. Matches the mockup's `<a>`
/// affordances and the surface's "color only for action/attention" rule.
private struct SpeakerQuietLinkButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(LibraryTokens.meta)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled && isHovering ? LibraryTokens.ink2 : LibraryTokens.ink3)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Playback progress

/// Thin capsule fill that sweeps across a clip's estimated duration while it
/// plays, then eases back to empty once playback stops. Purely declarative —
/// no timer and no polling of `SpeakerClipPlayback`: `isPlaying` already comes
/// from the section's existing `SpeakerClipPlayback.stateDidChangeNotification`
/// subscription (`playbackStateVersion`), and SwiftUI's own animation engine
/// advances the fill from that single start/stop transition.
private struct SpeakerClipProgressBar: View {
    let isPlaying: Bool
    let duration: TimeInterval

    /// Used when a clip's real duration could not be read (see
    /// `probeClipDuration(_:)` below) so the sweep still looks intentional
    /// instead of snapping instantly to full.
    static let fallbackDuration: TimeInterval = 6

    @State private var isFilled = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(LibraryTokens.hairline)
                Capsule()
                    .fill(LibraryTokens.accent)
                    .frame(width: geometry.size.width * (isFilled ? 1 : 0))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
        .onChange(of: isPlaying) { _, playing in
            if playing {
                isFilled = false
                withAnimation(.linear(duration: max(duration, 0.5))) {
                    isFilled = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.18)) {
                    isFilled = false
                }
            }
        }
    }
}

/// Best-effort clip length for `SpeakerClipProgressBar`'s fill timing.
/// `SpeakerClipPlayback` does not expose the active `NSSound`'s duration (by
/// design — it stays a thin play/stop seam), so this reads the duration
/// directly off the file instead. Cheap: `SpeakerClipExtractor` caps these
/// samples at 8 seconds, and this never touches playback state or starts
/// audio of its own.
private func probeClipDuration(_ url: URL) -> TimeInterval {
    let duration = NSSound(contentsOf: url, byReference: true)?.duration ?? 0
    return duration > 0.1 ? duration : SpeakerClipProgressBar.fallbackDuration
}

private extension DateFormatter {
    func stringIfAvailable(from date: Date) -> String? {
        date == .distantPast ? nil : string(from: date)
    }
}

// MARK: - Everyone directory

/// Quiet find field over the directory — same treatment as the Meetings
/// page's `HomeMeetingSearchField`. The old manual refresh button is gone:
/// navigation and every mutation already refresh the model, so the library
/// never needs hand-cranking.
private struct SpeakerSearchRow: View {
    @ObservedObject var model: SpeakerPeopleSettingsViewModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Search speakers", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFocused)
                // Fires on first appearance and whenever ⌘F bumps the token,
                // so "Find Speaker" focuses the field whether or not the
                // Speakers page was already open.
                .task(id: model.searchFocusRequestToken) {
                    guard model.searchFocusRequestToken > 0 else { return }
                    isSearchFocused = true
                }
                .accessibilityIdentifier("transcripted.speakers.search.field")

            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear speaker search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

private struct SpeakerPersonRow: View {
    let profile: SpeakerProfile
    @ObservedObject var model: SpeakerPeopleSettingsViewModel
    /// Lifted to the parent list so opening one person closes any other —
    /// "one person open at a time", per spec.
    @Binding var expandedPersonID: UUID?

    @State private var nameDraft: String = ""
    @State private var expansionClipDuration = SpeakerClipProgressBar.fallbackDuration
    @State private var showDeleteConfirmation = false
    @State private var pendingMergeTarget: SpeakerProfile?
    @State private var showMergeConfirmation = false
    @State private var showUnmergeConfirmation = false

    @State private var isHovering = false

    private var isExpandedRow: Bool { expandedPersonID == profile.id }

    /// Play + ••• stay hidden until hover, but a row whose clip is playing
    /// keeps its controls (and pause glyph) visible so "what is playing"
    /// never goes dark mid-clip.
    private var showsRowActions: Bool { isHovering || isPlaying }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SpeakerAvatarView(name: profile.displayName)

                Text(displayName)
                    .font(LibraryTokens.rowTitle)
                    .foregroundStyle(profile.displayName == nil ? LibraryTokens.ink2 : Color.primary)
                    .lineLimit(1)

                if let badge {
                    SpeakerStatusBadge(title: badge)
                }

                Spacer(minLength: 12)

                // Always present so the row keeps one constant height; hover
                // only fades the actions in and tints the background — no
                // size change, matching the Meetings/Dictations rows.
                HStack(spacing: 2) {
                    if hasClip {
                        SpeakerQuietPlayButton(
                            hasClip: hasClip,
                            isPlaying: isPlaying,
                            action: { model.playSample(for: profile.id) },
                            accessibilityIdentifier: "transcripted.speakers.person.play"
                        )
                    }

                    rowMenu
                }
                .opacity(showsRowActions ? 1 : 0)
                .allowsHitTesting(showsRowActions)
                .accessibilityHidden(!showsRowActions)

                Text(metadataLine)
                    .font(LibraryTokens.meta)
                    .monospacedDigit()
                    .foregroundStyle(LibraryTokens.ink3)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: LibraryTokens.radiusControl + 1, style: .continuous)
                    .fill((isHovering || isExpandedRow) ? LibraryTokens.rowHover : Color.clear)
            )
            .padding(.horizontal, -10)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
            // Buttons and the menu above consume their own taps before this
            // ever fires, so hover actions (play / rename via the menu /
            // more) keep working without also toggling the expansion.
            .onTapGesture { toggleExpansion() }
            .help("Open speaker")
            .accessibilityIdentifier("transcripted.speakers.person.row")

            if isExpandedRow {
                expansionCard
            }
        }
        .alert("Delete this speaker?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                model.delete(profile: profile)
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("This removes the saved voice profile and sample clip. Past transcripts stay unchanged.")
        }
        .alert(
            mergeConfirmationTitle,
            isPresented: $showMergeConfirmation,
            presenting: pendingMergeTarget
        ) { target in
            Button("Merge") {
                model.merge(source: profile, into: target)
                // Only collapse an expansion that belongs to the merge —
                // an unrelated open speaker (and its rename draft) stays put.
                if expandedPersonID == profile.id || expandedPersonID == target.id {
                    expandedPersonID = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This combines their voices into one. You can undo it later from this speaker's ••• menu. Past transcripts are updated.")
        }
        .alert(unmergeConfirmationTitle, isPresented: $showUnmergeConfirmation) {
            Button("Undo Merge") {
                model.unmerge(into: profile)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This splits the merged voice back into two separate profiles so future recordings match the right person. Past transcripts keep the merged name.")
        }
    }

    private func toggleExpansion() {
        expandedPersonID = isExpandedRow ? nil : profile.id
    }

    private var rowMenu: some View {
        Menu {
            Button(profile.displayName == nil ? "Add Name…" : "Rename…") {
                expandedPersonID = profile.id
            }

            let mergeTargets = model.mergeTargets(for: profile)
            if !mergeTargets.isEmpty {
                Menu("Merge Into") {
                    ForEach(mergeTargets, id: \.id) { target in
                        Button(mergeLabel(for: target)) {
                            pendingMergeTarget = target
                            showMergeConfirmation = true
                        }
                    }
                }
            }

            if model.undoableMerge(for: profile) != nil {
                Button("Undo Last Merge…") {
                    showUnmergeConfirmation = true
                }
            }

            Divider()

            Button("Delete…", role: .destructive) {
                showDeleteConfirmation = true
            }
        } label: {
            SpeakerCompactIconLabel(
                systemName: "ellipsis",
                foregroundColor: .secondary,
                fontSize: 13,
                fontWeight: .semibold
            )
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Rename, merge, or delete this speaker")
        .accessibilityLabel("Speaker actions")
        .accessibilityIdentifier("transcripted.speakers.person.menu")
    }

    private var displayName: String {
        profile.displayName ?? "Unknown voice"
    }

    private var mergeConfirmationTitle: String {
        let source = SpeakerDuplicateCandidate.displayName(for: profile)
        guard let pendingMergeTarget else {
            return "Merge “\(source)” into another speaker?"
        }
        return "Merge “\(source)” into “\(SpeakerDuplicateCandidate.displayName(for: pendingMergeTarget))”?"
    }

    private var unmergeConfirmationTitle: String {
        let name = SpeakerDuplicateCandidate.displayName(for: profile)
        if let merge = model.undoableMerge(for: profile), let sourceName = merge.sourceName {
            return "Undo merge of “\(sourceName)” into “\(name)”?"
        }
        return "Undo the last merge into “\(name)”?"
    }

    private var metadataLine: String {
        let meetings = profile.callCount == 1 ? "1 meeting" : "\(profile.callCount) meetings"
        var parts = [meetings]
        if let lastHeard = Self.relativeFormatter.string(for: profile.lastSeen) {
            parts.append("last heard \(lastHeard)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Expansion

    /// The opened person, expanded in place as a raised card: title (already
    /// shown in the row above), meta line, a voice-sample player, an inline
    /// rename field (autocomplete-backed, same as the queue row), and a quiet
    /// "Merge into…" affordance that shares this row's own merge alert.
    private var expansionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 15, weight: .semibold))
                Text(metadataLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LibraryTokens.ink3)
            }

            expansionPlayerRow
            expansionRenameRow
        }
        .padding(16)
        .contentShape(Rectangle())
        // Swallow taps inside the card so the section's background tap
        // catcher (click-away collapse) doesn't fire for clicks on the
        // card's own non-interactive areas — same trick as
        // `QuietMeetingExpansion`.
        .onTapGesture {}
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .fill(LibraryTokens.raisedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .stroke(LibraryTokens.raisedStroke, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            // Zero-size hidden control so Esc collapses the expansion,
            // matching `QuietMeetingExpansion`'s same trick on Home.
            Button(action: { expandedPersonID = nil }) { EmptyView() }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.bottom, 8)
        .onAppear {
            nameDraft = profile.displayName ?? ""
            if let clipURL = model.clipURL(for: profile.id) {
                expansionClipDuration = probeClipDuration(clipURL)
            }
        }
        .accessibilityIdentifier("transcripted.speakers.person.expansion")
    }

    private var expansionPlayerRow: some View {
        HStack(spacing: 6) {
            SpeakerQuietPlayButton(
                hasClip: hasClip,
                isPlaying: isPlaying,
                action: { model.playSample(for: profile.id) },
                accessibilityIdentifier: "transcripted.speakers.person.expansion.play"
            )

            Text(isPlaying ? "playing voice sample" : "voice sample")
                .font(.system(size: 11))
                .foregroundStyle(isPlaying ? LibraryTokens.ink2 : LibraryTokens.ink3)

            SpeakerClipProgressBar(isPlaying: isPlaying, duration: expansionClipDuration)
                .frame(maxWidth: 160)
                .opacity(isPlaying ? 1 : 0)
                .animation(.easeOut(duration: 0.18), value: isPlaying)

            Spacer(minLength: 0)
        }
    }

    private var expansionRenameRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                expansionNameField
                Text("⏎ to rename")
                    .font(.system(size: 11))
                    .foregroundStyle(LibraryTokens.ink3)
                Spacer(minLength: 8)
                mergeIntoAffordance
            }

            VStack(alignment: .leading, spacing: 8) {
                expansionNameField
                HStack {
                    Text("⏎ to rename")
                        .font(.system(size: 11))
                        .foregroundStyle(LibraryTokens.ink3)
                    Spacer()
                    mergeIntoAffordance
                }
            }
        }
    }

    private var expansionNameField: some View {
        SpeakerNameAutocompleteField(
            text: $nameDraft,
            placeholder: "Speaker name",
            options: nameSuggestions,
            accessibilityIdentifier: "transcripted.speakers.person.expansion.name",
            onSubmit: commitRename
        )
        .frame(minWidth: 180, maxWidth: 240)
    }

    @ViewBuilder
    private var mergeIntoAffordance: some View {
        let targets = model.mergeTargets(for: profile)
        if !targets.isEmpty {
            Menu {
                ForEach(targets, id: \.id) { target in
                    Button(mergeLabel(for: target)) {
                        pendingMergeTarget = target
                        showMergeConfirmation = true
                    }
                }
            } label: {
                Text("Merge into…")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink3)
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("transcripted.speakers.person.expansion.merge")
        }
    }

    private var nameSuggestions: [SpeakerIdentityOption] {
        SpeakerNameSuggestionSource.options(from: model.profiles, excluding: profile.id)
    }

    private func commitRename() {
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.rename(profile: profile, to: trimmed)
        expandedPersonID = nil
    }

    private var badge: String? {
        if model.duplicateCount(for: profile) > 0 {
            return "Possible duplicate"
        }
        if profile.disputeCount > 0 {
            return "Check name"
        }
        return nil
    }

    private var hasClip: Bool {
        model.clipURL(for: profile.id) != nil
    }

    private var isPlaying: Bool {
        model.isPlayingSample(for: profile.id)
    }

    private func mergeLabel(for target: SpeakerProfile) -> String {
        let name = target.displayName ?? "Unknown voice"
        let meetings = target.callCount == 1 ? "1 meeting" : "\(target.callCount) meetings"
        return "\(name) (\(meetings))"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()
}

private struct SpeakerAvatarView: View {
    let name: String?

    var body: some View {
        Circle()
            .fill(color.opacity(0.16))
            .frame(width: 24, height: 24)
            .overlay(
                Text(initials)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color)
            )
    }

    private var initials: String {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "?"
        }
        let words = name
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }
        return letters.joined().uppercased()
    }

    private var color: Color {
        guard let name, !name.isEmpty else { return .secondary }
        return HomeMeetingSpeakerColor.color(for: name)
    }
}

/// Quiet inline status note next to a speaker's name — e.g. "Possible duplicate".
/// Plain ink text, no filled capsule: hierarchy comes from ink level, not a box.
private struct SpeakerStatusBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(LibraryTokens.meta.weight(.medium))
            .foregroundStyle(LibraryTokens.ink3)
            .lineLimit(1)
    }
}
