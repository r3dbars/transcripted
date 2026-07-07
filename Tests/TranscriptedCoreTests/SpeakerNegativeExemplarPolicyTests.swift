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

    private func unitVector(degrees: Float) -> [Float] {
        let radians = degrees * .pi / 180
        return [cos(radians), sin(radians)]
    }
}
