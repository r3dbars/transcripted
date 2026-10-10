import XCTest
@testable import TranscriptedCore

/// Promises for unsupervised split of a collapsed diarizer ID: two voices that
/// share one speaker label come apart when their embeddings are bimodal;
/// one voice that was over-segmented or merely noisy does not.
@available(macOS 14.0, *)
final class EmbeddingClustererSplitTests: XCTestCase {

    func testTwoMeansFindsOrthogonalGroups() {
        let embeddings = Array(repeating: [Float(1), 0], count: 4)
            + Array(repeating: [Float(0), 1], count: 4)
        let part = SpeakerEmbeddingBimodality.partition(
            embeddings: embeddings,
            maxBetween: 0.88,
            minCount: 2
        )
        XCTAssertNotNil(part)
        XCTAssertEqual(Set([part?.left.count, part?.right.count]), [4])
        XCTAssertLessThan(part?.between ?? 1, 0.2)
        XCTAssertGreaterThan(part?.separation ?? 0, 0.5)
    }

    func testTwoMeansRejectsAUnimodalCloud() {
        let embeddings = (0..<8).map { index in
            unitVector(cosineToXAxis: 0.98 + Float(index) * 0.002)
        }
        XCTAssertNil(
            SpeakerEmbeddingBimodality.partition(
                embeddings: embeddings,
                maxBetween: 0.88,
                minCount: 2
            )
        )
    }

    func testTwoMeansRejectsWhenCentroidsClearTheConsolidationBar() {
        // Two tight groups whose centroids sit at 0.95 — same voice, not two people.
        let embeddings = Array(repeating: [Float(1), 0], count: 4)
            + Array(repeating: unitVector(cosineToXAxis: 0.95), count: 4)
        XCTAssertNil(
            SpeakerEmbeddingBimodality.partition(
                embeddings: embeddings,
                maxBetween: 0.88,
                minCount: 2
            )
        )
    }

    func testCollapsedClusterSplitsTwoVoicesThatShareOneId() {
        var segments: [SpeakerSegment] = []
        for index in 0..<6 {
            segments.append(segment(speakerId: 1, start: Double(index * 10), end: Double(index * 10 + 10), embedding: [1, 0]))
        }
        for index in 0..<6 {
            segments.append(segment(speakerId: 1, start: Double(60 + index * 10), end: Double(70 + index * 10), embedding: [0, 1]))
        }

        let split = EmbeddingClusterer.splitCollapsedSpeakers(segments: segments, maxBetween: 0.88)
        XCTAssertEqual(Set(split.map(\.speakerId)).count, 2)
        XCTAssertEqual(split.filter { $0.speakerId == 1 }.count, 6)
        XCTAssertEqual(split.filter { $0.speakerId != 1 }.count, 6)
    }

    func testCollapsedClusterDoesNotSplitAnOverSegmentedSameVoice() {
        let embeddings: [[Float]] = [
            [1, 0],
            unitVector(cosineToXAxis: 0.99),
            unitVector(cosineToXAxis: 0.97),
            unitVector(cosineToXAxis: 0.95),
            unitVector(cosineToXAxis: 0.96),
            unitVector(cosineToXAxis: 0.98),
        ]
        let segments = embeddings.enumerated().map { index, embedding in
            segment(speakerId: 1, start: Double(index * 10), end: Double(index * 10 + 10), embedding: embedding)
        }
        let split = EmbeddingClusterer.splitCollapsedSpeakers(segments: segments, maxBetween: 0.88)
        XCTAssertEqual(Set(split.map(\.speakerId)), [1])
    }

    func testPostProcessRecoversThreePeopleWhenTwoShareADiarizerId() {
        // meet3-shaped: A is its own ID; B and C were collapsed onto one ID
        // and take turns (A-B-C), the way a three-person meeting actually talks.
        var segments: [SpeakerSegment] = []
        var time = 0.0
        for index in 0..<14 {
            segments.append(segment(speakerId: 1, start: time, end: time + 3, embedding: [1, 0]))
            time += 3.5
            if index < 13 {
                segments.append(segment(speakerId: 2, start: time, end: time + 3, embedding: [0, 1]))
                time += 3.5
                segments.append(segment(speakerId: 2, start: time, end: time + 3, embedding: unitVector(degrees: 180)))
                time += 3.5
            }
        }

        let processed = EmbeddingClusterer.postProcess(
            segments: segments,
            existingProfiles: [],
            pairwiseMergeThreshold: nil
        )
        XCTAssertEqual(
            Set(processed.map(\.speakerId)).count,
            3,
            "Two collapsed voices plus a third distinct ID become three speakers to name"
        )
    }

    func testPostProcessStillConsolidatesAnOverSegmentedSameVoiceAfterTheSplitPass() {
        let voices: [[Float]] = [
            [1, 0],
            unitVector(cosineToXAxis: 0.99),
            unitVector(cosineToXAxis: 0.98),
            unitVector(cosineToXAxis: 0.97),
        ]
        let segments = voices.enumerated().map { index, embedding in
            segment(
                speakerId: index + 1,
                start: Double(index * 40),
                end: Double(index * 40 + 40),
                embedding: embedding
            )
        }
        let processed = EmbeddingClusterer.postProcess(
            segments: segments,
            existingProfiles: [],
            pairwiseMergeThreshold: nil
        )
        XCTAssertEqual(Set(processed.map(\.speakerId)).count, 1)
    }

    func testOneCollapsedIdDoesNotFragmentAcrossRounds() {
        // Four compact, well-separated voices under one ID. A recursive
        // 2-means would keep splitting (0° vs 180°, then 90° vs 270°). One
        // starting ID may produce at most one new ID, even when the caller
        // asks for four rounds.
        let directions: [Float] = [0, 90, 180, 270]
        var segments: [SpeakerSegment] = []
        var time = 0.0
        for degrees in directions {
            for _ in 0..<6 {
                segments.append(segment(
                    speakerId: 1,
                    start: time,
                    end: time + 10,
                    embedding: unitVector(degrees: degrees)
                ))
                time += 10
            }
        }
        let split = EmbeddingClusterer.splitCollapsedSpeakers(
            segments: segments,
            maxBetween: 0.88,
            maxRounds: 4
        )
        XCTAssertEqual(
            Set(split.map(\.speakerId)).count,
            2,
            "A collapsed ID splits once; leftover sides are not split again"
        )
    }

    func testLongTenureDriftDoesNotInventASpeaker() {
        // Same geometry as the interleaved test below: centroids at 0.80 cosine,
        // cohesion gap 0.20. That clears the default 0.10 hole. Early block then
        // late block is one voice drifting across a meeting, not two people.
        let early: [Float] = [1, 0]
        let late = unitVector(cosineToXAxis: 0.80)
        var segments: [SpeakerSegment] = []
        for index in 0..<6 {
            segments.append(segment(speakerId: 1, start: Double(index * 10), end: Double(index * 10 + 10), embedding: early))
        }
        for index in 0..<6 {
            segments.append(segment(speakerId: 1, start: Double(60 + index * 10), end: Double(70 + index * 10), embedding: late))
        }
        let split = EmbeddingClusterer.splitCollapsedSpeakers(segments: segments, maxBetween: 0.88)
        XCTAssertEqual(Set(split.map(\.speakerId)), [1])
    }

    func testInterleavedVoicesStillSplitWhenTheGapIsOnlyModest() {
        // Identical vectors to the drift test. A-B-A-B is two people taking
        // turns, so the default cohesion gap is enough.
        let first: [Float] = [1, 0]
        let second = unitVector(cosineToXAxis: 0.80)
        var segments: [SpeakerSegment] = []
        for index in 0..<12 {
            let embedding = index % 2 == 0 ? first : second
            segments.append(segment(
                speakerId: 1,
                start: Double(index * 10),
                end: Double(index * 10 + 10),
                embedding: embedding
            ))
        }
        let split = EmbeddingClusterer.splitCollapsedSpeakers(segments: segments, maxBetween: 0.88)
        XCTAssertEqual(Set(split.map(\.speakerId)).count, 2)
    }

    func testSplitNeedsEnoughTalkTimeOnEachSide() {
        // Two voices, but the second only has 4 s total — below the 8 s floor.
        var segments: [SpeakerSegment] = []
        for index in 0..<4 {
            segments.append(segment(speakerId: 1, start: Double(index * 10), end: Double(index * 10 + 10), embedding: [1, 0]))
        }
        segments.append(segment(speakerId: 1, start: 40, end: 42, embedding: [0, 1]))
        segments.append(segment(speakerId: 1, start: 42, end: 44, embedding: [0, 1]))
        let split = EmbeddingClusterer.splitCollapsedSpeakers(segments: segments, maxBetween: 0.88)
        XCTAssertEqual(Set(split.map(\.speakerId)), [1])
    }

    private func segment(
        speakerId: Int,
        start: Double,
        end: Double,
        embedding: [Float]
    ) -> SpeakerSegment {
        SpeakerSegment(
            speakerId: speakerId,
            startTime: start,
            endTime: end,
            embedding: embedding,
            qualityScore: 0.95
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
