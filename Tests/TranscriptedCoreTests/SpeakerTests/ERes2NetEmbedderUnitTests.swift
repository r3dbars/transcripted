import XCTest
@testable import TranscriptedCore

/// Model-free unit tests for ERes2NetEmbedder's pure windowing / pooling math —
/// the logic most likely to harbor an off-by-one or normalization bug. No CoreML
/// model required, so these always run (incl. CI).
@available(macOS 14.0, *)
final class ERes2NetEmbedderUnitTests: XCTestCase {

    private let minS = 8000
    private let maxS = 480_000

    // MARK: windowBounds

    func testWindowBoundsEmpty() {
        XCTAssertTrue(ERes2NetEmbedder.windowBounds(sampleCount: 0, minSamples: minS, maxSamples: maxS).isEmpty)
    }

    func testWindowBoundsSingleShort() {
        let b = ERes2NetEmbedder.windowBounds(sampleCount: 1, minSamples: minS, maxSamples: maxS)
        XCTAssertEqual(b.map { [$0.start, $0.end] }, [[0, 1]])
    }

    func testWindowBoundsExactlyMaxIsSingle() {
        let b = ERes2NetEmbedder.windowBounds(sampleCount: maxS, minSamples: minS, maxSamples: maxS)
        XCTAssertEqual(b.map { [$0.start, $0.end] }, [[0, maxS]])
    }

    func testWindowBoundsJustOverMaxSplits() {
        let b = ERes2NetEmbedder.windowBounds(sampleCount: maxS + 1, minSamples: minS, maxSamples: maxS)
        XCTAssertEqual(b.map { [$0.start, $0.end] }, [[0, maxS], [maxS, maxS + 1]])
    }

    func testWindowBoundsTwoFullWindows() {
        let b = ERes2NetEmbedder.windowBounds(sampleCount: 2 * maxS, minSamples: minS, maxSamples: maxS)
        XCTAssertEqual(b.map { [$0.start, $0.end] }, [[0, maxS], [maxS, 2 * maxS]])
    }

    func testWindowBoundsThreeWindows() {
        let b = ERes2NetEmbedder.windowBounds(sampleCount: 2 * maxS + 1, minSamples: minS, maxSamples: maxS)
        XCTAssertEqual(b.count, 3)
        XCTAssertEqual(b.last.map { [$0.start, $0.end] }, [2 * maxS, 2 * maxS + 1])
    }

    /// Invariants over many sizes: starts at 0, ends at n, contiguous, each <= maxS, non-empty.
    func testWindowBoundsCoverageInvariants() {
        for n in [1, 7999, 8000, 8001, 240_000, maxS, maxS + 1, 1_000_000, 1_234_567] {
            let b = ERes2NetEmbedder.windowBounds(sampleCount: n, minSamples: minS, maxSamples: maxS)
            XCTAssertEqual(b.first?.start, 0, "n=\(n)")
            XCTAssertEqual(b.last?.end, n, "n=\(n)")
            if b.count > 1 {
                for i in 1..<b.count {
                    XCTAssertEqual(b[i].start, b[i - 1].end, "contiguous n=\(n)")
                }
            }
            for w in b {
                XCTAssertGreaterThan(w.end, w.start, "non-empty n=\(n)")
                XCTAssertLessThanOrEqual(w.end - w.start, maxS, "<=maxS n=\(n)")
            }
        }
    }

    // MARK: tile

    func testTileEmptyStaysEmpty() {
        XCTAssertTrue(ERes2NetEmbedder.tile([], to: 100).isEmpty)
    }

    func testTileShorterRepeatsToExactLength() {
        let t = ERes2NetEmbedder.tile([1, 2, 3], to: 7)
        XCTAssertEqual(t, [1, 2, 3, 1, 2, 3, 1])
        XCTAssertEqual(t.count, 7)
    }

    func testTileEqualOrLongerUnchanged() {
        XCTAssertEqual(ERes2NetEmbedder.tile([1, 2, 3], to: 3), [1, 2, 3])
        XCTAssertEqual(ERes2NetEmbedder.tile([1, 2, 3, 4], to: 3), [1, 2, 3, 4])
    }

    // MARK: l2Normalize

    func testL2NormalizeZeroVectorStaysZero() {
        XCTAssertEqual(ERes2NetEmbedder.l2Normalize([0, 0, 0]), [0, 0, 0])
    }

    func testL2NormalizeProducesUnitNorm() {
        let n = ERes2NetEmbedder.l2Normalize([3, 4])
        XCTAssertEqual(n[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(n[1], 0.8, accuracy: 1e-6)
        XCTAssertEqual((n[0] * n[0] + n[1] * n[1]).squareRoot(), 1, accuracy: 1e-6)
    }

    // MARK: meanPoolNormalized

    func testMeanPoolEmpty() {
        XCTAssertTrue(ERes2NetEmbedder.meanPoolNormalized([]).isEmpty)
    }

    func testMeanPoolSingleIsUnitNorm() {
        let p = ERes2NetEmbedder.meanPoolNormalized([[3, 4]])
        XCTAssertEqual((p[0] * p[0] + p[1] * p[1]).squareRoot(), 1, accuracy: 1e-6)
    }

    func testMeanPoolIdenticalEqualsInput() {
        let v = ERes2NetEmbedder.l2Normalize([1, 1, 1, 1])
        let p = ERes2NetEmbedder.meanPoolNormalized([v, v, v])
        for i in 0..<4 { XCTAssertEqual(p[i], v[i], accuracy: 1e-6) }
    }

    func testMeanPoolOppositeVectorsCancelToZero() {
        let v = ERes2NetEmbedder.l2Normalize([1, 0, 0])
        let w = ERes2NetEmbedder.l2Normalize([-1, 0, 0])
        XCTAssertEqual(ERes2NetEmbedder.meanPoolNormalized([v, w]), [0, 0, 0])
    }

    func testMeanPoolFiltersMismatchedDims() {
        let p = ERes2NetEmbedder.meanPoolNormalized([[1, 0], [0, 1], [9, 9, 9]])
        XCTAssertEqual(p.count, 2)
        XCTAssertEqual(p[0], p[1], accuracy: 1e-6)  // mean of [1,0],[0,1] -> [.707,.707]
    }
}
