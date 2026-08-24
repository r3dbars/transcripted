import XCTest
import SQLite3
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class SpeakerProfileMergerTests: XCTestCase {

    private var tempDirectory: URL!
    private var database: SpeakerDatabase!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerProfileMergerTests-\(UUID().uuidString)")
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

    func testMergeDuplicatesSkipsDisputedProfiles() {
        let first = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: nil
        )
        let second = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: nil
        )

        database.incrementDisputeCount(id: first.id)
        database.mergeDuplicates(threshold: 0.6)

        XCTAssertNotNil(database.getSpeaker(id: first.id))
        XCTAssertNotNil(database.getSpeaker(id: second.id))
    }

    func testMergeDuplicatesSkipsConflictingNamedProfiles() {
        let first = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.4, count: 256),
            existingId: nil
        )
        let second = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.4, count: 256),
            existingId: nil
        )

        database.setDisplayName(id: first.id, name: "Matt Vlasach", source: NameSource.userManual)
        database.setDisplayName(id: second.id, name: "Sarah Graham", source: NameSource.userManual)
        database.mergeDuplicates(threshold: 0.6)

        XCTAssertNotNil(database.getSpeaker(id: first.id))
        XCTAssertNotNil(database.getSpeaker(id: second.id))
    }

    func testMergeDuplicatesPreservesProtectedPendingProfiles() {
        let first = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: nil
        )
        let second = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: nil
        )

        database.mergeDuplicates(threshold: 0.6, protecting: [first.id])

        XCTAssertNotNil(
            database.getSpeaker(id: first.id),
            "Profiles referenced by pending speaker review rows must not be absorbed before review completes."
        )
        XCTAssertNotNil(database.getSpeaker(id: second.id))
    }

    func testDefaultProtectedMergeFallbackSkipsWhenIdsAreProtected() {
        let store = DefaultMergeFallbackSpeakerStore()

        store.mergeDuplicates(protecting: [UUID()])
        XCTAssertEqual(store.mergeDuplicatesCallCount, 0)

        store.mergeDuplicates(protecting: [])
        XCTAssertEqual(store.mergeDuplicatesCallCount, 1)
    }

    func testPruneWeakProfilesKeepsDeferredProfilesWithReviewSamples() throws {
        let profileId = UUID()
        _ = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: profileId
        )
        let staleProfile = SpeakerProfile(
            id: profileId,
            displayName: nil,
            nameSource: nil,
            embedding: [Float](repeating: 0.25, count: 256),
            firstSeen: Date().addingTimeInterval(-7200),
            lastSeen: Date().addingTimeInterval(-7200),
            callCount: 1,
            confidence: 0.5,
            disputeCount: 0
        )
        database.restoreProfile(staleProfile)

        let clipsDirectory = tempDirectory.appendingPathComponent("speaker_clips", isDirectory: true)
        try FileManager.default.createDirectory(at: clipsDirectory, withIntermediateDirectories: true)
        try Data("clip".utf8).write(to: clipsDirectory.appendingPathComponent("\(profileId.uuidString).wav"))

        database.pruneWeakProfiles()

        XCTAssertNotNil(
            database.getSpeaker(id: profileId),
            "deferred unnamed profiles with review samples should survive pruning"
        )
    }

    // MARK: - Explicit merge outcomes

    func testMergeProfilesSumsCallCountsTransfersNameAndDeletesSource() throws {
        let target = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.30, count: 256),
            existingId: nil
        )
        let source = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.31, count: 256),
            existingId: nil
        )
        database.setDisplayName(id: source.id, name: "Jenny Wen", source: NameSource.userManual)

        let targetBefore = try XCTUnwrap(database.getSpeaker(id: target.id))
        let sourceBefore = try XCTUnwrap(database.getSpeaker(id: source.id))
        database.recordNegativeExemplar(profileId: source.id, embedding: [Float](repeating: 0.12, count: 256))

        try database.mergeProfiles(sourceId: source.id, into: target.id)

        XCTAssertNil(database.getSpeaker(id: source.id), "source profile is deleted after merge")
        XCTAssertTrue(
            database.negativeExemplars(profileId: source.id).isEmpty,
            "absorbed profile must not leave identity-bound negative embeddings behind"
        )

        let merged = try XCTUnwrap(database.getSpeaker(id: target.id))
        XCTAssertEqual(merged.callCount, targetBefore.callCount + sourceBefore.callCount, "call counts sum")
        XCTAssertEqual(merged.displayName, "Jenny Wen", "name transfers when the target is unnamed")
        XCTAssertEqual(merged.confidence, min(1.0, targetBefore.confidence + 0.15), accuracy: 0.0001, "confidence bumps")
    }

    func testMergeProfilesThrowsWhenEitherProfileIsMissing() throws {
        let target = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.30, count: 256),
            existingId: nil
        )
        let missingSourceId = UUID()

        XCTAssertThrowsError(try database.mergeProfiles(sourceId: missingSourceId, into: target.id)) { error in
            guard case SpeakerDatabase.ProfileMergeError.profileNotFound(
                sourceId: missingSourceId,
                targetId: target.id
            ) = error else {
                XCTFail("Expected profileNotFound, got \(error)")
                return
            }
        }
    }

    func testAtomicMergeBatchRollsBackEarlierMergeWhenLaterMergeFails() throws {
        let firstSource = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.20, count: 256),
            existingId: nil
        )
        let firstTarget = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.30, count: 256),
            existingId: nil
        )
        let firstSourceBefore = try XCTUnwrap(database.getSpeaker(id: firstSource.id))
        let firstTargetBefore = try XCTUnwrap(database.getSpeaker(id: firstTarget.id))

        XCTAssertThrowsError(try database.performMutationBatch {
            try database.mergeProfiles(sourceId: firstSource.id, into: firstTarget.id)
            try database.mergeProfiles(sourceId: UUID(), into: firstTarget.id)
        })

        assertProfile(database.getSpeaker(id: firstSource.id), equals: firstSourceBefore)
        assertProfile(database.getSpeaker(id: firstTarget.id), equals: firstTargetBefore)
        XCTAssertTrue(database.recentUndoableMerges().isEmpty)
    }

    private func assertProfile(
        _ actual: SpeakerProfile?,
        equals expected: SpeakerProfile,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            XCTFail("Expected speaker profile \(expected.id)", file: file, line: line)
            return
        }
        XCTAssertEqual(actual.id, expected.id, file: file, line: line)
        XCTAssertEqual(actual.displayName, expected.displayName, file: file, line: line)
        XCTAssertEqual(actual.nameSource, expected.nameSource, file: file, line: line)
        XCTAssertEqual(actual.embedding, expected.embedding, file: file, line: line)
        XCTAssertEqual(actual.exemplars, expected.exemplars, file: file, line: line)
        XCTAssertEqual(actual.firstSeen, expected.firstSeen, file: file, line: line)
        XCTAssertEqual(actual.lastSeen, expected.lastSeen, file: file, line: line)
        XCTAssertEqual(actual.callCount, expected.callCount, file: file, line: line)
        XCTAssertEqual(actual.confidence, expected.confidence, file: file, line: line)
        XCTAssertEqual(actual.disputeCount, expected.disputeCount, file: file, line: line)
    }

    func testMergeProfilesRollsBackAndThrowsWhenTargetUpdateCannotBePrepared() throws {
        let (source, target) = makeNamedSourceAndUnnamedTarget()
        let result = database.queue.sync {
            sqlite3_set_authorizer(database.db, { _, action, tableName, _, _, _ in
                guard action == SQLITE_UPDATE,
                      let tableName,
                      String(cString: tableName) == "speakers" else {
                    return SQLITE_OK
                }
                return SQLITE_DENY
            }, nil)
        }
        XCTAssertEqual(result, SQLITE_OK)
        defer {
            _ = database.queue.sync { sqlite3_set_authorizer(database.db, nil, nil) }
        }

        assertMergeThrows(sourceId: source.id, targetId: target.id, operation: "prepare merge target update")
        try assertMergeDidNotMutate(source: source, target: target)
    }

    func testMergeProfilesRollsBackAndThrowsWhenTargetUpdateStepFails() throws {
        let (source, target) = makeNamedSourceAndUnnamedTarget()
        try executeSQL("""
        CREATE TRIGGER fail_merge_target_update
        BEFORE UPDATE ON speakers
        WHEN OLD.id = '\(target.id.uuidString)' AND NEW.call_count > OLD.call_count
        BEGIN
            SELECT RAISE(ABORT, 'forced merge update failure');
        END;
        """)

        assertMergeThrows(sourceId: source.id, targetId: target.id, operation: "step merge target update")
        try assertMergeDidNotMutate(source: source, target: target)
    }

    func testMergeProfilesThrowsWhenTransactionCannotBegin() throws {
        let (source, target) = makeNamedSourceAndUnnamedTarget()

        let thrown = database.queue.sync { () -> Error? in
            guard sqlite3_exec(database.db, "BEGIN EXCLUSIVE", nil, nil, nil) == SQLITE_OK else {
                return TestFailure.couldNotStartTransaction
            }
            defer { sqlite3_exec(database.db, "ROLLBACK", nil, nil, nil) }
            do {
                try database.mergeProfilesImpl(sourceId: source.id, into: target.id)
                return nil
            } catch {
                return error
            }
        }

        assertSQLiteOperation(thrown, equals: "begin speaker transaction")
        try assertMergeDidNotMutate(source: source, target: target)
    }

    func testMergeProfilesRollsBackAndThrowsWhenCommitFails() throws {
        let (source, target) = makeNamedSourceAndUnnamedTarget()
        try executeSQL("PRAGMA foreign_keys = ON;")
        try executeSQL("""
        CREATE TABLE merge_commit_guard (
            source_id TEXT NOT NULL REFERENCES speakers(id) DEFERRABLE INITIALLY DEFERRED
        );
        INSERT INTO merge_commit_guard (source_id) VALUES ('\(source.id.uuidString)');
        """)

        assertMergeThrows(sourceId: source.id, targetId: target.id, operation: "commit speaker transaction")
        try assertMergeDidNotMutate(source: source, target: target)
    }

    func testMergeDuplicatesMergesIdenticalUnnamedProfiles() throws {
        let a = database.addOrUpdateSpeaker(embedding: [Float](repeating: 0.25, count: 256), existingId: nil)
        let b = database.addOrUpdateSpeaker(embedding: [Float](repeating: 0.25, count: 256), existingId: nil)

        database.mergeDuplicates(threshold: 0.6)

        let survivors = [a.id, b.id].compactMap { database.getSpeaker(id: $0) }
        XCTAssertEqual(survivors.count, 1, "identical unnamed embeddings above threshold merge into one")
    }

    func testMergeDuplicatesContinuesAfterOuterProfileIsAbsorbed() {
        let now = Date()
        let lowCallOuter = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: nil
        )
        let highCallKeeper = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: nil
        )
        let remaining = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: nil
        )
        database.restoreProfile(SpeakerProfile(
            id: lowCallOuter.id, displayName: nil, nameSource: nil,
            embedding: lowCallOuter.embedding, firstSeen: now, lastSeen: now,
            callCount: 1, confidence: 0.5, disputeCount: 0
        ))
        database.restoreProfile(SpeakerProfile(
            id: highCallKeeper.id, displayName: nil, nameSource: nil,
            embedding: highCallKeeper.embedding, firstSeen: now, lastSeen: now.addingTimeInterval(-60),
            callCount: 3, confidence: 0.7, disputeCount: 0
        ))
        database.restoreProfile(SpeakerProfile(
            id: remaining.id, displayName: nil, nameSource: nil,
            embedding: remaining.embedding, firstSeen: now, lastSeen: now.addingTimeInterval(-120),
            callCount: 1, confidence: 0.5, disputeCount: 0
        ))

        database.mergeDuplicates(threshold: 0.6)

        let survivors = [lowCallOuter.id, highCallKeeper.id, remaining.id].compactMap {
            database.getSpeaker(id: $0)
        }
        XCTAssertEqual(survivors.map(\.id), [highCallKeeper.id])
    }

    func testPruneWeakProfilesRemovesNegativeExemplarsWithProfile() {
        let profileId = UUID()
        _ = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: profileId
        )
        database.restoreProfile(SpeakerProfile(
            id: profileId,
            displayName: nil,
            nameSource: nil,
            embedding: [Float](repeating: 0.25, count: 256),
            firstSeen: Date().addingTimeInterval(-7200),
            lastSeen: Date().addingTimeInterval(-7200),
            callCount: 1,
            confidence: 0.5,
            disputeCount: 0
        ))
        database.recordNegativeExemplar(profileId: profileId, embedding: [Float](repeating: 0.12, count: 256))

        database.pruneWeakProfiles()

        XCTAssertNil(database.getSpeaker(id: profileId))
        XCTAssertTrue(database.negativeExemplars(profileId: profileId).isEmpty)
    }

    private func makeNamedSourceAndUnnamedTarget() -> (source: SpeakerProfile, target: SpeakerProfile) {
        let target = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.30, count: 256),
            existingId: nil
        )
        let source = database.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.31, count: 256),
            existingId: nil
        )
        database.setDisplayName(id: source.id, name: "Jenny Wen", source: NameSource.userManual)
        database.recordNegativeExemplar(
            profileId: source.id,
            embedding: [Float](repeating: 0.12, count: 256)
        )
        return (source, target)
    }

    private func assertMergeThrows(sourceId: UUID, targetId: UUID, operation: String) {
        XCTAssertThrowsError(try database.mergeProfiles(sourceId: sourceId, into: targetId)) {
            self.assertSQLiteOperation($0, equals: operation)
        }
    }

    private func assertSQLiteOperation(
        _ error: Error?,
        equals operation: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let sqliteError = error as? SpeakerDatabase.SQLiteOperationError else {
            XCTFail("Expected SQLiteOperationError, got \(String(describing: error))", file: file, line: line)
            return
        }
        XCTAssertEqual(sqliteError.operation, operation, file: file, line: line)
    }

    private func assertMergeDidNotMutate(
        source: SpeakerProfile,
        target: SpeakerProfile,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let sourceAfter = try XCTUnwrap(database.getSpeaker(id: source.id), file: file, line: line)
        let targetAfter = try XCTUnwrap(database.getSpeaker(id: target.id), file: file, line: line)
        XCTAssertEqual(sourceAfter.displayName, "Jenny Wen", file: file, line: line)
        XCTAssertEqual(sourceAfter.callCount, source.callCount, file: file, line: line)
        XCTAssertNil(targetAfter.displayName, file: file, line: line)
        XCTAssertEqual(targetAfter.callCount, target.callCount, file: file, line: line)
        XCTAssertFalse(database.negativeExemplars(profileId: source.id).isEmpty, file: file, line: line)
        XCTAssertTrue(database.recentUndoableMerges().isEmpty, file: file, line: line)
    }

    private func executeSQL(_ sql: String) throws {
        try database.queue.sync {
            var message: UnsafeMutablePointer<CChar>?
            let result = sqlite3_exec(database.db, sql, nil, nil, &message)
            defer { sqlite3_free(message) }
            guard result == SQLITE_OK else {
                throw NSError(
                    domain: "SpeakerProfileMergerTests.SQLite",
                    code: Int(result),
                    userInfo: [NSLocalizedDescriptionKey: message.map { String(cString: $0) } ?? "unknown SQLite error"]
                )
            }
        }
    }

    private enum TestFailure: Error {
        case couldNotStartTransaction
    }
}

@available(macOS 14.0, *)
private final class DefaultMergeFallbackSpeakerStore: SpeakerStore, @unchecked Sendable {
    var mergeDuplicatesCallCount = 0

    func matchSpeaker(embedding _: [Float], threshold _: Double) -> SpeakerMatchResult? { nil }

    func addOrUpdateSpeaker(embedding: [Float], existingId: UUID?) -> SpeakerProfile {
        SpeakerProfile(
            id: existingId ?? UUID(),
            displayName: nil,
            nameSource: nil,
            embedding: embedding,
            firstSeen: Date(),
            lastSeen: Date(),
            callCount: 1,
            confidence: 0.5,
            disputeCount: 0
        )
    }

    func getSpeaker(id _: UUID) -> SpeakerProfile? { nil }
    func allSpeakers() -> [SpeakerProfile] { [] }
    func setDisplayName(id _: UUID, name _: String, source _: String) {}
    func restoreProfile(_: SpeakerProfile) {}
    func deleteSpeaker(id _: UUID) {}
    func mergeProfiles(sourceId _: UUID, into _: UUID) throws {}

    func mergeDuplicates() {
        mergeDuplicatesCallCount += 1
    }

    func pruneWeakProfiles() {}
    func incrementDisputeCount(id _: UUID) {}
    func resetDisputeCount(id _: UUID) {}
}
