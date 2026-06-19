import XCTest
import Foundation
@testable import TranscriptedCore

/// Model-backed behavior tests for ERes2NetEmbedder.embed(...): dimension,
/// input validation, the short-clip tiling path, the long-clip multi-window
/// path, determinism, unit-norm output, and finite (no NaN/Inf) output on
/// silence. Skips when the model isn't staged on this machine.
@available(macOS 14.0, *)
final class ERes2NetEmbedderModelTests: XCTestCase {

    private func loadEmbedder() throws -> ERes2NetEmbedder {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw XCTSkip("no application support dir")
        }
        let url = appSupport.appendingPathComponent("FluidAudio/Models/eres2net-embedding/Model.mlmodelc")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("ERes2Net model not staged")
        }
        guard let e = ERes2NetEmbedder(modelURL: url) else {
            throw XCTSkip("ERes2Net model present but failed to load")
        }
        return e
    }

    private func tone(_ n: Int, freq: Double = 220) -> [Float] {
        (0..<n).map { Float(0.3 * sin(2 * Double.pi * freq * Double($0) / 16000)) }
    }

    private func assertFinite(_ v: [Float]) {
        for x in v { XCTAssertFalse(x.isNaN, "NaN"); XCTAssertFalse(x.isInfinite, "Inf") }
    }

    private func assertUnitNorm(_ v: [Float]) {
        let n = v.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        XCTAssertEqual(n, 1, accuracy: 1e-3)
    }

    func testDimensionAndIdentifier() throws {
        let e = try loadEmbedder()
        XCTAssertEqual(e.dimension, 192)
        XCTAssertEqual(e.identifier, "eres2net")
    }

    func testRejectsNon16kSampleRate() throws {
        XCTAssertNil(try loadEmbedder().embed(samples: tone(24000), sampleRate: 44100))
    }

    func testRejectsEmptyInput() throws {
        XCTAssertNil(try loadEmbedder().embed(samples: [], sampleRate: 16000))
    }

    func testShortClipUsesTilingPath() throws {
        let out = try XCTUnwrap(try loadEmbedder().embed(samples: tone(4000), sampleRate: 16000))
        XCTAssertEqual(out.count, 192)
        assertFinite(out); assertUnitNorm(out)
    }

    func testNormalClip() throws {
        let out = try XCTUnwrap(try loadEmbedder().embed(samples: tone(24000), sampleRate: 16000))
        XCTAssertEqual(out.count, 192)
        assertFinite(out); assertUnitNorm(out)
    }

    func testLongClipUsesMultiWindowPath() throws {
        // > 480000 samples (30s) exercises windowBounds + meanPoolNormalized.
        let out = try XCTUnwrap(try loadEmbedder().embed(samples: tone(500_000), sampleRate: 16000))
        XCTAssertEqual(out.count, 192)
        assertFinite(out); assertUnitNorm(out)
    }

    func testDeterministic() throws {
        let e = try loadEmbedder()
        let s = tone(24000)
        let a = try XCTUnwrap(e.embed(samples: s, sampleRate: 16000))
        let b = try XCTUnwrap(e.embed(samples: s, sampleRate: 16000))
        let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }  // both unit norm -> dot == cosine
        XCTAssertEqual(dot, 1, accuracy: 1e-4)
    }

    func testDifferentTonesProduceDifferentEmbeddings() throws {
        let e = try loadEmbedder()
        let a = try XCTUnwrap(e.embed(samples: tone(24000, freq: 180), sampleRate: 16000))
        let b = try XCTUnwrap(e.embed(samples: tone(24000, freq: 600), sampleRate: 16000))
        let dot = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        XCTAssertLessThan(dot, 0.999, "distinct inputs should not be identical")
    }

    func testSilenceProducesFiniteEmbedding() throws {
        let out = try XCTUnwrap(try loadEmbedder().embed(
            samples: Array(repeating: Float(0), count: 24000), sampleRate: 16000))
        XCTAssertEqual(out.count, 192)
        assertFinite(out)  // must not be NaN/Inf even on degenerate all-zero audio
    }
}
