import XCTest
import Accelerate
@testable import Transcripted

@available(macOS 14.0, *)
final class SpeakerEmbeddingMatcherTests: XCTestCase {

    private var db: SpeakerDatabase!

    override func setUp() {
        super.setUp()
        db = SpeakerDatabase.shared
    }

    override func tearDown() {
        db = nil
        super.tearDown()
    }

    // MARK: - Cosine Similarity

    func testCosineSimilarityIdenticalVectors() {
        let v: [Float] = [1.0, 0.0, 0.0, 0.0]
        let similarity = db.cosineSimilarity(v, v)
        XCTAssertEqual(similarity, 1.0, accuracy: 0.001)
    }

    func testCosineSimilarityOrthogonalVectors() {
        let a: [Float] = [1.0, 0.0, 0.0, 0.0]
        let b: [Float] = [0.0, 1.0, 0.0, 0.0]
        let similarity = db.cosineSimilarity(a, b)
        XCTAssertEqual(similarity, 0.0, accuracy: 0.001)
    }

    func testCosineSimilarityOppositeVectors() {
        let a: [Float] = [1.0, 0.0, 0.0, 0.0]
        let b: [Float] = [-1.0, 0.0, 0.0, 0.0]
        let similarity = db.cosineSimilarity(a, b)
        XCTAssertEqual(similarity, -1.0, accuracy: 0.001)
    }

    func testCosineSimilarityEmptyVectorsReturnsZero() {
        let similarity = db.cosineSimilarity([], [])
        XCTAssertEqual(similarity, 0.0)
    }

    func testCosineSimilarityMismatchedLengthsReturnsZero() {
        let a: [Float] = [1.0, 0.0]
        let b: [Float] = [1.0, 0.0, 0.0]
        let similarity = db.cosineSimilarity(a, b)
        XCTAssertEqual(similarity, 0.0)
    }

    func testCosineSimilarityZeroVectorReturnsZero() {
        let a: [Float] = [0.0, 0.0, 0.0, 0.0]
        let b: [Float] = [1.0, 0.0, 0.0, 0.0]
        let similarity = db.cosineSimilarity(a, b)
        XCTAssertEqual(similarity, 0.0)
    }

    func testCosineSimilarityPartialOverlap() {
        let a: [Float] = [1.0, 1.0, 0.0, 0.0]
        let b: [Float] = [1.0, 0.0, 0.0, 0.0]
        let similarity = db.cosineSimilarity(a, b)
        // Expected: dot(a,b) / (|a| * |b|) = 1 / (sqrt(2) * 1) ≈ 0.707
        XCTAssertEqual(similarity, 0.707, accuracy: 0.01)
    }

    func testCosineSimilarityMatchesManualCalculation() {
        let a: [Float] = [3.0, 4.0]
        let b: [Float] = [4.0, 3.0]
        // dot = 12 + 12 = 24, |a| = 5, |b| = 5, similarity = 24/25 = 0.96
        let similarity = db.cosineSimilarity(a, b)
        XCTAssertEqual(similarity, 0.96, accuracy: 0.001)
    }

    // MARK: - L2 Normalize

    func testL2NormalizeProducesUnitVector() {
        let v: [Float] = [3.0, 4.0]
        let normalized = db.l2Normalize(v)
        // Should be [0.6, 0.8]
        XCTAssertEqual(normalized[0], 0.6, accuracy: 0.001)
        XCTAssertEqual(normalized[1], 0.8, accuracy: 0.001)

        // Verify unit length
        var norm: Float = 0
        vDSP_dotpr(normalized, 1, normalized, 1, &norm, vDSP_Length(normalized.count))
        XCTAssertEqual(sqrt(norm), 1.0, accuracy: 0.001)
    }

    func testL2NormalizeZeroVectorReturnsZeroVector() {
        let v: [Float] = [0.0, 0.0, 0.0]
        let normalized = db.l2Normalize(v)
        XCTAssertEqual(normalized, v)
    }

    func testL2NormalizeAlreadyUnitVector() {
        let v: [Float] = [1.0, 0.0, 0.0, 0.0]
        let normalized = db.l2Normalize(v)
        XCTAssertEqual(normalized[0], 1.0, accuracy: 0.001)
        XCTAssertEqual(normalized[1], 0.0, accuracy: 0.001)
    }

    // MARK: - Match Speaker

    func testMatchSpeakerReturnsBestMatchAboveThreshold() {
        // Add two speakers
        let profile1 = db.addOrUpdateSpeaker(embedding: [1.0, 0.0, 0.0, 0.0], existingId: nil)
        _ = db.addOrUpdateSpeaker(embedding: [0.0, 1.0, 0.0, 0.0], existingId: nil)

        let query: [Float] = [0.95, 0.05, 0.0, 0.0] // Close to profile1
        let result = db.matchSpeaker(embedding: query, threshold: 0.5)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.profile.id, profile1.id)
    }

    func testMatchSpeakerSelectsHighestSimilarity() {
        // Add three speakers
        _ = db.addOrUpdateSpeaker(embedding: [1.0, 0.0, 0.0, 0.0], existingId: nil)
        let closest = db.addOrUpdateSpeaker(embedding: [0.9, 0.1, 0.0, 0.0], existingId: nil)
        _ = db.addOrUpdateSpeaker(embedding: [0.0, 0.0, 1.0, 0.0], existingId: nil)

        let query: [Float] = [0.85, 0.15, 0.0, 0.0]
        let result = db.matchSpeaker(embedding: query, threshold: 0.5)
        XCTAssertNotNil(result)
        // Should match the closest embedding, not just the first above threshold
        XCTAssertEqual(result?.profile.id, closest.id)
    }

    func testMatchSpeakerSimilarityInExpectedRange() {
        _ = db.addOrUpdateSpeaker(embedding: [1.0, 0.0, 0.0, 0.0], existingId: nil)

        let result = db.matchSpeaker(embedding: [1.0, 0.0, 0.0, 0.0], threshold: 0.6)
        XCTAssertNotNil(result)
        XCTAssertGreaterThanOrEqual(result!.similarity, 0.9)
        XCTAssertLessThanOrEqual(result!.similarity, 1.0)
    }
}
