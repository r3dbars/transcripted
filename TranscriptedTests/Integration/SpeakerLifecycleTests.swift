import XCTest
import SQLite3
@testable import Transcripted

/// Integration test: full speaker lifecycle using an isolated temp database.
/// Covers add -> match -> update -> name -> find -> merge -> prune.
@available(macOS 14.0, *)
final class SpeakerLifecycleTests: XCTestCase {

    private var db: SpeakerDatabase!
    private var dbPath: URL!

    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerLifecycleTests-\(UUID().uuidString).sqlite")
        db = SpeakerDatabase(path: dbPath.path)
    }

    override func tearDown() {
        db = nil
        // Clean up SQLite WAL/SHM files too
        for ext in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath.path + ext)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    /// Generate a deterministic embedding vector of dimension `dim`.
    /// Different seeds produce orthogonal-ish vectors.
    private func makeEmbedding(seed: Int, dim: Int = 256) -> [Float] {
        var embedding = [Float](repeating: 0, count: dim)
        // Place energy at a specific position to make vectors distinguishable
        let position = seed % dim
        embedding[position] = 1.0
        // Add small noise to other dimensions
        for i in 0..<dim {
            if i != position {
                embedding[i] = Float(i + seed) * 0.001
            }
        }
        return embedding
    }

    /// Generate an embedding that is nearly identical to another (high cosine similarity).
    private func makeNearDuplicate(of base: [Float], noise: Float = 0.02) -> [Float] {
        base.map { $0 + Float.random(in: -noise...noise) }
    }

    // MARK: - Add + Match + Verify callCount

    func testAddNewSpeakerThenMatchReturnsIt() {
        let embedding = makeEmbedding(seed: 0)

        // Add a new speaker
        let profile = db.addOrUpdateSpeaker(embedding: embedding)
        XCTAssertEqual(profile.callCount, 1, "New speaker should have callCount=1")

        // Match with the same embedding
        let match = db.matchSpeaker(embedding: embedding, threshold: 0.5)
        XCTAssertNotNil(match, "Should match the speaker we just added")
        XCTAssertEqual(match?.profile.id, profile.id, "Matched speaker ID should equal the added speaker ID")
        XCTAssertEqual(match?.profile.callCount, 1, "callCount should still be 1 (match doesn't increment)")
    }

    // MARK: - Update Increments callCount and Confidence

    func testAddOrUpdateIncrementsCallCountAndConfidence() {
        let embedding = makeEmbedding(seed: 1)

        let profile = db.addOrUpdateSpeaker(embedding: embedding)
        XCTAssertEqual(profile.callCount, 1)
        XCTAssertEqual(profile.confidence, 0.5, accuracy: 0.01)

        // Update with existing ID
        let updated = db.addOrUpdateSpeaker(embedding: embedding, existingId: profile.id)
        XCTAssertEqual(updated.callCount, 2, "callCount should increment to 2")
        XCTAssertEqual(updated.confidence, 0.6, accuracy: 0.01, "confidence should increase by 0.1")

        // Verify persisted in database
        let fetched = db.getSpeaker(id: profile.id)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.callCount, 2)
    }

    // MARK: - Set Display Name + Find by Name

    func testSetDisplayNameThenFindByName() {
        let embedding = makeEmbedding(seed: 2)
        let profile = db.addOrUpdateSpeaker(embedding: embedding)

        db.setDisplayName(id: profile.id, name: "Charlie", source: "user_manual")

        let results = db.findProfilesByName("Charlie")
        XCTAssertEqual(results.count, 1, "Should find exactly one profile named Charlie")
        XCTAssertEqual(results.first?.id, profile.id)
        XCTAssertEqual(results.first?.displayName, "Charlie")
    }

    func testFindByNameCaseInsensitive() {
        let embedding = makeEmbedding(seed: 3)
        let profile = db.addOrUpdateSpeaker(embedding: embedding)
        db.setDisplayName(id: profile.id, name: "Diana", source: "test")

        let results = db.findProfilesByName("diana")
        XCTAssertEqual(results.count, 1, "findProfilesByName should be case-insensitive")
        XCTAssertEqual(results.first?.id, profile.id)
    }

    // MARK: - Merge Profiles by Name

    func testMergeProfilesByNameConsolidatesDuplicateNames() {
        // Create 3 profiles, name 2 as "Alice" with different case
        let embedding1 = makeEmbedding(seed: 10)
        let embedding2 = makeEmbedding(seed: 11)
        let embedding3 = makeEmbedding(seed: 12)

        let profile1 = db.addOrUpdateSpeaker(embedding: embedding1)
        let profile2 = db.addOrUpdateSpeaker(embedding: embedding2)
        let profile3 = db.addOrUpdateSpeaker(embedding: embedding3)

        db.setDisplayName(id: profile1.id, name: "Alice", source: "user_manual")
        db.setDisplayName(id: profile2.id, name: "alice", source: "qwen_inferred")
        db.setDisplayName(id: profile3.id, name: "Bob", source: "user_manual")

        // Verify we have 3 profiles before merge
        XCTAssertEqual(db.allSpeakers().count, 3)

        // Merge profiles that share the same name
        db.mergeProfilesByName()

        let allSpeakers = db.allSpeakers()
        XCTAssertEqual(allSpeakers.count, 2, "Should have 2 profiles after merging Alice duplicates")

        // Verify only 1 Alice remains
        let aliceProfiles = db.findProfilesByName("Alice")
        XCTAssertEqual(aliceProfiles.count, 1, "Should have exactly 1 Alice profile after merge")

        // Verify Bob is untouched
        let bobProfiles = db.findProfilesByName("Bob")
        XCTAssertEqual(bobProfiles.count, 1, "Bob should be unchanged")
    }

    // MARK: - Prune Weak Profiles

    func testPruneWeakProfilesDeletesOldUnnamed() {
        // Add 5 profiles: some will be prunable, some won't
        var profiles: [SpeakerProfile] = []
        for i in 0..<5 {
            let embedding = makeEmbedding(seed: 20 + i)
            let profile = db.addOrUpdateSpeaker(embedding: embedding)
            profiles.append(profile)
        }

        // Name the first 2 (they should survive pruning)
        db.setDisplayName(id: profiles[0].id, name: "Named1", source: "test")
        db.setDisplayName(id: profiles[1].id, name: "Named2", source: "test")

        // Give profile 2 (unnamed) extra calls so it survives (callCount > 1)
        _ = db.addOrUpdateSpeaker(embedding: makeEmbedding(seed: 22), existingId: profiles[2].id)

        // Profiles 3 and 4 are unnamed, callCount=1, confidence=0.5 -- prunable if old enough

        // Manipulate first_seen for profiles 3 and 4 to make them old via raw SQL
        let cutoffDate = Date().addingTimeInterval(-7200) // 2 hours ago
        let isoFormatter = ISO8601DateFormatter()
        let oldDateStr = isoFormatter.string(from: cutoffDate)

        for i in 3..<5 {
            let sql = "UPDATE speakers SET first_seen = '\(oldDateStr)' WHERE id = '\(profiles[i].id.uuidString)';"
            db.executeSQL(sql)
        }

        let beforeCount = db.allSpeakers().count
        XCTAssertEqual(beforeCount, 5, "Should have 5 profiles before pruning")

        db.pruneWeakProfiles()

        let afterSpeakers = db.allSpeakers()
        XCTAssertEqual(afterSpeakers.count, 3, "Should have 3 profiles after pruning (2 named + 1 with callCount>1)")

        let remainingIds = Set(afterSpeakers.map { $0.id })
        XCTAssertTrue(remainingIds.contains(profiles[0].id), "Named profile 0 should survive")
        XCTAssertTrue(remainingIds.contains(profiles[1].id), "Named profile 1 should survive")
        XCTAssertTrue(remainingIds.contains(profiles[2].id), "Profile 2 with callCount>1 should survive")
        XCTAssertFalse(remainingIds.contains(profiles[3].id), "Old unnamed weak profile 3 should be pruned")
        XCTAssertFalse(remainingIds.contains(profiles[4].id), "Old unnamed weak profile 4 should be pruned")
    }

    // MARK: - Merge Duplicates (Embedding Similarity)

    func testMergeDuplicatesMergesNearIdenticalEmbeddings() {
        let baseEmbedding = makeEmbedding(seed: 30)
        let nearDuplicate = makeNearDuplicate(of: baseEmbedding, noise: 0.01)

        let profile1 = db.addOrUpdateSpeaker(embedding: baseEmbedding)
        let profile2 = db.addOrUpdateSpeaker(embedding: nearDuplicate)

        db.setDisplayName(id: profile1.id, name: "DupTest", source: "test")

        XCTAssertEqual(db.allSpeakers().count, 2, "Should have 2 profiles before merge")

        // The near-duplicate should have high cosine similarity (> 0.6 threshold)
        let similarity = db.cosineSimilarity(
            db.l2Normalize(baseEmbedding),
            db.l2Normalize(nearDuplicate)
        )
        XCTAssertGreaterThan(similarity, 0.6, "Near-duplicate embeddings should be similar enough to merge")

        db.mergeDuplicates(threshold: 0.6)

        let remaining = db.allSpeakers()
        XCTAssertEqual(remaining.count, 1, "Should have 1 profile after merging near-duplicates")
        XCTAssertEqual(remaining.first?.displayName, "DupTest", "Merged profile should retain the display name")
    }

    // MARK: - Cosine Similarity Sanity

    func testCosineSimilarityIdenticalVectors() {
        let embedding = makeEmbedding(seed: 40)
        let normalized = db.l2Normalize(embedding)
        let similarity = db.cosineSimilarity(normalized, normalized)
        XCTAssertEqual(similarity, 1.0, accuracy: 0.001, "Identical normalized vectors should have similarity ~1.0")
    }

    func testCosineSimilarityOrthogonalVectors() {
        // Two vectors with energy in different dimensions
        var a = [Float](repeating: 0, count: 256)
        a[0] = 1.0
        var b = [Float](repeating: 0, count: 256)
        b[128] = 1.0

        let similarity = db.cosineSimilarity(a, b)
        XCTAssertEqual(similarity, 0.0, accuracy: 0.001, "Orthogonal vectors should have similarity ~0.0")
    }

    // MARK: - Full Lifecycle: Add -> Match -> Name -> Merge -> Prune

    func testFullLifecycleChain() {
        // Step 1: Add a speaker
        let embedding = makeEmbedding(seed: 50)
        let profile = db.addOrUpdateSpeaker(embedding: embedding)
        XCTAssertEqual(profile.callCount, 1)

        // Step 2: Match and update
        let match = db.matchSpeaker(embedding: embedding, threshold: 0.5)
        XCTAssertNotNil(match)
        let updated = db.addOrUpdateSpeaker(embedding: embedding, existingId: profile.id)
        XCTAssertEqual(updated.callCount, 2)

        // Step 3: Name the speaker
        db.setDisplayName(id: profile.id, name: "Eve", source: "user_manual")
        let found = db.findProfilesByName("Eve")
        XCTAssertEqual(found.count, 1)

        // Step 4: Add a duplicate and merge
        let nearDup = makeNearDuplicate(of: embedding, noise: 0.01)
        let dupProfile = db.addOrUpdateSpeaker(embedding: nearDup)
        XCTAssertEqual(db.allSpeakers().count, 2)
        db.mergeDuplicates(threshold: 0.6)
        XCTAssertEqual(db.allSpeakers().count, 1, "Duplicate should be merged")

        // Step 5: Add a weak profile and prune it
        let weakEmb = makeEmbedding(seed: 51)
        let weakProfile = db.addOrUpdateSpeaker(embedding: weakEmb)
        // Make it old
        let oldDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7200))
        db.executeSQL("UPDATE speakers SET first_seen = '\(oldDate)' WHERE id = '\(weakProfile.id.uuidString)';")
        db.pruneWeakProfiles()

        let finalSpeakers = db.allSpeakers()
        XCTAssertEqual(finalSpeakers.count, 1, "Only Eve should remain after pruning")
        XCTAssertEqual(finalSpeakers.first?.displayName, "Eve")
    }

    // MARK: - Name Variant Matching

    func testNameVariantMatchingInFindProfiles() {
        let embedding = makeEmbedding(seed: 60)
        let profile = db.addOrUpdateSpeaker(embedding: embedding)
        db.setDisplayName(id: profile.id, name: "Michael", source: "test")

        // "Mike" is a variant of "Michael"
        let results = db.findProfilesByName("Mike")
        XCTAssertEqual(results.count, 1, "Should find Michael when searching for Mike (name variant)")
        XCTAssertEqual(results.first?.id, profile.id)
    }

    // MARK: - Dispute Count

    func testDisputeCountIncrementAndReset() {
        let embedding = makeEmbedding(seed: 70)
        let profile = db.addOrUpdateSpeaker(embedding: embedding)

        // Initially 0
        XCTAssertEqual(db.getSpeaker(id: profile.id)?.disputeCount, 0)

        // Increment
        db.incrementDisputeCount(id: profile.id)
        db.incrementDisputeCount(id: profile.id)
        XCTAssertEqual(db.getSpeaker(id: profile.id)?.disputeCount, 2)

        // Reset
        db.resetDisputeCount(id: profile.id)
        XCTAssertEqual(db.getSpeaker(id: profile.id)?.disputeCount, 0)
    }
}
