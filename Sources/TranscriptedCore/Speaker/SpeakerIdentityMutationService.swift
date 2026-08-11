import Foundation

// MARK: - Speaker Identity Mutation Service
//
// "Write a speaker identity change to both the speaker DB and saved transcripts" used to
// be implemented three different ways with three different orderings:
//
// 1. `SpeakerNamingCoordinator.handleNamingComplete` (per-meeting naming flow): rewrites
//    the just-finalized transcript first (it has the `TranscriptionResult` in memory, so
//    it can rewrite by utterance position instead of by name text), then applies the DB
//    mutation batch, and rolls the transcript back to its pre-rewrite snapshot if the DB
//    step throws. This is the only one of the three that had any rollback at all.
// 2. `SpeakerPeopleSettingsViewModel.rename` (Settings > People): wrote the DB change
//    first, then scanned every saved transcript on disk and rewrote each one, logging and
//    continuing past per-file failures. A DB write that succeeded while a later transcript
//    write failed left the two stores permanently disagreeing about the speaker's name.
// 3. The merge path (`SpeakerPeopleSettingsViewModel.merge` +
//    `SpeakerProfileMergeSideEffectCoordinator`): DB merge, then clip promotion/deletion,
//    then a separate un-rolled-back transcript scan — its own ordering and its own subset
//    of side effects.
//
// This type is the single canonical implementation of that sequence: plan which saved
// transcripts reference the affected profile(s), snapshot their current content, rewrite
// them, commit the database change inside a real SQL transaction
// (`SpeakerStore.performMutationBatch`), and — if that transaction throws — restore every
// transcript this call rewrote back to its snapshot. Clip side effects run last, only
// after both stores agree.
//
// Deliberate ordering note: transcripts are rewritten *before* the DB transaction, not
// after. `performMutationBatch` already gets a free, exact rollback from SQLite's own
// ROLLBACK when the batch throws — nothing extra to do there. A transcript rewrite has no
// equivalent undo once a DB merge has *committed* (there is no way to losslessly reverse
// "the source profile's row was deleted and its embedding blended into the target"; even
// `unmergeMostRecent` only approximately reconstructs it from stored history). Restoring
// a transcript from an in-memory snapshot, on the other hand, is always exact. So the step
// with a free, exact rollback (the DB write) is the one that safely goes last — same
// ordering `SpeakerNamingCoordinator` already used and the model for this service.
//
// Engine note: this service reuses `TranscriptSaver.applyRetroactiveRename` — the same
// frontmatter-row-scoped, name-conflict-aware rewrite engine already shared by the legacy
// `retroactivelyUpdateSpeaker`/`retroactivelyMergeSpeaker` entry points — as the one
// library-scan rewrite engine for rename and merge. It intentionally does *not* adopt
// `SpeakerNamingCoordinator`'s utterance-position engine
// (`TranscriptSaver.updateSpeakerNames(transcriptURL:updates:transcriptionResult:)`):
// that engine requires the in-memory `TranscriptionResult` from the transcription that
// just finished, which does not exist for historical transcripts being scanned from disk.
// The two engines are not interchangeable, so "pick the strictest" is scoped to the
// engines that could actually replace each other; see the PR description for the full
// engine census, including the still-separate single-transcript
// `updateDeferredSpeakerName` engine intentionally left out of this unification.
@available(macOS 14.0, *)
public enum SpeakerIdentityMutationService {

    public enum Intent {
        /// Rename a profile everywhere it appears in the saved-transcript library.
        case rename(profileId: UUID, newName: String)
        /// Absorb `sourceId` into `targetId`, repointing every saved-transcript reference.
        case merge(sourceId: UUID, targetId: UUID)
        /// Remove a profile's database link from every saved transcript that references it.
        /// When `matchedProfileSnapshot` is provided the profile is restored to that
        /// snapshot (a review verdict reverting to the previously-matched person);
        /// otherwise the profile itself is deleted (discarding a newly-created profile).
        case discard(profileId: UUID, matchedProfileSnapshot: SpeakerProfile?)
    }

    /// Best-effort, non-transcript side effects that only run after both the transcript
    /// rewrites and the DB transaction have succeeded. Callers own their own clip storage
    /// layout, so these are injected rather than owned by this Core-layer service.
    public struct ClipSideEffects {
        public var onMergeCommitted: (_ sourceId: UUID, _ targetId: UUID) -> Void
        public var onDiscardDeletedProfile: (_ profileId: UUID) -> Void

        public init(
            onMergeCommitted: @escaping (_ sourceId: UUID, _ targetId: UUID) -> Void = { _, _ in },
            onDiscardDeletedProfile: @escaping (_ profileId: UUID) -> Void = { _ in }
        ) {
            self.onMergeCommitted = onMergeCommitted
            self.onDiscardDeletedProfile = onDiscardDeletedProfile
        }
    }

    public struct Outcome {
        public let succeeded: Bool
        public let updatedTranscriptCount: Int
        public let resolvedDisplayName: String?
    }

    /// Thrown for failures too severe to represent as an ordinary `Outcome(succeeded:
    /// false)` — either because nothing was mutated yet (so the caller should treat this
    /// as "did not happen" rather than "happened and failed"), or because the DB and saved
    /// transcripts may now disagree and a caller silently swallowing a boolean would hide
    /// that.
    public enum MutationError: Error, LocalizedError, Equatable {
        /// A transcript the byte pre-scan flagged as possibly referencing this profile
        /// could not be fully read to confirm. Thrown instead of silently treating
        /// "unreadable" as "not affected" — nothing is mutated yet at the planning stage,
        /// so aborting here is clean.
        case transcriptPlanningReadFailed(fileCount: Int)
        /// The DB transaction (or a transcript write) failed AND restoring at least one
        /// already-rewritten transcript back to its snapshot also failed, even after one
        /// retry. The DB and the named transcript(s) may now disagree — this is surfaced
        /// distinctly so a caller doesn't mistake it for an ordinary, cleanly-rolled-back
        /// failure.
        case transcriptRestoreFailed(fileCount: Int)
        /// Rejects a no-op merge that would update-then-delete the same profile row,
        /// leaving dangling `db_id` references in every transcript that pointed at it.
        case sameSourceAndTarget(profileId: UUID)

        public var errorDescription: String? {
            switch self {
            case .transcriptPlanningReadFailed(let count):
                return "Could not confirm \(count) transcript(s) flagged as possibly referencing this speaker; aborted before any mutation."
            case .transcriptRestoreFailed(let count):
                return "Failed to restore \(count) transcript(s) after a rollback; the database and those transcripts may now disagree."
            case .sameSourceAndTarget:
                return "Cannot merge a speaker profile into itself."
            }
        }
    }

    /// Apply one speaker identity intent under the canonical sequence. Thread-safe:
    /// serialized on the same queue transcript finalization uses
    /// (`TranscriptSaver.serializeTranscriptFileUpdate`), so this cannot race a naming-flow
    /// transcript write or another mutation from this service.
    ///
    /// Throws `MutationError` for the failure modes above; returns `Outcome(succeeded:
    /// false, ...)` for ordinary, cleanly-rolled-back failures (a transcript write failed,
    /// or the DB transaction threw and every rewritten transcript was restored) so callers
    /// that just want a boolean don't have to unwrap an error for the common case.
    @discardableResult
    public static func apply(
        _ intent: Intent,
        speakerDB: any SpeakerStore,
        directory: URL = TranscriptSaver.defaultSaveDirectory,
        clipSideEffects: ClipSideEffects = ClipSideEffects()
    ) throws -> Outcome {
        if case let .merge(sourceId, targetId) = intent, sourceId == targetId {
            throw MutationError.sameSourceAndTarget(profileId: sourceId)
        }

        return try TranscriptSaver.serializeTranscriptFileUpdate {
            switch intent {
            case let .rename(profileId, newName):
                return try applyRename(profileId: profileId, newName: newName, speakerDB: speakerDB, directory: directory)
            case let .merge(sourceId, targetId):
                return try applyMerge(
                    sourceId: sourceId,
                    targetId: targetId,
                    speakerDB: speakerDB,
                    directory: directory,
                    clipSideEffects: clipSideEffects
                )
            case let .discard(profileId, matchedProfileSnapshot):
                return try applyDiscard(
                    profileId: profileId,
                    matchedProfileSnapshot: matchedProfileSnapshot,
                    speakerDB: speakerDB,
                    directory: directory,
                    clipSideEffects: clipSideEffects
                )
            }
        }
    }

    // MARK: - Rename

    private static func applyRename(
        profileId: UUID,
        newName: String,
        speakerDB: any SpeakerStore,
        directory: URL
    ) throws -> Outcome {
        let planned = try planAffectedTranscripts(matchingDbId: profileId, directory: directory)
        guard !replacementBlocksMutation(planned, operation: "rename") else {
            return failure()
        }

        let rewrites: [PlannedRewrite] = planned.compactMap { entry in
            var content = entry.content
            guard TranscriptSaver.applyRetroactiveRename(
                in: &content,
                dbId: profileId,
                newName: newName,
                fileName: entry.url.lastPathComponent
            ) else { return nil }
            return PlannedRewrite(url: entry.url, originalContent: entry.content, rewrittenContent: content)
        }

        guard let written = try writeAndTrackForRollback(rewrites) else {
            return failure()
        }

        do {
            try speakerDB.performMutationBatch {
                speakerDB.setDisplayName(id: profileId, name: newName, source: NameSource.userManual)
                speakerDB.resetDisputeCount(id: profileId)
            }
        } catch {
            AppLogger.speakers.error("Speaker rename persistence failed; restoring transcripts", [
                "profileId": profileId.uuidString,
                "error": error.localizedDescription
            ])
            try restoreOrThrow(written)
            return failure()
        }

        if !written.isEmpty {
            AppLogger.speakers.info("Renamed speaker across saved transcripts", [
                "profileId": profileId.uuidString,
                "files": "\(written.count)"
            ])
        }
        return Outcome(succeeded: true, updatedTranscriptCount: written.count, resolvedDisplayName: newName)
    }

    // MARK: - Merge

    private static func applyMerge(
        sourceId: UUID,
        targetId: UUID,
        speakerDB: any SpeakerStore,
        directory: URL,
        clipSideEffects: ClipSideEffects
    ) throws -> Outcome {
        // Mirrors SpeakerDatabase.mergeProfilesImpl's own merged-name rule so the transcript
        // rewrite (which must happen before the DB commit) uses the exact name the DB
        // mutation is about to produce.
        //
        // Ordering/race note: this read happens inside the same `serializeTranscriptFileUpdate`
        // lock `apply(_:)` already holds for the whole call, so it can't interleave with
        // another `SpeakerIdentityMutationService.apply` call or with
        // `SpeakerNamingCoordinator`'s own transcript-write-then-DB-mutation block, which is
        // also wrapped in one `serializeTranscriptFileUpdate` closure — those two either fully
        // precede or fully follow this read. The one residual window: Coordinator's
        // collapse/discard DB side effects (`restoreCollapsedMatchedSpeakers`,
        // `applyDiscardedSpeakerActions`, the collapsed-mic-profile delete loop) run *after*
        // that closure returns and the lock is released, on a background queue — a merge that
        // lands in that specific gap could still read a display name Coordinator is about to
        // overwrite or restore. Closing that fully would mean moving those DB writes inside
        // Coordinator's lock, a change to a separately deeply-tested 900-line file that is out
        // of scope here (see the PR description). Documented, not silently assumed away.
        let sourceProfile = speakerDB.getSpeaker(id: sourceId)
        let targetProfile = speakerDB.getSpeaker(id: targetId)
        let resolvedName = targetProfile?.displayName
            ?? sourceProfile?.displayName
            ?? "Speaker \(targetId.uuidString.prefix(8))"

        let planned = try planAffectedTranscripts(matchingDbId: sourceId, directory: directory)
        guard !replacementBlocksMutation(planned, operation: "merge") else {
            return failure()
        }
        let sourceIdNeedle = "db_id: \"\(sourceId.uuidString)\""
        let targetIdReplacement = "db_id: \"\(targetId.uuidString)\""

        let rewrites: [PlannedRewrite] = planned.map { entry in
            var content = entry.content
            TranscriptSaver.applyRetroactiveRename(
                in: &content,
                dbId: sourceId,
                newName: resolvedName,
                fileName: entry.url.lastPathComponent
            )
            content = content.replacingOccurrences(of: sourceIdNeedle, with: targetIdReplacement)
            return PlannedRewrite(url: entry.url, originalContent: entry.content, rewrittenContent: content)
        }

        guard let written = try writeAndTrackForRollback(rewrites) else {
            return failure()
        }

        do {
            try speakerDB.performMutationBatch {
                try speakerDB.mergeProfiles(sourceId: sourceId, into: targetId)
                // Matches SpeakerNamingCoordinator's merge mutation: a merge is a resolved
                // identity, not a dispute, so the target's dispute counter clears too.
                speakerDB.resetDisputeCount(id: targetId)
            }
        } catch {
            AppLogger.speakers.error("Speaker merge persistence failed; restoring transcripts", [
                "sourceId": sourceId.uuidString,
                "targetId": targetId.uuidString,
                "error": error.localizedDescription
            ])
            try restoreOrThrow(written)
            return failure()
        }

        clipSideEffects.onMergeCommitted(sourceId, targetId)

        if !written.isEmpty {
            AppLogger.speakers.info("Retroactively merged speaker in transcripts", [
                "sourceId": sourceId.uuidString,
                "targetId": targetId.uuidString,
                "files": "\(written.count)"
            ])
        }
        return Outcome(succeeded: true, updatedTranscriptCount: written.count, resolvedDisplayName: resolvedName)
    }

    // MARK: - Discard

    private static func applyDiscard(
        profileId: UUID,
        matchedProfileSnapshot: SpeakerProfile?,
        speakerDB: any SpeakerStore,
        directory: URL,
        clipSideEffects: ClipSideEffects
    ) throws -> Outcome {
        let planned = try planAffectedTranscripts(matchingDbId: profileId, directory: directory)
        guard !replacementBlocksMutation(planned, operation: "discard") else {
            return failure()
        }

        let rewrites: [PlannedRewrite] = planned.compactMap { entry in
            var content = entry.content
            guard TranscriptSaver.discardSpeakerDatabaseLink(in: &content, dbId: profileId) else { return nil }
            return PlannedRewrite(url: entry.url, originalContent: entry.content, rewrittenContent: content)
        }

        guard let written = try writeAndTrackForRollback(rewrites) else {
            return failure()
        }

        do {
            try speakerDB.performMutationBatch {
                if let matchedProfileSnapshot {
                    speakerDB.restoreProfile(matchedProfileSnapshot)
                    speakerDB.incrementDisputeCount(id: matchedProfileSnapshot.id)
                } else {
                    speakerDB.deleteSpeaker(id: profileId)
                }
            }
        } catch {
            AppLogger.speakers.error("Speaker discard persistence failed; restoring transcripts", [
                "profileId": profileId.uuidString,
                "error": error.localizedDescription
            ])
            try restoreOrThrow(written)
            return failure()
        }

        if matchedProfileSnapshot == nil {
            clipSideEffects.onDiscardDeletedProfile(profileId)
        }

        if !written.isEmpty {
            AppLogger.speakers.info("Discarded speaker database link across saved transcripts", [
                "profileId": profileId.uuidString,
                "files": "\(written.count)"
            ])
        }
        return Outcome(succeeded: true, updatedTranscriptCount: written.count, resolvedDisplayName: nil)
    }

    // MARK: - Plan / snapshot / write / rollback

    private struct PlannedTranscript {
        let url: URL
        let content: String
    }

    private static func replacementBlocksMutation(
        _ planned: [PlannedTranscript],
        operation: String
    ) -> Bool {
        let urls = planned.map(\.url)
        guard TranscriptSaver.isReplacingAnyTranscript(at: urls) else { return false }

        AppLogger.speakers.warning("Speaker identity mutation blocked during replacement retranscription", [
            "operation": operation,
            "files": "\(urls.count)"
        ])
        return true
    }

    // Not private: SpeakerIdentityMutationServiceTests exercises restoreOrThrow directly
    // (a real end-to-end filesystem repro of "the rewrite succeeded but the later restore
    // of that exact path then fails" isn't constructible with static POSIX permissions —
    // both operations target the identical path under identical permissions — so the
    // retry/throw mechanism itself is what's under test here).
    struct PlannedRewrite {
        let url: URL
        let originalContent: String
        let rewrittenContent: String
    }

    /// Cheap-filters then fully reads every saved transcript referencing `dbId`. The
    /// returned content doubles as the pre-mutation snapshot used to roll back a partial
    /// write set if a later step fails.
    ///
    /// Fails closed: the byte pre-scan (`scanFrontmatter`) can return `.matched` or
    /// `.needsFullRead` for a file that genuinely (or possibly) references `dbId`. If the
    /// follow-up full read of such a file then fails, silently treating it as "not
    /// affected" would let the DB mutation commit while that transcript's stale reference
    /// survives untouched and unreported. Nothing has been mutated yet at this point, so
    /// throwing here is a clean abort rather than a partial one.
    private static func planAffectedTranscripts(
        matchingDbId dbId: UUID,
        directory: URL
    ) throws -> [PlannedTranscript] {
        let needle = "db_id: \"\(dbId.uuidString)\""
        var results: [PlannedTranscript] = []
        var unreadableCount = 0
        for url in TranscriptSaver.transcriptMarkdownFiles(under: directory) {
            guard TranscriptSaver.scanFrontmatter(at: url, for: needle) != .notMatched else { continue }
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                AppLogger.speakers.error("Speaker identity planning could not read a flagged transcript", [
                    "file": url.lastPathComponent
                ])
                unreadableCount += 1
                continue
            }
            guard content.contains(needle) else { continue }
            results.append(PlannedTranscript(url: url, content: content))
        }
        guard unreadableCount == 0 else {
            throw MutationError.transcriptPlanningReadFailed(fileCount: unreadableCount)
        }
        return results
    }

    /// Writes every planned rewrite in order. On the first write failure, restores every
    /// file already written in this call back to its snapshot and returns nil — callers
    /// must not proceed to the DB mutation when this returns nil, since the transcript and
    /// DB stores would then disagree. Throws instead of returning nil if the restore itself
    /// can't be completed (see `restoreOrThrow`).
    private static func writeAndTrackForRollback(_ plans: [PlannedRewrite]) throws -> [PlannedRewrite]? {
        var written: [PlannedRewrite] = []
        for plan in plans {
            do {
                try plan.rewrittenContent.write(to: plan.url, atomically: true, encoding: .utf8)
                FileManager.default.restrictToOwnerOnly(atPath: plan.url.path)
                written.append(plan)
            } catch {
                AppLogger.speakers.error("Speaker identity transcript rewrite failed", [
                    "file": plan.url.lastPathComponent,
                    "error": error.localizedDescription
                ])
                try restoreOrThrow(written)
                return nil
            }
        }
        return written
    }

    /// Restores every plan to its snapshot, retrying a failed restore once (covers a
    /// transient failure — e.g. a momentary lock from a file indexer or backup agent —
    /// without adding unbounded delay to a UI-facing rename/merge/discard call). If any
    /// file still can't be restored after the retry, throws `.transcriptRestoreFailed`
    /// instead of silently leaving the database and that transcript disagreeing.
    ///
    /// Residual reality: this only helps with transient failures. A persistent condition
    /// (the volume is full, the directory was deleted, permissions were changed and stay
    /// changed) will still fail after the retry — no in-process retry can fix that. At that
    /// point the thrown error is this call's way of refusing to report success it can't
    /// back up; recovery is an out-of-band, on-disk repair (or a future retry once the
    /// underlying condition clears), not something this call can complete for the caller.
    ///
    /// Not private, for the same testability reason as `PlannedRewrite`.
    static func restoreOrThrow(_ plans: [PlannedRewrite]) throws {
        var stillFailing = plans.filter { !attemptRestore($0) }
        guard !stillFailing.isEmpty else { return }

        stillFailing = stillFailing.filter { !attemptRestore($0) }
        guard stillFailing.isEmpty else {
            AppLogger.speakers.error("Speaker identity transcript rollback failed after retry", [
                "fileCount": "\(stillFailing.count)"
            ])
            throw MutationError.transcriptRestoreFailed(fileCount: stillFailing.count)
        }
    }

    private static func attemptRestore(_ plan: PlannedRewrite) -> Bool {
        do {
            try plan.originalContent.write(to: plan.url, atomically: true, encoding: .utf8)
            FileManager.default.restrictToOwnerOnly(atPath: plan.url.path)
            return true
        } catch {
            AppLogger.speakers.error("Speaker identity transcript rollback failed", [
                "file": plan.url.lastPathComponent,
                "error": error.localizedDescription
            ])
            return false
        }
    }

    private static func failure() -> Outcome {
        Outcome(succeeded: false, updatedTranscriptCount: 0, resolvedDisplayName: nil)
    }
}
