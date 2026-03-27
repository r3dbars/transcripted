import XCTest
import SQLite3
@testable import Transcripted

@available(macOS 14.0, *)
final class SpeakerDatabaseTests: XCTestCase {

    private var db: SpeakerDatabase!

    override func setUp() {
        super.setUp()
        let tempDir = FileManager.default.temporaryDirectory
        let dbPath = tempDir.appendingPathComponent("test_speakers_\(UUID().uuidString).sqlite")
        db = SpeakerDatabase(path: dbPath.path)
    }

    override func tearDown() {
        db = nil
        super.tearDown()
    }

    // MARK: - Helpers

    /// Create a test profile with a random embedding
    private func createTestProfile(name: String? = nil, callCount: Int = 1) -> SpeakerProfile {
        let embedding = (0..<256).map { _ in Float.random(in: -1...1) }
        var profile = db.addOrUpdateSpeaker(embedding: embedding)

        // Bump call count
        for _ in 1..<callCount {
            profile = db.addOrUpdateSpeaker(embedding: embedding, existingId: profile.id)
        }

        if let name = name {
            db.setDisplayName(id: profile.id, name: name, source: "test")
            // Re-fetch the profile so the returned struct reflects the updated display name
            if let updated = db.getSpeaker(id: profile.id) {
                profile = updated
            }
        }

        return profile
    }

    // MARK: - findProfilesByName

    func testFindProfilesByNameExactMatch() {
        let profile = createTestProfile(name: "TestUser_\(UUID().uuidString.prefix(8))")
        let name = profile.displayName!

        let results = db.findProfilesByName(name)
        XCTAssertFalse(results.isEmpty, "Should find profile by exact name")
        XCTAssertEqual(results.first?.id, profile.id)
    }

    func testFindProfilesByNameCaseInsensitive() {
        let uniqueName = "CaseTest_\(UUID().uuidString.prefix(8))"
        let profile = createTestProfile(name: uniqueName)

        let results = db.findProfilesByName(uniqueName.lowercased())
        XCTAssertFalse(results.isEmpty, "Should match case-insensitively")
        XCTAssertEqual(results.first?.id, profile.id)
    }

    func testFindProfilesByNameVariants() {
        let profile = createTestProfile(name: "Nathan")

        let results = db.findProfilesByName("Nate")
        let matchIds = results.map { $0.id }
        XCTAssertTrue(matchIds.contains(profile.id), "Should find 'Nathan' when searching 'Nate'")
    }

    func testFindProfilesByNameNoMatch() {
        _ = createTestProfile(name: "ZZZNoMatch_\(UUID().uuidString.prefix(8))")

        let results = db.findProfilesByName("CompletelyDifferentName_\(UUID().uuidString)")
        XCTAssertTrue(results.isEmpty, "Should not find unrelated profiles")
    }

    func testFindProfilesByNameSortedByCallCount() {
        let uniqueSuffix = UUID().uuidString.prefix(8)
        let highCalls = createTestProfile(name: "TestSort_\(uniqueSuffix)", callCount: 5)
        let lowCalls = createTestProfile(name: "TestSort_\(uniqueSuffix)", callCount: 1)

        let results = db.findProfilesByName("TestSort_\(uniqueSuffix)")
        XCTAssertGreaterThanOrEqual(results.count, 2)
        // First result should have more calls
        if results.count >= 2 {
            XCTAssertGreaterThanOrEqual(results[0].callCount, results[1].callCount)
        }
    }

    func testFindProfilesByNameEmptyString() {
        let results = db.findProfilesByName("")
        XCTAssertTrue(results.isEmpty, "Empty string should return no results")
    }

    func testFindProfilesByNameWhitespaceOnly() {
        let results = db.findProfilesByName("   ")
        XCTAssertTrue(results.isEmpty, "Whitespace-only should return no results")
    }

    // MARK: - mergeProfiles

    func testMergeProfilesDeletesSource() {
        let source = createTestProfile(name: "MergeSource_\(UUID().uuidString.prefix(8))")
        let target = createTestProfile(name: "MergeTarget_\(UUID().uuidString.prefix(8))")

        db.mergeProfiles(sourceId: source.id, into: target.id)

        // Source should be deleted
        XCTAssertNil(db.getSpeaker(id: source.id), "Source profile should be deleted after merge")
        // Target should still exist
        XCTAssertNotNil(db.getSpeaker(id: target.id), "Target profile should still exist after merge")
    }

    func testMergeProfilesSumsCallCount() {
        let source = createTestProfile(callCount: 3)
        let target = createTestProfile(callCount: 5)
        let expectedCalls = 3 + 5

        db.mergeProfiles(sourceId: source.id, into: target.id)

        let merged = db.getSpeaker(id: target.id)
        XCTAssertEqual(merged?.callCount, expectedCalls, "Merged profile should have summed call count")
    }

    func testMergeProfilesTransfersNameToUnnamed() {
        let sourceName = "SourceName_\(UUID().uuidString.prefix(8))"
        let source = createTestProfile(name: sourceName)
        let target = createTestProfile()  // no name

        db.mergeProfiles(sourceId: source.id, into: target.id)

        let merged = db.getSpeaker(id: target.id)
        XCTAssertEqual(merged?.displayName, sourceName, "Target should inherit name from source when unnamed")
    }

    func testMergeProfilesKeepsTargetName() {
        let targetName = "KeepMe_\(UUID().uuidString.prefix(8))"
        let source = createTestProfile(name: "DontUseMe_\(UUID().uuidString.prefix(8))")
        let target = createTestProfile(name: targetName)

        db.mergeProfiles(sourceId: source.id, into: target.id)

        let merged = db.getSpeaker(id: target.id)
        XCTAssertEqual(merged?.displayName, targetName, "Target should keep its own name when already named")
    }

    func testMergeProfilesNonexistentSource() {
        let target = createTestProfile()
        let fakeSourceId = UUID()

        // Should not crash — just logs a warning
        db.mergeProfiles(sourceId: fakeSourceId, into: target.id)

        // Target should be unmodified
        XCTAssertNotNil(db.getSpeaker(id: target.id))
    }

    // MARK: - SpeakerNameUpdate with .merged

    func testSpeakerNameUpdateMergedAction() {
        let targetId = UUID()
        let update = SpeakerNameUpdate(
            persistentSpeakerId: UUID(),
            sortformerSpeakerId: "0",
            newName: "MKBHD",
            action: .merged(targetProfileId: targetId)
        )

        if case .merged(let id) = update.action {
            XCTAssertEqual(id, targetId)
        } else {
            XCTFail("Expected .merged action")
        }
    }

    func testSpeakerNameUpdateNamedAction() {
        let update = SpeakerNameUpdate(
            persistentSpeakerId: UUID(),
            sortformerSpeakerId: "0",
            newName: "Test",
            action: .named
        )

        if case .named = update.action {
            // expected
        } else {
            XCTFail("Expected .named action")
        }
    }

    // MARK: - areNameVariants (static, no DB needed)

    func testAreNameVariantsExactMatch() {
        XCTAssertTrue(SpeakerDatabase.areNameVariants("MKBHD", "mkbhd"))
    }

    func testAreNameVariantsNicknames() {
        XCTAssertTrue(SpeakerDatabase.areNameVariants("Nate", "Nathan"))
        XCTAssertTrue(SpeakerDatabase.areNameVariants("Mike", "Michael"))
        XCTAssertTrue(SpeakerDatabase.areNameVariants("Bob", "Robert"))
    }

    func testAreNameVariantsContains() {
        XCTAssertTrue(SpeakerDatabase.areNameVariants("Marques Brownlee", "Marques"))
    }

    func testAreNameVariantsNoMatch() {
        XCTAssertFalse(SpeakerDatabase.areNameVariants("Alice", "Bob"))
    }

    // MARK: - addOrUpdateSpeaker (new profile)

    func testAddNewSpeakerReturnsProfileWithDefaults() {
        let embedding: [Float] = (0..<256).map { _ in Float.random(in: -1...1) }
        let profile = db.addOrUpdateSpeaker(embedding: embedding, existingId: nil)

        XCTAssertEqual(profile.callCount, 1, "New speaker should have callCount=1")
        XCTAssertEqual(profile.confidence, 0.5, accuracy: 0.01, "New speaker should have confidence=0.5")
        XCTAssertNil(profile.displayName, "New speaker should have no display name")
    }

    // MARK: - addOrUpdateSpeaker (existing profile — EMA)

    func testUpdateExistingSpeakerIncrementsCallCount() {
        let embedding: [Float] = (0..<256).map { _ in Float.random(in: -1...1) }
        let initial = db.addOrUpdateSpeaker(embedding: embedding, existingId: nil)

        let updated = db.addOrUpdateSpeaker(embedding: embedding, existingId: initial.id)
        XCTAssertEqual(updated.callCount, 2, "Call count should increment by 1")
    }

    func testUpdateExistingSpeakerIncreasesConfidence() {
        let embedding: [Float] = (0..<256).map { _ in Float.random(in: -1...1) }
        let initial = db.addOrUpdateSpeaker(embedding: embedding, existingId: nil)

        let updated = db.addOrUpdateSpeaker(embedding: embedding, existingId: initial.id)
        XCTAssertEqual(updated.confidence, 0.6, accuracy: 0.01, "Confidence should increase by 0.1")
    }

    func testUpdateExistingSpeakerConfidenceCappedAt1() {
        let embedding: [Float] = (0..<256).map { _ in Float.random(in: -1...1) }
        var profile = db.addOrUpdateSpeaker(embedding: embedding, existingId: nil)

        // Update 10 times to push confidence past 1.0
        for _ in 0..<10 {
            profile = db.addOrUpdateSpeaker(embedding: embedding, existingId: profile.id)
        }
        XCTAssertLessThanOrEqual(profile.confidence, 1.0, "Confidence should be capped at 1.0")
    }

    // MARK: - WAL mode verification

    func testDatabaseUsesWALMode() {
        guard let dbHandle = db.db else {
            XCTFail("Database handle should be open")
            return
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(dbHandle, "PRAGMA journal_mode;", -1, &stmt, nil) == SQLITE_OK else {
            XCTFail("Failed to prepare PRAGMA journal_mode query")
            return
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cString = sqlite3_column_text(stmt, 0) else {
            XCTFail("Failed to read journal_mode result")
            return
        }
        let journalMode = String(cString: cString)
        XCTAssertEqual(journalMode, "wal", "Database should use WAL journal mode")
    }
}
