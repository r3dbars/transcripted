import XCTest
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

        database.mergeProfiles(sourceId: source.id, into: target.id)

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

        database.mergeProfiles(sourceId: source.id, into: target.id)

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

        database.mergeProfiles(sourceId: first.id, into: keeper.id)
        let firstEvent = try XCTUnwrap(database.undoableMerge(forTargetId: keeper.id))
        database.mergeProfiles(sourceId: second.id, into: keeper.id)

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

        database.mergeProfiles(sourceId: source.id, into: target.id)

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

    func testUnmergeNonexistentEventIsNoop() {
        XCTAssertFalse(database.unmerge(mergeId: UUID()))
        XCTAssertFalse(database.unmergeMostRecent(forTargetId: UUID()))
    }
}
