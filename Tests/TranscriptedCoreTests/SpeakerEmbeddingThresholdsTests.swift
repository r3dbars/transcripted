import XCTest
@testable import TranscriptedCore

/// Locks down the per-model threshold presets and proves the active set actually
/// flows from the embedder through DiarizationService into the clusterer.
@available(macOS 14.0, *)
final class SpeakerEmbeddingThresholdsTests: XCTestCase {

    /// Regression guard: the WeSpeaker preset must equal the exact production
    /// values, so the default (no-embedder) path stays byte-identical.
    func testWeSpeakerPresetMatchesProductionValues() {
        let t = SpeakerEmbeddingThresholds.weSpeaker
        XCTAssertEqual(t.matchOneSegment, 0.85)
        XCTAssertEqual(t.matchFewSegments, 0.78)
        XCTAssertEqual(t.matchManySegments, 0.70)
        XCTAssertEqual(t.ghostMergeFloor, 0.72)
        XCTAssertEqual(t.consolidation, 0.88)
        XCTAssertEqual(t.absorb, 0.72)
        XCTAssertEqual(t.microAbsorb, 0.62)
        XCTAssertEqual(t.perSegmentSplit, 0.62)
        XCTAssertEqual(t.knownProfileConflict, 0.70)
        // Must still equal the standalone constants the clusterer/naming policy use.
        XCTAssertEqual(t.consolidation, EmbeddingClusterer.sameVoiceConsolidationThreshold)
    }

    /// ERes2Net thresholds are calibrated lower (tighter different-speaker band).
    func testERes2NetPresetIsCalibratedLower() {
        let e = SpeakerEmbeddingThresholds.eRes2Net
        let w = SpeakerEmbeddingThresholds.weSpeaker
        XCTAssertLessThan(e.matchManySegments, w.matchManySegments)
        XCTAssertLessThan(e.consolidation, w.consolidation)
        XCTAssertLessThan(e.ghostMergeFloor, w.ghostMergeFloor)
        XCTAssertNotEqual(e, w)
    }

    func testAdaptiveMatchBySegmentCount() {
        let t = SpeakerEmbeddingThresholds.eRes2Net
        XCTAssertEqual(t.adaptiveMatch(forSegmentCount: 1), t.matchOneSegment)
        XCTAssertEqual(t.adaptiveMatch(forSegmentCount: 2), t.matchFewSegments)
        XCTAssertEqual(t.adaptiveMatch(forSegmentCount: 3), t.matchFewSegments)
        XCTAssertEqual(t.adaptiveMatch(forSegmentCount: 4), t.matchManySegments)
        XCTAssertEqual(t.adaptiveMatch(forSegmentCount: 99), t.matchManySegments)
    }

    private final class ThresholdStub: SpeakerSegmentEmbedder, @unchecked Sendable {
        let dimension = 192
        let identifier = "stub"
        let thresholds: SpeakerEmbeddingThresholds
        init(_ t: SpeakerEmbeddingThresholds) { thresholds = t }
        func embed(samples: [Float], sampleRate: Int) -> [Float]? { nil }
    }

    func testDiarizationServiceExposesActiveThresholds() async {
        let none = await MainActor.run { DiarizationService() }
        XCTAssertEqual(none.activeSpeakerThresholds, .weSpeaker)
        let svc = await MainActor.run { DiarizationService(segmentEmbedder: ThresholdStub(.eRes2Net)) }
        XCTAssertEqual(svc.activeSpeakerThresholds, .eRes2Net)
    }

    /// End-to-end: two clusters with mean cosine ~0.70 — between ERes2Net's
    /// consolidation bar (0.65) and WeSpeaker's (0.88) — so the chosen threshold
    /// set changes the clustering outcome. Proves the thresholds reach postProcess.
    func testThresholdsFlowIntoConsolidation() {
        let dim = 192
        var a = [Float](repeating: 0, count: dim); a[0] = 1
        var b = [Float](repeating: 0, count: dim); b[0] = 0.70; b[1] = (1 - 0.49).squareRoot()
        func seg(_ id: Int, _ e: [Float], _ t: Double) -> SpeakerSegment {
            SpeakerSegment(speakerId: id, startTime: t, endTime: t + 2, embedding: e, qualityScore: 0.5)
        }
        let segs = [seg(0, a, 0), seg(0, a, 3), seg(0, a, 6),
                    seg(1, b, 9), seg(1, b, 12), seg(1, b, 15)]
        func speakerCount(_ th: SpeakerEmbeddingThresholds) -> Int {
            Set(EmbeddingClusterer.postProcess(
                segments: segs, existingProfiles: [],
                pairwiseMergeThreshold: nil,
                consolidationThreshold: th.consolidation,
                thresholds: th).map { $0.speakerId }).count
        }
        XCTAssertEqual(speakerCount(.weSpeaker), 2, "0.88 consolidation keeps 0.70-similar clusters apart")
        XCTAssertEqual(speakerCount(.eRes2Net), 1, "0.65 consolidation merges them")
    }
}
