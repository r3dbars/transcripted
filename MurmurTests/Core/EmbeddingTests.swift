import XCTest
@testable import Transcripted

@available(macOS 26.0, *)
final class EmbeddingTests: XCTestCase {

    // MARK: - Cosine Similarity

    func testCosineSimilarityIdenticalVectors() {
        let v = [Float](repeating: 1.0, count: 256)
        let similarity = Transcription.cosineSimilarityStatic(v, v)
        XCTAssertEqual(similarity, 1.0, accuracy: 0.001)
    }

    func testCosineSimilarityOppositeVectors() {
        let a: [Float] = [1.0, 0.0, 0.0]
        let b: [Float] = [-1.0, 0.0, 0.0]
        let similarity = Transcription.cosineSimilarityStatic(a, b)
        XCTAssertEqual(similarity, -1.0, accuracy: 0.001)
    }

    func testCosineSimilarityOrthogonalVectors() {
        let a: [Float] = [1.0, 0.0, 0.0]
        let b: [Float] = [0.0, 1.0, 0.0]
        let similarity = Transcription.cosineSimilarityStatic(a, b)
        XCTAssertEqual(similarity, 0.0, accuracy: 0.001)
    }

    func testCosineSimilarityEmptyVectors() {
        let similarity = Transcription.cosineSimilarityStatic([], [])
        XCTAssertEqual(similarity, 0.0)
    }

    func testCosineSimilarityDifferentLengths() {
        let a: [Float] = [1.0, 0.0]
        let b: [Float] = [1.0, 0.0, 0.0]
        let similarity = Transcription.cosineSimilarityStatic(a, b)
        XCTAssertEqual(similarity, 0.0) // Different lengths → 0
    }

    func testCosineSimilarityZeroVector() {
        let a: [Float] = [0.0, 0.0, 0.0]
        let b: [Float] = [1.0, 0.0, 0.0]
        let similarity = Transcription.cosineSimilarityStatic(a, b)
        XCTAssertEqual(similarity, 0.0) // Zero denominator → 0
    }

    // MARK: - Mean Embedding

    func testMeanEmbeddingSingleVector() {
        let input: [[Float]] = [[1.0, 2.0, 3.0]]
        let mean = Transcription.computeMeanEmbedding(input)
        XCTAssertEqual(mean, [1.0, 2.0, 3.0])
    }

    func testMeanEmbeddingEmpty() {
        let mean = Transcription.computeMeanEmbedding([])
        XCTAssertTrue(mean.isEmpty)
    }

    func testMeanEmbeddingAveragesCorrectly() {
        let input: [[Float]] = [
            [2.0, 0.0, 0.0],
            [0.0, 2.0, 0.0]
        ]
        let mean = Transcription.computeMeanEmbedding(input)
        // Mean of [2,0,0] and [0,2,0] = [1,1,0], then L2 normalized
        XCTAssertEqual(mean.count, 3)
        // After L2 normalization: [1,1,0] / sqrt(2) ≈ [0.707, 0.707, 0]
        XCTAssertEqual(mean[0], mean[1], accuracy: 0.001) // symmetric
        XCTAssertEqual(mean[2], 0.0, accuracy: 0.001)
    }

    func testMeanEmbeddingIsNormalized() {
        let input: [[Float]] = [
            [3.0, 4.0],
            [1.0, 0.0]
        ]
        let mean = Transcription.computeMeanEmbedding(input)
        // Check L2 norm ≈ 1.0
        let norm = sqrt(mean.reduce(0) { $0 + $1 * $1 })
        XCTAssertEqual(norm, 1.0, accuracy: 0.001)
    }

    // MARK: - SpeakerMapping display name

    func testSpeakerMappingWithName() {
        let mapping = SpeakerMapping(speakerId: "0", identifiedName: "Alice", confidence: .high)
        XCTAssertEqual(mapping.displayName, "Alice")
    }

    func testSpeakerMappingMediumConfidence() {
        let mapping = SpeakerMapping(speakerId: "0", identifiedName: "Alice", confidence: .medium)
        XCTAssertEqual(mapping.displayName, "Alice?")
    }

    func testSpeakerMappingNoName() {
        let mapping = SpeakerMapping(speakerId: "2")
        XCTAssertEqual(mapping.displayName, "Speaker 2")
    }

    func testSpeakerMappingHighConfidenceNoQuestionMark() {
        let mapping = SpeakerMapping(speakerId: "1", identifiedName: "Bob", confidence: .high)
        XCTAssertFalse(mapping.displayName.contains("?"))
    }
}
