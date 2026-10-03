import XCTest
import Foundation
import CoreML
@preconcurrency import FluidAudio
@testable import TranscriptedCore

/// Promise: `NemotronDiarizationRunner.run` feeds the recording to Nemotron in
/// slices (to keep the whole-recording mel and padded copy out of memory) and still
/// gives exactly what FluidAudio's one-shot `processComplete` gives: the same
/// probabilities bit for bit, the same frame count, and the same speaker turns.
/// Back-to-back runs on one runner don't carry anything over.
///
/// Skips unless the fast128 model is in FluidAudio's cache on this machine:
///   ~/Library/Application Support/FluidAudio/Models/nemotron-3-diarization/
/// It never downloads. Runs on CPU so results are deterministic.
final class NemotronStreamingParityTests: XCTestCase {

    private var stagingDirectory: URL?

    override func tearDownWithError() throws {
        if let dir = stagingDirectory {
            // Only the temp dir this test made (symlinks, never the model cache).
            precondition(dir.path.hasPrefix(FileManager.default.temporaryDirectory.path))
            try? FileManager.default.removeItem(at: dir)
        }
        stagingDirectory = nil
        try super.tearDownWithError()
    }

    func testStreamingRunMatchesProcessCompleteAcrossLengths() async throws {
        let config = Nemotron3Config.fast128
        let models = try await loadStagedModels(config: config)
        let runner = NemotronDiarizationRunner(presetName: "fast128", config: config, models: models)

        let lengths = [
            16_000 * 3 + 37,      // below one slice and one chunk
            NemotronDiarizationRunner.feedSliceSamples, // exactly one slice
            16_000 * 214 + 137,   // many slices, short tail chunk
        ]
        for (index, count) in lengths.enumerated() {
            let audio = makeAudio(count: count, seed: UInt64(index + 1))
            let streamed = try await runner.run(samples: audio)
            let reference = try Nemotron3Diarizer(config: config, models: models).processComplete(audio)
            assertSame(streamed, reference, numSpeakers: config.numSpeakers, label: "\(count) samples")
        }
    }

    func testBackToBackRunsDoNotCarryOver() async throws {
        let config = Nemotron3Config.fast128
        let models = try await loadStagedModels(config: config)
        let runner = NemotronDiarizationRunner(presetName: "fast128", config: config, models: models)

        let longer = makeAudio(count: 16_000 * 25 + 11, seed: 7)
        let shorter = makeAudio(count: 16_000 * 6 + 3, seed: 9)
        _ = try await runner.run(samples: longer)
        let second = try await runner.run(samples: shorter)
        let reference = try Nemotron3Diarizer(config: config, models: models).processComplete(shorter)
        assertSame(second, reference, numSpeakers: config.numSpeakers, label: "second run")
    }

    // MARK: - Helpers

    private func assertSame(
        _ streamed: NemotronFrameProbabilities,
        _ reference: (probabilities: [Float], frameCount: Int),
        numSpeakers: Int,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(streamed.numSpeakers, numSpeakers, label, file: file, line: line)
        XCTAssertEqual(streamed.frameCount, reference.frameCount, "\(label): frame count", file: file, line: line)
        XCTAssertEqual(
            streamed.probabilities.map(\.bitPattern),
            reference.probabilities.map(\.bitPattern),
            "\(label): probabilities differ", file: file, line: line)

        let streamedTurns = NemotronTurnBuilder.turns(
            probabilities: streamed.probabilities,
            frameCount: streamed.frameCount,
            numSpeakers: streamed.numSpeakers,
            frameSeconds: streamed.frameSeconds)
        let referenceTurns = NemotronTurnBuilder.turns(
            probabilities: reference.probabilities,
            frameCount: reference.frameCount,
            numSpeakers: numSpeakers,
            frameSeconds: streamed.frameSeconds)
        XCTAssertEqual(streamedTurns, referenceTurns, "\(label): turns", file: file, line: line)
    }

    /// Symlink the cached fast128 files into a flat temp dir, the layout
    /// `Nemotron3Models.load(config:directory:)` expects. Never downloads.
    private func loadStagedModels(config: Nemotron3Config) async throws -> Nemotron3Models {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw XCTSkip("no Application Support directory")
        }
        let cache = appSupport.appendingPathComponent("FluidAudio/Models/nemotron-3-diarization")
        let model = cache.appendingPathComponent("monolithic/Nemotron3Diarizer_fast128.mlmodelc")
        let silence = cache.appendingPathComponent("learnable_sil_emb.bin")
        let fm = FileManager.default
        guard fm.fileExists(atPath: model.path), fm.fileExists(atPath: silence.path) else {
            throw XCTSkip("Nemotron fast128 model not staged in the FluidAudio Models cache")
        }
        let dir = fm.temporaryDirectory.appendingPathComponent("nemotron-parity-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        stagingDirectory = dir
        try fm.createSymbolicLink(at: dir.appendingPathComponent(model.lastPathComponent), withDestinationURL: model)
        try fm.createSymbolicLink(at: dir.appendingPathComponent(silence.lastPathComponent), withDestinationURL: silence)
        return try await Nemotron3Models.load(config: config, directory: dir, computeUnits: .cpuOnly)
    }

    /// Deterministic speech-like audio: alternating pitch bands with pauses plus a
    /// little seeded noise.
    private func makeAudio(count: Int, seed: UInt64) -> [Float] {
        var rng = seed
        func noise() -> Float {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(rng >> 40) / Float(1 << 24) - 0.5
        }
        let bands: [Float] = [110, 210, 160, 260, 0]
        var out = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let t = Float(i) / 16_000
            let segment = Int(t / 2.3) % bands.count
            let gate: Float = segment == bands.count - 1 ? 0 : 1
            let am = 0.5 + 0.5 * sinf(2 * .pi * 4.1 * t)
            let f0 = bands[segment] + 25 * sinf(2 * .pi * 0.7 * t)
            out[i] = gate * am * (0.25 * sinf(2 * .pi * f0 * t) + 0.1 * sinf(2 * .pi * 2.7 * f0 * t)) + 0.01 * noise()
        }
        return out
    }
}
