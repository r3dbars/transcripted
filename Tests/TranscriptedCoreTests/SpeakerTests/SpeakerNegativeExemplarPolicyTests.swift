import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class SpeakerNegativeExemplarPolicyTests: XCTestCase {

    // MARK: - shouldVeto(positiveSimilarity:negativeSimilarity:)

    func testVetoesWhenNegativeIsCloseAndCompetitive() {
        // Rejected sample clears the veto floor and is more similar than the profile itself.
        XCTAssertTrue(SpeakerNegativeExemplarPolicy.shouldVeto(
            positiveSimilarity: 0.88,
            negativeSimilarity: 0.95
        ))
    }

    func testDoesNotVetoWhenNegativeBelowPositive() {
        // The candidate is closer to the profile's own fingerprint (0.88) than to the rejected
        // sample (0.86): a genuine returning owner. No handicap — do not veto.
        XCTAssertFalse(SpeakerNegativeExemplarPolicy.shouldVeto(
            positiveSimilarity: 0.88,
            negativeSimilarity: 0.86
        ))
    }

    func testDoesNotVetoWhenNegativeBelowFloor() {
        // Coincidental resemblance to a rejected sample (< 0.80) never fires.
        XCTAssertFalse(SpeakerNegativeExemplarPolicy.shouldVeto(
            positiveSimilarity: 0.99,
            negativeSimilarity: 0.79
        ))
    }

    func testDoesNotVetoWhenPositiveClearlyBeatsNegative() {
        // Candidate is clearly closer to the fingerprint than to any rejected sample (gap > margin):
        // trust the positive match, stay silent. This is what protects the genuine returning voice.
        XCTAssertFalse(SpeakerNegativeExemplarPolicy.shouldVeto(
            positiveSimilarity: 0.99,
            negativeSimilarity: 0.90
        ))
    }

    func testVetoBoundaryWhenEqualAtFloor() {
        // Negative exactly equals the positive and sits exactly at the floor → vetoes (>= on both).
        XCTAssertTrue(SpeakerNegativeExemplarPolicy.shouldVeto(
            positiveSimilarity: SpeakerNegativeExemplarPolicy.vetoFloor,
            negativeSimilarity: SpeakerNegativeExemplarPolicy.vetoFloor
        ))
    }

    func testDoesNotVetoAtFloorWhenPositiveExceedsIt() {
        // Negative sits at the floor but the owner is closer to the fingerprint → no veto.
        XCTAssertFalse(SpeakerNegativeExemplarPolicy.shouldVeto(
            positiveSimilarity: SpeakerNegativeExemplarPolicy.vetoFloor + 0.05,
            negativeSimilarity: SpeakerNegativeExemplarPolicy.vetoFloor
        ))
    }

    // MARK: - maxNegativeSimilarity / shouldVeto(candidate:)

    func testMaxNegativeSimilarityPicksClosestExemplar() {
        let candidate = unitVector(degrees: 10)
        let exemplars = [unitVector(degrees: 80), unitVector(degrees: 12), unitVector(degrees: 200)]

        let best = SpeakerNegativeExemplarPolicy.maxNegativeSimilarity(candidate, negativeExemplars: exemplars)

        // Closest is the 12° exemplar → cos(2°) ≈ 0.9994.
        XCTAssertEqual(best, cos(2 * .pi / 180), accuracy: 0.001)
    }

    func testMaxNegativeSimilaritySkipsDimensionMismatch() {
        let best = SpeakerNegativeExemplarPolicy.maxNegativeSimilarity(
            [1, 0],
            negativeExemplars: [[1, 0, 0], [0, 1, 0]]
        )
        XCTAssertEqual(best, -1, accuracy: 0.000_1)
    }

    func testNoNegativeExemplarsNeverVetoes() {
        XCTAssertFalse(SpeakerNegativeExemplarPolicy.shouldVeto(
            candidate: [1, 0],
            positiveSimilarity: 0.99,
            negativeExemplars: []
        ))
    }

    // MARK: - Condition-transported negatives (cross-condition veto, #1493 follow-up)

    /// A synthetic 4-D geometry that reproduces the cross-condition failure mode the eval measured.
    /// Dims 0-1 encode speaker *identity* (owner `A` vs the wrongly-matched impostor `B`, ~56° apart so
    /// B is confusable with A); dims 2-3 encode the audio *condition* (a shared, speaker-independent
    /// channel — "in-room" vs "telephone"). Each speaker is observed in both conditions. Vectors solved
    /// so the raw cosine between the impostor's two conditions falls below the veto floor (the
    /// documented cross-condition miss) while A's own in-room→telephone shift transports the rejected
    /// sample onto the returning impostor.
    private enum Geo {
        // Profile A: blended average, plus one positive exemplar capturing its condition-2 (telephone).
        static let aAverage = l2([0.8835, 0.0000, 0.3313, 0.3313])
        static let aExemplarCond2 = l2([0.8000, 0.0000, 0.0000, 0.6000])
        // Impostor B in condition 1 (the rejected sample the user corrected) and returning in condition 2.
        static let bCond1 = l2([0.4474, 0.6632, 0.6000, 0.0000])
        static let bCond2 = l2([0.4474, 0.6632, 0.0000, 0.6000])
        // The genuine owner A returning in condition 2 (a fresh sample, near but not equal to the exemplar).
        static let aCond2 = l2([0.7999, 0.0000, 0.1200, 0.5880])
    }

    /// Cross-condition impostor: B's rejected sample is in condition 1; B returns in condition 2.
    /// Raw cosine to the single stored negative is below the floor (the documented under-fire), so the
    /// raw veto misses it — but transporting the negative along A's own condition-1→2 shift catches it.
    func testTransportVetoesSameImpostorInDifferentCondition() {
        let candidate = Geo.bCond2
        let negatives = [Geo.bCond1]
        let pos = SpeakerVectorMath.bestSimilarity(
            candidate: candidate, average: Geo.aAverage, exemplars: [Geo.aExemplarCond2])

        // Raw resemblance to the rejected sample is below the veto floor → raw veto does NOT fire.
        let rawNeg = SpeakerNegativeExemplarPolicy.maxNegativeSimilarity(candidate, negativeExemplars: negatives)
        XCTAssertLessThan(rawNeg, SpeakerNegativeExemplarPolicy.vetoFloor)
        XCTAssertFalse(SpeakerNegativeExemplarPolicy.shouldVeto(
            candidate: candidate, positiveSimilarity: pos, negativeExemplars: negatives))

        // Transported along A's observed condition shift, the same impostor is caught.
        let txNeg = SpeakerNegativeExemplarPolicy.maxNegativeSimilarity(
            candidate, negativeExemplars: negatives,
            profileAverage: Geo.aAverage, positiveExemplars: [Geo.aExemplarCond2])
        XCTAssertGreaterThan(txNeg, rawNeg, "transport must raise the negative similarity cross-condition")
        XCTAssertTrue(SpeakerNegativeExemplarPolicy.shouldVeto(
            candidate: candidate, positiveSimilarity: pos, negativeExemplars: negatives,
            profileAverage: Geo.aAverage, positiveExemplars: [Geo.aExemplarCond2]),
            "transported negative should veto the same impostor returning in another condition")
    }

    /// The genuine owner returning in a different condition must NOT be vetoed by transport: the owner
    /// is closer to its own fingerprint than to the transported *impostor* sample, so the ≥pos owner
    /// gate still protects it. This is the guardrail — a correction must never veto the real owner.
    func testTransportDoesNotVetoOwnerInDifferentCondition() {
        let candidate = Geo.aCond2                 // the owner, in condition 2
        let negatives = [Geo.bCond1]               // impostor B's rejected condition-1 sample
        let pos = SpeakerVectorMath.bestSimilarity(
            candidate: candidate, average: Geo.aAverage, exemplars: [Geo.aExemplarCond2])

        XCTAssertFalse(SpeakerNegativeExemplarPolicy.shouldVeto(
            candidate: candidate, positiveSimilarity: pos, negativeExemplars: negatives,
            profileAverage: Geo.aAverage, positiveExemplars: [Geo.aExemplarCond2]),
            "transport must not veto the genuine owner returning in another condition")
    }

    /// With no positive exemplars a profile has no observed condition shifts, so the transported
    /// overload derives nothing and reduces EXACTLY to the raw negative similarity — single-condition
    /// profiles are byte-for-byte unchanged (no owner-collateral regression for them).
    func testTransportWithoutExemplarsMatchesRawExactly() {
        let candidate = Geo.bCond2
        let negatives = [Geo.bCond1, Geo.aExemplarCond2]
        let raw = SpeakerNegativeExemplarPolicy.maxNegativeSimilarity(candidate, negativeExemplars: negatives)
        let tx = SpeakerNegativeExemplarPolicy.maxNegativeSimilarity(
            candidate, negativeExemplars: negatives,
            profileAverage: Geo.aAverage, positiveExemplars: [])
        XCTAssertEqual(raw, tx, accuracy: 1e-9)
    }

    private func unitVector(degrees: Float) -> [Float] {
        let radians = degrees * .pi / 180
        return [cos(radians), sin(radians)]
    }

    private static func l2(_ v: [Float]) -> [Float] { SpeakerVectorMath.l2Normalize(v) }
}
