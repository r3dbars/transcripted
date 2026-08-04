import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class SpeakerEmbeddingMatcherTests: XCTestCase {

    // MARK: - Test database helpers

    private func makeDatabase() -> (db: SpeakerDatabase, path: String) {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerEmbeddingMatcherTests-\(UUID().uuidString).sqlite")
            .path
        return (SpeakerDatabase(path: path), path)
    }

    /// Insert a speaker with a known embedding and return its persisted profile.
    /// `addOrUpdateSpeaker` l2-normalizes on write, so the stored vector is the
    /// unit-normalized form of the input direction — which is exactly what the
    /// cosine-similarity matcher compares against.
    @discardableResult
    private func insertSpeaker(_ db: SpeakerDatabase, embedding: [Float]) -> SpeakerProfile {
        db.addOrUpdateSpeaker(embedding: embedding)
    }

    // MARK: - matchSpeaker

    func testMatchSpeakerReturnsNilOnEmptyDatabase() {
        let (db, _) = makeDatabase()

        let result = db.matchSpeaker(embedding: [1, 0, 0], threshold: 0.6)

        XCTAssertNil(result)
    }

    func testMatchSpeakerPicksBestMatchAboveThreshold() {
        let (db, _) = makeDatabase()

        let near = insertSpeaker(db, embedding: [1, 0, 0])
        // Orthogonal speaker — cosine 0 against the query, well below threshold.
        insertSpeaker(db, embedding: [0, 1, 0])

        let result = db.matchSpeaker(embedding: [1, 0, 0], threshold: 0.6)

        XCTAssertEqual(result?.profile.id, near.id)
        XCTAssertEqual(result?.similarity ?? 0, 1.0, accuracy: 0.000_1)
    }

    func testMatchSpeakerSelectsHighestSimilarityAmongCandidates() {
        let (db, _) = makeDatabase()

        // Closer candidate (cosine ~0.99) and a farther one (cosine ~0.71),
        // both above a 0.6 threshold. Matcher must return the closer one.
        let closer = insertSpeaker(db, embedding: unitVector(cosineToXAxis: 0.99))
        insertSpeaker(db, embedding: unitVector(cosineToXAxis: 0.71))

        let result = db.matchSpeaker(embedding: [1, 0], threshold: 0.6)

        XCTAssertEqual(result?.profile.id, closer.id)
        XCTAssertEqual(result?.similarity ?? 0, 0.99, accuracy: 0.01)
    }

    func testMatchSpeakerReturnsNilWhenAllBelowThreshold() {
        let (db, _) = makeDatabase()

        // Orthogonal speaker — cosine 0 against the query.
        insertSpeaker(db, embedding: [0, 1])

        let result = db.matchSpeaker(embedding: [1, 0], threshold: 0.6)

        XCTAssertNil(result)
    }

    func testMatchSpeakerThresholdBoundaryIsInclusive() {
        let (db, _) = makeDatabase()

        // Exactly on the X axis (cosine 1.0) so the only variable is the
        // threshold comparison itself. matchSpeaker uses `>= threshold`.
        // Matured past callCount 4 so the maturity bonus (see
        // testMatchSpeakerAppliesMaturityBonusForNewProfile below) doesn't shift the
        // effective threshold away from the boundary this test is isolating.
        var speaker = insertSpeaker(db, embedding: [1, 0])
        for _ in 0..<4 {
            speaker = db.addOrUpdateSpeaker(embedding: [1, 0], existingId: speaker.id)
        }
        XCTAssertGreaterThan(speaker.callCount, 4)

        let atThreshold = db.matchSpeaker(embedding: [1, 0], threshold: 1.0)
        XCTAssertEqual(atThreshold?.profile.id, speaker.id)

        // Push a stored speaker just under the requested floor and confirm nil.
        let (db2, _) = makeDatabase()
        insertSpeaker(db2, embedding: unitVector(cosineToXAxis: 0.59))
        XCTAssertNil(db2.matchSpeaker(embedding: [1, 0], threshold: 0.6))
    }

    // MARK: - matchSpeaker maturity-bonus tiers
    //
    // `matchSpeaker` delegates to `Transcription.matchAgainstProfiles`, which raises the
    // effective threshold for immature profiles: +0.08 for callCount <= 2, +0.04 for callCount
    // 3...4 (see the `maturityBonus` switch in SpeakerMatchingService.swift). Each tier gets an
    // accept-at and a reject-just-below case so a change to either constant — or a change that
    // collapses the two tiers into one — fails a test here, not just "some bonus > 0.05".

    /// Tier 1 (callCount <= 2): effective threshold is base 0.6 + 0.08 = 0.68. A brand-new
    /// profile (callCount 1 from a single insert) at exactly that similarity must match.
    func testMatchSpeakerMaturityBonusTier1AcceptsAtEffectiveThreshold() {
        let (db, _) = makeDatabase()
        insertSpeaker(db, embedding: unitVector(cosineToXAxis: 0.68))

        XCTAssertNotNil(
            db.matchSpeaker(embedding: [1, 0], threshold: 0.6),
            "similarity 0.68 meets base threshold 0.6 plus the callCount<=2 bonus of 0.08"
        )
    }

    /// Tier 1, just below its bonus-adjusted floor: clears the bare 0.6 threshold but must
    /// still be rejected. Paired with the accept case above, this pins +0.08 exactly rather than
    /// merely confirming some positive bonus exists.
    func testMatchSpeakerMaturityBonusTier1RejectsJustBelowEffectiveThreshold() {
        let (db, _) = makeDatabase()
        insertSpeaker(db, embedding: unitVector(cosineToXAxis: 0.66))

        XCTAssertNil(
            db.matchSpeaker(embedding: [1, 0], threshold: 0.6),
            "similarity 0.66 clears the bare 0.6 threshold but not 0.6 + the 0.08 bonus"
        )
    }

    /// Tier 2 (callCount 3...4): effective threshold is base 0.6 + 0.04 = 0.64 — half the tier-1
    /// bonus, so this is the case a tier-collapse (e.g. always applying 0.08) would miss.
    /// Matured to callCount 3 by repeating the SAME embedding direction on every write, which
    /// keeps the blended average — and therefore the similarity score — unchanged while only
    /// callCount advances.
    func testMatchSpeakerMaturityBonusTier2AcceptsAtEffectiveThreshold() {
        let (db, _) = makeDatabase()
        let embedding = unitVector(cosineToXAxis: 0.64)
        var speaker = insertSpeaker(db, embedding: embedding)
        for _ in 0..<2 {
            speaker = db.addOrUpdateSpeaker(embedding: embedding, existingId: speaker.id)
        }
        XCTAssertEqual(speaker.callCount, 3)

        XCTAssertNotNil(
            db.matchSpeaker(embedding: [1, 0], threshold: 0.6),
            "similarity 0.64 meets base threshold 0.6 plus the callCount 3...4 bonus of 0.04"
        )
    }

    /// Tier 2, just below its bonus-adjusted floor.
    func testMatchSpeakerMaturityBonusTier2RejectsJustBelowEffectiveThreshold() {
        let (db, _) = makeDatabase()
        let embedding = unitVector(cosineToXAxis: 0.62)
        var speaker = insertSpeaker(db, embedding: embedding)
        for _ in 0..<2 {
            speaker = db.addOrUpdateSpeaker(embedding: embedding, existingId: speaker.id)
        }
        XCTAssertEqual(speaker.callCount, 3)

        XCTAssertNil(
            db.matchSpeaker(embedding: [1, 0], threshold: 0.6),
            "similarity 0.62 clears the bare 0.6 threshold but not 0.6 + the 0.04 bonus"
        )
    }

    // MARK: - cosineSimilarity

    func testCosineSimilarityIdenticalVectorsIsOne() {
        XCTAssertEqual(SpeakerVectorMath.cosineSimilarity([1, 2, 3], [1, 2, 3]), 1.0, accuracy: 0.000_1)
    }

    func testCosineSimilarityOrthogonalVectorsIsZero() {
        XCTAssertEqual(SpeakerVectorMath.cosineSimilarity([1, 0], [0, 1]), 0.0, accuracy: 0.000_1)
    }

    func testCosineSimilarityOppositeVectorsIsNegativeOne() {
        XCTAssertEqual(SpeakerVectorMath.cosineSimilarity([1, 0], [-1, 0]), -1.0, accuracy: 0.000_1)
    }

    func testCosineSimilarityMismatchedLengthIsZero() {
        XCTAssertEqual(SpeakerVectorMath.cosineSimilarity([1, 0, 0], [1, 0]), 0.0)
    }

    func testCosineSimilarityEmptyVectorsIsZero() {
        XCTAssertEqual(SpeakerVectorMath.cosineSimilarity([], []), 0.0)
    }

    func testCosineSimilarityZeroVectorIsZero() {
        // A zero-magnitude vector makes the denominator zero — guarded to 0.
        XCTAssertEqual(SpeakerVectorMath.cosineSimilarity([0, 0], [1, 0]), 0.0)
    }

    // MARK: - l2Normalize

    func testL2NormalizeProducesUnitVector() {
        let normalized = SpeakerVectorMath.l2Normalize([3, 4])

        XCTAssertEqual(magnitude(normalized), 1.0, accuracy: 0.000_1)
        XCTAssertEqual(normalized[0], 0.6, accuracy: 0.000_1)
        XCTAssertEqual(normalized[1], 0.8, accuracy: 0.000_1)
    }

    func testL2NormalizeLeavesAlreadyUnitVectorUnchanged() {
        let normalized = SpeakerVectorMath.l2Normalize([1, 0, 0])

        XCTAssertEqual(magnitude(normalized), 1.0, accuracy: 0.000_1)
        XCTAssertEqual(normalized, [1, 0, 0])
    }

    func testL2NormalizeNoOpsZeroVector() {
        // Zero magnitude — guarded to return the input untouched.
        XCTAssertEqual(SpeakerVectorMath.l2Normalize([0, 0, 0]), [0, 0, 0])
    }

    // MARK: - Helpers

    private func unitVector(cosineToXAxis: Float) -> [Float] {
        let y = sqrt(max(0, 1 - (cosineToXAxis * cosineToXAxis)))
        return [cosineToXAxis, y]
    }

    private func magnitude(_ vector: [Float]) -> Float {
        sqrt(vector.reduce(0) { $0 + ($1 * $1) })
    }
}
