import XCTest
import Foundation
@testable import TranscriptedCore

/// Promises of the generic fused-model voiceprint embedder, checked through
/// `embed(samples:sampleRate:)` with a stand-in model (no Core ML needed):
/// every model call fits the model's length bounds, short turns are tiled (never
/// padded with silence), long turns are windowed and pooled by talk time, the
/// result is unit length, and bad model output never becomes a voiceprint.
@available(macOS 14.0, *)
final class CoreMLSpeakerSegmentEmbedderTests: XCTestCase {

    /// Records every window the stand-in model is asked to embed.
    private final class CallLog: @unchecked Sendable {
        private let lock = NSLock()
        private var windows: [[Float]] = []
        func record(_ window: [Float]) { lock.lock(); windows.append(window); lock.unlock() }
        var calls: [[Float]] { lock.lock(); defer { lock.unlock() }; return windows }
    }

    private func plan(
        min: Int, max: Int, window: Int? = nil, hop: Int? = nil,
        pooling: SpeakerEmbeddingPooling = .talkTimeWeighted
    ) throws -> CoreMLSpeakerEmbeddingPlan {
        try CoreMLSpeakerEmbeddingPlan.resolve(
            minSamples: min, maxSamples: max, windowSamples: window, hopSamples: hop,
            pooling: pooling, modelLengths: nil)
    }

    private func embedder(
        _ plan: CoreMLSpeakerEmbeddingPlan, dimension: Int = 2, log: CallLog = CallLog(),
        model: @escaping @Sendable ([Float]) -> [Float]?
    ) throws -> CoreMLSpeakerSegmentEmbedder {
        try CoreMLSpeakerSegmentEmbedder(
            identifier: "candidate-a", dimension: dimension, thresholds: .weSpeaker, plan: plan,
            predict: { window in log.record(window); return model(window) })
    }

    private func norm(_ v: [Float]) -> Float { v.reduce(0) { $0 + $1 * $1 }.squareRoot() }

    // MARK: - Fitting audio to the model

    func testShortTurnReachesTheModelTiledToItsMinimum() throws {
        let log = CallLog()
        let e = try embedder(plan(min: 7, max: 100), log: log) { _ in [1, 0] }
        _ = e.embed(samples: [1, 2, 3], sampleRate: 16_000)
        XCTAssertEqual(log.calls, [[1, 2, 3, 1, 2, 3, 1]])
    }

    func testEveryModelCallFitsTheModelBounds() throws {
        let log = CallLog()
        let e = try embedder(plan(min: 8_000, max: 48_000, window: 32_000, hop: 16_000), log: log) { _ in [1, 0] }
        for count in [1, 7_999, 8_000, 31_999, 32_000, 32_001, 48_000, 100_000, 123_457] {
            XCTAssertNotNil(e.embed(samples: [Float](repeating: 0.1, count: count), sampleRate: 16_000), "n=\(count)")
        }
        XCTAssertFalse(log.calls.isEmpty)
        for window in log.calls {
            XCTAssertGreaterThanOrEqual(window.count, 8_000)
            XCTAssertLessThanOrEqual(window.count, 32_000)
        }
    }

    func testLongTurnIsCutIntoWindowsThatCoverItToTheEnd() throws {
        // 22 samples, window 10, hop 5: [0,10) [5,15) [10,20) [15,22).
        let log = CallLog()
        let e = try embedder(plan(min: 1, max: 10, window: 10, hop: 5), log: log) { _ in [1, 0] }
        let samples = (0..<22).map(Float.init)
        _ = e.embed(samples: samples, sampleRate: 16_000)
        XCTAssertEqual(log.calls, [
            Array(samples[0..<10]), Array(samples[5..<15]), Array(samples[10..<20]), Array(samples[15..<22]),
        ])
    }

    // MARK: - Pooling

    /// 10 s of one voice then 2 s of another, in back-to-back 10 s windows: the
    /// voiceprint leans 10:2 toward the first window.
    func testLongTurnPoolsWindowsByTalkTime() throws {
        let second = 16_000
        let samples = [Float](repeating: 1, count: 10 * second) + [Float](repeating: 2, count: 2 * second)
        let e = try embedder(plan(min: second / 2, max: 30 * second, window: 10 * second)) { window in
            window.first == 1 ? [1, 0] : [0, 1]
        }
        let v = try XCTUnwrap(e.embed(samples: samples, sampleRate: 16_000))
        let expected = CoreMLSpeakerSegmentEmbedder.l2Normalize([10, 2])
        XCTAssertEqual(v[0], expected[0], accuracy: 1e-6)
        XCTAssertEqual(v[1], expected[1], accuracy: 1e-6)
    }

    func testEqualPoolingGivesEveryWindowTheSameVote() throws {
        let second = 16_000
        let samples = [Float](repeating: 1, count: 10 * second) + [Float](repeating: 2, count: 2 * second)
        let e = try embedder(plan(min: second / 2, max: 30 * second, window: 10 * second, pooling: .equal)) { window in
            window.first == 1 ? [1, 0] : [0, 1]
        }
        let v = try XCTUnwrap(e.embed(samples: samples, sampleRate: 16_000))
        XCTAssertEqual(v[0], v[1], accuracy: 1e-6)
        XCTAssertEqual(norm(v), 1, accuracy: 1e-6)
    }

    /// A loud window must not outvote a longer quiet one: each window is
    /// normalized before it is weighted.
    func testWindowsAreNormalizedBeforePooling() throws {
        let samples = [Float](repeating: 1, count: 30) + [Float](repeating: 2, count: 10)
        let e = try embedder(plan(min: 1, max: 30, window: 30)) { window in
            window.first == 1 ? [1, 0] : [0, 1000]
        }
        let v = try XCTUnwrap(e.embed(samples: samples, sampleRate: 16_000))
        XCTAssertGreaterThan(v[0], v[1], "30 samples of the first voice outweigh 10 of the second")
    }

    func testVoiceprintIsUnitLength() throws {
        let e = try embedder(plan(min: 1, max: 100)) { _ in [3, 4] }
        let v = try XCTUnwrap(e.embed(samples: [Float](repeating: 0.2, count: 50), sampleRate: 16_000))
        XCTAssertEqual(v[0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(v[1], 0.8, accuracy: 1e-6)
    }

    // MARK: - Bad input and bad model output

    func testNon16kAudioIsRefusedWithoutCallingTheModel() throws {
        let log = CallLog()
        let e = try embedder(plan(min: 1, max: 100), log: log) { _ in [1, 0] }
        XCTAssertNil(e.embed(samples: [Float](repeating: 0.2, count: 50), sampleRate: 44_100))
        XCTAssertTrue(log.calls.isEmpty)
    }

    func testEmptyAudioHasNoVoiceprint() throws {
        let e = try embedder(plan(min: 1, max: 100)) { _ in [1, 0] }
        XCTAssertNil(e.embed(samples: [], sampleRate: 16_000))
    }

    func testOutputOfTheWrongSizeIsNotAVoiceprint() throws {
        let e = try embedder(plan(min: 1, max: 100), dimension: 2) { _ in [1, 0, 0] }
        XCTAssertNil(e.embed(samples: [Float](repeating: 0.2, count: 50), sampleRate: 16_000))
    }

    func testNaNOrZeroOutputIsNotAVoiceprint() throws {
        let nan = try embedder(plan(min: 1, max: 100)) { _ in [.nan, 1] }
        XCTAssertNil(nan.embed(samples: [Float](repeating: 0.2, count: 50), sampleRate: 16_000))
        let zero = try embedder(plan(min: 1, max: 100)) { _ in [0, 0] }
        XCTAssertNil(zero.embed(samples: [Float](repeating: 0.2, count: 50), sampleRate: 16_000))
    }

    func testAFailedWindowIsLeftOutAndTheRestStillCount() throws {
        let samples = [Float](repeating: 1, count: 10) + [Float](repeating: 2, count: 10)
        let e = try embedder(plan(min: 1, max: 10, window: 10)) { window in
            window.first == 1 ? [0, 5] : nil
        }
        XCTAssertEqual(e.embed(samples: samples, sampleRate: 16_000), [0, 1])
    }

    func testModelThatAlwaysFailsGivesNoVoiceprint() throws {
        let e = try embedder(plan(min: 1, max: 10, window: 10)) { _ in nil }
        XCTAssertNil(e.embed(samples: [Float](repeating: 1, count: 35), sampleRate: 16_000))
    }

    // MARK: - Configuration

    func testIdentifierMustBeSafeForADatabaseFileName() throws {
        let p = try plan(min: 1, max: 10)
        for bad in ["", "../speakers", "a/b", "has space", String(repeating: "x", count: 65)] {
            XCTAssertThrowsError(try CoreMLSpeakerSegmentEmbedder(
                identifier: bad, dimension: 2, thresholds: .weSpeaker, plan: p, predict: { _ in nil }), bad)
        }
        XCTAssertNoThrow(try CoreMLSpeakerSegmentEmbedder(
            identifier: "wavlm-base_plus.sv2", dimension: 2, thresholds: .weSpeaker, plan: p, predict: { _ in nil }))
        XCTAssertThrowsError(try CoreMLSpeakerSegmentEmbedder(
            identifier: "ok", dimension: 0, thresholds: .weSpeaker, plan: p, predict: { _ in nil }))
    }

    func testPlanReadsMinAndMaxFromTheModelWhenUnset() throws {
        let p = try CoreMLSpeakerEmbeddingPlan.resolve(
            minSamples: nil, maxSamples: nil, windowSamples: nil, hopSamples: nil,
            pooling: .talkTimeWeighted, modelLengths: .range(8_000...160_000))
        XCTAssertEqual(p, CoreMLSpeakerEmbeddingPlan(
            minSamples: 8_000, maxSamples: 160_000, windowSamples: 160_000, hopSamples: 160_000,
            pooling: .talkTimeWeighted))
    }

    func testPlanCapsTheDefaultWindowAt30SecondsForUnboundedModels() throws {
        let p = try CoreMLSpeakerEmbeddingPlan.resolve(
            minSamples: nil, maxSamples: nil, windowSamples: nil, hopSamples: nil,
            pooling: .talkTimeWeighted, modelLengths: .range(1...Int(Int32.max)))
        XCTAssertEqual(p.windowSamples, 480_000)
        XCTAssertEqual(p.hopSamples, 480_000)
    }

    func testFixedLengthModelGetsEveryCallAtThatLength() throws {
        let p = try CoreMLSpeakerEmbeddingPlan.resolve(
            minSamples: nil, maxSamples: nil, windowSamples: nil, hopSamples: nil,
            pooling: .talkTimeWeighted, modelLengths: .enumerated([48_000]))
        let log = CallLog()
        let e = try embedder(p, log: log) { _ in [1, 0] }
        _ = e.embed(samples: [Float](repeating: 0.1, count: 100_000), sampleRate: 16_000)
        _ = e.embed(samples: [Float](repeating: 0.1, count: 1_000), sampleRate: 16_000)
        XCTAssertEqual(Set(log.calls.map(\.count)), [48_000])
    }

    // MARK: - Models converted with enumerated lengths

    private let enumeratedSeconds = [1, 1.5, 2, 2.5, 3, 4, 5, 10].map { Int($0 * 16_000) }

    func testEnumeratedModelUsesItsLongestLengthUpTo30sAsTheWindow() throws {
        let p = try CoreMLSpeakerEmbeddingPlan.resolve(
            minSamples: nil, maxSamples: nil, windowSamples: nil, hopSamples: nil,
            pooling: .talkTimeWeighted, modelLengths: .enumerated(enumeratedSeconds.reversed()))
        XCTAssertEqual(p.allowedLengths, enumeratedSeconds)
        XCTAssertEqual(p.minSamples, 16_000)
        XCTAssertEqual(p.maxSamples, 160_000)
        XCTAssertEqual(p.windowSamples, 160_000)
        let long = try CoreMLSpeakerEmbeddingPlan.resolve(
            minSamples: nil, maxSamples: nil, windowSamples: nil, hopSamples: nil,
            pooling: .talkTimeWeighted, modelLengths: .enumerated([16_000, 320_000, 640_000]))
        XCTAssertEqual(long.windowSamples, 320_000, "longest length that is at most 30 s")
    }

    /// Every call has a length the model lists, and each call starts with the real
    /// audio it stands for: short pieces are tiled up to the next listed length,
    /// never cut.
    func testEnumeratedModelGetsOnlyListedLengthsAndNoAudioIsCut() throws {
        let p = try CoreMLSpeakerEmbeddingPlan.resolve(
            minSamples: nil, maxSamples: nil, windowSamples: nil, hopSamples: nil,
            pooling: .talkTimeWeighted, modelLengths: .enumerated(enumeratedSeconds))
        let log = CallLog()
        let e = try embedder(p, log: log) { _ in [1, 0] }
        for count in [100, 16_000, 22_400, 40_001, 70_000, 159_999, 160_001, 400_000] {
            let samples = (0..<count).map { Float($0 % 1000) / 1000 }
            let before = log.calls.count
            XCTAssertNotNil(e.embed(samples: samples, sampleRate: 16_000), "n=\(count)")
            let windows = CoreMLSpeakerSegmentEmbedder.windowBounds(
                sampleCount: count, window: p.windowSamples, hop: p.hopSamples)
            let calls = Array(log.calls[before...])
            XCTAssertEqual(calls.count, windows.count, "n=\(count)")
            for (call, window) in zip(calls, windows) {
                XCTAssertTrue(enumeratedSeconds.contains(call.count), "n=\(count): call of \(call.count)")
                XCTAssertEqual(Array(call.prefix(window.end - window.start)), Array(samples[window.start..<window.end]))
            }
        }
        XCTAssertEqual(p.callLength(forSampleCount: 22_400), 24_000, "1.4 s goes up to 1.5 s")
        XCTAssertEqual(p.callLength(forSampleCount: 32_000), 32_000, "a listed length is used as is")
    }

    func testEnumeratedWindowMustBeAListedLength() {
        XCTAssertThrowsError(try CoreMLSpeakerEmbeddingPlan.resolve(
            minSamples: nil, maxSamples: nil, windowSamples: 56_000, hopSamples: nil,
            pooling: .talkTimeWeighted, modelLengths: .enumerated(enumeratedSeconds)))
        XCTAssertNoThrow(try CoreMLSpeakerEmbeddingPlan.resolve(
            minSamples: nil, maxSamples: nil, windowSamples: 64_000, hopSamples: 32_000,
            pooling: .talkTimeWeighted, modelLengths: .enumerated(enumeratedSeconds)))
    }

    func testExplicitBoundsNarrowAnEnumeratedModel() throws {
        let p = try CoreMLSpeakerEmbeddingPlan.resolve(
            minSamples: 30_000, maxSamples: 80_000, windowSamples: nil, hopSamples: nil,
            pooling: .talkTimeWeighted, modelLengths: .enumerated(enumeratedSeconds))
        XCTAssertEqual(p.allowedLengths, [32_000, 40_000, 48_000, 64_000, 80_000])
        XCTAssertEqual(p.minSamples, 32_000)
        XCTAssertEqual(p.windowSamples, 80_000)
        XCTAssertThrowsError(try CoreMLSpeakerEmbeddingPlan.resolve(
            minSamples: 170_000, maxSamples: 200_000, windowSamples: nil, hopSamples: nil,
            pooling: .talkTimeWeighted, modelLengths: .enumerated(enumeratedSeconds)))
    }

    func testPlanRejectsSettingsThatCannotCoverATurn() {
        func resolve(_ min: Int?, _ max: Int?, _ window: Int?, _ hop: Int?,
                     lengths: CoreMLVoiceprintInputLengths? = nil) throws -> CoreMLSpeakerEmbeddingPlan {
            try CoreMLSpeakerEmbeddingPlan.resolve(
                minSamples: min, maxSamples: max, windowSamples: window, hopSamples: hop,
                pooling: .talkTimeWeighted, modelLengths: lengths)
        }
        XCTAssertThrowsError(try resolve(nil, nil, nil, nil), "no bounds from the model or the configuration")
        XCTAssertThrowsError(try resolve(100, 10, nil, nil), "min above max")
        XCTAssertThrowsError(try resolve(10, 100, 200, nil), "window above max")
        XCTAssertThrowsError(try resolve(10, 100, 5, nil), "window below min")
        XCTAssertThrowsError(try resolve(10, 100, 50, 60), "hop longer than the window leaves gaps")
        XCTAssertThrowsError(try resolve(10, 100, 50, 0), "zero hop")
    }

    /// ERes2Net runs through this embedder with its original policy: 0.5 s
    /// minimum, back-to-back 30 s windows, equal-weight pooling.
    func testERes2NetKeepsItsOriginalLengthPolicy() throws {
        let config = ERes2NetEmbedder.configuration(modelURL: URL(fileURLWithPath: "/nonexistent/Model.mlmodelc"))
        XCTAssertEqual(config.identifier, "eres2net")
        XCTAssertEqual(config.dimension, 192)
        XCTAssertEqual(config.thresholds, .eRes2Net)
        let p = try CoreMLSpeakerEmbeddingPlan.resolve(
            minSamples: config.minSamples, maxSamples: config.maxSamples,
            windowSamples: config.windowSamples, hopSamples: config.hopSamples,
            pooling: config.pooling, modelLengths: .range(1...1))
        XCTAssertEqual(p, CoreMLSpeakerEmbeddingPlan(
            minSamples: 8_000, maxSamples: 480_000, windowSamples: 480_000, hopSamples: 480_000, pooling: .equal))
    }

    func testMissingModelFileIsAnErrorNotACrash() {
        let config = CoreMLSpeakerEmbedderConfiguration(
            modelURL: URL(fileURLWithPath: "/nonexistent/model.mlmodelc"),
            identifier: "candidate-a", dimension: 192, thresholds: .weSpeaker)
        XCTAssertThrowsError(try CoreMLSpeakerSegmentEmbedder(configuration: config)) { error in
            XCTAssertTrue(error is CoreMLSpeakerEmbedderError)
            XCTAssertFalse(error.localizedDescription.contains("/nonexistent"), "errors carry no paths")
        }
        XCTAssertNil(ERes2NetEmbedder(modelURL: URL(fileURLWithPath: "/nonexistent/Model.mlmodelc")))
    }
}

/// With the ERes2Net model staged, a fused model dropped in with only its path, id
/// and size (length bounds read from the model) reproduces the ERes2Net golden.
/// Skips when the model isn't on this machine.
@available(macOS 14.0, *)
final class CoreMLSpeakerSegmentEmbedderModelTests: XCTestCase {
    private struct Fixture: Decodable {
        let sampleRate: Int
        let samples: [Float]
        let embedding: [Float]
        let dim: Int
    }

    func testModelLoadedFromItsOwnShapeMatchesTheGolden() throws {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { throw XCTSkip("no application support dir") }
        let url = appSupport.appendingPathComponent("FluidAudio/Models/eres2net-embedding/Model.mlmodelc")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("ERes2Net model not staged") }
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/eres2net_swift_golden.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))

        let embedder = try CoreMLSpeakerSegmentEmbedder(configuration: CoreMLSpeakerEmbedderConfiguration(
            modelURL: url, identifier: "eres2net-generic", dimension: fixture.dim, thresholds: .eRes2Net))
        XCTAssertEqual(embedder.plan.minSamples, 8_000)
        XCTAssertEqual(embedder.plan.maxSamples, 480_000)
        let out = try XCTUnwrap(embedder.embed(samples: fixture.samples, sampleRate: fixture.sampleRate))
        var dot: Float = 0
        for i in 0..<out.count { dot += out[i] * fixture.embedding[i] }
        let goldenNorm = fixture.embedding.reduce(0) { $0 + $1 * $1 }.squareRoot()
        XCTAssertGreaterThan(dot / goldenNorm, 0.999)
    }
}
