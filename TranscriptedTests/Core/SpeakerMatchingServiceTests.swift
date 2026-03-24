import XCTest
@testable import Transcripted

@available(macOS 26.0, *)
final class SpeakerMatchingServiceTests: XCTestCase {

    // MARK: - Helpers

    private func l2Norm(_ v: [Float]) -> Float {
        sqrt(v.map { $0 * $0 }.reduce(0, +))
    }

    /// Returns an L2-normalized version of the input vector.
    private func normalized(_ v: [Float]) -> [Float] {
        let norm = l2Norm(v)
        guard norm > 0 else { return v }
        return v.map { $0 / norm }
    }

    // MARK: - computeWeightedMeanEmbedding

    func testWeightedMeanEmptyReturnsEmpty() {
        let result = Transcription.computeWeightedMeanEmbedding([], weights: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testWeightedMeanSingleEmbedding() {
        let emb: [Float] = [3.0, 4.0, 0.0]
        let result = Transcription.computeWeightedMeanEmbedding([emb], weights: [1.0])
        // Single embedding with weight -> weighted sum / totalWeight = emb itself, then L2 normalized
        let expected = normalized(emb)
        XCTAssertEqual(result.count, expected.count)
        for i in 0..<result.count {
            XCTAssertEqual(result[i], expected[i], accuracy: 0.001)
        }
    }

    func testWeightedMeanIdenticalEqualWeights() {
        let emb: [Float] = [0.6, 0.8, 0.0]
        let result = Transcription.computeWeightedMeanEmbedding([emb, emb, emb], weights: [1.0, 1.0, 1.0])
        // Identical embeddings with equal weights -> same direction, normalized
        let expected = normalized(emb)
        XCTAssertEqual(result.count, expected.count)
        for i in 0..<result.count {
            XCTAssertEqual(result[i], expected[i], accuracy: 0.001)
        }
    }

    func testWeightedMeanDifferentEqualWeights() {
        let a: [Float] = [1.0, 0.0, 0.0, 0.0]
        let b: [Float] = [0.0, 1.0, 0.0, 0.0]
        let result = Transcription.computeWeightedMeanEmbedding([a, b], weights: [1.0, 1.0])
        // Equal weights -> midpoint [0.5, 0.5, 0, 0], then normalized
        let expected = normalized([0.5, 0.5, 0.0, 0.0])
        XCTAssertEqual(result.count, expected.count)
        for i in 0..<result.count {
            XCTAssertEqual(result[i], expected[i], accuracy: 0.001)
        }
    }

    func testWeightedMeanAsymmetricWeights() {
        let a: [Float] = [1.0, 0.0, 0.0]
        let b: [Float] = [0.0, 1.0, 0.0]
        // Weight a heavily: 9.0 vs 1.0
        let result = Transcription.computeWeightedMeanEmbedding([a, b], weights: [9.0, 1.0])
        // Weighted sum = [9, 1, 0] / 10 = [0.9, 0.1, 0], normalized
        let weightedMean: [Float] = [0.9, 0.1, 0.0]
        let expected = normalized(weightedMean)
        XCTAssertEqual(result.count, expected.count)
        for i in 0..<result.count {
            XCTAssertEqual(result[i], expected[i], accuracy: 0.001)
        }
        // The result should be biased toward a (the [1,0,0] direction)
        XCTAssertGreaterThan(result[0], result[1])
    }

    func testWeightedMeanAllZeroWeightsFallback() {
        let a: [Float] = [1.0, 0.0, 0.0]
        let b: [Float] = [0.0, 1.0, 0.0]
        // All zero weights -> totalWeight = 0 -> falls back to computeMeanEmbedding
        let result = Transcription.computeWeightedMeanEmbedding([a, b], weights: [0.0, 0.0])
        let unweighted = Transcription.computeMeanEmbedding([a, b])
        XCTAssertEqual(result.count, unweighted.count)
        for i in 0..<result.count {
            XCTAssertEqual(result[i], unweighted[i], accuracy: 0.001)
        }
    }

    func testWeightedMeanCountMismatchFallback() {
        let a: [Float] = [1.0, 0.0, 0.0]
        let b: [Float] = [0.0, 1.0, 0.0]
        // weights.count (3) != embeddings.count (2) -> falls back to computeMeanEmbedding
        let result = Transcription.computeWeightedMeanEmbedding([a, b], weights: [1.0, 1.0, 1.0])
        let unweighted = Transcription.computeMeanEmbedding([a, b])
        XCTAssertEqual(result.count, unweighted.count)
        for i in 0..<result.count {
            XCTAssertEqual(result[i], unweighted[i], accuracy: 0.001)
        }
    }

    func testWeightedMeanResultIsNormalized() {
        let embeddings: [[Float]] = [
            [3.0, 4.0, 0.0],
            [0.0, 5.0, 12.0],
            [1.0, 1.0, 1.0]
        ]
        let weights: [Float] = [2.0, 0.5, 1.5]
        let result = Transcription.computeWeightedMeanEmbedding(embeddings, weights: weights)
        XCTAssertFalse(result.isEmpty)
        let norm = l2Norm(result)
        XCTAssertEqual(norm, 1.0, accuracy: 0.001)
    }

    func testWeightedMeanThreeEmbeddingsMixedWeights() {
        let a: [Float] = [1.0, 0.0, 0.0]
        let b: [Float] = [0.0, 1.0, 0.0]
        let c: [Float] = [0.0, 0.0, 1.0]
        let weights: [Float] = [1.0, 0.3, 1.0]
        let result = Transcription.computeWeightedMeanEmbedding([a, b, c], weights: weights)
        // Weighted sum = [1.0, 0.3, 1.0] / 2.3 -> normalized
        let totalWeight: Float = 2.3
        let weightedMean: [Float] = [1.0 / totalWeight, 0.3 / totalWeight, 1.0 / totalWeight]
        let expected = normalized(weightedMean)
        XCTAssertEqual(result.count, 3)
        for i in 0..<result.count {
            XCTAssertEqual(result[i], expected[i], accuracy: 0.001)
        }
        // Dimensions 0 and 2 should be equal (same weight * same magnitude input)
        XCTAssertEqual(result[0], result[2], accuracy: 0.001)
        // Dimension 1 should be smaller
        XCTAssertLessThan(result[1], result[0])
    }

    func testWeightedMeanSingleZeroWeightAmongValid() {
        let a: [Float] = [1.0, 0.0, 0.0]
        let b: [Float] = [0.0, 1.0, 0.0]
        let c: [Float] = [0.0, 0.0, 1.0]
        // b has zero weight -> effectively ignored in weighted sum
        let result = Transcription.computeWeightedMeanEmbedding([a, b, c], weights: [1.0, 0.0, 1.0])
        // Weighted sum = [1, 0, 1] / 2 = [0.5, 0, 0.5] -> normalized
        let expected = normalized([0.5, 0.0, 0.5])
        XCTAssertEqual(result.count, 3)
        for i in 0..<result.count {
            XCTAssertEqual(result[i], expected[i], accuracy: 0.001)
        }
        // b's dimension should be zero since its weight was zero
        XCTAssertEqual(result[1], 0.0, accuracy: 0.001)
    }

    // MARK: - computeMeanEmbedding

    func testMeanEmptyReturnsEmpty() {
        let result = Transcription.computeMeanEmbedding([])
        XCTAssertTrue(result.isEmpty)
    }

    func testMeanSingleReturnsAsIs() {
        // Single embedding returns first directly (not re-normalized)
        let emb: [Float] = [3.0, 4.0, 0.0]
        let result = Transcription.computeMeanEmbedding([emb])
        // Code returns `first` directly, so should be identical
        XCTAssertEqual(result, emb)
    }

    func testMeanIdenticalReturnsSame() {
        let emb: [Float] = [0.6, 0.8, 0.0]
        let result = Transcription.computeMeanEmbedding([emb, emb, emb])
        // Mean of identical = same direction, then L2 normalized
        let expected = normalized(emb)
        XCTAssertEqual(result.count, expected.count)
        for i in 0..<result.count {
            XCTAssertEqual(result[i], expected[i], accuracy: 0.001)
        }
    }

    func testMeanOrthogonalReturnsNormalizedMidpoint() {
        let a: [Float] = [1.0, 0.0, 0.0, 0.0]
        let b: [Float] = [0.0, 1.0, 0.0, 0.0]
        let result = Transcription.computeMeanEmbedding([a, b])
        // Mean = [0.5, 0.5, 0, 0], then normalized -> [1/sqrt(2), 1/sqrt(2), 0, 0]
        let invSqrt2 = Float(1.0 / sqrt(2.0))
        XCTAssertEqual(result.count, 4)
        XCTAssertEqual(result[0], invSqrt2, accuracy: 0.001)
        XCTAssertEqual(result[1], invSqrt2, accuracy: 0.001)
        XCTAssertEqual(result[2], 0.0, accuracy: 0.001)
        XCTAssertEqual(result[3], 0.0, accuracy: 0.001)
    }

    func testMeanResultIsL2Normalized() {
        let embeddings: [[Float]] = [
            [3.0, 4.0],
            [1.0, 0.0]
        ]
        let result = Transcription.computeMeanEmbedding(embeddings)
        let norm = l2Norm(result)
        XCTAssertEqual(norm, 1.0, accuracy: 0.001)
    }

    func testMeanManyEmbeddings() {
        // 10 embeddings, each a unit basis vector in a 10-dim space
        var embeddings: [[Float]] = []
        for i in 0..<10 {
            var emb = [Float](repeating: 0.0, count: 10)
            emb[i] = 1.0
            embeddings.append(emb)
        }
        let result = Transcription.computeMeanEmbedding(embeddings)
        // Mean = [0.1, 0.1, ..., 0.1], then L2 normalized
        // All components should be equal
        XCTAssertEqual(result.count, 10)
        let expectedComponent = normalized([Float](repeating: 0.1, count: 10))[0]
        for i in 0..<10 {
            XCTAssertEqual(result[i], expectedComponent, accuracy: 0.001)
        }
        // L2 norm should be 1.0
        let norm = l2Norm(result)
        XCTAssertEqual(norm, 1.0, accuracy: 0.001)
    }

    // MARK: - matchAgainstProfiles

    func testMatchEmptyProfilesReturnsNil() {
        let embedding: [Float] = [1.0, 0.0, 0.0, 0.0]
        let result = Transcription.matchAgainstProfiles(embedding, profiles: [], threshold: 0.5)
        XCTAssertNil(result)
    }

    func testMatchEmptyEmbeddingReturnsNil() {
        let profile = SpeakerProfile.mock(embedding: [1.0, 0.0, 0.0, 0.0])
        let result = Transcription.matchAgainstProfiles([], profiles: [profile], threshold: 0.5)
        XCTAssertNil(result)
    }

    func testMatchSingleProfileAboveThreshold() {
        let profileId = UUID()
        let profile = SpeakerProfile.mock(id: profileId, embedding: [1.0, 0.0, 0.0, 0.0])
        let embedding: [Float] = [0.95, 0.05, 0.0, 0.0]
        let result = Transcription.matchAgainstProfiles(embedding, profiles: [profile], threshold: 0.5)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.profileId, profileId)
        XCTAssertGreaterThanOrEqual(result!.similarity, 0.5)
        // Similarity should be close to 1.0 since vectors are nearly aligned
        XCTAssertGreaterThan(result!.similarity, 0.9)
    }

    func testMatchSingleProfileBelowThreshold() {
        let profile = SpeakerProfile.mock(embedding: [1.0, 0.0, 0.0, 0.0])
        // Orthogonal embedding -> cosine similarity = 0.0
        let embedding: [Float] = [0.0, 1.0, 0.0, 0.0]
        let result = Transcription.matchAgainstProfiles(embedding, profiles: [profile], threshold: 0.5)
        XCTAssertNil(result)
    }

    func testMatchMultipleProfilesReturnsBest() {
        let idA = UUID()
        let idB = UUID()
        let idC = UUID()
        let profileA = SpeakerProfile.mock(id: idA, embedding: [1.0, 0.0, 0.0, 0.0])
        let profileB = SpeakerProfile.mock(id: idB, embedding: [0.9, 0.44, 0.0, 0.0]) // somewhat aligned
        let profileC = SpeakerProfile.mock(id: idC, embedding: [0.0, 1.0, 0.0, 0.0]) // orthogonal

        // Embedding most similar to profileA
        let embedding: [Float] = [0.98, 0.02, 0.0, 0.0]
        let result = Transcription.matchAgainstProfiles(
            embedding, profiles: [profileA, profileB, profileC], threshold: 0.5
        )
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.profileId, idA)

        // Verify it's actually the highest similarity
        let simA = Transcription.cosineSimilarityStatic(embedding, profileA.embedding)
        let simB = Transcription.cosineSimilarityStatic(embedding, profileB.embedding)
        let simC = Transcription.cosineSimilarityStatic(embedding, profileC.embedding)
        XCTAssertEqual(result!.similarity, simA, accuracy: 0.001)
        XCTAssertGreaterThan(simA, simB)
        XCTAssertGreaterThan(simA, simC)
    }

    func testMatchAllBelowThreshold() {
        let profileA = SpeakerProfile.mock(embedding: [1.0, 0.0, 0.0, 0.0])
        let profileB = SpeakerProfile.mock(embedding: [0.0, 1.0, 0.0, 0.0])
        // Embedding in a completely different direction
        let embedding: [Float] = [0.0, 0.0, 0.0, 1.0]
        let result = Transcription.matchAgainstProfiles(
            embedding, profiles: [profileA, profileB], threshold: 0.5
        )
        XCTAssertNil(result)
    }

    func testMatchThresholdBoundaryIncluded() {
        let profileId = UUID()
        // Use normalized vectors for predictable cosine similarity
        let profileEmb = normalized([1.0, 1.0, 0.0, 0.0])
        let profile = SpeakerProfile.mock(id: profileId, embedding: profileEmb)

        // The embedding is the same -> cosine similarity = 1.0
        // Set threshold to exactly 1.0 -> should still match (>= check)
        let embedding = profileEmb
        let result = Transcription.matchAgainstProfiles(
            embedding, profiles: [profile], threshold: 1.0
        )
        XCTAssertNotNil(result, "Similarity exactly at threshold should match (>= check)")
        XCTAssertEqual(result?.profileId, profileId)
        XCTAssertEqual(result!.similarity, 1.0, accuracy: 0.001)
    }

    func testMatchDimensionMismatchSkipped() {
        let goodId = UUID()
        let badId = UUID()
        // Profile with wrong dimension (3 instead of 4)
        let badProfile = SpeakerProfile.mock(id: badId, embedding: [1.0, 0.0, 0.0])
        // Profile with correct dimension
        let goodProfile = SpeakerProfile.mock(id: goodId, embedding: [1.0, 0.0, 0.0, 0.0])

        let embedding: [Float] = [1.0, 0.0, 0.0, 0.0]
        let result = Transcription.matchAgainstProfiles(
            embedding, profiles: [badProfile, goodProfile], threshold: 0.5
        )
        XCTAssertNotNil(result)
        // Should match the good profile, not the dimension-mismatched one
        XCTAssertEqual(result?.profileId, goodId)
    }

    // MARK: - cosineSimilarityStatic

    func testCosineIdentical() {
        let v: [Float] = [1.0, 2.0, 3.0, 4.0]
        let result = Transcription.cosineSimilarityStatic(v, v)
        XCTAssertEqual(result, 1.0, accuracy: 0.001)
    }

    func testCosineOpposite() {
        let a: [Float] = [1.0, 2.0, 3.0]
        let b: [Float] = [-1.0, -2.0, -3.0]
        let result = Transcription.cosineSimilarityStatic(a, b)
        XCTAssertEqual(result, -1.0, accuracy: 0.001)
    }

    func testCosineOrthogonal() {
        let a: [Float] = [1.0, 0.0, 0.0]
        let b: [Float] = [0.0, 1.0, 0.0]
        let result = Transcription.cosineSimilarityStatic(a, b)
        XCTAssertEqual(result, 0.0, accuracy: 0.001)
    }

    func testCosineEmpty() {
        let result = Transcription.cosineSimilarityStatic([], [])
        XCTAssertEqual(result, 0.0)
    }

    func testCosineDifferentLengths() {
        let a: [Float] = [1.0, 0.0]
        let b: [Float] = [1.0, 0.0, 0.0]
        let result = Transcription.cosineSimilarityStatic(a, b)
        XCTAssertEqual(result, 0.0)
    }
}
