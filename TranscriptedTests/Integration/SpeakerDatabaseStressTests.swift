import XCTest
import Accelerate
@testable import Transcripted

/// Stress tests that exercise the speaker database under load: high speaker counts,
/// bulk matching, merge operations at scale, and mathematical correctness of embeddings.
@available(macOS 14.0, *)
final class SpeakerDatabaseStressTests: XCTestCase {

    var db: SpeakerDatabase!
    var dbPath: URL!

    override func setUp() {
        super.setUp()
        dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("stress_\(UUID().uuidString).sqlite")
        db = SpeakerDatabase(path: dbPath.path)
    }

    override func tearDown() {
        db = nil
        for ext in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath.path + ext)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    /// Generate a random 256-dim unit vector.
    private func randomUnitVector(dim: Int = 256) -> [Float] {
        var v = (0..<dim).map { _ in Float.random(in: -1...1) }
        // L2 normalize
        var norm: Float = 0
        vDSP_dotpr(v, 1, v, 1, &norm, vDSP_Length(dim))
        norm = sqrt(norm)
        guard norm > 0 else { return v }
        var divisor = norm
        vDSP_vsdiv(v, 1, &divisor, &v, 1, vDSP_Length(dim))
        return v
    }

    /// Add noise of given magnitude to a vector, then re-normalize.
    private func addNoise(to vector: [Float], magnitude: Float) -> [Float] {
        let noisy = vector.map { $0 + Float.random(in: -magnitude...magnitude) }
        // L2 normalize
        var norm: Float = 0
        vDSP_dotpr(noisy, 1, noisy, 1, &norm, vDSP_Length(noisy.count))
        norm = sqrt(norm)
        guard norm > 0 else { return noisy }
        var result = [Float](repeating: 0, count: noisy.count)
        var divisor = norm
        vDSP_vsdiv(noisy, 1, &divisor, &result, 1, vDSP_Length(noisy.count))
        return result
    }

    // MARK: - Tests

    /// Add 100 speakers with random 256-dim embeddings, then match each one by its exact
    /// embedding and verify cosine similarity > 0.99. Tests scale and match accuracy.
    func testAdd100SpeakersAndMatchAll() {
        let count = 100
        var embeddings: [[Float]] = []
        var profileIds: [UUID] = []

        let startTime = Date()

        // Insert 100 speakers
        for _ in 0..<count {
            let emb = randomUnitVector()
            embeddings.append(emb)
            let profile = db.addOrUpdateSpeaker(embedding: emb)
            profileIds.append(profile.id)
        }

        let insertTime = Date().timeIntervalSince(startTime)

        // Match each speaker by its exact embedding
        var matchSuccessCount = 0
        let matchStart = Date()

        for i in 0..<count {
            if let match = db.matchSpeaker(embedding: embeddings[i], threshold: 0.5) {
                // The stored embedding is L2-normalized by the DB, so the retrieved one
                // should have very high similarity to the original (also normalized)
                if match.similarity > 0.99 {
                    matchSuccessCount += 1
                }
            }
        }

        let matchTime = Date().timeIntervalSince(matchStart)

        XCTAssertEqual(matchSuccessCount, count,
            "All \(count) speakers should match their own embedding with similarity > 0.99, " +
            "but only \(matchSuccessCount) did")

        // Performance check: insertion + matching should complete in reasonable time
        let totalTime = insertTime + matchTime
        XCTAssertLessThan(totalTime, 30.0,
            "100 inserts + 100 matches took \(String(format: "%.2f", totalTime))s — should be under 30s")
    }

    /// Add 50 speakers where 25 pairs have very similar embeddings (noise magnitude 0.01).
    /// Call mergeDuplicates(). Verify exactly 25 remain.
    func testMergeDuplicatesWithManySimilarProfiles() {
        let pairCount = 25

        for _ in 0..<pairCount {
            let base = randomUnitVector()
            let similar = addNoise(to: base, magnitude: 0.01)

            _ = db.addOrUpdateSpeaker(embedding: base)
            _ = db.addOrUpdateSpeaker(embedding: similar)
        }

        let beforeCount = db.allSpeakers().count
        XCTAssertEqual(beforeCount, 50, "Should have 50 profiles before merge")

        db.mergeDuplicates(threshold: 0.6)

        let afterCount = db.allSpeakers().count
        XCTAssertEqual(afterCount, pairCount,
            "After merging 25 similar pairs, should have 25 profiles, got \(afterCount)")
    }

    /// Add 200 profiles. Backdate 100 of them via raw SQL so they appear as "weak"
    /// (unnamed, low confidence, old). Call pruneWeakProfiles(). Verify exactly 100 remain.
    func testPruneWeakProfilesAtScale() {
        // Add 200 speakers
        var weakIds: [UUID] = []
        var strongIds: [UUID] = []

        for i in 0..<200 {
            let emb = randomUnitVector()
            let profile = db.addOrUpdateSpeaker(embedding: emb)
            if i < 100 {
                weakIds.append(profile.id)
            } else {
                strongIds.append(profile.id)
                // Give strong profiles a name so they survive pruning
                db.setDisplayName(id: profile.id, name: "Speaker \(i)", source: "user_manual")
            }
        }

        // Backdate weak profiles to 2 hours ago via raw SQL so they pass the 1-hour cutoff
        let twoHoursAgo = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-7200))
        for weakId in weakIds {
            db.executeSQL("UPDATE speakers SET first_seen = '\(twoHoursAgo)' WHERE id = '\(weakId.uuidString)'")
        }

        let beforeCount = db.allSpeakers().count
        XCTAssertEqual(beforeCount, 200, "Should have 200 profiles before pruning")

        db.pruneWeakProfiles()

        let afterCount = db.allSpeakers().count
        XCTAssertEqual(afterCount, 100,
            "After pruning 100 weak profiles, should have 100 remaining, got \(afterCount)")

        // Verify all strong profiles survived
        for strongId in strongIds {
            let profile = db.getSpeaker(id: strongId)
            XCTAssertNotNil(profile, "Strong profile \(strongId) should survive pruning")
        }
    }

    /// Add 60 speakers with 20 unique names (3 per name on average).
    /// Call mergeProfilesByName(). Verify exactly 20 remain.
    func testMergeByNameWithManyGroups() {
        let nameCount = 20
        let profilesPerName = 3
        let names = (0..<nameCount).map { "Person \($0)" }

        for name in names {
            for _ in 0..<profilesPerName {
                let emb = randomUnitVector()
                let profile = db.addOrUpdateSpeaker(embedding: emb)
                db.setDisplayName(id: profile.id, name: name, source: "user_manual")
            }
        }

        let beforeCount = db.allSpeakers().count
        XCTAssertEqual(beforeCount, nameCount * profilesPerName,
            "Should have \(nameCount * profilesPerName) profiles before merge")

        db.mergeProfilesByName()

        let afterCount = db.allSpeakers().count
        XCTAssertEqual(afterCount, nameCount,
            "After merging by name, should have \(nameCount) profiles (one per name), got \(afterCount)")

        // Verify each name has exactly one profile
        for name in names {
            let profiles = db.findProfilesByName(name)
            XCTAssertEqual(profiles.count, 1,
                "Name '\(name)' should have exactly 1 profile after merge, got \(profiles.count)")
        }
    }

    /// Add a speaker, then update 20 times with slightly different embeddings.
    /// Verify the embedding converges toward the mean and confidence increases toward 1.0.
    func testEMABlendingConverges() {
        let baseEmbedding = randomUnitVector()
        let profile = db.addOrUpdateSpeaker(embedding: baseEmbedding)
        let profileId = profile.id

        // Track all input embeddings (including the initial one) for reference
        var allInputs: [[Float]] = [baseEmbedding]

        // Update 20 times with small perturbations
        for _ in 0..<20 {
            let perturbedEmbedding = addNoise(to: baseEmbedding, magnitude: 0.05)
            allInputs.append(perturbedEmbedding)
            _ = db.addOrUpdateSpeaker(embedding: perturbedEmbedding, existingId: profileId)
        }

        let finalProfile = db.getSpeaker(id: profileId)
        XCTAssertNotNil(finalProfile, "Profile should still exist after 20 updates")

        // Confidence should have increased: starts at 0.5, +0.1 per update, capped at 1.0
        // After 20 updates: min(0.5 + 20*0.1, 1.0) = 1.0
        XCTAssertEqual(finalProfile!.confidence, 1.0, accuracy: 0.01,
            "Confidence should converge to 1.0 after 20 updates, got \(finalProfile!.confidence)")

        // Call count should be 21 (1 initial + 20 updates)
        XCTAssertEqual(finalProfile!.callCount, 21,
            "Call count should be 21 after initial + 20 updates, got \(finalProfile!.callCount)")

        // The final embedding should still be highly similar to the base
        // (since perturbations are small, EMA with alpha=0.15 converges toward the mean)
        let similarity = db.cosineSimilarity(finalProfile!.embedding, baseEmbedding)
        XCTAssertGreaterThan(similarity, 0.90,
            "Final embedding should still be highly similar to base (>0.90), got \(similarity)")
    }

    /// Test ALL name variant pairs from the SpeakerProfileMerger's lookup table.
    /// Verify symmetry and completeness.
    func testNameVariantsExhaustive() {
        // Every pair that should be recognized as variants
        let variantPairs: [(String, String)] = [
            ("Mike", "Michael"), ("Mike", "Mikey"),
            ("Nate", "Nathan"), ("Nate", "Nathaniel"), ("Nathan", "Nathaniel"),
            ("Dave", "David"),
            ("Alex", "Alexander"), ("Alex", "Alexandra"),
            ("Dan", "Daniel"), ("Dan", "Danny"), ("Daniel", "Danny"),
            ("Matt", "Matthew"),
            ("Chris", "Christopher"), ("Chris", "Christine"), ("Chris", "Christina"),
            ("Nick", "Nicholas"), ("Nick", "Nic"),
            ("Rob", "Robert"), ("Rob", "Bob"), ("Rob", "Bobby"), ("Rob", "Robbie"),
            ("Robert", "Bob"), ("Robert", "Bobby"),
            ("Ed", "Edward"), ("Ed", "Eddie"),
            ("Joe", "Joseph"), ("Joe", "Joey"),
            ("Tom", "Thomas"), ("Tom", "Tommy"),
            ("Sam", "Samuel"), ("Sam", "Samantha"),
            ("Jen", "Jennifer"), ("Jen", "Jenny"),
            ("Will", "William"), ("Will", "Bill"), ("Will", "Billy"),
            ("William", "Bill"), ("William", "Billy"),
            ("Jim", "James"), ("Jim", "Jimmy"),
            ("Tony", "Anthony"),
            ("Steve", "Steven"), ("Steve", "Stephen"), ("Steven", "Stephen"),
            ("Ben", "Benjamin"), ("Ben", "Benny"),
            ("Andy", "Andrew"), ("Andy", "Drew"), ("Andrew", "Drew"),
            ("Marques", "Marquez"),
        ]

        var failedPairs: [(String, String)] = []

        for (a, b) in variantPairs {
            // Forward
            if !SpeakerDatabase.areNameVariants(a, b) {
                failedPairs.append((a, b))
            }
            // Symmetric (reverse)
            if !SpeakerDatabase.areNameVariants(b, a) {
                failedPairs.append((b, a))
            }
        }

        XCTAssertTrue(failedPairs.isEmpty,
            "These name variant pairs failed: \(failedPairs.map { "\($0.0) <-> \($0.1)" }.joined(separator: ", "))")

        // Self-identity: every name should be a variant of itself
        let allNames = Set(variantPairs.flatMap { [$0.0, $0.1] })
        for name in allNames {
            XCTAssertTrue(SpeakerDatabase.areNameVariants(name, name),
                "'\(name)' should be a variant of itself")
        }

        // Case insensitivity
        XCTAssertTrue(SpeakerDatabase.areNameVariants("MIKE", "michael"))
        XCTAssertTrue(SpeakerDatabase.areNameVariants("nAtE", "NATHAN"))

        // Empty strings should return false
        XCTAssertFalse(SpeakerDatabase.areNameVariants("", "Mike"))
        XCTAssertFalse(SpeakerDatabase.areNameVariants("Mike", ""))
        XCTAssertFalse(SpeakerDatabase.areNameVariants("", ""))
    }

    /// Test cosine similarity with real 256-dim vectors (unlike existing tests that use 2-4 dims).
    func testCosineSimilarityWith256DimVectors() {
        // Self-similarity should be exactly 1.0 for unit vectors
        for _ in 0..<10 {
            let v = randomUnitVector()
            let selfSim = db.cosineSimilarity(v, v)
            XCTAssertEqual(selfSim, 1.0, accuracy: 1e-5,
                "Self-similarity of a unit vector should be 1.0, got \(selfSim)")
        }

        // Orthogonal vectors should have near-zero similarity
        // Construct two orthogonal 256-dim vectors
        var v1 = [Float](repeating: 0, count: 256)
        v1[0] = 1.0  // unit vector along first axis
        var v2 = [Float](repeating: 0, count: 256)
        v2[1] = 1.0  // unit vector along second axis

        let orthSim = db.cosineSimilarity(v1, v2)
        XCTAssertEqual(orthSim, 0.0, accuracy: 1e-5,
            "Orthogonal unit vectors should have 0.0 similarity, got \(orthSim)")

        // Opposite vectors should have similarity -1.0
        let v3 = v1.map { -$0 }
        let oppSim = db.cosineSimilarity(v1, v3)
        XCTAssertEqual(oppSim, -1.0, accuracy: 1e-5,
            "Opposite vectors should have -1.0 similarity, got \(oppSim)")

        // Two random unit vectors should have similarity in (-1, 1) — not exactly 0 or 1
        let rndA = randomUnitVector()
        let rndB = randomUnitVector()
        let rndSim = db.cosineSimilarity(rndA, rndB)
        XCTAssertGreaterThan(rndSim, -1.0)
        XCTAssertLessThan(rndSim, 1.0)

        // Verify symmetry: cos(a,b) == cos(b,a)
        let simAB = db.cosineSimilarity(rndA, rndB)
        let simBA = db.cosineSimilarity(rndB, rndA)
        XCTAssertEqual(simAB, simBA, accuracy: 1e-6,
            "Cosine similarity must be symmetric")

        // Empty vectors should return 0
        let emptySim = db.cosineSimilarity([], [])
        XCTAssertEqual(emptySim, 0.0, "Empty vectors should have 0.0 similarity")

        // Mismatched dimensions should return 0
        let mismatchSim = db.cosineSimilarity([1, 0], [1, 0, 0])
        XCTAssertEqual(mismatchSim, 0.0, "Mismatched dimensions should return 0.0")

        // Known angle: cos(60 degrees) = 0.5
        // In 256-dim, create two vectors at 60 degrees apart
        var a60 = [Float](repeating: 0, count: 256)
        a60[0] = 1.0
        var b60 = [Float](repeating: 0, count: 256)
        b60[0] = cos(Float.pi / 3)  // 0.5
        b60[1] = sin(Float.pi / 3)  // ~0.866
        let sim60 = db.cosineSimilarity(a60, b60)
        XCTAssertEqual(sim60, 0.5, accuracy: 1e-4,
            "Vectors at 60 degrees should have similarity 0.5, got \(sim60)")
    }
}
