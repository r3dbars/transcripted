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
        let speaker = insertSpeaker(db, embedding: [1, 0])

        let atThreshold = db.matchSpeaker(embedding: [1, 0], threshold: 1.0)
        XCTAssertEqual(atThreshold?.profile.id, speaker.id)

        // Push a stored speaker just under the requested floor and confirm nil.
        let (db2, _) = makeDatabase()
        insertSpeaker(db2, embedding: unitVector(cosineToXAxis: 0.59))
        XCTAssertNil(db2.matchSpeaker(embedding: [1, 0], threshold: 0.6))
    }

    // MARK: - cosineSimilarity

    func testCosineSimilarityIdenticalVectorsIsOne() {
        let (db, _) = makeDatabase()
        XCTAssertEqual(db.cosineSimilarity([1, 2, 3], [1, 2, 3]), 1.0, accuracy: 0.000_1)
    }

    func testCosineSimilarityOrthogonalVectorsIsZero() {
        let (db, _) = makeDatabase()
        XCTAssertEqual(db.cosineSimilarity([1, 0], [0, 1]), 0.0, accuracy: 0.000_1)
    }

    func testCosineSimilarityOppositeVectorsIsNegativeOne() {
        let (db, _) = makeDatabase()
        XCTAssertEqual(db.cosineSimilarity([1, 0], [-1, 0]), -1.0, accuracy: 0.000_1)
    }

    func testCosineSimilarityMismatchedLengthIsZero() {
        let (db, _) = makeDatabase()
        XCTAssertEqual(db.cosineSimilarity([1, 0, 0], [1, 0]), 0.0)
    }

    func testCosineSimilarityEmptyVectorsIsZero() {
        let (db, _) = makeDatabase()
        XCTAssertEqual(db.cosineSimilarity([], []), 0.0)
    }

    func testCosineSimilarityZeroVectorIsZero() {
        let (db, _) = makeDatabase()
        // A zero-magnitude vector makes the denominator zero — guarded to 0.
        XCTAssertEqual(db.cosineSimilarity([0, 0], [1, 0]), 0.0)
    }

    // MARK: - l2Normalize

    func testL2NormalizeProducesUnitVector() {
        let (db, _) = makeDatabase()
        let normalized = db.l2Normalize([3, 4])

        XCTAssertEqual(magnitude(normalized), 1.0, accuracy: 0.000_1)
        XCTAssertEqual(normalized[0], 0.6, accuracy: 0.000_1)
        XCTAssertEqual(normalized[1], 0.8, accuracy: 0.000_1)
    }

    func testL2NormalizeLeavesAlreadyUnitVectorUnchanged() {
        let (db, _) = makeDatabase()
        let normalized = db.l2Normalize([1, 0, 0])

        XCTAssertEqual(magnitude(normalized), 1.0, accuracy: 0.000_1)
        XCTAssertEqual(normalized, [1, 0, 0])
    }

    func testL2NormalizeNoOpsZeroVector() {
        let (db, _) = makeDatabase()
        // Zero magnitude — guarded to return the input untouched.
        XCTAssertEqual(db.l2Normalize([0, 0, 0]), [0, 0, 0])
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
