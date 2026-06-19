import XCTest
import Foundation
@testable import TranscriptedCore

/// Verifies the Swift `ERes2NetEmbedder` reproduces the CoreML model's embedding
/// for a known input, i.e. that the MLMultiArray plumbing (shape, byte layout,
/// output decode, L2-normalization) is correct. The Python conversion already
/// proved CoreML == the PyTorch reference (min cosine 0.99974); this closes the
/// loop on the Swift side.
///
/// Skips when the model isn't staged on this machine (e.g. CI without the model),
/// so it only asserts where the artifact is available:
///   ~/Library/Application Support/FluidAudio/Models/eres2net-embedding/Model.mlmodelc
final class ERes2NetEmbedderParityTests: XCTestCase {

    private struct Fixture: Decodable {
        let sampleRate: Int
        let samples: [Float]
        let embedding: [Float]
        let dim: Int
    }

    func testSwiftEmbedderMatchesGolden() throws {
        guard #available(macOS 14.0, *) else { throw XCTSkip("requires macOS 14") }

        guard let modelURL = stagedModelURL() else {
            throw XCTSkip("ERes2Net model not staged at FluidAudio Models cache")
        }
        guard let embedder = ERes2NetEmbedder(modelURL: modelURL) else {
            throw XCTSkip("ERes2Net model present but failed to load")
        }

        let fixture = try loadFixture()
        XCTAssertEqual(embedder.dimension, fixture.dim)

        let out = try XCTUnwrap(
            embedder.embed(samples: fixture.samples, sampleRate: fixture.sampleRate),
            "embedder returned nil")
        XCTAssertEqual(out.count, fixture.dim)

        let cos = cosine(out, fixture.embedding)
        XCTAssertGreaterThan(cos, 0.999, "Swift embedding diverged from CoreML golden (cosine \(cos))")

        // Output must be (near) unit norm — the embedder L2-normalizes.
        let norm = out.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        XCTAssertEqual(norm, 1.0, accuracy: 1e-3)
    }

    // MARK: - Helpers

    private func stagedModelURL() -> URL? {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let url = appSupport
            .appendingPathComponent("FluidAudio/Models/eres2net-embedding/Model.mlmodelc")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func loadFixture() throws -> Fixture {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/eres2net_swift_golden.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let denom = na.squareRoot() * nb.squareRoot()
        return denom > 0 ? dot / denom : 0
    }
}
