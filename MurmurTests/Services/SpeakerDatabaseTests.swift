import XCTest
@testable import Transcripted

@available(macOS 14.0, *)
final class SpeakerDatabaseTests: XCTestCase {

    private let db = SpeakerDatabase.shared

    // Track profiles we create so we can clean them up
    private var createdProfileIds: [UUID] = []

    override func tearDown() {
        super.tearDown()
        for id in createdProfileIds {
            db.deleteSpeaker(id: id)
        }
        createdProfileIds.removeAll()
    }

    // MARK: - Helpers

    /// Create a test profile with a random embedding and track it for cleanup
    private func createTestProfile(name: String? = nil, callCount: Int = 1) -> SpeakerProfile {
        let embedding = (0..<256).map { _ in Float.random(in: -1...1) }
        var profile = db.addOrUpdateSpeaker(embedding: embedding)
        createdProfileIds.append(profile.id)

        // Bump call count
        for _ in 1..<callCount {
            profile = db.addOrUpdateSpeaker(embedding: embedding, existingId: profile.id)
        }

        if let name = name {
            db.setDisplayName(id: profile.id, name: name, source: "test")
            // setDisplayName uses queue.async — wait for it to flush
            Thread.sleep(forTimeInterval: 0.3)
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

        // Remove source from cleanup list since it's already deleted
        createdProfileIds.removeAll { $0 == source.id }
    }

    func testMergeProfilesSumsCallCount() {
        let source = createTestProfile(callCount: 3)
        let target = createTestProfile(callCount: 5)
        let expectedCalls = 3 + 5

        db.mergeProfiles(sourceId: source.id, into: target.id)

        let merged = db.getSpeaker(id: target.id)
        XCTAssertEqual(merged?.callCount, expectedCalls, "Merged profile should have summed call count")

        createdProfileIds.removeAll { $0 == source.id }
    }

    func testMergeProfilesTransfersNameToUnnamed() {
        let sourceName = "SourceName_\(UUID().uuidString.prefix(8))"
        let source = createTestProfile(name: sourceName)
        let target = createTestProfile()  // no name

        db.mergeProfiles(sourceId: source.id, into: target.id)

        let merged = db.getSpeaker(id: target.id)
        XCTAssertEqual(merged?.displayName, sourceName, "Target should inherit name from source when unnamed")

        createdProfileIds.removeAll { $0 == source.id }
    }

    func testMergeProfilesKeepsTargetName() {
        let targetName = "KeepMe_\(UUID().uuidString.prefix(8))"
        let source = createTestProfile(name: "DontUseMe_\(UUID().uuidString.prefix(8))")
        let target = createTestProfile(name: targetName)

        db.mergeProfiles(sourceId: source.id, into: target.id)

        let merged = db.getSpeaker(id: target.id)
        XCTAssertEqual(merged?.displayName, targetName, "Target should keep its own name when already named")

        createdProfileIds.removeAll { $0 == source.id }
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
}
