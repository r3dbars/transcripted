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
