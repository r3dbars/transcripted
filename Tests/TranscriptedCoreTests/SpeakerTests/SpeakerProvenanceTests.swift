import XCTest
import SQLite3
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class SpeakerProvenanceTests: XCTestCase {

    private var tempDirectory: URL!
    private var database: SpeakerDatabase!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerProvenanceTests-\(UUID().uuidString)")
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

    /// One-hot-ish 256-dim embedding so two speakers point in orthogonal directions.
    private func embedding(axis: Int) -> [Float] {
        var vector = [Float](repeating: 0.01, count: 256)
        vector[axis] = 1.0
        return vector
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var dot: Double = 0, na: Double = 0, nb: Double = 0
        for i in 0..<min(a.count, b.count) {
            dot += Double(a[i]) * Double(b[i])
            na += Double(a[i]) * Double(a[i])
            nb += Double(b[i]) * Double(b[i])
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    // MARK: - Core safety net

    func testUnmergeRestoresTwoDistinctProfiles() throws {
        let source = database.addOrUpdateSpeaker(embedding: embedding(axis: 0), existingId: nil)
        let target = database.addOrUpdateSpeaker(embedding: embedding(axis: 1), existingId: nil)
        database.setDisplayName(id: source.id, name: "Alice", source: NameSource.userManual)
        database.setDisplayName(id: target.id, name: "Bob", source: NameSource.userManual)

        let preSource = try XCTUnwrap(database.getSpeaker(id: source.id)).embedding
        let preTarget = try XCTUnwrap(database.getSpeaker(id: target.id)).embedding
        // Profiles are genuinely distinct going in.
        XCTAssertLessThan(cosine(preSource, preTarget), 0.5)

        try database.mergeProfiles(sourceId: source.id, into: target.id)

        // Merge fused them: source is gone, only the keeper remains.
        XCTAssertNil(database.getSpeaker(id: source.id))
        XCTAssertNotNil(database.getSpeaker(id: target.id))

        let undone = database.unmergeMostRecent(forTargetId: target.id)
        XCTAssertTrue(undone, "un-merge should reverse the most recent merge")

        // Both profiles exist again as two distinct people.
        let restoredSource = try XCTUnwrap(database.getSpeaker(id: source.id), "absorbed profile must be reconstructed")
        let restoredTarget = try XCTUnwrap(database.getSpeaker(id: target.id))

        XCTAssertEqual(restoredSource.displayName, "Alice")
        XCTAssertEqual(restoredTarget.displayName, "Bob")

        // Embeddings restored to their exact pre-merge state, not the blend.
        XCTAssertGreaterThan(cosine(restoredSource.embedding, preSource), 0.999)
        XCTAssertGreaterThan(cosine(restoredTarget.embedding, preTarget), 0.999)
        XCTAssertLessThan(cosine(restoredSource.embedding, restoredTarget.embedding), 0.5)
    }

    func testAutoDuplicateMergeIsUndoable() throws {
        // Two near-identical voices auto-merge after a recording.
        let a = database.addOrUpdateSpeaker(embedding: [Float](repeating: 0.25, count: 256), existingId: nil)
        let b = database.addOrUpdateSpeaker(embedding: [Float](repeating: 0.25, count: 256), existingId: nil)

        database.mergeDuplicates(threshold: 0.6)

        // Exactly one survived.
        let survivor = database.getSpeaker(id: a.id) != nil ? a.id : b.id
        let absorbed = survivor == a.id ? b.id : a.id
        XCTAssertNil(database.getSpeaker(id: absorbed))

        let record = try XCTUnwrap(database.undoableMerge(forTargetId: survivor))
        XCTAssertEqual(record.kind, SpeakerMergeKind.duplicate)

        XCTAssertTrue(database.unmergeMostRecent(forTargetId: survivor))
        XCTAssertNotNil(database.getSpeaker(id: absorbed), "auto-merge must be reversible")
        XCTAssertNotNil(database.getSpeaker(id: survivor))
    }

    func testContributionsRecordedPerProfile() throws {
        let id = UUID()
        _ = database.addOrUpdateSpeaker(embedding: embedding(axis: 3), existingId: id)
        _ = database.addOrUpdateSpeaker(embedding: embedding(axis: 3), existingId: id)
        _ = database.addOrUpdateSpeaker(embedding: embedding(axis: 3), existingId: id)

        let contributions = database.contributions(forProfileId: id)
        XCTAssertGreaterThanOrEqual(contributions.count, 3, "each recording should leave a provenance row")
        XCTAssertTrue(contributions.allSatisfy { $0.hasEmbedding })
        XCTAssertEqual(contributions.filter { $0.kind == SpeakerProvenanceKind.seed }.count, 1)
    }

    func testMergeLeavesFuseMarkerThenUndoRemovesIt() throws {
        let source = database.addOrUpdateSpeaker(embedding: embedding(axis: 5), existingId: nil)
        let target = database.addOrUpdateSpeaker(embedding: embedding(axis: 6), existingId: nil)

        try database.mergeProfiles(sourceId: source.id, into: target.id)

        let afterMerge = database.contributions(forProfileId: target.id)
        XCTAssertTrue(
            afterMerge.contains { $0.kind == SpeakerProvenanceKind.merge && $0.sourceProfileId == source.id },
            "merge should leave a fuse marker on the keeper's audit trail"
        )

        XCTAssertTrue(database.unmergeMostRecent(forTargetId: target.id))
        let afterUndo = database.contributions(forProfileId: target.id)
        XCTAssertFalse(
            afterUndo.contains { $0.kind == SpeakerProvenanceKind.merge },
            "un-merge should drop the fuse marker"
        )
    }

    func testUnmergeRefusedWhenNewerMergeTargetsSameKeeper() throws {
        let first = database.addOrUpdateSpeaker(embedding: embedding(axis: 10), existingId: nil)
        let second = database.addOrUpdateSpeaker(embedding: embedding(axis: 11), existingId: nil)
        let keeper = database.addOrUpdateSpeaker(embedding: embedding(axis: 12), existingId: nil)

        try database.mergeProfiles(sourceId: first.id, into: keeper.id)
        let firstEvent = try XCTUnwrap(database.undoableMerge(forTargetId: keeper.id))
        try database.mergeProfiles(sourceId: second.id, into: keeper.id)

        // The older merge can't be undone while a newer merge still sits on top.
        XCTAssertFalse(database.unmerge(mergeId: firstEvent.id))
        XCTAssertNil(database.getSpeaker(id: first.id))

        // Undo proceeds newest-first.
        XCTAssertTrue(database.unmergeMostRecent(forTargetId: keeper.id))
        XCTAssertNotNil(database.getSpeaker(id: second.id))
        // Now the older one is undoable.
        XCTAssertTrue(database.unmerge(mergeId: firstEvent.id))
        XCTAssertNotNil(database.getSpeaker(id: first.id))
    }

    func testReassignContributionMovesAuditRow() throws {
        let a = database.addOrUpdateSpeaker(embedding: embedding(axis: 20), existingId: nil)
        let b = database.addOrUpdateSpeaker(embedding: embedding(axis: 21), existingId: nil)

        let contribution = try XCTUnwrap(database.contributions(forProfileId: a.id).first)
        XCTAssertTrue(database.reassignContribution(id: contribution.id, toProfileId: b.id))

        XCTAssertFalse(database.contributions(forProfileId: a.id).contains { $0.id == contribution.id })
        XCTAssertTrue(database.contributions(forProfileId: b.id).contains { $0.id == contribution.id })
    }

    func testUnmergePreservesPostMergeTargetLearning() throws {
        let source = database.addOrUpdateSpeaker(embedding: embedding(axis: 30), existingId: nil)
        let target = database.addOrUpdateSpeaker(embedding: embedding(axis: 31), existingId: nil)

        try database.mergeProfiles(sourceId: source.id, into: target.id)

        // The keeper picks up another recording AFTER the merge.
        _ = database.addOrUpdateSpeaker(embedding: embedding(axis: 31), existingId: target.id)

        XCTAssertTrue(database.unmergeMostRecent(forTargetId: target.id))

        // Un-merge must not roll the keeper back to its single pre-merge recording —
        // its own seed + the post-merge recording should both still count.
        let restoredTarget = try XCTUnwrap(database.getSpeaker(id: target.id))
        XCTAssertEqual(restoredTarget.callCount, 2, "post-merge learning must survive un-merge")
        // The absorbed profile is back as its own distinct person.
        XCTAssertNotNil(database.getSpeaker(id: source.id))
    }

    /// Builds a profile with `legacyRecordings` recordings that predate provenance (their
    /// audit rows are dropped, like a profile created before provenance shipped), then one
    /// post-provenance recording with `laterAxis` that leaves a single contribution row.
    private func makePartlyLegacyProfile(axis: Int, legacyRecordings: Int, laterAxis: Int) throws -> UUID {
        let id = UUID()
        for _ in 0..<legacyRecordings {
            _ = database.addOrUpdateSpeaker(embedding: embedding(axis: axis), existingId: id)
        }
        let dropResult = database.queue.sync {
            sqlite3_exec(database.db, "DELETE FROM speaker_provenance WHERE profile_id = '\(id.uuidString)';", nil, nil, nil)
        }
        XCTAssertEqual(dropResult, SQLITE_OK)
        _ = database.addOrUpdateSpeaker(embedding: embedding(axis: laterAxis), existingId: id)
        XCTAssertEqual(database.contributions(forProfileId: id).count, 1)
        return id
    }

    func testUnmergeRestoresPreMergeVoiceprintForPartlyLegacySource() throws {
        let sourceId = try makePartlyLegacyProfile(axis: 50, legacyRecordings: 20, laterAxis: 51)
        let target = database.addOrUpdateSpeaker(embedding: embedding(axis: 52), existingId: nil)
        let preSource = try XCTUnwrap(database.getSpeaker(id: sourceId))
        XCTAssertEqual(preSource.callCount, 21)

        try database.mergeProfiles(sourceId: sourceId, into: target.id)
        XCTAssertTrue(database.unmergeMostRecent(forTargetId: target.id))

        let restored = try XCTUnwrap(database.getSpeaker(id: sourceId))
        XCTAssertEqual(restored.callCount, 21, "un-merge must keep the 20 recordings that have no audit rows")
        XCTAssertGreaterThan(
            cosine(restored.embedding, preSource.embedding), 0.999,
            "un-merge must restore the pre-merge voiceprint, not the mean of one contribution row"
        )
    }

    func testUnmergeKeepsPartlyLegacyTargetHistoryAndAddsPostMergeLearning() throws {
        let targetId = try makePartlyLegacyProfile(axis: 60, legacyRecordings: 20, laterAxis: 61)
        let source = database.addOrUpdateSpeaker(embedding: embedding(axis: 62), existingId: nil)
        let preTarget = try XCTUnwrap(database.getSpeaker(id: targetId))

        try database.mergeProfiles(sourceId: source.id, into: targetId)
        _ = database.addOrUpdateSpeaker(embedding: embedding(axis: 60), existingId: targetId)
        XCTAssertTrue(database.unmergeMostRecent(forTargetId: targetId))

        let restored = try XCTUnwrap(database.getSpeaker(id: targetId))
        XCTAssertEqual(restored.callCount, preTarget.callCount + 1, "pre-merge history plus the one post-merge recording")
        XCTAssertGreaterThan(
            cosine(restored.embedding, preTarget.embedding), 0.99,
            "a partial row set must not replace the keeper's voiceprint"
        )
        XCTAssertLessThan(cosine(restored.embedding, embedding(axis: 62)), 0.5, "the absorbed voice is gone again")
    }

    func testUnmergeWeighsPostMergeRowsAgainstTheKeepersFullHistory() throws {
        let targetId = try makePartlyLegacyProfile(axis: 70, legacyRecordings: 20, laterAxis: 70)
        let source = database.addOrUpdateSpeaker(embedding: embedding(axis: 72), existingId: nil)
        let preTarget = try XCTUnwrap(database.getSpeaker(id: targetId))
        XCTAssertEqual(preTarget.callCount, 21)

        try database.mergeProfiles(sourceId: source.id, into: targetId)
        // Three post-merge recordings of a different voice land on the keeper.
        for _ in 0..<3 {
            _ = database.addOrUpdateSpeaker(embedding: embedding(axis: 71), existingId: targetId)
        }
        XCTAssertTrue(database.unmergeMostRecent(forTargetId: targetId))

        let restored = try XCTUnwrap(database.getSpeaker(id: targetId))
        XCTAssertEqual(restored.callCount, 24, "21 pre-merge recordings plus the 3 after it")
        XCTAssertGreaterThan(
            cosine(restored.embedding, preTarget.embedding), 0.95,
            "3 new rows must not outweigh 21 recordings of history"
        )
    }

    // MARK: - Post-merge reassignments (#2152)

    /// The contribution row on `profileId` whose stored embedding points along `axis`.
    private func contributionId(profileId: UUID, axis: Int) -> UUID? {
        database.queue.sync {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = "SELECT id, embedding FROM speaker_provenance WHERE profile_id = ? AND embedding IS NOT NULL;"
            guard sqlite3_prepare_v2(database.db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(statement, 1, (profileId.uuidString as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let ptr = sqlite3_column_blob(statement, 1) else { continue }
                let count = Int(sqlite3_column_bytes(statement, 1)) / MemoryLayout<Float>.size
                let vector = Array(UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: Float.self), count: count))
                if cosine(vector, embedding(axis: axis)) > 0.99,
                   let text = sqlite3_column_text(statement, 0) {
                    return UUID(uuidString: String(cString: text))
                }
            }
            return nil
        }
    }

    func testUnmergeKeepsPreMergeRowReassignedIntoKeeperAfterMerge() throws {
        let source = database.addOrUpdateSpeaker(embedding: embedding(axis: 80), existingId: nil)
        let target = database.addOrUpdateSpeaker(embedding: embedding(axis: 81), existingId: nil)
        let other = database.addOrUpdateSpeaker(embedding: embedding(axis: 82), existingId: nil)
        let otherRow = try XCTUnwrap(database.contributions(forProfileId: other.id).first)

        try database.mergeProfiles(sourceId: source.id, into: target.id)
        // After the merge the user says this older recording was really the keeper.
        XCTAssertTrue(database.reassignContribution(id: otherRow.id, toProfileId: target.id))
        XCTAssertTrue(database.unmergeMostRecent(forTargetId: target.id))

        let restored = try XCTUnwrap(database.getSpeaker(id: target.id))
        XCTAssertEqual(restored.callCount, 2, "the keeper's own recording plus the one moved onto it after the merge")
        XCTAssertGreaterThan(cosine(restored.embedding, embedding(axis: 82)), 0.5,
                             "the recording reassigned onto the keeper must still be in its voiceprint")
        XCTAssertTrue(database.contributions(forProfileId: target.id).contains { $0.id == otherRow.id })
    }

    func testUnmergeDropsPreMergeKeeperRowReassignedAwayAfterMerge() throws {
        let targetId = UUID()
        _ = database.addOrUpdateSpeaker(embedding: embedding(axis: 83), existingId: targetId)
        _ = database.addOrUpdateSpeaker(embedding: embedding(axis: 84), existingId: targetId)
        let wrongRow = try XCTUnwrap(contributionId(profileId: targetId, axis: 84))
        let source = database.addOrUpdateSpeaker(embedding: embedding(axis: 85), existingId: nil)
        let other = database.addOrUpdateSpeaker(embedding: embedding(axis: 86), existingId: nil)

        try database.mergeProfiles(sourceId: source.id, into: targetId)
        // After the merge the user moves one of the keeper's older recordings away.
        XCTAssertTrue(database.reassignContribution(id: wrongRow, toProfileId: other.id))
        XCTAssertTrue(database.unmergeMostRecent(forTargetId: targetId))

        let restored = try XCTUnwrap(database.getSpeaker(id: targetId))
        XCTAssertEqual(restored.callCount, 1, "the recording moved away after the merge must not come back with the snapshot")
        XCTAssertLessThan(cosine(restored.embedding, embedding(axis: 84)), 0.5,
                          "the moved-away voice must not be restored into the keeper's voiceprint")
        XCTAssertTrue(database.contributions(forProfileId: other.id).contains { $0.id == wrongRow })
    }

    func testUnmergeLeavesAbsorbedRowWhereTheUserReassignedIt() throws {
        let source = database.addOrUpdateSpeaker(embedding: embedding(axis: 87), existingId: nil)
        _ = database.addOrUpdateSpeaker(embedding: embedding(axis: 88), existingId: source.id)
        let movedRow = try XCTUnwrap(contributionId(profileId: source.id, axis: 88))
        let target = database.addOrUpdateSpeaker(embedding: embedding(axis: 89), existingId: nil)
        let other = database.addOrUpdateSpeaker(embedding: embedding(axis: 90), existingId: nil)

        try database.mergeProfiles(sourceId: source.id, into: target.id)
        XCTAssertTrue(database.reassignContribution(id: movedRow, toProfileId: other.id))
        XCTAssertTrue(database.unmergeMostRecent(forTargetId: target.id))

        XCTAssertTrue(database.contributions(forProfileId: other.id).contains { $0.id == movedRow },
                      "un-merge must not pull a reassigned row back onto the absorbed profile")
        let restoredSource = try XCTUnwrap(database.getSpeaker(id: source.id))
        XCTAssertEqual(restoredSource.callCount, 1)
        XCTAssertLessThan(cosine(restoredSource.embedding, embedding(axis: 88)), 0.5)
    }

    func testUnmergeNonexistentEventIsNoop() {
        XCTAssertFalse(database.unmerge(mergeId: UUID()))
        XCTAssertFalse(database.unmergeMostRecent(forTargetId: UUID()))
    }

    func testUnmergeRollsBackEveryWriteWhenFinalEventUpdateFails() throws {
        let source = database.addOrUpdateSpeaker(embedding: embedding(axis: 40), existingId: nil)
        let target = database.addOrUpdateSpeaker(embedding: embedding(axis: 41), existingId: nil)
        try database.mergeProfiles(sourceId: source.id, into: target.id)
        let merge = try XCTUnwrap(database.undoableMerge(forTargetId: target.id))
        let mergedTarget = try XCTUnwrap(database.getSpeaker(id: target.id))

        let triggerResult = database.queue.sync {
            sqlite3_exec(database.db, """
            CREATE TRIGGER reject_unmerge_completion
            BEFORE UPDATE OF undone_at ON speaker_merge_events
            WHEN NEW.undone_at IS NOT NULL
            BEGIN
                SELECT RAISE(ABORT, 'forced unmerge failure');
            END;
            """, nil, nil, nil)
        }
        XCTAssertEqual(triggerResult, SQLITE_OK)

        XCTAssertFalse(database.unmerge(mergeId: merge.id))
        XCTAssertNil(database.getSpeaker(id: source.id), "rolled-back unmerge must not resurrect the source")
        XCTAssertEqual(database.getSpeaker(id: target.id)?.callCount, mergedTarget.callCount)
        XCTAssertEqual(database.undoableMerge(forTargetId: target.id)?.id, merge.id)
        XCTAssertTrue(
            database.contributions(forProfileId: target.id).contains {
                $0.kind == SpeakerProvenanceKind.merge && $0.sourceProfileId == source.id
            },
            "rolled-back unmerge must retain its fuse marker"
        )
    }
}
