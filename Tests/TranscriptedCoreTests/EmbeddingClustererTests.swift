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

    func testConsolidateMergesOverSegmentedSameVoice() {
        // One voice that VBx split into four near-identical large clusters.
        let merged = EmbeddingClusterer.consolidateSameVoiceClusters(
            segments: [
                segment(speakerId: 1, startTime: 0, endTime: 40, embedding: [1.0, 0.0]),
                segment(speakerId: 2, startTime: 40, endTime: 80, embedding: unitVector(cosineToXAxis: 0.99)),
                segment(speakerId: 3, startTime: 80, endTime: 120, embedding: unitVector(cosineToXAxis: 0.97)),
                segment(speakerId: 4, startTime: 120, endTime: 160, embedding: unitVector(cosineToXAxis: 0.95)),
            ],
            threshold: 0.88
        )

        XCTAssertEqual(Set(merged.map(\.speakerId)).count, 1)
    }

    func testConsolidatePreservesDistinctSpeakers() {
        // Realistic distinct voices sit well under ~0.6 cosine, so none merge.
        let kept = EmbeddingClusterer.consolidateSameVoiceClusters(
            segments: [
                segment(speakerId: 1, startTime: 0, endTime: 40, embedding: unitVector(degrees: 0)),
                segment(speakerId: 2, startTime: 40, endTime: 80, embedding: unitVector(degrees: 66)),
                segment(speakerId: 3, startTime: 80, endTime: 120, embedding: unitVector(degrees: 132)),
            ],
            threshold: 0.88
        )

        XCTAssertEqual(Set(kept.map(\.speakerId)).count, 3)
    }

    func testConsolidateDoesNotMergeAtAutoAcceptBoundary() {
        // SpeakerNamingPolicy only auto-accepts above 0.88. The consolidation pass
        // should use the same strict edge so genuinely similar voices get review.
        let kept = EmbeddingClusterer.consolidateSameVoiceClusters(
            segments: [
                segment(speakerId: 1, startTime: 0, endTime: 40, embedding: [1.0, 0.0]),
                segment(speakerId: 2, startTime: 40, endTime: 80, embedding: unitVector(cosineToXAxis: 0.88)),
            ],
            threshold: 0.88
        )

        XCTAssertEqual(Set(kept.map(\.speakerId)).count, 2)
    }

    func testConsolidationThresholdNotAboveAutoAcceptBar() {
        // Drift guard: within-meeting same-voice consolidation must never merge two clusters
        // we would not also auto-accept as the same known person across meetings. The auto bar
        // (0.92) is now stricter than the consolidation bar (0.88) — consolidation may merge at
        // a lower bar (it has within-meeting evidence), but it must never EXCEED the auto bar.
        XCTAssertLessThanOrEqual(
            EmbeddingClusterer.sameVoiceConsolidationThreshold,
            Float(SpeakerNamingPolicy.autoAcceptSimilarityThreshold),
            "Consolidation threshold must not exceed SpeakerNamingPolicy.autoAcceptSimilarityThreshold"
        )
    }

    func testPostProcessDoesNotConsolidateConflictingKnownProfilesBeforeDbSplit() {
        let alexId = UUID()
        let blairId = UUID()
        let blairEmbedding = unitVector(cosineToXAxis: 0.90)
        let profiles = [
            speakerProfile(id: alexId, embedding: [1.0, 0.0], name: "Alex"),
            speakerProfile(id: blairId, embedding: blairEmbedding, name: "Blair")
        ]
        let segments = [
            segment(speakerId: 1, startTime: 0, endTime: 40, embedding: [1.0, 0.0]),
            segment(speakerId: 2, startTime: 40, endTime: 80, embedding: blairEmbedding)
        ]

        let processed = EmbeddingClusterer.postProcess(
            segments: segments,
            existingProfiles: profiles,
            pairwiseMergeThreshold: nil
        )

        XCTAssertEqual(
            Set(processed.map(\.speakerId)).count,
            2,
            "Known distinct profiles should stay separate even when their centroids sit above the consolidation bar"
        )
    }

    func testPostProcessPreservesKnownProfileConflictsBelowConsolidationBar() {
        let alexId = UUID()
        let blairId = UUID()
        let alexSegmentEmbedding: [Float] = [1.0, 0.0]
        let blairSegmentEmbedding = unitVector(cosineToXAxis: 0.90)
        let profiles = [
            speakerProfile(id: alexId, embedding: unitVector(degrees: -36.87), name: "Alex"),
            speakerProfile(id: blairId, embedding: unitVector(degrees: 62.71), name: "Blair")
        ]
        let segments = [
            segment(speakerId: 1, startTime: 0, endTime: 40, embedding: alexSegmentEmbedding),
            segment(speakerId: 2, startTime: 40, endTime: 80, embedding: blairSegmentEmbedding)
        ]

        let processed = EmbeddingClusterer.postProcess(
            segments: segments,
            existingProfiles: profiles,
            pairwiseMergeThreshold: nil
        )

        XCTAssertEqual(
            Set(processed.map(\.speakerId)).count,
            2,
            "Plausible matches to different known profiles should block consolidation even below the 0.88 auto-accept bar"
        )
    }

    func testConsolidateDoesNotChainCollapseAcrossDissimilarEndpoints() {
        // A≈B and B≈C, but A and C are far apart. Recomputed centroids must stop
        // the transitive collapse that broke the broad pairwise merge.
        let chained = EmbeddingClusterer.consolidateSameVoiceClusters(
            segments: [
                segment(speakerId: 1, startTime: 0, endTime: 40, embedding: unitVector(degrees: 0)),
                segment(speakerId: 2, startTime: 40, endTime: 80, embedding: unitVector(degrees: 20)),
                segment(speakerId: 3, startTime: 80, endTime: 120, embedding: unitVector(degrees: 40)),
            ],
            threshold: 0.88
        )

        XCTAssertEqual(
            Set(chained.map(\.speakerId)).count,
            2,
            "Recomputed centroids stop A≈B, B≈C from chain-collapsing into one speaker"
        )
    }

    func testPostProcessConsolidatesOneOnOneCallToSingleSpeaker() {
        // The reported case: a single remote voice over-segmented into four large
        // clusters that all survive small-cluster absorption.
        let voices: [[Float]] = [
            [1.0, 0.0],
            unitVector(cosineToXAxis: 0.99),
            unitVector(cosineToXAxis: 0.98),
            unitVector(cosineToXAxis: 0.97),
        ]
        let segments = voices.enumerated().map { index, embedding in
            segment(
                speakerId: index + 1,
                startTime: Double(index * 40),
                endTime: Double(index * 40 + 40),
                embedding: embedding
            )
        }

        let processed = EmbeddingClusterer.postProcess(
            segments: segments,
            existingProfiles: [],
            pairwiseMergeThreshold: nil
        )
        XCTAssertEqual(
            Set(processed.map(\.speakerId)).count,
            1,
            "An over-segmented single remote voice should collapse to one speaker to name"
        )

        // The pass is opt-out: passing nil leaves the over-segmentation in place.
        let notConsolidated = EmbeddingClusterer.postProcess(
            segments: segments,
            existingProfiles: [],
            pairwiseMergeThreshold: nil,
            consolidationThreshold: nil
        )
        XCTAssertEqual(Set(notConsolidated.map(\.speakerId)).count, 4)
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
