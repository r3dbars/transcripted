import XCTest
import CoreML
@testable import TranscriptedCore

/// The diarization backend switch on `DiarizationService`, the Nemotron preset
/// override, and the pure helpers of the WeSpeaker fallback embedder. None of
/// these tests load or download a model.
@available(macOS 14.0, *)
final class DiarizationBackendTests: XCTestCase {

    // MARK: - DiarizationBackend

    func testBackendRawValuesRoundTrip() throws {
        XCTAssertEqual(DiarizationBackend.allCases, [.pyannote, .nemotron])
        XCTAssertEqual(DiarizationBackend.pyannote.rawValue, "pyannote")
        XCTAssertEqual(DiarizationBackend.nemotron.rawValue, "nemotron")
        for backend in DiarizationBackend.allCases {
            XCTAssertEqual(DiarizationBackend(rawValue: backend.rawValue), backend)
        }
        XCTAssertNil(DiarizationBackend(rawValue: "sortformer"))

        let encoded = try JSONEncoder().encode(DiarizationBackend.allCases)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), #"["pyannote","nemotron"]"#)
        XCTAssertEqual(try JSONDecoder().decode([DiarizationBackend].self, from: encoded), DiarizationBackend.allCases)
    }

    // MARK: - DiarizationService

    func testServiceDefaultsToPyannote() async {
        let defaultService = await MainActor.run { DiarizationService() }
        XCTAssertEqual(defaultService.backend, .pyannote)
        let embedderOnly = await MainActor.run { DiarizationService(segmentEmbedder: StubEmbedder(result: nil)) }
        XCTAssertEqual(embedderOnly.backend, .pyannote)
    }

    func testServiceKeepsRequestedBackend() async {
        let service = await MainActor.run { DiarizationService(bundleProvider: { _ in nil }, backend: .nemotron) }
        XCTAssertEqual(service.backend, .nemotron)
        let ready = await MainActor.run { service.isReady }
        XCTAssertFalse(ready)
        let state = await MainActor.run { service.modelState }
        XCTAssertEqual(state, .notLoaded)
    }

    func testNemotronThresholdsFollowTheEmbedder() async {
        // No injected embedder: the WeSpeaker fallback's thresholds.
        let fallback = await MainActor.run { DiarizationService(backend: .nemotron) }
        XCTAssertEqual(fallback.activeSpeakerThresholds, .weSpeaker)
        // Injected embedder: its thresholds, same as the pyannote backend.
        let injected = await MainActor.run {
            DiarizationService(segmentEmbedder: StubEmbedder(result: nil, thresholds: .eRes2Net), backend: .nemotron)
        }
        XCTAssertEqual(injected.activeSpeakerThresholds, .eRes2Net)
    }

    func testNemotronDiarizeBeforeInitializeThrowsNotLoaded() async {
        let service = await MainActor.run { DiarizationService(bundleProvider: { _ in nil }, backend: .nemotron) }
        do {
            _ = try await service.diarizeOffline(samples: [Float](repeating: 0.01, count: 16000), sampleRate: 16000)
            XCTFail("expected a not-loaded error")
        } catch {
            XCTAssertTrue(error.localizedDescription.lowercased().contains("not loaded"), "\(error)")
        }
    }

    func testCleanupResetsNemotronService() async {
        let service = await MainActor.run { DiarizationService(backend: .nemotron) }
        await MainActor.run { service.cleanup() }
        let state = await MainActor.run { service.modelState }
        XCTAssertEqual(state, .notLoaded)
        let ready = await MainActor.run { service.isReady }
        XCTAssertFalse(ready)
    }

    func testReembedUsesTheExplicitEmbedderWithoutAnInjectedOne() async {
        // The Nemotron path embeds with its fallback embedder even though no
        // `segmentEmbedder` was injected, through the same slicing as reembedIfNeeded.
        let service = await MainActor.run { DiarizationService(backend: .nemotron) }
        let stub = StubEmbedder(result: [Float](repeating: 0.0625, count: 256))
        let segments = [
            SpeakerSegment(speakerId: 1, startTime: 0, endTime: 1.5, embedding: nil, qualityScore: 0.8),
            SpeakerSegment(speakerId: 2, startTime: 2, endTime: 2, embedding: nil, qualityScore: 0.7),
        ]
        let out = service.reembed(
            segments: segments,
            samples: [Float](repeating: 0.01, count: 16000 * 3),
            sampleRate: 16000,
            using: stub
        )
        XCTAssertEqual(out.map { $0.embedding?.count }, [256, nil])  // zero-length turn stays unembedded
        XCTAssertEqual(out.map(\.speakerId), [1, 2])
        XCTAssertEqual(out.map(\.qualityScore), [0.8, 0.7])
        XCTAssertEqual(stub.seenLengths, [24000])
        // With no injected embedder, reembedIfNeeded stays a no-op.
        XCTAssertEqual(service.reembedIfNeeded(segments: segments, samples: [], sampleRate: 16000).map { $0.embedding?.count }, [nil, nil])
    }

    // MARK: - Nemotron preset override

    func testPresetDefaultsToFast128() {
        XCTAssertEqual(NemotronDiarizationRunner.defaultPresetName, "fast128")
        XCTAssertEqual(NemotronDiarizationRunner.resolvePresetName(environment: [:]), "fast128")
        XCTAssertEqual(NemotronDiarizationRunner.resolvePresetName(environment: ["TRANSCRIPTED_NEMOTRON_PRESET": "   "]), "fast128")
    }

    func testPresetOverrideAcceptsKnownNames() {
        let key = NemotronDiarizationRunner.presetEnvironmentKey
        XCTAssertEqual(key, "TRANSCRIPTED_NEMOTRON_PRESET")
        XCTAssertEqual(NemotronDiarizationRunner.resolvePresetName(environment: [key: "fast32"]), "fast32")
        XCTAssertEqual(NemotronDiarizationRunner.resolvePresetName(environment: [key: " offline\n"]), "offline")
        XCTAssertEqual(NemotronDiarizationRunner.resolvePresetName(environment: [key: "fast32-int8"]), "fast32-int8")
    }

    func testPresetOverrideRejectsUnknownNames() {
        let key = NemotronDiarizationRunner.presetEnvironmentKey
        XCTAssertEqual(NemotronDiarizationRunner.resolvePresetName(environment: [key: "turbo"]), "fast128")
    }

    func testPublicPresetAccessorMatchesTheRunner() {
        let key = NemotronDiarizationRunner.presetEnvironmentKey
        let environments: [[String: String]] = [[:], [key: "fast32"], [key: " offline\n"], [key: "turbo"]]
        for env in environments {
            XCTAssertEqual(DiarizationService.resolvedNemotronPresetName(environment: env),
                           NemotronDiarizationRunner.resolvePresetName(environment: env))
        }
        XCTAssertEqual(DiarizationService.resolvedNemotronPresetName(environment: [:]), "fast128")
    }

    func testOfflinePresetAvoidsTheNeuralEngine() {
        XCTAssertEqual(NemotronDiarizationRunner.computeUnits(forPreset: "offline"), .cpuAndGPU)
        XCTAssertEqual(NemotronDiarizationRunner.computeUnits(forPreset: "offline-int8"), .cpuAndGPU)
        XCTAssertEqual(NemotronDiarizationRunner.computeUnits(forPreset: "fast128"), .all)
        XCTAssertEqual(NemotronDiarizationRunner.computeUnits(forPreset: "fast32"), .all)
    }

    // MARK: - FluidWeSpeakerSegmentEmbedder pure helpers

    func testWeSpeakerWindowBounds() {
        let window = 160_000, tail = 16_000
        XCTAssertEqual(FluidWeSpeakerSegmentEmbedder.windowBounds(sampleCount: 0, windowSamples: window, minTailSamples: tail), [])
        XCTAssertEqual(FluidWeSpeakerSegmentEmbedder.windowBounds(sampleCount: 8_000, windowSamples: window, minTailSamples: tail), [0..<8_000])
        XCTAssertEqual(FluidWeSpeakerSegmentEmbedder.windowBounds(sampleCount: 160_000, windowSamples: window, minTailSamples: tail), [0..<160_000])
        // 25 s: two full windows + a 5 s tail that is long enough to keep.
        XCTAssertEqual(
            FluidWeSpeakerSegmentEmbedder.windowBounds(sampleCount: 400_000, windowSamples: window, minTailSamples: tail),
            [0..<160_000, 160_000..<320_000, 320_000..<400_000]
        )
        // 10.5 s: the 0.5 s tail is skipped.
        XCTAssertEqual(
            FluidWeSpeakerSegmentEmbedder.windowBounds(sampleCount: 168_000, windowSamples: window, minTailSamples: tail),
            [0..<160_000]
        )
    }

    func testWeSpeakerUsableEmbeddingFilters() {
        XCTAssertNil(FluidWeSpeakerSegmentEmbedder.usableEmbedding([Float](repeating: 1, count: 192), dimension: 256))
        XCTAssertNil(FluidWeSpeakerSegmentEmbedder.usableEmbedding([Float](repeating: 0, count: 256), dimension: 256))
        var withNaN = [Float](repeating: 1, count: 256)
        withNaN[3] = .nan
        XCTAssertNil(FluidWeSpeakerSegmentEmbedder.usableEmbedding(withNaN, dimension: 256))

        let usable = FluidWeSpeakerSegmentEmbedder.usableEmbedding([Float](repeating: 2, count: 256), dimension: 256) ?? []
        XCTAssertEqual(usable.count, 256)
        var squaredNorm: Float = 0
        for value in usable { squaredNorm += value * value }
        XCTAssertEqual(squaredNorm.squareRoot(), 1, accuracy: 1e-5)
    }

    func testWeSpeakerEmbedderIdentity() {
        XCTAssertEqual(FluidWeSpeakerSegmentEmbedder.embedderIdentifier, "wespeaker-fluid-online")
        XCTAssertEqual(FluidWeSpeakerSegmentEmbedder.bundleDirectoryName, "online-diarizer-models")
    }

    // MARK: - Helpers

    final class StubEmbedder: SpeakerSegmentEmbedder, @unchecked Sendable {
        let dimension = 256
        let identifier = "stub"
        let thresholds: SpeakerEmbeddingThresholds
        let result: [Float]?
        private let lock = NSLock()
        private var _seen: [Int] = []
        var seenLengths: [Int] { lock.lock(); defer { lock.unlock() }; return _seen }
        init(result: [Float]?, thresholds: SpeakerEmbeddingThresholds = .weSpeaker) {
            self.result = result
            self.thresholds = thresholds
        }
        func embed(samples: [Float], sampleRate: Int) -> [Float]? {
            lock.lock(); _seen.append(samples.count); lock.unlock()
            return result
        }
    }
}
