import XCTest
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

        database.mergeProfiles(sourceId: source.id, into: target.id)

        XCTAssertNil(database.getSpeaker(id: source.id), "source profile is deleted after merge")

        let merged = try XCTUnwrap(database.getSpeaker(id: target.id))
        XCTAssertEqual(merged.callCount, targetBefore.callCount + sourceBefore.callCount, "call counts sum")
        XCTAssertEqual(merged.displayName, "Jenny Wen", "name transfers when the target is unnamed")
        XCTAssertEqual(merged.confidence, min(1.0, targetBefore.confidence + 0.15), accuracy: 0.0001, "confidence bumps")
    }

    func testMergeProfilesByNameCollapsesSameNameProfiles() throws {
        // Distinct embeddings on purpose: same-name merge ignores similarity, so
        // four "Jenny Wen" profiles must still collapse into one.
        let a = database.addOrUpdateSpeaker(embedding: [Float](repeating: 0.20, count: 256), existingId: nil)
        let b = database.addOrUpdateSpeaker(embedding: [Float](repeating: 0.90, count: 256), existingId: nil)
        let c = database.addOrUpdateSpeaker(embedding: [Float](repeating: 0.50, count: 256), existingId: nil)
        for id in [a.id, b.id, c.id] {
            database.setDisplayName(id: id, name: "Jenny Wen", source: NameSource.userManual)
        }

        database.mergeProfilesByName()

        let survivors = [a.id, b.id, c.id].compactMap { database.getSpeaker(id: $0) }
        XCTAssertEqual(survivors.count, 1, "same-name profiles collapse into a single profile")
        XCTAssertEqual(survivors.first?.displayName, "Jenny Wen")
    }

    func testMergeDuplicatesMergesIdenticalUnnamedProfiles() throws {
        let a = database.addOrUpdateSpeaker(embedding: [Float](repeating: 0.25, count: 256), existingId: nil)
        let b = database.addOrUpdateSpeaker(embedding: [Float](repeating: 0.25, count: 256), existingId: nil)

        database.mergeDuplicates(threshold: 0.6)

        let survivors = [a.id, b.id].compactMap { database.getSpeaker(id: $0) }
        XCTAssertEqual(survivors.count, 1, "identical unnamed embeddings above threshold merge into one")
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
    func mergeProfiles(sourceId _: UUID, into _: UUID) {}
    func mergeProfilesByName() {}

    func mergeDuplicates() {
        mergeDuplicatesCallCount += 1
    }

    func pruneWeakProfiles() {}
    func incrementDisputeCount(id _: UUID) {}
    func resetDisputeCount(id _: UUID) {}
    func findProfilesByName(_: String) -> [SpeakerProfile] { [] }
}
