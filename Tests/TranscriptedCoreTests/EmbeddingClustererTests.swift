import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class EmbeddingClustererTests: XCTestCase {

    func testPairwiseMergeHandlesTransitiveSpeakerMatches() {
        let merged = EmbeddingClusterer.pairwiseMerge(
            segments: [
                segment(speakerId: 1, startTime: 0, endTime: 3, embedding: [1.0, 0.0]),
                segment(speakerId: 2, startTime: 3, endTime: 6, embedding: unitVector(cosineToXAxis: 0.995)),
                segment(speakerId: 3, startTime: 6, endTime: 9, embedding: unitVector(cosineToXAxis: 0.98)),
            ],
            threshold: 0.99
        )

        XCTAssertEqual(Set(merged.map(\.speakerId)), [1])
    }

    func testOfflinePostProcessSkipsTransitivePairwiseCollapse() {
        let segments = [
            segment(speakerId: 1, startTime: 0, endTime: 3, embedding: unitVector(degrees: 0)),
            segment(speakerId: 2, startTime: 3, endTime: 6, embedding: unitVector(degrees: 30)),
            segment(speakerId: 3, startTime: 6, endTime: 9, embedding: unitVector(degrees: 60)),
            segment(speakerId: 4, startTime: 9, endTime: 12, embedding: unitVector(degrees: 90)),
            segment(speakerId: 5, startTime: 12, endTime: 15, embedding: unitVector(degrees: 120)),
            segment(speakerId: 6, startTime: 15, endTime: 18, embedding: unitVector(degrees: 150)),
        ]

        XCTAssertEqual(
            Set(EmbeddingClusterer.pairwiseMerge(segments: segments, threshold: 0.78).map(\.speakerId)).count,
            1,
            "Transitive pairwise merge reproduces the reported multi-speaker collapse risk"
        )

        let withoutPairwise = EmbeddingClusterer.postProcess(
            segments: segments,
            existingProfiles: [],
            pairwiseMergeThreshold: nil
        )

        XCTAssertEqual(Set(withoutPairwise.map(\.speakerId)).count, 6)
    }

    func testPostProcessStillAbsorbsSmallClustersWhenPairwiseMergeIsSkipped() {
        let processed = EmbeddingClusterer.postProcess(
            segments: [
                segment(speakerId: 1, startTime: 0, endTime: 40, embedding: [1.0, 0.0]),
                segment(speakerId: 2, startTime: 40, endTime: 44, embedding: unitVector(cosineToXAxis: 0.95)),
                segment(speakerId: 3, startTime: 44, endTime: 84, embedding: [0.0, 1.0]),
            ],
            existingProfiles: [],
            pairwiseMergeThreshold: nil
        )

        XCTAssertEqual(Set(processed.map(\.speakerId)), [1, 3])
    }

    func testPostProcessStillRunsDbInformedSplitWhenPairwiseMergeIsSkipped() {
        let profileA = speakerProfile(id: UUID(), embedding: [1.0, 0.0], name: "Alex")
        let profileB = speakerProfile(id: UUID(), embedding: [0.0, 1.0], name: "Blair")
        var segments: [SpeakerSegment] = []
        for index in 0..<8 {
            segments.append(segment(speakerId: 1, startTime: Double(index), endTime: Double(index + 1), embedding: [1.0, 0.0]))
        }
        for index in 8..<16 {
            segments.append(segment(speakerId: 1, startTime: Double(index), endTime: Double(index + 1), embedding: [0.0, 1.0]))
        }

        let processed = EmbeddingClusterer.postProcess(
            segments: segments,
            existingProfiles: [profileA, profileB],
            pairwiseMergeThreshold: nil
        )

        XCTAssertEqual(Set(processed.map { $0.speakerId }).count, 2)
    }

    func testAbsorbSmallClustersPreservesAtLeastTwoSpeakers() {
        let protected = EmbeddingClusterer.absorbSmallClusters(
            segments: [
                segment(speakerId: 1, startTime: 0, endTime: 20, embedding: [1.0, 0.0]),
                segment(speakerId: 1, startTime: 20, endTime: 40, embedding: [1.0, 0.0]),
                segment(speakerId: 2, startTime: 40, endTime: 45, embedding: unitVector(cosineToXAxis: 0.99)),
            ],
            minClusterDuration: 30.0,
            absorptionThreshold: 0.72,
            microClusterDuration: 10.0,
            microAbsorptionThreshold: 0.62
        )

        XCTAssertEqual(Set(protected.map(\.speakerId)), [1, 2])
    }

    func testDbInformedSplitCreatesSeparateSpeakerIdsForMixedCluster() {
        let profileA = speakerProfile(id: UUID(), embedding: [1.0, 0.0], name: "Alex")
        let profileB = speakerProfile(id: UUID(), embedding: [0.0, 1.0], name: "Blair")

        let split = EmbeddingClusterer.dbInformedSplit(
            segments: [
                segment(speakerId: 1, startTime: 0, endTime: 2, embedding: [1.0, 0.0]),
                segment(speakerId: 1, startTime: 2, endTime: 4, embedding: [1.0, 0.0]),
                segment(speakerId: 1, startTime: 4, endTime: 6, embedding: [0.0, 1.0]),
                segment(speakerId: 1, startTime: 6, endTime: 8, embedding: [0.0, 1.0]),
            ],
            profiles: [profileA, profileB],
            perSegmentThreshold: 0.62,
            minSegmentsPerProfile: 2
        )

        let ids = split.map(\.speakerId)
        XCTAssertEqual(Set(ids), [1, 2])
        XCTAssertEqual(ids.filter { $0 == 1 }.count, 2)
        XCTAssertEqual(ids.filter { $0 == 2 }.count, 2)
    }

    private func segment(
        speakerId: Int,
        startTime: Double,
        endTime: Double,
        embedding: [Float]
    ) -> SpeakerSegment {
        SpeakerSegment(
            speakerId: speakerId,
            startTime: startTime,
            endTime: endTime,
            embedding: embedding,
            qualityScore: 0.95
        )
    }

    private func speakerProfile(id: UUID, embedding: [Float], name: String) -> SpeakerProfile {
        SpeakerProfile(
            id: id,
            displayName: name,
            nameSource: NameSource.userManual,
            embedding: embedding,
            firstSeen: Date(),
            lastSeen: Date(),
            callCount: 6,
            confidence: 0.9,
            disputeCount: 0
        )
    }

    private func unitVector(cosineToXAxis: Float) -> [Float] {
        let y = sqrt(max(0, 1 - (cosineToXAxis * cosineToXAxis)))
        return [cosineToXAxis, y]
    }

    private func unitVector(degrees: Float) -> [Float] {
        let radians = degrees * .pi / 180
        return [cos(radians), sin(radians)]
    }
}
