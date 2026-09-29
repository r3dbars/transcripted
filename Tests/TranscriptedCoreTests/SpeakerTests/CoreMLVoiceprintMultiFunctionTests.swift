import XCTest
import Foundation
@testable import TranscriptedCore

/// Promises for multifunction voiceprint models (one fixed-length Core ML function
/// per input length, like the ReDimNet2 builds' `len_<samples>`):
///   - every model call runs on the function built for exactly that call's length,
///     and pieces between lengths are tiled up to the next one;
///   - each function is loaded once, on first use, and a function that fails to
///     load fails only its own calls;
///   - function names come from the model when it lists more than one, else from
///     the configuration; a single-function model is loaded as before.
/// Checked with stand-in functions (no Core ML needed).
@available(macOS 15.0, *)
final class CoreMLVoiceprintMultiFunctionTests: XCTestCase {

    /// Records which function each call ran on and every function load.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [(function: String, count: Int)] = []
        private var loaded: [String] = []
        func call(_ function: String, _ count: Int) { lock.lock(); calls.append((function, count)); lock.unlock() }
        func load(_ function: String) { lock.lock(); loaded.append(function); lock.unlock() }
        var callLog: [(function: String, count: Int)] { lock.lock(); defer { lock.unlock() }; return calls }
        var loads: [String] { lock.lock(); defer { lock.unlock() }; return loaded }
    }

    private let second = 16_000
    private var lengths: [Int] { [1, 2, 4, 8, 10].map { $0 * second } }
    private var functions: [Int: String] {
        Dictionary(uniqueKeysWithValues: lengths.map { ($0, "len_\($0)") })
    }

    private func router(
        _ recorder: Recorder, failing: Set<String> = []
    ) -> CoreMLVoiceprintFunctionRouter {
        CoreMLVoiceprintFunctionRouter(functionsByLength: functions) { name in
            recorder.load(name)
            if failing.contains(name) { throw CoreMLSpeakerEmbedderError("stand-in load failure") }
            return { window in recorder.call(name, window.count); return [1, 0] }
        }
    }

    private func embedder(_ router: CoreMLVoiceprintFunctionRouter) throws -> CoreMLSpeakerSegmentEmbedder {
        let plan = try CoreMLSpeakerEmbeddingPlan.resolve(
            minSamples: nil, maxSamples: nil, windowSamples: nil, hopSamples: nil,
            pooling: .talkTimeWeighted, modelLengths: .enumerated(router.lengths))
        return try CoreMLSpeakerSegmentEmbedder(
            identifier: "multi-candidate", dimension: 2, thresholds: .weSpeaker, plan: plan,
            predict: { router.predict($0) })
    }

    // MARK: - Routing

    func testEveryCallRunsOnTheFunctionBuiltForItsLength() throws {
        let recorder = Recorder()
        let e = try embedder(router(recorder))
        // 0.3 s, 1 s, 1.5 s, 4 s, 7 s, 10 s, and 23 s (10 + 10 + 3 s windows).
        for count in [4_800, 16_000, 24_000, 64_000, 112_000, 160_000, 368_000] {
            XCTAssertNotNil(e.embed(samples: [Float](repeating: 0.1, count: count), sampleRate: 16_000), "n=\(count)")
        }
        let log = recorder.callLog
        XCTAssertFalse(log.isEmpty)
        for call in log {
            XCTAssertEqual(call.function, "len_\(call.count)", "a \(call.count)-sample call ran on \(call.function)")
        }
        XCTAssertEqual(log.map(\.count), [
            16_000, 16_000, 32_000, 64_000, 128_000, 160_000, 160_000, 160_000, 64_000,
        ], "pieces between lengths go up to the next length (7 s -> 8 s, 3 s -> 4 s)")
    }

    func testEachFunctionLoadsOnceAndOnlyWhenFirstUsed() throws {
        let recorder = Recorder()
        let r = router(recorder)
        let e = try embedder(r)
        XCTAssertEqual(recorder.loads, [], "nothing loads before a call needs it")
        for _ in 0..<5 {
            _ = e.embed(samples: [Float](repeating: 0.1, count: 2 * second), sampleRate: 16_000)
        }
        XCTAssertEqual(recorder.loads, ["len_32000"])
        _ = e.embed(samples: [Float](repeating: 0.1, count: 4 * second), sampleRate: 16_000)
        _ = e.embed(samples: [Float](repeating: 0.1, count: 2 * second), sampleRate: 16_000)
        XCTAssertEqual(recorder.loads, ["len_32000", "len_64000"])
    }

    func testPreloadLoadsOneFunctionAndReportsItsFailure() throws {
        let recorder = Recorder()
        let r = router(recorder, failing: ["len_16000"])
        XCTAssertNoThrow(try r.preload(length: 10 * second))
        XCTAssertEqual(recorder.loads, ["len_160000"])
        XCTAssertThrowsError(try r.preload(length: second))
        XCTAssertThrowsError(try r.preload(length: 3 * second), "no function takes 3 s")
    }

    func testAFunctionThatFailsToLoadFailsOnlyItsOwnCallsAndIsNotRetried() throws {
        let recorder = Recorder()
        let e = try embedder(router(recorder, failing: ["len_16000"]))
        XCTAssertNil(e.embed(samples: [Float](repeating: 0.1, count: second), sampleRate: 16_000))
        XCTAssertNil(e.embed(samples: [Float](repeating: 0.1, count: second / 2), sampleRate: 16_000))
        XCTAssertNotNil(e.embed(samples: [Float](repeating: 0.1, count: 2 * second), sampleRate: 16_000))
        XCTAssertEqual(recorder.loads.filter { $0 == "len_16000" }.count, 1)
    }

    func testACallWithNoFunctionForItsLengthFailsWithoutLoadingAnything() {
        let recorder = Recorder()
        let r = router(recorder)
        XCTAssertNil(r.predict([Float](repeating: 0.1, count: 12_345)))
        XCTAssertEqual(recorder.loads, [])
        XCTAssertEqual(r.lengths, lengths)
    }

    // MARK: - Where function names come from

    /// Releasing drops every loaded function (their GPU memory with them); the next
    /// call for a length loads its function again, and nothing else reloads.
    func testReleasingDropsLoadedFunctionsAndTheNextCallReloadsOnlyItsOwn() {
        let recorder = Recorder()
        let r = router(recorder)
        _ = r.predict([Float](repeating: 0.1, count: 2 * second))
        _ = r.predict([Float](repeating: 0.1, count: 4 * second))
        XCTAssertEqual(r.loadedCount, 2)

        r.releaseLoadedFunctions()
        XCTAssertEqual(r.loadedCount, 0)

        XCTAssertNotNil(r.predict([Float](repeating: 0.1, count: 2 * second)))
        XCTAssertEqual(r.loadedCount, 1)
        XCTAssertEqual(recorder.loads, ["len_32000", "len_64000", "len_32000"])
    }

    /// A function that failed to load is tried again after a release, so a
    /// transient failure doesn't disable a length for the rest of the session.
    func testAFailedFunctionIsRetriedAfterARelease() {
        let recorder = Recorder()
        let r = router(recorder, failing: ["len_16000"])
        XCTAssertNil(r.predict([Float](repeating: 0.1, count: second)))
        r.releaseLoadedFunctions()
        XCTAssertNil(r.predict([Float](repeating: 0.1, count: second)))
        XCTAssertEqual(recorder.loads, ["len_16000", "len_16000"])
    }

    /// Without an idle-release setting, loaded functions stay loaded.
    func testWithoutIdleReleaseFunctionsStayLoaded() {
        let recorder = Recorder()
        let r = router(recorder)
        _ = r.predict([Float](repeating: 0.1, count: 8 * second))
        XCTAssertEqual(r.loadedCount, 1)
        XCTAssertEqual(recorder.loads, ["len_128000"])
    }

    func testFunctionNameCarriesItsLength() {
        XCTAssertEqual(CoreMLVoiceprintFunctions.length(fromFunctionName: "len_64000"), 64_000)
        for bad in ["main", "len_", "len_0", "len_-5", "len_4s", "64000", "xlen_64000"] {
            XCTAssertNil(CoreMLVoiceprintFunctions.length(fromFunctionName: bad), bad)
        }
    }

    func testTheModelsOwnFunctionsWinOverTheConfiguration() throws {
        let map = try CoreMLVoiceprintFunctions.resolve(
            modelFunctions: [("len_16000", 16_000), ("len_32000", 32_000)],
            configured: [48_000: "len_48000"])
        XCTAssertEqual(map, [16_000: "len_16000", 32_000: "len_32000"])
    }

    func testAFunctionIsKeyedByTheLengthItsInputDeclares() throws {
        let map = try CoreMLVoiceprintFunctions.resolve(
            modelFunctions: [("short", 16_000), ("long", 160_000), ("len_48000", nil)], configured: nil)
        XCTAssertEqual(map, [16_000: "short", 160_000: "long", 48_000: "len_48000"],
                       "a function whose input length can't be read falls back to the length in its name")
    }

    func testFunctionsWithoutAUsableLengthAreLeftOut() throws {
        let map = try CoreMLVoiceprintFunctions.resolve(
            modelFunctions: [("len_16000", 16_000), ("flexible", nil), ("len_32000", 32_000)], configured: nil)
        XCTAssertEqual(map, [16_000: "len_16000", 32_000: "len_32000"])
        XCTAssertThrowsError(try CoreMLVoiceprintFunctions.resolve(
            modelFunctions: [("a", nil), ("b", nil)], configured: nil), "no function has a length")
    }

    func testTwoFunctionsForOneLengthIsAnError() {
        XCTAssertThrowsError(try CoreMLVoiceprintFunctions.resolve(
            modelFunctions: [("a", 16_000), ("b", 16_000)], configured: nil))
    }

    func testConfiguredFunctionsAreUsedWhenTheModelDoesNotListAny() throws {
        let configured = [16_000: "len_16000", 64_000: "len_64000"]
        XCTAssertEqual(try CoreMLVoiceprintFunctions.resolve(modelFunctions: nil, configured: configured), configured)
        XCTAssertEqual(try CoreMLVoiceprintFunctions.resolve(modelFunctions: [], configured: configured), configured)
        XCTAssertThrowsError(try CoreMLVoiceprintFunctions.resolve(
            modelFunctions: nil, configured: [0: "len_0"]), "a configured length must be positive")
    }

    func testASingleFunctionModelIsLoadedAsBefore() throws {
        XCTAssertNil(try CoreMLVoiceprintFunctions.resolve(modelFunctions: nil, configured: nil))
        XCTAssertNil(try CoreMLVoiceprintFunctions.resolve(modelFunctions: [], configured: nil))
        XCTAssertNil(try CoreMLVoiceprintFunctions.resolve(modelFunctions: [("main", 48_000)], configured: nil))
    }
}

/// Swift vs Python parity for a real multifunction build, loaded the way the app and
/// the harness load it (`CoreMLSpeakerSegmentEmbedder(configuration:)`: function list
/// read from the model, one function per clip length). Runs only when
/// `TRANSCRIPTED_VOICEPRINT_PARITY_MANIFEST` names a manifest written by the
/// voiceprint bake-off (model path, dimension, clips as raw float32 files with the
/// Python runtime's embedding for each); skips otherwise.
@available(macOS 15.0, *)
final class CoreMLVoiceprintMultiFunctionParityTests: XCTestCase {
    private struct Manifest: Decodable {
        struct Clip: Decodable {
            let id: String
            let samples: String
            let reference: [Float]
        }
        let model: String
        let identifier: String
        let dim: Int
        let minCosine: Float
        let clips: [Clip]
    }

    func testEveryClipMatchesThePythonRuntime() throws {
        guard let path = ProcessInfo.processInfo.environment["TRANSCRIPTED_VOICEPRINT_PARITY_MANIFEST"] else {
            throw XCTSkip("set TRANSCRIPTED_VOICEPRINT_PARITY_MANIFEST to run the Swift/Python voiceprint parity check")
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        let embedder = try CoreMLSpeakerSegmentEmbedder(configuration: CoreMLSpeakerEmbedderConfiguration(
            modelURL: URL(fileURLWithPath: manifest.model), identifier: manifest.identifier,
            dimension: manifest.dim, thresholds: .weSpeaker))
        XCTAssertNotNil(embedder.functionsByLength, "the model under test is a multifunction build")
        XCTAssertFalse(manifest.clips.isEmpty)
        var cosines: [Float] = []
        for clip in manifest.clips {
            let data = try Data(contentsOf: URL(fileURLWithPath: clip.samples))
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            XCTAssertTrue(embedder.plan.allowedLengths?.contains(samples.count) ?? false,
                          "\(clip.id): \(samples.count) samples is one of the model's lengths")
            let vector = try XCTUnwrap(embedder.embed(samples: samples, sampleRate: 16_000), clip.id)
            let reference = CoreMLSpeakerSegmentEmbedder.l2Normalize(clip.reference)
            var dot: Float = 0
            for i in 0..<vector.count { dot += vector[i] * reference[i] }
            cosines.append(dot)
            XCTAssertGreaterThanOrEqual(dot, manifest.minCosine, clip.id)
        }
        let mean = cosines.reduce(0, +) / Float(cosines.count)
        print(String(format: "voiceprint parity %@: %d clips, min %.6f, mean %.6f",
                     manifest.identifier, cosines.count, cosines.min() ?? 0, mean))
    }
}
