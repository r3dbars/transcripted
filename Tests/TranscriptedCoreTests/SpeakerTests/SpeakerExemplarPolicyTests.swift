import XCTest
import Foundation
@testable import TranscriptedCore

/// Unit tests for the pure multi-exemplar maintenance policy — no database, no audio.
@available(macOS 14.0, *)
final class SpeakerExemplarPolicyTests: XCTestCase {

    /// A 4-dim unit basis vector, optionally tilted toward another axis, L2-normalized.
    private func vec(_ a: Float, _ b: Float, _ c: Float, _ d: Float) -> [Float] {
        SpeakerVectorMath.l2Normalize([a, b, c, d])
    }

    // A mean already covered by the average (same direction) adds no exemplar.
    func testSameAsAverageStoresNoExemplar() {
        let average = vec(1, 0, 0, 0)
        let mean = vec(0.98, 0.02, 0, 0) // cos ~0.9998 > sameConditionSimilarity
        let result = SpeakerExemplarPolicy.updated(current: [], newMean: mean, average: average)
        XCTAssertTrue(result.isEmpty, "A mean the average already covers should not be stored")
    }

    // A mean from a distinct condition (far from the average) earns its own exemplar.
    func testDistinctConditionCreatesExemplar() {
        let average = vec(1, 0, 0, 0)
        let mean = vec(0, 1, 0, 0) // orthogonal → cos 0 < threshold
        let result = SpeakerExemplarPolicy.updated(current: [], newMean: mean, average: average)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].segmentCount, 1)
    }

    // A second same-condition mean blends into the existing exemplar rather than duplicating it.
    func testSameConditionBlendsIntoExemplarAndBumpsCount() {
        let average = vec(1, 0, 0, 0)
        let cond2 = vec(0, 1, 0, 0)
        var exemplars = SpeakerExemplarPolicy.updated(current: [], newMean: cond2, average: average)
        XCTAssertEqual(exemplars.count, 1)

        let cond2Again = vec(0.05, 0.99, 0, 0) // very close to cond2 → same condition
        exemplars = SpeakerExemplarPolicy.updated(current: exemplars, newMean: cond2Again, average: average)
        XCTAssertEqual(exemplars.count, 1, "Same-condition mean should blend, not add a slot")
        XCTAssertEqual(exemplars[0].segmentCount, 2)
        // Stays unit-norm after the EMA blend.
        let norm = exemplars[0].embedding.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        XCTAssertEqual(norm, 1, accuracy: 1e-3)
    }

    // The set never exceeds maxExemplars; a further distinct mean evicts the most-redundant slot.
    func testCapEnforcedAndEvictsMostRedundant() {
        let average = vec(1, 0, 0, 0)
        var exemplars: [SpeakerExemplarPolicy.Exemplar] = []
        // Three distinct conditions fill the three slots.
        for m in [vec(0, 1, 0, 0), vec(0, 0, 1, 0), vec(0, 0, 0, 1)] {
            exemplars = SpeakerExemplarPolicy.updated(current: exemplars, newMean: m, average: average)
        }
        XCTAssertEqual(exemplars.count, SpeakerExemplarPolicy.maxExemplars)

        // A brand-new, maximally-distinct direction. It is more distinct than the most-redundant
        // existing exemplar, so the set stays at the cap and swaps one out.
        let novel = vec(-1, -1, -1, -1)
        let after = SpeakerExemplarPolicy.updated(current: exemplars, newMean: novel, average: average)
        XCTAssertEqual(after.count, SpeakerExemplarPolicy.maxExemplars, "Never exceeds the cap")
        XCTAssertTrue(
            after.contains { SpeakerVectorMath.cosineSimilarity($0.embedding, novel) > 0.99 },
            "The novel distinct condition should be retained after eviction"
        )
    }

    // A dimension-mismatched mean is ignored (never mixes 192-d and 256-d geometry).
    func testDimensionMismatchIgnored() {
        let average = vec(1, 0, 0, 0)
        let wrongDim = SpeakerVectorMath.l2Normalize([0, 1, 0]) // 3-dim
        let result = SpeakerExemplarPolicy.updated(current: [], newMean: wrongDim, average: average)
        XCTAssertTrue(result.isEmpty)
    }

    // bestSimilarity is monotonic: adding an exemplar never lowers the score, and matching the
    // exemplar direction beats matching the average alone.
    func testBestSimilarityUsesBestFittingRepresentative() {
        let average = vec(1, 0, 0, 0)
        let exemplar = vec(0, 1, 0, 0)
        let candidate = vec(0.1, 0.99, 0, 0) // close to the exemplar, far from the average

        let averageOnly = SpeakerVectorMath.bestSimilarity(candidate: candidate, average: average, exemplars: [])
        let withExemplar = SpeakerVectorMath.bestSimilarity(candidate: candidate, average: average, exemplars: [exemplar])

        XCTAssertGreaterThan(withExemplar, averageOnly)
        XCTAssertEqual(withExemplar, SpeakerVectorMath.cosineSimilarity(candidate, exemplar), accuracy: 1e-6)
        // Empty exemplar set is exactly the single-average cosine (legacy behavior).
        XCTAssertEqual(averageOnly, SpeakerVectorMath.cosineSimilarity(candidate, average), accuracy: 1e-6)
    }
}
