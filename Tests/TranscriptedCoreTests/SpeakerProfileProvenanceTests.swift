import XCTest
@testable import TranscriptedCore

/// Direct coverage for `SpeakerProfileProvenance.swift`: the `ProfileSnapshot` codable
/// round trip, and the `speaker_provenance` / `speaker_merge_events` query surface
/// (`recentUndoableMerges`, `undoableMerge`, `contributions`, `unmerge`,
/// `reassignContribution`) that the audit tables back.
///
/// `SpeakerProvenanceTests.swift` already covers the core un-merge safety net (blend
/// reversal, LIFO refusal, fuse markers, post-merge learning). This file targets the
/// parts of the same source file that aren't exercised there: the pure snapshot
/// encode/decode helpers, `recentUndoableMerges` ordering/limit/undone-filtering,
/// `undoableMerge` misses, merge-kind propagation for `mergeProfilesByName`,
/// double-undo rejection, `reassignContribution` failure paths and its embedding/
/// call-count re-derivation, and persistence across a database reopen.
@available(macOS 14.0, *)
final class SpeakerProfileProvenanceTests: XCTestCase {

    private var tempDirectory: URL!
    private var database: SpeakerDatabase!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerProfileProvenanceTests-\(UUID().uuidString)")
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

    /// One-hot-ish embedding so profiles are genuinely distinct going in.
    private func embedding(axis: Int, dim: Int = 256) -> [Float] {
        var vector = [Float](repeating: 0.01, count: dim)
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

    // MARK: - ProfileSnapshot encode/decode (pure, no DB)

    func testProfileSnapshotRoundTripsAllFields() throws {
        let iso = ISO8601DateFormatter()
        let profile = SpeakerProfile(
            id: UUID(),
            displayName: "Nate",
            nameSource: NameSource.userManual,
            embedding: [0.1, -0.2, 0.3, 0.0],
            firstSeen: Date(timeIntervalSince1970: 1_700_000_000),
            lastSeen: Date(timeIntervalSince1970: 1_700_100_000),
            callCount: 7,
            confidence: 0.82,
            disputeCount: 2
        )

        let json = try XCTUnwrap(SpeakerDatabase.encodeProfileSnapshot(profile))
        let snapshot = try XCTUnwrap(SpeakerDatabase.decodeProfileSnapshot(json))

        XCTAssertEqual(snapshot.id, profile.id)
        XCTAssertEqual(snapshot.displayName, "Nate")
        XCTAssertEqual(snapshot.nameSource, NameSource.userManual)
        XCTAssertEqual(snapshot.embedding, profile.embedding)
        XCTAssertEqual(snapshot.firstSeen, iso.string(from: profile.firstSeen))
        XCTAssertEqual(snapshot.lastSeen, iso.string(from: profile.lastSeen))
        XCTAssertEqual(snapshot.callCount, 7)
        XCTAssertEqual(snapshot.confidence, 0.82, accuracy: 0.0001)
        XCTAssertEqual(snapshot.disputeCount, 2)
    }

    func testProfileSnapshotRoundTripsNilNameFieldsAndEmptyEmbedding() throws {
        let profile = SpeakerProfile(
            id: UUID(),
            displayName: nil,
            nameSource: nil,
            embedding: [],
            firstSeen: Date(),
            lastSeen: Date(),
            callCount: 1,
            confidence: 0.5,
            disputeCount: 0
        )

        let json = try XCTUnwrap(SpeakerDatabase.encodeProfileSnapshot(profile))
        let snapshot = try XCTUnwrap(SpeakerDatabase.decodeProfileSnapshot(json))

        XCTAssertNil(snapshot.displayName)
        XCTAssertNil(snapshot.nameSource)
        XCTAssertEqual(snapshot.embedding, [])
    }

    func testDecodeProfileSnapshotRejectsMalformedOrEmptyInput() {
        XCTAssertNil(SpeakerDatabase.decodeProfileSnapshot("not json"))
        XCTAssertNil(SpeakerDatabase.decodeProfileSnapshot(""))
        XCTAssertNil(SpeakerDatabase.decodeProfileSnapshot("{\"id\": \"not-a-uuid\"}"))
    }

    // MARK: - recentUndoableMerges

    func testRecentUndoableMergesReturnsNewestFirstWithNamesAndRespectsLimit() throws {
        let keeper = database.addOrUpdateSpeaker(embedding: embedding(axis: 0), existingId: nil)
        let first = database.addOrUpdateSpeaker(embedding: embedding(axis: 1), existingId: nil)
        let second = database.addOrUpdateSpeaker(embedding: embedding(axis: 2), existingId: nil)
        let third = database.addOrUpdateSpeaker(embedding: embedding(axis: 3), existingId: nil)
        database.setDisplayName(id: keeper.id, name: "Keeper", source: NameSource.userManual)
        database.setDisplayName(id: third.id, name: "Charlie", source: NameSource.userManual)

        database.mergeProfiles(sourceId: first.id, into: keeper.id)
        database.mergeProfiles(sourceId: second.id, into: keeper.id)
        database.mergeProfiles(sourceId: third.id, into: keeper.id)

        let all = database.recentUndoableMerges(limit: 25)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all[0].sourceId, third.id, "most recent merge must be first")
        XCTAssertEqual(all[1].sourceId, second.id)
        XCTAssertEqual(all[2].sourceId, first.id)
        XCTAssertEqual(all[0].sourceName, "Charlie")
        XCTAssertEqual(all[0].targetName, "Keeper")
        XCTAssertTrue(all.allSatisfy { $0.kind == SpeakerMergeKind.explicit })
        XCTAssertTrue(all.allSatisfy { !$0.isUndone })

        let limited = database.recentUndoableMerges(limit: 1)
        XCTAssertEqual(limited.count, 1)
        XCTAssertEqual(limited[0].sourceId, third.id)
    }

    func testRecentUndoableMergesExcludesUndoneMerges() throws {
        let source = database.addOrUpdateSpeaker(embedding: embedding(axis: 5), existingId: nil)
        let target = database.addOrUpdateSpeaker(embedding: embedding(axis: 6), existingId: nil)
        database.mergeProfiles(sourceId: source.id, into: target.id)

        XCTAssertTrue(database.recentUndoableMerges(limit: 25).contains { $0.sourceId == source.id })
        XCTAssertTrue(database.unmergeMostRecent(forTargetId: target.id))
        XCTAssertFalse(database.recentUndoableMerges(limit: 25).contains { $0.sourceId == source.id })
    }

    func testRecentUndoableMergesWithNonPositiveLimitReturnsEmpty() throws {
        let source = database.addOrUpdateSpeaker(embedding: embedding(axis: 7), existingId: nil)
        let target = database.addOrUpdateSpeaker(embedding: embedding(axis: 8), existingId: nil)
        database.mergeProfiles(sourceId: source.id, into: target.id)

        XCTAssertTrue(database.recentUndoableMerges(limit: 0).isEmpty)
        XCTAssertTrue(database.recentUndoableMerges(limit: -5).isEmpty)
    }

    // MARK: - undoableMerge(forTargetId:)

    func testUndoableMergeReturnsNilWhenNoMergeTargetsProfile() {
        let target = database.addOrUpdateSpeaker(embedding: embedding(axis: 9), existingId: nil)
        XCTAssertNil(database.undoableMerge(forTargetId: target.id))
        XCTAssertNil(database.undoableMerge(forTargetId: UUID()))
    }

    func testMergeProfilesByNameRecordsByNameKind() throws {
        let a = database.addOrUpdateSpeaker(embedding: embedding(axis: 40), existingId: nil)
        let b = database.addOrUpdateSpeaker(embedding: embedding(axis: 41), existingId: nil)
        database.setDisplayName(id: a.id, name: "Jenny Wen", source: NameSource.userManual)
        database.setDisplayName(id: b.id, name: "Jenny Wen", source: NameSource.userManual)

        database.mergeProfilesByName()

        let survivorId = database.getSpeaker(id: a.id) != nil ? a.id : b.id
        let record = try XCTUnwrap(database.undoableMerge(forTargetId: survivorId))
        XCTAssertEqual(record.kind, SpeakerMergeKind.byName)
    }

    // MARK: - contributions(forProfileId:)

    func testContributionsForUnknownProfileIsEmpty() {
        XCTAssertTrue(database.contributions(forProfileId: UUID()).isEmpty)
    }

    // MARK: - unmerge double-undo rejection

    func testUnmergeFailsWhenCalledTwiceOnSameEvent() throws {
        let source = database.addOrUpdateSpeaker(embedding: embedding(axis: 50), existingId: nil)
        let target = database.addOrUpdateSpeaker(embedding: embedding(axis: 51), existingId: nil)
        database.mergeProfiles(sourceId: source.id, into: target.id)
        let record = try XCTUnwrap(database.undoableMerge(forTargetId: target.id))

        XCTAssertTrue(database.unmerge(mergeId: record.id))
        XCTAssertFalse(database.unmerge(mergeId: record.id), "an already-undone merge event cannot be undone again")
    }

    // MARK: - reassignContribution

    func testReassignContributionIsNoopWhenDestinationEqualsSource() throws {
        let profile = database.addOrUpdateSpeaker(embedding: embedding(axis: 60), existingId: nil)
        let contribution = try XCTUnwrap(database.contributions(forProfileId: profile.id).first)

        XCTAssertTrue(database.reassignContribution(id: contribution.id, toProfileId: profile.id))
        XCTAssertEqual(database.contributions(forProfileId: profile.id).count, 1)
    }

    func testReassignContributionFailsForUnknownContribution() {
        let profile = database.addOrUpdateSpeaker(embedding: embedding(axis: 61), existingId: nil)
        XCTAssertFalse(database.reassignContribution(id: UUID(), toProfileId: profile.id))
    }

    func testReassignContributionFailsWhenDestinationProfileMissing() throws {
        let profile = database.addOrUpdateSpeaker(embedding: embedding(axis: 62), existingId: nil)
        let contribution = try XCTUnwrap(database.contributions(forProfileId: profile.id).first)

        XCTAssertFalse(database.reassignContribution(id: contribution.id, toProfileId: UUID()))
        XCTAssertTrue(
            database.contributions(forProfileId: profile.id).contains { $0.id == contribution.id },
            "a failed reassign must leave the contribution where it was"
        )
    }

    func testReassignContributionRederivesEmbeddingsAndCallCounts() throws {
        let axis0 = embedding(axis: 0)
        let axis1 = embedding(axis: 1)
        let source = database.addOrUpdateSpeaker(embedding: axis0, existingId: nil)
        let target = database.addOrUpdateSpeaker(embedding: axis1, existingId: nil)

        let contribution = try XCTUnwrap(database.contributions(forProfileId: source.id).first)
        XCTAssertTrue(database.reassignContribution(id: contribution.id, toProfileId: target.id))

        XCTAssertFalse(database.contributions(forProfileId: source.id).contains { $0.id == contribution.id })
        XCTAssertTrue(database.contributions(forProfileId: target.id).contains { $0.id == contribution.id })

        // Target now has two stored contribution embeddings (its own seed plus the
        // reassigned one), so re-derivation sets call_count to that count.
        let restoredTarget = try XCTUnwrap(database.getSpeaker(id: target.id))
        XCTAssertEqual(restoredTarget.callCount, 2)

        // Its embedding should now be the L2-normalized mean of the two raw contribution
        // vectors, not purely axis1 anymore.
        var expectedMean = [Float](repeating: 0, count: axis0.count)
        for i in 0..<axis0.count { expectedMean[i] = (axis0[i] + axis1[i]) / 2 }
        var norm: Float = 0
        for value in expectedMean { norm += value * value }
        norm = norm.squareRoot()
        let expectedNormalized = expectedMean.map { $0 / norm }
        XCTAssertGreaterThan(cosine(restoredTarget.embedding, expectedNormalized), 0.999)

        // Source has no remaining contribution embeddings, so its re-derivation is a
        // no-op: call_count and embedding stay whatever addOrUpdateSpeaker first wrote.
        let restoredSource = try XCTUnwrap(database.getSpeaker(id: source.id))
        XCTAssertEqual(restoredSource.callCount, 1)
    }

    // MARK: - Persistence across reopen

    func testProvenanceAndMergeEventsPersistAcrossDatabaseReopen() throws {
        let dbPath = tempDirectory.appendingPathComponent("reopen.sqlite").path
        var db1: SpeakerDatabase? = SpeakerDatabase(path: dbPath)
        let source = db1!.addOrUpdateSpeaker(embedding: embedding(axis: 90), existingId: nil)
        let target = db1!.addOrUpdateSpeaker(embedding: embedding(axis: 91), existingId: nil)
        db1!.setDisplayName(id: source.id, name: "Pat", source: NameSource.userManual)
        db1!.mergeProfiles(sourceId: source.id, into: target.id)
        let contributionCountBefore = db1!.contributions(forProfileId: target.id).count
        db1 = nil // close the connection before reopening the same file

        let db2 = SpeakerDatabase(path: dbPath)
        let record = try XCTUnwrap(db2.undoableMerge(forTargetId: target.id), "merge event must survive reopen")
        XCTAssertEqual(record.sourceId, source.id)
        XCTAssertEqual(record.sourceName, "Pat")
        XCTAssertEqual(db2.contributions(forProfileId: target.id).count, contributionCountBefore)

        // Un-merge still works after reopening from disk, reconstructing the source
        // profile from its persisted snapshot.
        XCTAssertTrue(db2.unmergeMostRecent(forTargetId: target.id))
        let restoredSource = try XCTUnwrap(db2.getSpeaker(id: source.id))
        XCTAssertEqual(restoredSource.displayName, "Pat")
    }
}
