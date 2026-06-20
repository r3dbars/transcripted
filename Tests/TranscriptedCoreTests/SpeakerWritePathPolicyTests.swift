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
        // (< crossClusterLinkFloor 0.78): distinct people. The weaker match is spun off, not fused.
        let p = UUID()
        let keeper = 1, intruder = 2
        let plan = Transcription.planCrossClusterLinks(
            matchedProfileBySpeaker: [keeper: p, intruder: p],
            matchSimilarityBySpeaker: [keeper: 0.95, intruder: 0.74],
            meanBySpeaker: [keeper: unit(cos: 1.0), intruder: unit(cos: 0.60)],
            segmentCountBySpeaker: [keeper: 10, intruder: 3]
        )
        XCTAssertTrue(plan.remaps.isEmpty, "distinct voices must not be fused")
        XCTAssertEqual(plan.spinOffs, [intruder], "the distinct voice is spun off; best-match keeps identity")
    }

    func testOverSegmentedVoiceIsFused() {
        // One person split into two clusters that are 0.85 similar to each other (>= 0.78):
        // genuine over-segmentation → fuse into the best-matching representative (de-frag preserved).
        let p = UUID()
        let big = 1, small = 2
        let plan = Transcription.planCrossClusterLinks(
            matchedProfileBySpeaker: [big: p, small: p],
            matchSimilarityBySpeaker: [big: 0.92, small: 0.85],
            meanBySpeaker: [big: unit(cos: 1.0), small: unit(cos: 0.85)],
            segmentCountBySpeaker: [big: 8, small: 4]
        )
        XCTAssertEqual(plan.remaps, [small: big], "over-segmented same voice should fuse into representative")
        XCTAssertTrue(plan.spinOffs.isEmpty)
    }

    func testMixedFuseAndSpinOffAgainstOneProfile() {
        // Representative A; B is the same voice (0.84) → fuse; C is a distinct voice (0.50) → spin off.
        let p = UUID()
        let a = 1, b = 2, c = 3
        // a,b same voice (0.84). c distinct from BOTH (0.50 to a, ~0.42 to b) — placed on an
        // independent axis so the 2-D plane doesn't make it accidentally close to b.
        let av: [Float] = [1, 0, 0]
        let bv: [Float] = [0.84, 0.5426, 0]
        let cv: [Float] = [0.5, 0, 0.866]   // cos(cv,av)=0.50, cos(cv,bv)=0.42
        let plan = Transcription.planCrossClusterLinks(
            matchedProfileBySpeaker: [a: p, b: p, c: p],
            matchSimilarityBySpeaker: [a: 0.95, b: 0.88, c: 0.74],
            meanBySpeaker: [a: av, b: bv, c: cv],
            segmentCountBySpeaker: [a: 12, b: 5, c: 4]
        )
        XCTAssertEqual(plan.remaps, [b: a])
        XCTAssertEqual(plan.spinOffs, [c])
    }

    func testDistinctProfilesAreLeftAlone() {
        let plan = Transcription.planCrossClusterLinks(
            matchedProfileBySpeaker: [1: UUID(), 2: UUID()],
            matchSimilarityBySpeaker: [1: 0.95, 2: 0.80],
            meanBySpeaker: [1: unit(cos: 1.0), 2: unit(cos: 0.60)],
            segmentCountBySpeaker: [1: 5, 2: 5]
        )
        XCTAssertTrue(plan.remaps.isEmpty)
        XCTAssertTrue(plan.spinOffs.isEmpty)
    }

    func testBestMatchKeepsIdentityEvenWithFewerSegments() {
        // The real returning speaker (id 7) matches the profile strongly but is short; a longer,
        // distinct voice (id 2) only weakly matched. The strong match must keep the name and the
        // long distinct voice must be spun off — NOT the other way around (canonical by similarity,
        // not segment count).
        let p = UUID()
        let plan = Transcription.planCrossClusterLinks(
            matchedProfileBySpeaker: [7: p, 2: p],
            matchSimilarityBySpeaker: [7: 0.95, 2: 0.72],
            meanBySpeaker: [7: unit(cos: 1.0), 2: unit(cos: 0.50)],
            segmentCountBySpeaker: [7: 2, 2: 9]   // id 2 has far more segments but a weaker match
        )
        XCTAssertEqual(plan.spinOffs, [2], "the longer but distinct voice is spun off")
        XCTAssertTrue(plan.remaps.isEmpty, "the strong (short) match keeps the profile")
    }

    func testThreeClustersTwoMutualFragmentsFuseTogether() {
        // x is the returning profile owner; y and z are a DIFFERENT person split into two fragments
        // (0.85 to each other, ~0.50 to x). y and z must fuse into ONE spun-off profile, not two —
        // the union-find prevents re-fragmenting a distinct voice across the profile boundary.
        let p = UUID()
        let x = 1, y = 2, z = 3
        // x = [1,0,0]; y,z ≈0.50 to x but ≈0.85 to each other (a distinct voice in two fragments).
        let xv: [Float] = [1, 0, 0]
        let yv: [Float] = [0.5, 0.866, 0]
        let zv: [Float] = [0.5, 0.6928, 0.5196]   // cos(zv,xv)=0.50, cos(zv,yv)=0.85
        let plan = Transcription.planCrossClusterLinks(
            matchedProfileBySpeaker: [x: p, y: p, z: p],
            matchSimilarityBySpeaker: [x: 0.95, y: 0.74, z: 0.73],
            meanBySpeaker: [x: xv, y: yv, z: zv],
            segmentCountBySpeaker: [x: 10, y: 4, z: 4]
        )
        // y is the higher-ranked of the two fragments (0.74 > 0.73) → representative.
        XCTAssertEqual(plan.spinOffs, [y], "the distinct voice gets exactly one new profile")
        XCTAssertEqual(plan.remaps, [z: y], "its second fragment fuses into it, not a third profile")
    }

    // MARK: - Helpers

    /// 2-D unit vector with a given cosine to the x-axis reference [1, 0].
    private func unit(cos: Float) -> [Float] {
        let y = (max(0, 1 - cos * cos)).squareRoot()
        return [cos, y]
    }
}
