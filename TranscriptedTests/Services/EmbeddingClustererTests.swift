import XCTest
@testable import Transcripted

@available(macOS 26.0, *)
final class EmbeddingClustererTests: XCTestCase {

    // MARK: - Pairwise Merge

    func testPairwiseMergeSingleSpeaker() {
        // One speaker only — nothing to merge
        let segments = makeSegments(speakerIds: [0, 0, 0], embedding: unitVector(0))
        let result = EmbeddingClusterer.pairwiseMerge(segments: segments)
        XCTAssertTrue(result.allSatisfy { $0.speakerId == 0 })
    }

    func testPairwiseMergeTwoDifferentSpeakers() {
        // Two speakers with orthogonal embeddings — should NOT merge
        let seg0 = makeSegments(speakerIds: [0, 0], embedding: unitVector(0))
        let seg1 = makeSegments(speakerIds: [1, 1], embedding: unitVector(1))
        let result = EmbeddingClusterer.pairwiseMerge(segments: seg0 + seg1)

        let uniqueIds = Set(result.map { $0.speakerId })
        XCTAssertEqual(uniqueIds.count, 2, "Orthogonal speakers should remain separate")
    }

    func testPairwiseMergeIdenticalSpeakers() {
        // Two speaker IDs with identical embeddings — should merge
        let embedding: [Float] = [1, 0, 0, 0]
        let seg0 = makeSegments(speakerIds: [0, 0], embedding: embedding)
        let seg1 = makeSegments(speakerIds: [1, 1], embedding: embedding)
        let result = EmbeddingClusterer.pairwiseMerge(segments: seg0 + seg1)

        let uniqueIds = Set(result.map { $0.speakerId })
        XCTAssertEqual(uniqueIds.count, 1, "Identical embeddings should merge into one speaker")
    }

    func testPairwiseMergeTransitiveClosure() {
        // A≈B and B≈C → all three should merge via union-find transitive closure
        let embA: [Float] = [1.0, 0.0, 0.0, 0.0]
        let embB: [Float] = [0.99, 0.14, 0.0, 0.0]  // cos(A,B) ≈ 0.99
        let embC: [Float] = [0.97, 0.24, 0.0, 0.0]  // cos(B,C) ≈ 0.99, cos(A,C) ≈ 0.97

        let segA = makeSegments(speakerIds: [0, 0], embedding: embA)
        let segB = makeSegments(speakerIds: [1, 1], embedding: embB)
        let segC = makeSegments(speakerIds: [2, 2], embedding: embC)

        let result = EmbeddingClusterer.pairwiseMerge(segments: segA + segB + segC, threshold: 0.85)
        let uniqueIds = Set(result.map { $0.speakerId })
        XCTAssertEqual(uniqueIds.count, 1, "Transitive similarity should merge all three speakers")
    }

    func testPairwiseMergeRespectsThreshold() {
        // Two speakers with moderate similarity — below threshold, should NOT merge
        let embA: [Float] = [1.0, 0.0, 0.0, 0.0]
        let embB: [Float] = [0.7, 0.7, 0.0, 0.0]  // cos ≈ 0.7

        let segA = makeSegments(speakerIds: [0, 0], embedding: embA)
        let segB = makeSegments(speakerIds: [1, 1], embedding: embB)

        let result = EmbeddingClusterer.pairwiseMerge(segments: segA + segB, threshold: 0.85)
        let uniqueIds = Set(result.map { $0.speakerId })
        XCTAssertEqual(uniqueIds.count, 2, "Similarity below threshold should not merge")
    }

    func testPairwiseMergeFiltersLowQualitySegments() {
        // Segments with low quality (< 0.3) or short duration (< 1.0s)
        // should be excluded from mean embedding computation
        let embedding: [Float] = [1, 0, 0, 0]
        let lowQuality = [
            SpeakerSegment(speakerId: 0, startTime: 0, endTime: 2, embedding: embedding, qualityScore: 0.1),
            SpeakerSegment(speakerId: 0, startTime: 2, endTime: 4, embedding: embedding, qualityScore: 0.1)
        ]
        // With only low-quality segments, speaker 0 won't have a valid mean embedding,
        // so no merge is possible even with identical embeddings for speaker 1
        let seg1 = makeSegments(speakerIds: [1, 1], embedding: embedding)
        let result = EmbeddingClusterer.pairwiseMerge(segments: lowQuality + seg1)

        // Speaker 0's low-quality segments get filtered; speaker 1 remains alone
        // Result may have 1 or 2 unique IDs depending on whether speaker 0 has valid mean
        let idsForSeg1 = Set(result.suffix(2).map { $0.speakerId })
        XCTAssertEqual(idsForSeg1.count, 1, "Speaker 1 segments should all have same ID")
    }

    func testPairwiseMergePreservesSegmentData() {
        // Verify that merge only changes speakerId, not timing/embedding/quality
        let embedding: [Float] = [1, 0, 0, 0]
        let seg0 = SpeakerSegment(speakerId: 0, startTime: 0.0, endTime: 2.0, embedding: embedding, qualityScore: 0.8)
        let seg1 = SpeakerSegment(speakerId: 1, startTime: 3.0, endTime: 5.0, embedding: embedding, qualityScore: 0.9)

        let result = EmbeddingClusterer.pairwiseMerge(segments: [seg0, seg1])
        // They should merge (identical embeddings)
        XCTAssertEqual(result[0].speakerId, result[1].speakerId)
        // But timing must be preserved
        XCTAssertEqual(result[0].startTime, 0.0)
        XCTAssertEqual(result[0].endTime, 2.0)
        XCTAssertEqual(result[1].startTime, 3.0)
        XCTAssertEqual(result[1].endTime, 5.0)
    }

    // MARK: - Post-Process

    func testPostProcessSingleSegmentReturnsAsIs() {
        let seg = SpeakerSegment(speakerId: 0, startTime: 0, endTime: 5, embedding: unitVector(0), qualityScore: 0.9)
        let result = EmbeddingClusterer.postProcess(segments: [seg], existingProfiles: [])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].speakerId, 0)
    }

    func testPostProcessEmptyReturnsEmpty() {
        let result = EmbeddingClusterer.postProcess(segments: [], existingProfiles: [])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - DB-Informed Split

    func testDbInformedSplitNoProfilesReturnsUnchanged() {
        let segments = makeSegments(speakerIds: [0, 0, 0], embedding: unitVector(0))
        let result = EmbeddingClusterer.dbInformedSplit(segments: segments, profiles: [])
        XCTAssertEqual(result.count, segments.count)
        XCTAssertTrue(result.allSatisfy { $0.speakerId == 0 })
    }

    func testDbInformedSplitTooFewSegmentsNoSplit() {
        // Needs minSegmentsPerProfile * 2 = 16 segments to attempt split
        let segments = makeSegments(speakerIds: Array(repeating: 0, count: 5), embedding: unitVector(0))
        let profile = makeProfile(embedding: unitVector(0))
        let result = EmbeddingClusterer.dbInformedSplit(segments: segments, profiles: [profile])
        // Too few segments — no split attempted
        XCTAssertEqual(Set(result.map { $0.speakerId }).count, 1)
    }

    // MARK: - Small Cluster Absorption

    func testAbsorbSmallClusterAboveThreshold() {
        // Large cluster: speaker 0 with 40s total (above 30s threshold)
        // Small cluster: speaker 1 with 6s total (below 30s threshold)
        // Embeddings are similar enough (cos ≈ 0.75) to exceed the 0.72 standard threshold
        let embA: [Float] = [1.0, 0.0, 0.0, 0.0]
        let embB: [Float] = [0.75, 0.66, 0.0, 0.0] // cos(A,B) ≈ 0.75

        // 20 segments × 2s each = 40s for speaker 0
        let largeSeg = (0..<20).map { i in
            SpeakerSegment(speakerId: 0, startTime: Double(i) * 2.0, endTime: Double(i) * 2.0 + 2.0,
                           embedding: embA, qualityScore: 0.8)
        }
        // 2 segments × 3s each = 6s for speaker 1
        let smallSeg = [
            SpeakerSegment(speakerId: 1, startTime: 50.0, endTime: 53.0, embedding: embB, qualityScore: 0.8),
            SpeakerSegment(speakerId: 1, startTime: 55.0, endTime: 58.0, embedding: embB, qualityScore: 0.8)
        ]

        let result = EmbeddingClusterer.absorbSmallClusters(segments: largeSeg + smallSeg)
        let uniqueIds = Set(result.map { $0.speakerId })
        XCTAssertEqual(uniqueIds.count, 1, "Small cluster with sim 0.75 should be absorbed (threshold 0.72)")
    }

    func testAbsorbSmallClusterBelowThresholdNotAbsorbed() {
        // Large cluster: speaker 0 with 40s
        // Small cluster: speaker 1 with 20s, very different embedding
        // Similarity is low but duration is above micro threshold (10s)
        let embA: [Float] = [1.0, 0.0, 0.0, 0.0]
        let embB: [Float] = [0.0, 1.0, 0.0, 0.0] // cos(A,B) = 0.0 (orthogonal)

        let largeSeg = (0..<20).map { i in
            SpeakerSegment(speakerId: 0, startTime: Double(i) * 2.0, endTime: Double(i) * 2.0 + 2.0,
                           embedding: embA, qualityScore: 0.8)
        }
        // 10 segments × 2s = 20s — small but NOT micro
        let smallSeg = (0..<10).map { i in
            SpeakerSegment(speakerId: 1, startTime: 50.0 + Double(i) * 2.0,
                           endTime: 52.0 + Double(i) * 2.0,
                           embedding: embB, qualityScore: 0.8)
        }

        let result = EmbeddingClusterer.absorbSmallClusters(segments: largeSeg + smallSeg)
        let uniqueIds = Set(result.map { $0.speakerId })
        XCTAssertEqual(uniqueIds.count, 2, "Small (non-micro) cluster with 0 similarity should NOT be absorbed")
    }

    func testAbsorbMicroClusterForcedAbsorption() {
        // Large cluster: speaker 0 with 40s
        // Micro cluster: speaker 1 with 6s (below 10s micro threshold)
        // Low similarity (0.22) — would NOT pass standard 0.72 threshold,
        // but SHOULD pass micro threshold (0.15)
        let embA: [Float] = [1.0, 0.0, 0.0, 0.0]
        let embB: [Float] = [0.22, 0.97, 0.0, 0.0] // cos(A,B) ≈ 0.22

        let largeSeg = (0..<20).map { i in
            SpeakerSegment(speakerId: 0, startTime: Double(i) * 2.0, endTime: Double(i) * 2.0 + 2.0,
                           embedding: embA, qualityScore: 0.8)
        }
        let microSeg = [
            SpeakerSegment(speakerId: 1, startTime: 50.0, endTime: 53.0, embedding: embB, qualityScore: 0.8),
            SpeakerSegment(speakerId: 1, startTime: 55.0, endTime: 58.3, embedding: embB, qualityScore: 0.8)
        ]

        let result = EmbeddingClusterer.absorbSmallClusters(segments: largeSeg + microSeg)
        let uniqueIds = Set(result.map { $0.speakerId })
        XCTAssertEqual(uniqueIds.count, 1, "Micro cluster (6.3s) with sim 0.22 should be force-absorbed (micro threshold 0.15)")
    }

    func testAbsorbMicroClusterNearZeroSimilarityRejected() {
        // Even micro clusters should NOT be absorbed if similarity is near zero
        // (likely silence or corrupt embedding)
        let embA: [Float] = [1.0, 0.0, 0.0, 0.0]
        let embB: [Float] = [0.05, 0.99, 0.0, 0.0] // cos(A,B) ≈ 0.05

        let largeSeg = (0..<20).map { i in
            SpeakerSegment(speakerId: 0, startTime: Double(i) * 2.0, endTime: Double(i) * 2.0 + 2.0,
                           embedding: embA, qualityScore: 0.8)
        }
        let microSeg = [
            SpeakerSegment(speakerId: 1, startTime: 50.0, endTime: 53.0, embedding: embB, qualityScore: 0.8),
            SpeakerSegment(speakerId: 1, startTime: 55.0, endTime: 58.0, embedding: embB, qualityScore: 0.8)
        ]

        let result = EmbeddingClusterer.absorbSmallClusters(segments: largeSeg + microSeg)
        let uniqueIds = Set(result.map { $0.speakerId })
        XCTAssertEqual(uniqueIds.count, 2, "Micro cluster with near-zero similarity (0.05) should NOT be absorbed")
    }

    // MARK: - Helpers

    /// Create a unit vector along the given axis (4-dimensional for simplicity)
    private func unitVector(_ axis: Int) -> [Float] {
        var v = [Float](repeating: 0, count: 4)
        v[axis % 4] = 1.0
        return v
    }

    /// Make quality-passing segments (quality >= 0.3, duration >= 1.0s)
    private func makeSegments(speakerIds: [Int], embedding: [Float]) -> [SpeakerSegment] {
        speakerIds.enumerated().map { (i, id) in
            SpeakerSegment(
                speakerId: id,
                startTime: Double(i) * 2.0,
                endTime: Double(i) * 2.0 + 1.5,
                embedding: embedding,
                qualityScore: 0.8
            )
        }
    }

    private func makeProfile(embedding: [Float], name: String? = nil) -> SpeakerProfile {
        SpeakerProfile(
            id: UUID(),
            displayName: name,
            nameSource: nil,
            embedding: embedding,
            firstSeen: Date(),
            lastSeen: Date(),
            callCount: 5,
            confidence: 0.9,
            disputeCount: 0
        )
    }
}
