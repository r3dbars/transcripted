import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class SpeakerWritePathPolicyTests: XCTestCase {

    // MARK: - #6 voiceprint write-back gate

    func testConfidentWellSeparatedMatchAdaptsAtFullRate() {
        let alpha = SpeakerWritePathPolicy.voiceprintBlendAlpha(similarity: 0.95, secondBestSimilarity: 0.50)
        XCTAssertEqual(alpha, SpeakerWritePathPolicy.confidentBlendAlpha)
    }

    func testNoRunnerUpHighSimilarityAdaptsFully() {
        // secondBest < 0 means no confusable runner-up cleared the floor → unambiguous.
        let alpha = SpeakerWritePathPolicy.voiceprintBlendAlpha(similarity: 0.85, secondBestSimilarity: -1)
        XCTAssertEqual(alpha, SpeakerWritePathPolicy.confidentBlendAlpha)
    }

    func testNilRunnerUpTreatedAsUnambiguous() {
        let alpha = SpeakerWritePathPolicy.voiceprintBlendAlpha(similarity: 0.85, secondBestSimilarity: nil)
        XCTAssertEqual(alpha, SpeakerWritePathPolicy.confidentBlendAlpha)
    }

    func testAmbiguousRunnerUpFreezesVoiceprintEvenWhenSimilarityHigh() {
        // margin 0.05 < writeBackMarginMin (0.12): we cannot be sure WHO this is → freeze.
        let alpha = SpeakerWritePathPolicy.voiceprintBlendAlpha(similarity: 0.90, secondBestSimilarity: 0.85)
        XCTAssertEqual(alpha, SpeakerWritePathPolicy.frozenBlendAlpha)
    }

    func testMarginalSimilarityAdaptsCautiously() {
        // 0.72 <= 0.75 < 0.80, well-separated → slow adaptation.
        let alpha = SpeakerWritePathPolicy.voiceprintBlendAlpha(similarity: 0.75, secondBestSimilarity: -1)
        XCTAssertEqual(alpha, SpeakerWritePathPolicy.cautiousBlendAlpha)
    }

    func testWeakMatchFreezesVoiceprint() {
        // The documented contamination case: a 0.70 match with no clear runner-up must NOT blend.
        let alpha = SpeakerWritePathPolicy.voiceprintBlendAlpha(similarity: 0.70, secondBestSimilarity: -1)
        XCTAssertEqual(alpha, SpeakerWritePathPolicy.frozenBlendAlpha)
    }

    func testWriteBackBandsAreDecoupledFromDisplayLadder() {
        // A match that NAMES (passes the read-side floor) but is below the display auto-name bar
        // (0.92) and below the confident write bar still gets a non-full / zero alpha — i.e. the
        // write path is strictly stricter-or-equal than the loose attach floor and never silently
        // rides the display bar.
        XCTAssertLessThan(SpeakerWritePathPolicy.confidentWriteBackSimilarity,
                          SpeakerNamingPolicy.autoAcceptSimilarityThreshold)
        XCTAssertEqual(SpeakerWritePathPolicy.writeBackMarginMin, SpeakerNamingPolicy.autoAcceptMarginMin)
    }

    // MARK: - #8 cross-cluster link/merge floor

    func testTwoDistinctVoicesMatchingOneProfileAreNotFused() {
        // Two clusters both matched profile P, but they are only 0.60 similar to each other
        // (< crossClusterLinkFloor 0.78): distinct people. The smaller must be spun off, not fused.
        let p = UUID()
        let big = 1, small = 2
        let plan = Transcription.planCrossClusterLinks(
            matchedProfileBySpeaker: [big: p, small: p],
            meanBySpeaker: [big: unit(cos: 1.0), small: unit(cos: 0.60)],
            segmentCountBySpeaker: [big: 10, small: 3]
        )
        XCTAssertTrue(plan.remaps.isEmpty, "distinct voices must not be fused")
        XCTAssertEqual(plan.spinOffs, [small], "smaller distinct voice should be spun off, larger keeps identity")
    }

    func testOverSegmentedVoiceIsFused() {
        // One person split into two clusters that are 0.85 similar to each other (>= 0.78):
        // genuine over-segmentation → fuse the smaller into the larger (de-fragmentation preserved).
        let p = UUID()
        let big = 1, small = 2
        let plan = Transcription.planCrossClusterLinks(
            matchedProfileBySpeaker: [big: p, small: p],
            meanBySpeaker: [big: unit(cos: 1.0), small: unit(cos: 0.85)],
            segmentCountBySpeaker: [big: 8, small: 4]
        )
        XCTAssertEqual(plan.remaps, [small: big], "over-segmented same voice should fuse into canonical")
        XCTAssertTrue(plan.spinOffs.isEmpty)
    }

    func testMixedFuseAndSpinOffAgainstOneProfile() {
        // Canonical A; B is the same voice (0.84) → fuse; C is a distinct voice (0.50) → spin off.
        let p = UUID()
        let a = 1, b = 2, c = 3
        let plan = Transcription.planCrossClusterLinks(
            matchedProfileBySpeaker: [a: p, b: p, c: p],
            meanBySpeaker: [a: unit(cos: 1.0), b: unit(cos: 0.84), c: unit(cos: 0.50)],
            segmentCountBySpeaker: [a: 12, b: 5, c: 4]
        )
        XCTAssertEqual(plan.remaps, [b: a])
        XCTAssertEqual(plan.spinOffs, [c])
    }

    func testDistinctProfilesAreLeftAlone() {
        let plan = Transcription.planCrossClusterLinks(
            matchedProfileBySpeaker: [1: UUID(), 2: UUID()],
            meanBySpeaker: [1: unit(cos: 1.0), 2: unit(cos: 0.60)],
            segmentCountBySpeaker: [1: 5, 2: 5]
        )
        XCTAssertTrue(plan.remaps.isEmpty)
        XCTAssertTrue(plan.spinOffs.isEmpty)
    }

    func testCanonicalIsLargestClusterRegardlessOfIteration() {
        // small id but most segments should claim the identity.
        let p = UUID()
        let plan = Transcription.planCrossClusterLinks(
            matchedProfileBySpeaker: [7: p, 2: p],
            meanBySpeaker: [7: unit(cos: 1.0), 2: unit(cos: 0.50)],
            segmentCountBySpeaker: [7: 2, 2: 9]   // id 2 has more segments → canonical
        )
        XCTAssertEqual(plan.spinOffs, [7], "the smaller (fewer-segment) cluster is spun off")
        XCTAssertTrue(plan.remaps.isEmpty)
    }

    // MARK: - Helpers

    /// 2-D unit vector with a given cosine to the x-axis reference [1, 0].
    private func unit(cos: Float) -> [Float] {
        let y = (max(0, 1 - cos * cos)).squareRoot()
        return [cos, y]
    }
}
