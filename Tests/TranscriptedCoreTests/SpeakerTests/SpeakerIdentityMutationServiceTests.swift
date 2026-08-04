import Foundation
import XCTest
import SQLite3
@testable import TranscriptedCore

/// Covers `SpeakerIdentityMutationService`, the canonical rename/merge/discard sequence
/// that replaced three independently-implemented orderings (see the type's doc comment
/// for the full history). These tests pin the one behavior none of the three old paths
/// had everywhere: a transcript-write failure must leave the speaker database untouched,
/// and must restore every transcript this call had already rewritten back to its
/// pre-mutation snapshot.
@available(macOS 14.0, *)
final class SpeakerIdentityMutationServiceTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var speakerDatabase: SpeakerDatabase!

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerIdentityMutationServiceTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        speakerDatabase = SpeakerDatabase(
            path: temporaryDirectory.appendingPathComponent("speakers.sqlite").path
        )
    }

    override func tearDown() {
        speakerDatabase = nil
        if let temporaryDirectory {
            // Best-effort: a rollback test may leave a subdirectory read-only.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: temporaryDirectory.appendingPathComponent("b").path
            )
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        super.tearDown()
    }

    // MARK: - Fixtures

    private func writeTranscript(
        named fileName: String,
        in directory: URL? = nil,
        speakerId: UUID,
        speakerName: String
    ) throws -> URL {
        let directory = directory ?? temporaryDirectory!
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        let content = """
        ---
        speakers:
          - id: "0"
            channel: system
            db_id: "\(speakerId.uuidString)"
            name: "\(TranscriptSaver.escapeYAML(speakerName))"
            confidence: medium
            source: db
        ---

        #### Remote Speaker Breakdown

        - **\(speakerName):** 1 utterances, ~2 words, 00:01

        ---

        [00:00] [System/\(speakerName)] hello there
        """
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Rename

    func testRenameHappyPathUpdatesDatabaseAndTranscript() throws {
        let speaker = speakerDatabase.addOrUpdateSpeaker(embedding: [Float](repeating: 0.1, count: 256), existingId: nil)
        speakerDatabase.setDisplayName(id: speaker.id, name: "Speaker 0", source: NameSource.userManual)
        speakerDatabase.incrementDisputeCount(id: speaker.id)
        let transcriptURL = try writeTranscript(named: "one.md", speakerId: speaker.id, speakerName: "Speaker 0")

        let outcome = try SpeakerIdentityMutationService.apply(
            .rename(profileId: speaker.id, newName: "Jamie"),
            speakerDB: speakerDatabase,
            directory: temporaryDirectory
        )

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.updatedTranscriptCount, 1)
        XCTAssertEqual(outcome.resolvedDisplayName, "Jamie")
        XCTAssertEqual(speakerDatabase.getSpeaker(id: speaker.id)?.displayName, "Jamie")
        XCTAssertEqual(speakerDatabase.getSpeaker(id: speaker.id)?.disputeCount, 0)

        let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(updated.contains(#"name: "Jamie""#))
        XCTAssertTrue(updated.contains("[System/Jamie]"))
        XCTAssertFalse(updated.contains("Speaker 0"))
    }

    /// Pins the new atomicity: when one of several affected transcripts can't be written,
    /// the database must never be mutated, and every transcript already rewritten in this
    /// call must be restored to its pre-mutation snapshot. Neither of the two DB-first
    /// legacy callers (Settings rename/merge) had this guarantee before.
    func testRenameWithOneTranscriptWriteFailureRestoresSnapshotsAndLeavesDatabaseUntouched() throws {
        let speaker = speakerDatabase.addOrUpdateSpeaker(embedding: [Float](repeating: 0.1, count: 256), existingId: nil)
        speakerDatabase.setDisplayName(id: speaker.id, name: "Speaker 0", source: NameSource.userManual)

        // "a" sorts before "b", so the writable file is rewritten first, then the
        // unwritable one fails — exercising the rollback of an already-written file.
        let directoryA = temporaryDirectory.appendingPathComponent("a", isDirectory: true)
        let directoryB = temporaryDirectory.appendingPathComponent("b", isDirectory: true)
        let transcriptA = try writeTranscript(
            named: "transcript.md", in: directoryA, speakerId: speaker.id, speakerName: "Speaker 0"
        )
        let transcriptB = try writeTranscript(
            named: "transcript.md", in: directoryB, speakerId: speaker.id, speakerName: "Speaker 0"
        )
        let originalA = try String(contentsOf: transcriptA, encoding: .utf8)
        let originalB = try String(contentsOf: transcriptB, encoding: .utf8)

        // Read-only directory: atomic writes create a sibling temp file before renaming,
        // so this deterministically fails the write to transcriptB without touching
        // transcriptB's own file permissions.
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directoryB.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryB.path)
        }

        let outcome = try SpeakerIdentityMutationService.apply(
            .rename(profileId: speaker.id, newName: "Jamie"),
            speakerDB: speakerDatabase,
            directory: temporaryDirectory
        )

        XCTAssertFalse(outcome.succeeded)
        XCTAssertEqual(outcome.updatedTranscriptCount, 0)

        // The database was never mutated — the write failure was caught before the DB step.
        XCTAssertEqual(speakerDatabase.getSpeaker(id: speaker.id)?.displayName, "Speaker 0")

        // transcriptA was successfully rewritten, then rolled back to its exact snapshot.
        XCTAssertEqual(try String(contentsOf: transcriptA, encoding: .utf8), originalA)
        // transcriptB's write never succeeded in the first place.
        XCTAssertEqual(try String(contentsOf: transcriptB, encoding: .utf8), originalB)
    }

    // MARK: - Merge

    func testMergeAppliesClipSideEffectsOnlyAfterDatabaseCommit() throws {
        let source = speakerDatabase.addOrUpdateSpeaker(embedding: [Float](repeating: 0.2, count: 256), existingId: nil)
        let target = speakerDatabase.addOrUpdateSpeaker(embedding: [Float](repeating: 0.21, count: 256), existingId: nil)
        speakerDatabase.setDisplayName(id: target.id, name: "Sarah", source: NameSource.userManual)
        speakerDatabase.incrementDisputeCount(id: target.id)
        let transcriptURL = try writeTranscript(named: "merge.md", speakerId: source.id, speakerName: "Speaker 0")

        var sideEffectCalls: [(UUID, UUID)] = []
        let outcome = try SpeakerIdentityMutationService.apply(
            .merge(sourceId: source.id, targetId: target.id),
            speakerDB: speakerDatabase,
            directory: temporaryDirectory,
            clipSideEffects: SpeakerIdentityMutationService.ClipSideEffects(
                onMergeCommitted: { sourceId, targetId in
                    sideEffectCalls.append((sourceId, targetId))
                }
            )
        )

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(outcome.resolvedDisplayName, "Sarah")
        XCTAssertEqual(sideEffectCalls.count, 1)
        XCTAssertEqual(sideEffectCalls.first?.0, source.id)
        XCTAssertEqual(sideEffectCalls.first?.1, target.id)

        XCTAssertNil(speakerDatabase.getSpeaker(id: source.id))
        XCTAssertEqual(speakerDatabase.getSpeaker(id: target.id)?.displayName, "Sarah")
        XCTAssertEqual(speakerDatabase.getSpeaker(id: target.id)?.disputeCount, 0)

        let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(updated.contains(#"db_id: "\#(target.id.uuidString)""#))
        XCTAssertTrue(updated.contains("[System/Sarah]"))
    }

    func testMergeRestoresTranscriptsWhenDatabaseMergeFails() throws {
        let source = speakerDatabase.addOrUpdateSpeaker(embedding: [Float](repeating: 0.2, count: 256), existingId: nil)
        // targetId does not exist — mergeProfiles throws profileNotFound, exercising the
        // DB-failure rollback path (the free SQL ROLLBACK plus this call's transcript restore).
        let missingTargetId = UUID()
        let transcriptURL = try writeTranscript(named: "merge-fail.md", speakerId: source.id, speakerName: "Speaker 0")
        let original = try String(contentsOf: transcriptURL, encoding: .utf8)

        var sideEffectCalled = false
        let outcome = try SpeakerIdentityMutationService.apply(
            .merge(sourceId: source.id, targetId: missingTargetId),
            speakerDB: speakerDatabase,
            directory: temporaryDirectory,
            clipSideEffects: SpeakerIdentityMutationService.ClipSideEffects(
                onMergeCommitted: { _, _ in sideEffectCalled = true }
            )
        )

        XCTAssertFalse(outcome.succeeded)
        XCTAssertFalse(sideEffectCalled, "clip side effects must not run when the DB transaction fails")
        XCTAssertNotNil(speakerDatabase.getSpeaker(id: source.id), "source profile must survive a failed merge")
        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), original)
    }

    // MARK: - Discard

    func testDiscardRestoresMatchedProfileSnapshotAndClearsTranscriptLink() throws {
        let matched = speakerDatabase.addOrUpdateSpeaker(embedding: [Float](repeating: 0.3, count: 256), existingId: nil)
        speakerDatabase.setDisplayName(id: matched.id, name: "Priya", source: NameSource.userManual)
        guard let snapshot = speakerDatabase.getSpeaker(id: matched.id) else {
            return XCTFail("expected snapshot")
        }
        // Simulate the review flow overwriting the profile with a tentative match before
        // the user discards it — the snapshot is what gets restored.
        speakerDatabase.setDisplayName(id: matched.id, name: "Wrong Guess", source: NameSource.userManual)
        let transcriptURL = try writeTranscript(named: "discard.md", speakerId: matched.id, speakerName: "Wrong Guess")

        var deletedCalled = false
        let outcome = try SpeakerIdentityMutationService.apply(
            .discard(profileId: matched.id, matchedProfileSnapshot: snapshot),
            speakerDB: speakerDatabase,
            directory: temporaryDirectory,
            clipSideEffects: SpeakerIdentityMutationService.ClipSideEffects(
                onDiscardDeletedProfile: { _ in deletedCalled = true }
            )
        )

        XCTAssertTrue(outcome.succeeded)
        XCTAssertFalse(deletedCalled, "a snapshot restore must not also delete the profile")
        XCTAssertEqual(speakerDatabase.getSpeaker(id: matched.id)?.displayName, "Priya")
        XCTAssertEqual(speakerDatabase.getSpeaker(id: matched.id)?.disputeCount, 1)

        let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertFalse(updated.contains(matched.id.uuidString))
        XCTAssertTrue(updated.contains("confidence: unknown"))
        XCTAssertTrue(updated.contains("source: unknown"))
    }

    func testDiscardWithoutSnapshotDeletesProfileAndInvokesClipCleanup() throws {
        let profile = speakerDatabase.addOrUpdateSpeaker(embedding: [Float](repeating: 0.4, count: 256), existingId: nil)
        let transcriptURL = try writeTranscript(named: "discard-new.md", speakerId: profile.id, speakerName: "Speaker 0")

        var deletedIds: [UUID] = []
        let outcome = try SpeakerIdentityMutationService.apply(
            .discard(profileId: profile.id, matchedProfileSnapshot: nil),
            speakerDB: speakerDatabase,
            directory: temporaryDirectory,
            clipSideEffects: SpeakerIdentityMutationService.ClipSideEffects(
                onDiscardDeletedProfile: { id in deletedIds.append(id) }
            )
        )

        XCTAssertTrue(outcome.succeeded)
        XCTAssertEqual(deletedIds, [profile.id])
        XCTAssertNil(speakerDatabase.getSpeaker(id: profile.id))

        let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertFalse(updated.contains(profile.id.uuidString))
    }

    // MARK: - Codex review follow-ups (PR #1630)

    /// P1a: a byte pre-scan match that can't be confirmed by a full read must abort the
    /// whole mutation instead of silently being treated as "not affected" while the DB
    /// mutation commits anyway.
    func testPlanningReadFailureAbortsBeforeAnyMutation() throws {
        let speaker = speakerDatabase.addOrUpdateSpeaker(embedding: [Float](repeating: 0.1, count: 256), existingId: nil)
        speakerDatabase.setDisplayName(id: speaker.id, name: "Speaker 0", source: NameSource.userManual)
        let transcriptURL = try writeTranscript(named: "unreadable.md", speakerId: speaker.id, speakerName: "Speaker 0")

        // Permission 0 means even the owning test process can't open the file — both the
        // scanFrontmatter byte pre-scan and the full read hit a real I/O failure, matching
        // the code path being pinned (as opposed to a needle-not-present skip).
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: transcriptURL.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: transcriptURL.path)
        }

        XCTAssertThrowsError(try SpeakerIdentityMutationService.apply(
            .rename(profileId: speaker.id, newName: "Jamie"),
            speakerDB: speakerDatabase,
            directory: temporaryDirectory
        )) { error in
            guard case SpeakerIdentityMutationService.MutationError.transcriptPlanningReadFailed(let fileCount) = error else {
                return XCTFail("expected transcriptPlanningReadFailed, got \(error)")
            }
            XCTAssertEqual(fileCount, 1)
        }

        // Nothing was mutated: the database still has the pre-rename name.
        XCTAssertEqual(speakerDatabase.getSpeaker(id: speaker.id)?.displayName, "Speaker 0")
    }

    /// P1b: a delete failure inside the discard mutation batch must roll the whole batch
    /// back — the profile must survive and the transcript's database link must be restored
    /// — not commit with the transcript link removed while the row stays.
    func testDiscardDeleteFailureRollsBackTheBatch() throws {
        let profile = speakerDatabase.addOrUpdateSpeaker(embedding: [Float](repeating: 0.4, count: 256), existingId: nil)
        let transcriptURL = try writeTranscript(named: "discard-delete-fails.md", speakerId: profile.id, speakerName: "Speaker 0")
        let original = try String(contentsOf: transcriptURL, encoding: .utf8)

        // Deny DELETEs on the speakers table so the SQL step inside deleteSpeakerImpl fails.
        // Mirrors the sqlite3_set_authorizer technique SpeakerNamingCoordinatorTests uses to
        // force a deterministic DB-layer failure.
        let authorizerResult = speakerDatabase.queue.sync {
            sqlite3_set_authorizer(speakerDatabase.db, { _, action, tableName, _, _, _ in
                guard action == SQLITE_DELETE, let tableName, String(cString: tableName) == "speakers" else {
                    return SQLITE_OK
                }
                return SQLITE_DENY
            }, nil)
        }
        XCTAssertEqual(authorizerResult, SQLITE_OK)
        defer {
            _ = speakerDatabase.queue.sync {
                sqlite3_set_authorizer(speakerDatabase.db, nil, nil)
            }
        }

        var deletedCalled = false
        let outcome = try SpeakerIdentityMutationService.apply(
            .discard(profileId: profile.id, matchedProfileSnapshot: nil),
            speakerDB: speakerDatabase,
            directory: temporaryDirectory,
            clipSideEffects: SpeakerIdentityMutationService.ClipSideEffects(
                onDiscardDeletedProfile: { _ in deletedCalled = true }
            )
        )

        XCTAssertFalse(outcome.succeeded)
        XCTAssertFalse(deletedCalled, "clip cleanup must not run when the DB transaction fails")
        XCTAssertNotNil(speakerDatabase.getSpeaker(id: profile.id), "the row must survive a rolled-back delete")
        XCTAssertEqual(
            try String(contentsOf: transcriptURL, encoding: .utf8),
            original,
            "the transcript's database link must be restored, not left removed"
        )
    }

    /// P2a: when a restore itself can't be completed (even after the built-in retry), the
    /// service must surface a distinct, nameable error rather than silently leaving the
    /// database and a transcript disagreeing. A true end-to-end filesystem repro of "the
    /// rewrite to a path succeeded, then the later restore to that identical path fails" is
    /// not constructible with static POSIX permissions (both operations have identical
    /// requirements on the identical path), so this exercises the retry/throw mechanism
    /// (`SpeakerIdentityMutationService.restoreOrThrow`) directly, against a path whose
    /// parent directory does not exist and so fails deterministically on every attempt.
    func testRestoreOrThrowSurfacesADistinctErrorWhenRestoreFailsAfterRetry() {
        let missingParentDirectory = temporaryDirectory
            .appendingPathComponent("does-not-exist", isDirectory: true)
        let ghostURL = missingParentDirectory.appendingPathComponent("ghost.md")
        let plan = SpeakerIdentityMutationService.PlannedRewrite(
            url: ghostURL,
            originalContent: "original",
            rewrittenContent: "rewritten"
        )

        XCTAssertThrowsError(try SpeakerIdentityMutationService.restoreOrThrow([plan])) { error in
            guard case SpeakerIdentityMutationService.MutationError.transcriptRestoreFailed(let fileCount) = error else {
                return XCTFail("expected transcriptRestoreFailed, got \(error)")
            }
            XCTAssertEqual(fileCount, 1)
        }
    }

    /// A restore set that fully succeeds must not throw — confirms the retry path only
    /// escalates to an error when a file is genuinely, persistently unrestorable.
    func testRestoreOrThrowSucceedsWhenEveryFileCanBeRestored() throws {
        let url = temporaryDirectory.appendingPathComponent("restorable.md")
        try "rewritten".write(to: url, atomically: true, encoding: .utf8)
        let plan = SpeakerIdentityMutationService.PlannedRewrite(
            url: url,
            originalContent: "original",
            rewrittenContent: "rewritten"
        )

        XCTAssertNoThrow(try SpeakerIdentityMutationService.restoreOrThrow([plan]))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "original")
    }

    /// P2c: a merge intent naming the same profile as both source and target would
    /// update-then-delete the same row, leaving dangling references — the service must
    /// reject it outright rather than let the Settings-layer `source.id != target.id`
    /// guard be the only thing standing between callers and that outcome.
    func testMergeWithSameSourceAndTargetThrowsBeforeAnyMutation() throws {
        let profile = speakerDatabase.addOrUpdateSpeaker(embedding: [Float](repeating: 0.5, count: 256), existingId: nil)
        speakerDatabase.setDisplayName(id: profile.id, name: "Solo", source: NameSource.userManual)
        _ = try writeTranscript(named: "self-merge.md", speakerId: profile.id, speakerName: "Solo")

        XCTAssertThrowsError(try SpeakerIdentityMutationService.apply(
            .merge(sourceId: profile.id, targetId: profile.id),
            speakerDB: speakerDatabase,
            directory: temporaryDirectory
        )) { error in
            guard case SpeakerIdentityMutationService.MutationError.sameSourceAndTarget(let id) = error else {
                return XCTFail("expected sameSourceAndTarget, got \(error)")
            }
            XCTAssertEqual(id, profile.id)
        }

        // Nothing was touched — the guard fires before the transcript scan or DB work.
        XCTAssertEqual(speakerDatabase.getSpeaker(id: profile.id)?.displayName, "Solo")
    }
}
