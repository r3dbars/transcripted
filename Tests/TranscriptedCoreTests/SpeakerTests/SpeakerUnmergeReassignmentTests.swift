import XCTest
import SQLite3
@testable import TranscriptedCore

/// Un-merge with contributions moved by hand around the merge (#2152 follow-ups).
@available(macOS 14.0, *)
final class SpeakerUnmergeReassignmentTests: XCTestCase {

    private var tempDirectory: URL!
    private var database: SpeakerDatabase!
    private var databasePath: String { tempDirectory.appendingPathComponent("speakers.sqlite").path }

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerUnmergeReassignmentTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        database = SpeakerDatabase(path: databasePath)
    }

    override func tearDownWithError() throws {
        database = nil
        if let tempDirectory { try? FileManager.default.removeItem(at: tempDirectory) }
        tempDirectory = nil
    }

    private func embedding(axis: Int) -> [Float] {
        var vector = [Float](repeating: 0.01, count: 256)
        vector[axis] = 1.0
        return vector
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Double {
        var dot: Double = 0, na: Double = 0, nb: Double = 0
        for i in 0..<min(a.count, b.count) {
            dot += Double(a[i]) * Double(b[i]); na += Double(a[i]) * Double(a[i]); nb += Double(b[i]) * Double(b[i])
        }
        guard na > 0, nb > 0 else { return 0 }
        return dot / (na.squareRoot() * nb.squareRoot())
    }

    private func exec(_ sql: String) -> Int32 {
        database.queue.sync { sqlite3_exec(database.db, sql, nil, nil, nil) }
    }

    /// The contribution row on `profileId` whose stored embedding points along `axis`.
    private func row(_ profileId: UUID, axis: Int) throws -> UUID {
        let found: UUID? = database.queue.sync {
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            let sql = "SELECT id, embedding FROM speaker_provenance WHERE profile_id = ? AND embedding IS NOT NULL;"
            guard sqlite3_prepare_v2(database.db, sql, -1, &statement, nil) == SQLITE_OK else { return nil }
            sqlite3_bind_text(statement, 1, (profileId.uuidString as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let ptr = sqlite3_column_blob(statement, 1) else { continue }
                let count = Int(sqlite3_column_bytes(statement, 1)) / MemoryLayout<Float>.size
                let vector = Array(UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: Float.self), count: count))
                if cosine(vector, embedding(axis: axis)) > 0.99, let text = sqlite3_column_text(statement, 0) {
                    return UUID(uuidString: String(cString: text))
                }
            }
            return nil
        }
        return try XCTUnwrap(found, "no row along axis \(axis)")
    }

    private func profile(axes: [Int]) -> UUID {
        let id = UUID()
        for axis in axes { _ = database.addOrUpdateSpeaker(embedding: embedding(axis: axis), existingId: id) }
        return id
    }

    private func owns(_ profileId: UUID, _ rowId: UUID) -> Bool {
        database.contributions(forProfileId: profileId).contains { $0.id == rowId }
    }

    func testMoveFromAnUndoneMergeIsNotCountedByTheNextMerge() throws {
        let source = profile(axes: [100, 101])
        let target = profile(axes: [102])
        let other = profile(axes: [103])
        let absorbed = try row(source, axis: 101)

        try database.mergeProfiles(sourceId: source, into: target)
        XCTAssertTrue(database.reassignContribution(id: absorbed, toProfileId: other))
        XCTAssertTrue(database.unmergeMostRecent(forTargetId: target))
        XCTAssertEqual(database.getSpeaker(id: source)?.callCount, 1)

        // Merge again with no new recordings: the old move must not be replayed.
        try database.mergeProfiles(sourceId: source, into: target)
        XCTAssertTrue(database.unmergeMostRecent(forTargetId: target))
        let restored = try XCTUnwrap(database.getSpeaker(id: source))
        XCTAssertEqual(restored.callCount, 1, "a move from the first, undone merge was subtracted again")
        XCTAssertGreaterThan(cosine(restored.embedding, embedding(axis: 100)), 0.9)
        XCTAssertTrue(owns(other, absorbed))
    }

    func testKeeperRecordingMovedTwiceAfterMergeLeavesTheKeeper() throws {
        let target = profile(axes: [110, 111])
        let source = profile(axes: [112])
        let first = profile(axes: [113])
        let second = profile(axes: [114])
        let moved = try row(target, axis: 111)

        try database.mergeProfiles(sourceId: source, into: target)
        XCTAssertTrue(database.reassignContribution(id: moved, toProfileId: first))
        XCTAssertTrue(database.reassignContribution(id: moved, toProfileId: second))
        XCTAssertTrue(database.unmergeMostRecent(forTargetId: target))

        let restored = try XCTUnwrap(database.getSpeaker(id: target))
        XCTAssertEqual(restored.callCount, 1)
        XCTAssertLessThan(cosine(restored.embedding, embedding(axis: 111)), 0.5)
        XCTAssertTrue(owns(second, moved))
    }

    func testAbsorbedRecordingMovedAwayAndBackToTheKeeperStaysOnTheKeeper() throws {
        let source = profile(axes: [115, 116])
        let target = profile(axes: [117])
        let other = profile(axes: [118])
        let moved = try row(source, axis: 116)

        try database.mergeProfiles(sourceId: source, into: target)
        XCTAssertTrue(database.reassignContribution(id: moved, toProfileId: other))
        XCTAssertTrue(database.reassignContribution(id: moved, toProfileId: target))
        XCTAssertTrue(database.unmergeMostRecent(forTargetId: target))

        XCTAssertTrue(owns(target, moved), "the user's final choice was the keeper")
        XCTAssertEqual(database.getSpeaker(id: source)?.callCount, 1)
        let keeper = try XCTUnwrap(database.getSpeaker(id: target))
        XCTAssertEqual(keeper.callCount, 2)
        XCTAssertGreaterThan(cosine(keeper.embedding, embedding(axis: 116)), 0.5)
    }

    func testMoveBeforeTheMergeIsIgnoredByUnmerge() throws {
        let target = profile(axes: [120, 121])
        let other = profile(axes: [122])
        let source = profile(axes: [123])
        XCTAssertTrue(database.reassignContribution(id: try row(target, axis: 121), toProfileId: other))
        let beforeMerge = try XCTUnwrap(database.getSpeaker(id: target))
        XCTAssertEqual(beforeMerge.callCount, 1)

        try database.mergeProfiles(sourceId: source, into: target)
        XCTAssertTrue(database.unmergeMostRecent(forTargetId: target))

        let restored = try XCTUnwrap(database.getSpeaker(id: target))
        XCTAssertEqual(restored.callCount, 1, "a move the snapshot already reflects was applied twice")
        XCTAssertGreaterThan(cosine(restored.embedding, beforeMerge.embedding), 0.999)
    }

    func testEveryKeeperRecordingMovedAwayLeavesAnEmptyButValidKeeper() throws {
        let target = profile(axes: [130])
        let source = profile(axes: [131])
        let other = profile(axes: [132])
        let preTarget = try XCTUnwrap(database.getSpeaker(id: target))

        try database.mergeProfiles(sourceId: source, into: target)
        XCTAssertTrue(database.reassignContribution(id: try row(target, axis: 130), toProfileId: other))
        XCTAssertTrue(database.unmergeMostRecent(forTargetId: target))

        let restored = try XCTUnwrap(database.getSpeaker(id: target))
        XCTAssertEqual(restored.callCount, 0)
        XCTAssertTrue(restored.embedding.allSatisfy { $0.isFinite })
        XCTAssertGreaterThan(cosine(restored.embedding, preTarget.embedding), 0.999,
                             "with nothing left, keep the snapshot voice, not rounding residue")
        XCTAssertNotNil(database.getSpeaker(id: source))
    }

    func testFailedReassignmentLogRollsTheMoveBack() throws {
        let a = profile(axes: [140])
        let b = profile(axes: [141])
        let moved = try row(a, axis: 140)
        XCTAssertEqual(exec("""
            CREATE TRIGGER reject_reassignment_log BEFORE INSERT ON speaker_contribution_reassignments
            BEGIN SELECT RAISE(ABORT, 'forced log failure'); END;
            """), SQLITE_OK)

        XCTAssertFalse(database.reassignContribution(id: moved, toProfileId: b))
        XCTAssertTrue(owns(a, moved), "an unlogged move must not go through")
    }

    func testOlderDatabaseWithoutTheLogTableGetsItOnOpen() throws {
        XCTAssertEqual(exec("DROP TABLE IF EXISTS speaker_contribution_reassignments;"), SQLITE_OK)
        database = nil
        database = SpeakerDatabase(path: databasePath)

        let source = profile(axes: [150, 151])
        let target = profile(axes: [152])
        let other = profile(axes: [153])
        let moved = try row(source, axis: 151)
        try database.mergeProfiles(sourceId: source, into: target)
        XCTAssertTrue(database.reassignContribution(id: moved, toProfileId: other))
        XCTAssertTrue(database.unmergeMostRecent(forTargetId: target))

        XCTAssertTrue(owns(other, moved))
        XCTAssertEqual(database.getSpeaker(id: source)?.callCount, 1)
    }
}
