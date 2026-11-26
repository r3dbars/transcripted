import XCTest
import SQLite3
@testable import TranscriptedCore

/// Regression tests for P4:
/// - `revertMatchContribution` and `restoreProfile` clean up rejected session exemplars
///   and `speaker_provenance` rows so rejected voices never poison matching or reappear
///   after a later un-merge.
/// - `deleteSpeaker` and `pruneWeakProfiles` erase `speaker_provenance`,
///   `speaker_merge_events`, `speaker_confirmation_moves`, and
///   `speaker_contribution_reassignments` (including transitive merged-in aliases),
///   while preserving `merge -> unmerge` for surviving speakers.
@available(macOS 14.0, *)
final class SpeakerRollbackAndDeletePrivacyTests: XCTestCase {

    private var tempDirectory: URL!
    private var database: SpeakerDatabase!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerRollbackAndDeletePrivacyTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        database = SpeakerDatabase(path: tempDirectory.appendingPathComponent("speakers.sqlite").path)
    }

    override func tearDownWithError() throws {
        database = nil
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    private func axisEmbedding(_ axis: Int, dim: Int = 256) -> [Float] {
        var vector = [Float](repeating: 0.0, count: dim)
        vector[axis] = 1.0
        return vector
    }

    private func rowCount(sql: String, bindings: [String] = []) throws -> Int {
        try database.queue.sync {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database.db, sql, -1, &statement, nil) == SQLITE_OK else {
                throw NSError(domain: "SQLiteTest", code: 1)
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for (index, value) in bindings.enumerated() {
                sqlite3_bind_text(statement, Int32(index + 1), (value as NSString).utf8String, -1, transient)
            }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    // MARK: - Rejected-session exemplar & provenance rollback

    func testRevertMatchContributionRemovesRejectedExemplarAndProvenanceRow() throws {
        let baseVoice = axisEmbedding(0)
        let wrongVoice = axisEmbedding(1)
        let profile = database.addOrUpdateSpeaker(embedding: baseVoice, existingId: nil)
        database.setDisplayName(id: profile.id, name: "Taylor", source: NameSource.userManual)
        let preMeetingSnapshot = try XCTUnwrap(database.getSpeaker(id: profile.id))
        XCTAssertTrue(preMeetingSnapshot.exemplars.isEmpty)
        XCTAssertEqual(database.contributions(forProfileId: profile.id).count, 1)

        // Meeting wrongly matches Taylor with a distinct voice, adding an exemplar + provenance row.
        _ = database.addOrUpdateSpeaker(embedding: wrongVoice, existingId: profile.id)
        let poisoned = try XCTUnwrap(database.getSpeaker(id: profile.id))
        XCTAssertEqual(poisoned.exemplars.count, 1, "distinct condition seeded an exemplar")
        XCTAssertEqual(database.contributions(forProfileId: profile.id).count, 2)

        // User discards / collapses / defers / corrects the match.
        database.revertMatchContribution(snapshot: preMeetingSnapshot, rejectedEmbedding: wrongVoice)

        let restored = try XCTUnwrap(database.getSpeaker(id: profile.id))
        XCTAssertEqual(restored.callCount, preMeetingSnapshot.callCount)
        XCTAssertEqual(restored.embedding, preMeetingSnapshot.embedding)
        XCTAssertTrue(restored.exemplars.isEmpty, "rejected session exemplar must be removed")
        XCTAssertEqual(
            database.contributions(forProfileId: profile.id).count,
            1,
            "rejected session provenance row must be removed"
        )
        XCTAssertNil(
            database.matchSpeaker(embedding: wrongVoice, threshold: 0.6),
            "rejected voice must no longer match via a lingering exemplar"
        )

        // A later merge + unmerge must never re-fold the rejected session's embedding.
        let other = database.addOrUpdateSpeaker(embedding: axisEmbedding(2), existingId: nil)
        try database.mergeProfiles(sourceId: other.id, into: profile.id)
        XCTAssertTrue(database.unmergeMostRecent(forTargetId: profile.id))
        let afterUnmerge = try XCTUnwrap(database.getSpeaker(id: profile.id))
        XCTAssertEqual(afterUnmerge.callCount, 1)
        XCTAssertLessThan(SpeakerVectorMath.cosineSimilarity(afterUnmerge.embedding, wrongVoice), 0.1)
    }

    func testRevertMatchContributionWithLaterMeetingRemovesOnlyRejectedContribution() throws {
        let baseVoice = axisEmbedding(10)
        let wrongVoice = axisEmbedding(11)
        let validVoice = axisEmbedding(12)

        let profile = database.addOrUpdateSpeaker(embedding: baseVoice, existingId: nil)
        let snapshot = try XCTUnwrap(database.getSpeaker(id: profile.id))

        // Meeting 1 wrongly matches profile; Meeting 2 legitimately matches before review finishes.
        _ = database.addOrUpdateSpeaker(embedding: wrongVoice, existingId: profile.id)
        _ = database.addOrUpdateSpeaker(embedding: validVoice, existingId: profile.id)
        XCTAssertEqual(database.contributions(forProfileId: profile.id).count, 3)

        database.revertMatchContribution(snapshot: snapshot, rejectedEmbedding: wrongVoice)

        let after = try XCTUnwrap(database.getSpeaker(id: profile.id))
        XCTAssertEqual(after.callCount, 2, "Meeting 2's call count survives")
        XCTAssertEqual(after.exemplars.count, 1, "only Meeting 1's rejected exemplar is removed; Meeting 2's distinct exemplar survives")
        XCTAssertGreaterThan(SpeakerVectorMath.cosineSimilarity(after.exemplars[0], validVoice), 0.99)
        XCTAssertNil(
            database.matchSpeaker(embedding: wrongVoice, threshold: 0.6),
            "Meeting 1's rejected voice must no longer match via a lingering exemplar"
        )
        XCTAssertEqual(
            database.matchSpeaker(embedding: validVoice, threshold: 0.6)?.profile.id,
            profile.id,
            "Meeting 2's valid distinct exemplar must continue to match"
        )
        XCTAssertEqual(database.contributions(forProfileId: profile.id).count, 2, "only Meeting 1's provenance row is deleted")

        // Confirm Meeting 1's exact embedding blob is gone while Meeting 2's remains.
        let wrongData = wrongVoice.withUnsafeBufferPointer { Data(buffer: $0) }
        let validData = validVoice.withUnsafeBufferPointer { Data(buffer: $0) }
        let remainingEmbeddings: [Data] = database.queue.sync {
            var blobs: [Data] = []
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(database.db, "SELECT embedding FROM speaker_provenance WHERE profile_id = ?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (profile.id.uuidString as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                while sqlite3_step(stmt) == SQLITE_ROW {
                    if let ptr = sqlite3_column_blob(stmt, 0) {
                        let size = Int(sqlite3_column_bytes(stmt, 0))
                        blobs.append(Data(bytes: ptr, count: size))
                    }
                }
            }
            sqlite3_finalize(stmt)
            return blobs
        }
        XCTAssertFalse(remainingEmbeddings.contains(wrongData))
        XCTAssertTrue(remainingEmbeddings.contains(validData))
    }

    func testRestoreProfileRestoresPreMeetingExemplarsAndDropsRolledBackContributions() throws {
        let baseVoice = axisEmbedding(20)
        let condition2 = axisEmbedding(21)
        let rejectedVoice = axisEmbedding(22)

        let profile = database.addOrUpdateSpeaker(embedding: baseVoice, existingId: nil)
        _ = database.addOrUpdateSpeaker(embedding: condition2, existingId: profile.id)
        let snapshot = try XCTUnwrap(database.getSpeaker(id: profile.id))
        XCTAssertEqual(snapshot.exemplars.count, 1)
        XCTAssertEqual(database.contributions(forProfileId: profile.id).count, 2)

        _ = database.addOrUpdateSpeaker(embedding: rejectedVoice, existingId: profile.id)
        XCTAssertEqual(try XCTUnwrap(database.getSpeaker(id: profile.id)).exemplars.count, 2)
        XCTAssertEqual(database.contributions(forProfileId: profile.id).count, 3)

        database.restoreProfile(snapshot)

        let restored = try XCTUnwrap(database.getSpeaker(id: profile.id))
        XCTAssertEqual(restored.callCount, snapshot.callCount)
        XCTAssertEqual(restored.exemplars, snapshot.exemplars, "pre-meeting exemplars must be restored exactly")
        XCTAssertEqual(database.contributions(forProfileId: profile.id).count, 2, "the rolled-back contribution row must be removed")
    }

    func testRevertOverlappingMeetingPreservesLaterExemplarSegmentCountAndProtectsProvenanceOnNilEmbedding() throws {
        let baseVoice = axisEmbedding(50)
        let wrongVoice = axisEmbedding(51)
        let validVoice = axisEmbedding(52)

        let profile = database.addOrUpdateSpeaker(embedding: baseVoice, existingId: nil)
        let snapshot = try XCTUnwrap(database.getSpeaker(id: profile.id))

        // Meeting 1 wrongly matches; Meeting 2 and Meeting 3 legitimately match a distinct condition
        // (raising validVoice's exemplar segment_count to 2).
        _ = database.addOrUpdateSpeaker(embedding: wrongVoice, existingId: profile.id)
        _ = database.addOrUpdateSpeaker(embedding: validVoice, existingId: profile.id)
        _ = database.addOrUpdateSpeaker(embedding: validVoice, existingId: profile.id)
        XCTAssertEqual(database.contributions(forProfileId: profile.id).count, 4)

        database.revertMatchContribution(snapshot: snapshot, rejectedEmbedding: wrongVoice)

        let afterTargetedRevert = try XCTUnwrap(database.getSpeaker(id: profile.id))
        XCTAssertEqual(afterTargetedRevert.callCount, 3)
        XCTAssertEqual(afterTargetedRevert.exemplars.count, 1, "later meeting's distinct exemplar must survive")
        XCTAssertGreaterThan(SpeakerVectorMath.cosineSimilarity(afterTargetedRevert.exemplars[0], validVoice), 0.99)
        let survivingSegmentCount: Int = database.queue.sync {
            var stmt: OpaquePointer?
            var count = 0
            if sqlite3_prepare_v2(database.db, "SELECT segment_count FROM speaker_exemplars WHERE profile_id = ?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (profile.id.uuidString as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
            }
            sqlite3_finalize(stmt)
            return count
        }
        XCTAssertEqual(survivingSegmentCount, 2, "surviving exemplar must keep its real segment_count")
        XCTAssertEqual(database.contributions(forProfileId: profile.id).count, 3)

        // When rejectedEmbedding is nil in an overlapping-meeting revert, wipe exemplars defensively
        // but NEVER fall back to deleting the newer valid meeting's provenance row.
        database.revertMatchContribution(snapshot: snapshot, rejectedEmbedding: nil)
        let afterNilRevert = try XCTUnwrap(database.getSpeaker(id: profile.id))
        XCTAssertTrue(afterNilRevert.exemplars.isEmpty, "nil rejectedEmbedding wipes exemplars defensively")
        XCTAssertEqual(
            database.contributions(forProfileId: profile.id).count,
            3,
            "overlapping revert with nil embedding must not delete newer valid meeting's provenance row"
        )
    }

    func testRestoreProfilePreservesExistingExemplarSegmentCount() throws {
        let baseVoice = axisEmbedding(55)
        let condition2 = axisEmbedding(56)
        let rejectedVoice = axisEmbedding(57)

        let profile = database.addOrUpdateSpeaker(embedding: baseVoice, existingId: nil)
        _ = database.addOrUpdateSpeaker(embedding: condition2, existingId: profile.id)
        _ = database.addOrUpdateSpeaker(embedding: condition2, existingId: profile.id)
        let snapshot = try XCTUnwrap(database.getSpeaker(id: profile.id))
        XCTAssertEqual(snapshot.exemplars.count, 1)

        _ = database.addOrUpdateSpeaker(embedding: rejectedVoice, existingId: profile.id)
        database.restoreProfile(snapshot)

        let restoredSegmentCount: Int = database.queue.sync {
            var stmt: OpaquePointer?
            var count = 0
            if sqlite3_prepare_v2(database.db, "SELECT segment_count FROM speaker_exemplars WHERE profile_id = ?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (profile.id.uuidString as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                if sqlite3_step(stmt) == SQLITE_ROW {
                    count = Int(sqlite3_column_int(stmt, 0))
                }
            }
            sqlite3_finalize(stmt)
            return count
        }
        XCTAssertEqual(restoredSegmentCount, 2, "replaceExemplarsImpl must preserve existing segment_count for restored exemplars")
    }

    // MARK: - Delete & prune provenance / merge-event privacy cleanup

    func testDeleteSpeakerErasesProvenanceMergeHistoryAndBlocksResurrection() throws {
        let a = database.addOrUpdateSpeaker(embedding: axisEmbedding(30), existingId: nil)
        let b = database.addOrUpdateSpeaker(embedding: axisEmbedding(31), existingId: nil)
        let c = database.addOrUpdateSpeaker(embedding: axisEmbedding(32), existingId: nil)
        let survivor = database.addOrUpdateSpeaker(embedding: axisEmbedding(33), existingId: nil)
        let survivorSource = database.addOrUpdateSpeaker(embedding: axisEmbedding(34), existingId: nil)

        database.setDisplayName(id: a.id, name: "Private Alpha", source: NameSource.userManual)
        database.setDisplayName(id: b.id, name: "Private Beta", source: NameSource.userManual)
        database.setDisplayName(id: c.id, name: "Private Gamma", source: NameSource.userManual)
        database.setDisplayName(id: survivor.id, name: "Kept Person", source: NameSource.userManual)
        database.setDisplayName(id: survivorSource.id, name: "Kept Source", source: NameSource.userManual)

        // Transitive merge chain: a -> b -> c, plus an unrelated merge into survivor.
        try database.recordUserConfirmations([
            SpeakerUserConfirmation(profileId: a.id, transcriptId: UUID(), kind: .named),
            SpeakerUserConfirmation(profileId: survivorSource.id, transcriptId: UUID(), kind: .named),
        ])
        try database.mergeProfiles(sourceId: a.id, into: b.id)
        try database.mergeProfiles(sourceId: b.id, into: c.id)
        let cMergeRecord = try XCTUnwrap(database.undoableMerge(forTargetId: c.id))
        try database.mergeProfiles(sourceId: survivorSource.id, into: survivor.id)

        // Explicitly delete c: c, b, and a must vanish from every history table.
        database.deleteSpeaker(id: c.id)

        for deletedId in [a.id, b.id, c.id] {
            XCTAssertNil(database.getSpeaker(id: deletedId))
            XCTAssertEqual(
                try rowCount(
                    sql: "SELECT COUNT(*) FROM speaker_provenance WHERE profile_id = ? OR source_profile_id = ?;",
                    bindings: [deletedId.uuidString, deletedId.uuidString]
                ),
                0,
                "speaker_provenance must have no rows for deleted profile or its absorbed aliases"
            )
            XCTAssertEqual(
                try rowCount(
                    sql: """
                    SELECT COUNT(*) FROM speaker_merge_events
                    WHERE (target_id = ? OR source_id = ?)
                      AND (source_snapshot != '' OR target_snapshot != '' OR moved_provenance_ids != '[]' OR undone_at IS NULL);
                    """,
                    bindings: [deletedId.uuidString, deletedId.uuidString]
                ),
                0,
                "speaker_merge_events must scrub snapshots (names + embeddings) and mark rows non-undoable"
            )
            XCTAssertEqual(
                try rowCount(
                    sql: "SELECT COUNT(*) FROM speaker_confirmation_moves WHERE source_profile_id = ? OR target_profile_id = ?;",
                    bindings: [deletedId.uuidString, deletedId.uuidString]
                ),
                0
            )
        }
        for privateName in ["Private Alpha", "Private Beta", "Private Gamma"] {
            XCTAssertEqual(
                try rowCount(
                    sql: "SELECT COUNT(*) FROM speaker_merge_events WHERE source_snapshot LIKE ? OR target_snapshot LIKE ?;",
                    bindings: ["%\(privateName)%", "%\(privateName)%"]
                ),
                0,
                "deleted speaker display name must not remain in speaker_merge_events"
            )
        }

        // Unmerge cannot resurrect the deleted target.
        XCTAssertFalse(database.unmerge(mergeId: cMergeRecord.id))
        XCTAssertNil(database.getSpeaker(id: c.id))
        XCTAssertNil(database.getSpeaker(id: b.id))

        // Surviving unrelated merge -> unmerge still works 100%.
        XCTAssertTrue(database.unmergeMostRecent(forTargetId: survivor.id))
        XCTAssertEqual(database.getSpeaker(id: survivor.id)?.displayName, "Kept Person")
        XCTAssertEqual(database.getSpeaker(id: survivorSource.id)?.displayName, "Kept Source")
    }

    func testDeleteAlreadyMergedSpeakerIdPreservesKeeperUndoMergeHistory() throws {
        let absorbed = database.addOrUpdateSpeaker(embedding: axisEmbedding(60), existingId: nil)
        let keeper = database.addOrUpdateSpeaker(embedding: axisEmbedding(61), existingId: nil)
        database.setDisplayName(id: absorbed.id, name: "Absorbed Speaker", source: NameSource.userManual)
        database.setDisplayName(id: keeper.id, name: "Surviving Keeper", source: NameSource.userManual)

        try database.mergeProfiles(sourceId: absorbed.id, into: keeper.id)
        XCTAssertNil(database.getSpeaker(id: absorbed.id))

        // Deleting an already-merged-away ID must be a safe no-op and never scrub the keeper's undo history.
        database.deleteSpeaker(id: absorbed.id)

        XCTAssertNotNil(database.undoableMerge(forTargetId: keeper.id), "keeper's live merge event must remain undoable")
        XCTAssertTrue(database.unmergeMostRecent(forTargetId: keeper.id), "unmerge must still succeed after no-op delete on absorbed ID")
        XCTAssertEqual(database.getSpeaker(id: keeper.id)?.displayName, "Surviving Keeper")
        XCTAssertEqual(database.getSpeaker(id: absorbed.id)?.displayName, "Absorbed Speaker")
    }

    func testDeleteSpeakerScrubsMergeEventsInPlacePreservingMonotonicRowid() throws {
        let x = database.addOrUpdateSpeaker(embedding: axisEmbedding(65), existingId: nil)
        let y = database.addOrUpdateSpeaker(embedding: axisEmbedding(66), existingId: nil)
        let p = database.addOrUpdateSpeaker(embedding: axisEmbedding(67), existingId: nil)
        let q = database.addOrUpdateSpeaker(embedding: axisEmbedding(68), existingId: nil)
        let z = database.addOrUpdateSpeaker(embedding: axisEmbedding(69), existingId: nil)
        database.setDisplayName(id: x.id, name: "Deleted X", source: NameSource.userManual)
        database.setDisplayName(id: y.id, name: "Deleted Y", source: NameSource.userManual)
        database.setDisplayName(id: p.id, name: "Person P", source: NameSource.userManual)
        database.setDisplayName(id: q.id, name: "Person Q", source: NameSource.userManual)
        database.setDisplayName(id: z.id, name: "Person Z", source: NameSource.userManual)

        // Add a second contribution to q so q keeps a contribution after reassigning one to z.
        _ = database.addOrUpdateSpeaker(embedding: axisEmbedding(70), existingId: q.id)

        try database.mergeProfiles(sourceId: x.id, into: y.id)
        let xyMerge = try XCTUnwrap(database.undoableMerge(forTargetId: y.id))
        let maxRowidBeforeDelete = try rowCount(sql: "SELECT COALESCE(MAX(rowid), 0) FROM speaker_merge_events;")
        XCTAssertGreaterThan(maxRowidBeforeDelete, 0)

        // Reassign one of q's contributions to z while xyMerge is the latest merge event.
        // This records merge_events_high = maxRowidBeforeDelete in speaker_contribution_reassignments.
        let qContribution = try XCTUnwrap(database.contributions(forProfileId: q.id).first)
        XCTAssertTrue(database.reassignContribution(id: qContribution.id, toProfileId: z.id))

        // Delete y: must scrub xyMerge in place so MAX(rowid) never shrinks.
        database.deleteSpeaker(id: y.id)

        XCTAssertEqual(
            try rowCount(sql: "SELECT COALESCE(MAX(rowid), 0) FROM speaker_merge_events;"),
            maxRowidBeforeDelete,
            "scrubbing speaker_merge_events in place must never shrink MAX(rowid)"
        )
        XCTAssertEqual(
            try rowCount(
                sql: "SELECT COUNT(*) FROM speaker_merge_events WHERE id = ? AND source_snapshot = '' AND target_snapshot = '' AND moved_provenance_ids = '[]' AND undone_at IS NOT NULL;",
                bindings: [xyMerge.id.uuidString]
            ),
            1,
            "scrubbed merge event must hold zero snapshots/embeddings/names and non-null undone_at"
        )
        XCTAssertFalse(database.unmerge(mergeId: xyMerge.id), "unmerge on a scrubbed event must fail cleanly")
        XCTAssertNil(database.undoableMerge(forTargetId: y.id))
        XCTAssertFalse(database.recentUndoableMerges().contains { $0.id == xyMerge.id })

        // Next merge p -> q must receive a strictly higher rowid than maxRowidBeforeDelete so
        // q's pre-merge reassignment (merge_events_high == maxRowidBeforeDelete) is never
        // misclassified as post-merge and double-subtracted when p -> q is unmerged.
        let pBeforeMerge = try XCTUnwrap(database.getSpeaker(id: p.id))
        let qBeforeMerge = try XCTUnwrap(database.getSpeaker(id: q.id))
        try database.mergeProfiles(sourceId: p.id, into: q.id)
        let maxRowidAfterNextMerge = try rowCount(sql: "SELECT COALESCE(MAX(rowid), 0) FROM speaker_merge_events;")
        XCTAssertGreaterThan(maxRowidAfterNextMerge, maxRowidBeforeDelete)

        XCTAssertTrue(database.unmergeMostRecent(forTargetId: q.id))
        let pAfterUnmerge = try XCTUnwrap(database.getSpeaker(id: p.id))
        let qAfterUnmerge = try XCTUnwrap(database.getSpeaker(id: q.id))
        XCTAssertEqual(pAfterUnmerge.callCount, pBeforeMerge.callCount)
        XCTAssertEqual(qAfterUnmerge.callCount, qBeforeMerge.callCount)
        XCTAssertEqual(qAfterUnmerge.embedding, qBeforeMerge.embedding)
    }

    func testUnmergeRefusesWhenTargetWasMergedAway() throws {
        let a = database.addOrUpdateSpeaker(embedding: axisEmbedding(75), existingId: nil)
        let b = database.addOrUpdateSpeaker(embedding: axisEmbedding(76), existingId: nil)
        let c = database.addOrUpdateSpeaker(embedding: axisEmbedding(77), existingId: nil)
        database.setDisplayName(id: a.id, name: "Alpha", source: NameSource.userManual)
        database.setDisplayName(id: b.id, name: "Beta", source: NameSource.userManual)
        database.setDisplayName(id: c.id, name: "Gamma", source: NameSource.userManual)

        // Merge A -> B, then merge B -> C so B no longer exists in `speakers` while A -> B's
        // merge event row is still present and un-scrubbed (undone_at IS NULL).
        try database.mergeProfiles(sourceId: a.id, into: b.id)
        let abMerge = try XCTUnwrap(database.undoableMerge(forTargetId: b.id))
        try database.mergeProfiles(sourceId: b.id, into: c.id)

        XCTAssertNil(database.getSpeaker(id: b.id))
        XCTAssertFalse(
            database.unmerge(mergeId: abMerge.id),
            "unmerge must refuse when the target profile no longer exists"
        )
        XCTAssertNil(database.getSpeaker(id: b.id), "unmerge must not resurrect B")
        XCTAssertNil(database.getSpeaker(id: a.id), "unmerge must not resurrect A")
        XCTAssertNotNil(database.getSpeaker(id: c.id), "C must remain intact")
    }

    func testPruneWeakProfilesErasesProvenanceRowsForPrunedSpeakersOnly() throws {
        let stale = database.addOrUpdateSpeaker(embedding: axisEmbedding(40), existingId: nil)
        let fresh = database.addOrUpdateSpeaker(embedding: axisEmbedding(41), existingId: nil)

        database.restoreProfile(SpeakerProfile(
            id: stale.id,
            displayName: nil,
            nameSource: nil,
            embedding: stale.embedding,
            firstSeen: Date().addingTimeInterval(-7200),
            lastSeen: Date().addingTimeInterval(-7200),
            callCount: 1,
            confidence: 0.5,
            disputeCount: 0
        ))
        XCTAssertEqual(database.contributions(forProfileId: stale.id).count, 1)
        XCTAssertEqual(database.contributions(forProfileId: fresh.id).count, 1)

        database.pruneWeakProfiles()

        XCTAssertNil(database.getSpeaker(id: stale.id))
        XCTAssertTrue(database.contributions(forProfileId: stale.id).isEmpty, "pruned profile provenance must be deleted")
        XCTAssertNotNil(database.getSpeaker(id: fresh.id))
        XCTAssertEqual(database.contributions(forProfileId: fresh.id).count, 1, "surviving profile provenance must remain intact")
    }

    func testDeletingResurrectedAbsorbedSourceIdPreservesKeeperUndoMergeHistory() throws {
        let source = database.addOrUpdateSpeaker(embedding: axisEmbedding(80), existingId: nil)
        let keeper = database.addOrUpdateSpeaker(embedding: axisEmbedding(81), existingId: nil)
        database.setDisplayName(id: keeper.id, name: "Keeper", source: NameSource.userManual)

        try database.mergeProfiles(sourceId: source.id, into: keeper.id)
        let liveMerge = try XCTUnwrap(database.undoableMerge(forTargetId: keeper.id))

        // Simulate a stale pipeline re-inserting the absorbed source UUID before pruning/deleting it.
        _ = database.addOrUpdateSpeaker(embedding: axisEmbedding(80), existingId: source.id)
        XCTAssertNotNil(database.getSpeaker(id: source.id))

        database.deleteSpeaker(id: source.id)

        XCTAssertNil(database.getSpeaker(id: source.id))
        XCTAssertEqual(
            database.undoableMerge(forTargetId: keeper.id)?.id,
            liveMerge.id,
            "deleting a resurrected absorbed source ID must never scrub the surviving keeper's live merge event"
        )
        XCTAssertTrue(
            database.unmerge(mergeId: liveMerge.id),
            "keeper's live merge event and merge marker must stay undoable"
        )
        XCTAssertNotNil(database.getSpeaker(id: source.id))
    }
}
