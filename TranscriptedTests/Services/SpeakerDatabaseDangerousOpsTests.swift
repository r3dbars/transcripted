import XCTest
import SQLite3
@testable import Transcripted

@available(macOS 14.0, *)
final class SpeakerDatabaseDangerousOpsTests: XCTestCase {

    private var db: SpeakerDatabase!
    private var dbFilePath: String!

    override func setUp() {
        super.setUp()
        let tempDir = FileManager.default.temporaryDirectory
        let path = tempDir.appendingPathComponent("test_speakers_\(UUID().uuidString).sqlite")
        dbFilePath = path.path
        db = SpeakerDatabase(path: dbFilePath)
    }

    override func tearDown() {
        db = nil
        // Clean up temp DB files
        try? FileManager.default.removeItem(atPath: dbFilePath)
        try? FileManager.default.removeItem(atPath: dbFilePath + "-wal")
        try? FileManager.default.removeItem(atPath: dbFilePath + "-shm")
        super.tearDown()
    }

    // MARK: - Helpers

    /// Create a test profile with a controlled embedding
    private func createTestProfile(
        name: String? = nil,
        callCount: Int = 1,
        embedding: [Float]? = nil
    ) -> SpeakerProfile {
        let emb = embedding ?? (0..<256).map { _ in Float.random(in: -1...1) }
        var profile = db.addOrUpdateSpeaker(embedding: emb)

        // Bump call count by re-adding with the same ID
        for _ in 1..<callCount {
            profile = db.addOrUpdateSpeaker(embedding: emb, existingId: profile.id)
        }

        if let name = name {
            db.setDisplayName(id: profile.id, name: name, source: "test")
            if let updated = db.getSpeaker(id: profile.id) {
                profile = updated
            }
        }

        return profile
    }

    /// Make a profile's first_seen old by directly updating SQLite via the db handle.
    /// This backdates the profile to the given number of seconds in the past.
    private func backdateFirstSeen(profileId: UUID, secondsAgo: TimeInterval) {
        guard let dbHandle = db.db else { return }

        let oldDate = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-secondsAgo))
        let sql = "UPDATE speakers SET first_seen = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(dbHandle, sql, -1, &stmt, nil) == SQLITE_OK {
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, (oldDate as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    // MARK: - pruneWeakProfiles

    func testPruneDeletesOldUnnamedLowConfidenceSingleCall() {
        // Create a profile that meets ALL prune criteria:
        // unnamed, callCount=1, confidence=0.5, first_seen > 1 hour ago
        let profile = createTestProfile()
        backdateFirstSeen(profileId: profile.id, secondsAgo: 7200) // 2 hours ago

        db.pruneWeakProfiles()

        let remaining = db.getSpeaker(id: profile.id)
        XCTAssertNil(remaining, "Old unnamed low-confidence single-call profile should be pruned")
    }

    func testPruneKeepsNamedProfile() {
        // Named profiles should never be pruned, even if old + low confidence
        let profile = createTestProfile(name: "Alice")
        backdateFirstSeen(profileId: profile.id, secondsAgo: 7200)

        db.pruneWeakProfiles()

        let remaining = db.getSpeaker(id: profile.id)
        XCTAssertNotNil(remaining, "Named profile should NOT be pruned")
    }

    func testPruneKeepsMultiCallProfile() {
        // callCount > 1 should protect from pruning
        let profile = createTestProfile(callCount: 3)
        backdateFirstSeen(profileId: profile.id, secondsAgo: 7200)

        db.pruneWeakProfiles()

        let remaining = db.getSpeaker(id: profile.id)
        XCTAssertNotNil(remaining, "Profile with callCount > 1 should NOT be pruned")
    }

    func testPruneKeepsHighConfidenceProfile() {
        // Create profile, then bump confidence above 0.5 by updating multiple times
        let embedding = (0..<256).map { _ in Float.random(in: -1...1) }
        var profile = db.addOrUpdateSpeaker(embedding: embedding)
        // Each update adds +0.1 confidence and +1 callCount, so we need to keep callCount=1
        // Instead, directly set confidence > 0.5 via SQL
        if let dbHandle = db.db {
            let sql = "UPDATE speakers SET confidence = 0.8, call_count = 1 WHERE id = ?;"
            var stmt: OpaquePointer?
            let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            if sqlite3_prepare_v2(dbHandle, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (profile.id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        backdateFirstSeen(profileId: profile.id, secondsAgo: 7200)

        db.pruneWeakProfiles()

        let remaining = db.getSpeaker(id: profile.id)
        XCTAssertNotNil(remaining, "Profile with confidence > 0.5 should NOT be pruned")
    }

    func testPruneKeepsRecentProfile() {
        // A profile created less than 1 hour ago should NOT be pruned, even if weak
        let profile = createTestProfile()
        // Don't backdate — it was just created (recent)

        db.pruneWeakProfiles()

        let remaining = db.getSpeaker(id: profile.id)
        XCTAssertNotNil(remaining, "Recent profile (< 1 hour) should NOT be pruned")
    }

    // MARK: - mergeDuplicates

    func testMergeDuplicatesSimilarEmbeddings() {
        // Create two profiles with very similar embeddings (cosine > 0.6)
        let baseEmbedding: [Float] = (0..<256).map { _ in Float.random(in: -1...1) }
        // Slightly perturb to keep very high similarity
        let perturbedEmbedding = baseEmbedding.map { $0 + Float.random(in: -0.01...0.01) }

        let profile1 = createTestProfile(callCount: 5, embedding: baseEmbedding)
        let profile2 = createTestProfile(callCount: 2, embedding: perturbedEmbedding)

        // Verify they're actually similar enough
        let similarity = db.cosineSimilarity(
            db.l2Normalize(baseEmbedding),
            db.l2Normalize(perturbedEmbedding)
        )
        XCTAssertGreaterThan(similarity, 0.6, "Test setup: embeddings should be similar")

        db.mergeDuplicates(threshold: 0.6)

        // The one with more calls (profile1) should survive
        let survivor = db.getSpeaker(id: profile1.id)
        let absorbed = db.getSpeaker(id: profile2.id)

        XCTAssertNotNil(survivor, "Profile with higher callCount should survive merge")
        XCTAssertNil(absorbed, "Profile with lower callCount should be absorbed")
    }

    func testMergeDuplicatesKeepsDifferentEmbeddings() {
        // Create two profiles with very different embeddings (orthogonal)
        var embeddingA = [Float](repeating: 0, count: 256)
        embeddingA[0] = 1.0
        var embeddingB = [Float](repeating: 0, count: 256)
        embeddingB[1] = 1.0

        let profile1 = createTestProfile(embedding: embeddingA)
        let profile2 = createTestProfile(embedding: embeddingB)

        db.mergeDuplicates(threshold: 0.6)

        // Both should still exist (similarity is ~0, well below threshold)
        XCTAssertNotNil(db.getSpeaker(id: profile1.id), "Dissimilar profile A should remain")
        XCTAssertNotNil(db.getSpeaker(id: profile2.id), "Dissimilar profile B should remain")
    }

    // MARK: - mergeProfilesByName

    func testMergeProfilesByNameMergesSameNameProfiles() {
        // Create 3 profiles: 2 named "Alice" with different call counts, 1 unnamed
        let alice1 = createTestProfile(name: "Alice", callCount: 5)
        let alice2 = createTestProfile(name: "Alice", callCount: 2)
        let unnamed = createTestProfile()

        db.mergeProfilesByName()

        // The Alice with higher callCount should survive
        let survivingAlice = db.getSpeaker(id: alice1.id)
        let absorbedAlice = db.getSpeaker(id: alice2.id)
        let untouchedUnnamed = db.getSpeaker(id: unnamed.id)

        XCTAssertNotNil(survivingAlice, "Alice with higher callCount should survive")
        XCTAssertNil(absorbedAlice, "Alice with lower callCount should be merged away")
        XCTAssertNotNil(untouchedUnnamed, "Unnamed profile should be untouched by name-based merge")
    }

    func testMergeProfilesByNameIsCaseInsensitive() {
        // Create profiles with same name but different casing
        let upper = createTestProfile(name: "ALICE", callCount: 3)
        let lower = createTestProfile(name: "alice", callCount: 1)

        db.mergeProfilesByName()

        // The one with higher callCount should survive
        let survivor = db.getSpeaker(id: upper.id)
        let absorbed = db.getSpeaker(id: lower.id)

        XCTAssertNotNil(survivor, "Profile with higher callCount should survive case-insensitive merge")
        XCTAssertNil(absorbed, "Profile with lower callCount should be absorbed in case-insensitive merge")
    }

    func testMergeProfilesByNameNoOpWhenNoSharedNames() {
        let alice = createTestProfile(name: "Alice")
        let bob = createTestProfile(name: "Bob")
        let unnamed = createTestProfile()

        db.mergeProfilesByName()

        XCTAssertNotNil(db.getSpeaker(id: alice.id), "Alice should remain")
        XCTAssertNotNil(db.getSpeaker(id: bob.id), "Bob should remain")
        XCTAssertNotNil(db.getSpeaker(id: unnamed.id), "Unnamed should remain")
    }
}
