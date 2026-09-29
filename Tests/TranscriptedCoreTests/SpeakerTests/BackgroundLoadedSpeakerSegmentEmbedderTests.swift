import Foundation
import XCTest
@testable import TranscriptedCore

/// Promises of the voiceprint that loads in the background, so building the
/// meeting stack at launch never loads a Core ML model on the main actor:
///   - building it, and a diarizer and speaker database around it, loads nothing;
///   - the load runs off the actor that waits for it, and that actor keeps running;
///   - a meeting that re-embeds before the load ends waits and gets the loaded
///     model's vectors, never nil for being early;
///   - a failed load, or a model that isn't the one declared, yields no vectors at
///     all, so the model's database never gets another model's vectors;
///   - however many callers wait at once, the model loads once.
@available(macOS 14.0, *)
final class BackgroundLoadedSpeakerSegmentEmbedderTests: XCTestCase {

    /// A loaded model: returns `vector` for any audio.
    final class FixedEmbedder: SpeakerSegmentEmbedder, @unchecked Sendable {
        let identifier: String
        let dimension: Int
        let thresholds: SpeakerEmbeddingThresholds
        let vector: [Float]
        init(identifier: String = "test-bg", dimension: Int = 4, thresholds: SpeakerEmbeddingThresholds = .reDimNet2B4) {
            self.identifier = identifier
            self.dimension = dimension
            self.thresholds = thresholds
            self.vector = SpeakerVectorMath.l2Normalize((0..<dimension).map { Float($0 + 1) })
        }
        func embed(samples: [Float], sampleRate: Int) -> [Float]? { samples.isEmpty ? nil : vector }
    }

    /// Stands in for `MLModel(contentsOf:)`: counts calls, notes the thread, and
    /// with `holds` waits for `release()` so a test can act mid-load.
    final class Loader: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        private var _ranOnMainThread = false
        private let hold: DispatchSemaphore?
        let reached = DispatchSemaphore(value: 0)
        let result: (any SpeakerSegmentEmbedder)?

        init(result: (any SpeakerSegmentEmbedder)?, holds: Bool = false) {
            self.result = result
            self.hold = holds ? DispatchSemaphore(value: 0) : nil
        }

        var calls: Int { lock.lock(); defer { lock.unlock() }; return _calls }
        var ranOnMainThread: Bool { lock.lock(); defer { lock.unlock() }; return _ranOnMainThread }

        func load() -> (any SpeakerSegmentEmbedder)? {
            lock.lock()
            _calls += 1
            _ranOnMainThread = _ranOnMainThread || Thread.isMainThread
            lock.unlock()
            reached.signal()
            hold?.wait()
            return result
        }

        func release() { hold?.signal() }

        /// Waits off the main actor for the load to start. The wide bound only
        /// stops a broken run from hanging the suite.
        func waitUntilReached() async -> Bool {
            await BackgroundLoadedSpeakerSegmentEmbedderTests.onPlainThread { self.reached.wait(timeout: .now() + 120) == .success }
        }
    }

    /// Runs blocking work on a GCD thread, not Swift's cooperative pool, so a
    /// caller parked in `embed` can't starve the tasks that would release it.
    static func onPlainThread<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: body()) }
        }
    }

    private func makeEmbedder(_ loader: Loader, dimension: Int = 4) -> BackgroundLoadedSpeakerSegmentEmbedder {
        BackgroundLoadedSpeakerSegmentEmbedder(
            identifier: "test-bg",
            dimension: dimension,
            thresholds: .reDimNet2B4,
            load: { loader.load() }
        )
    }

    private func segment(_ start: Double, _ end: Double) -> SpeakerSegment {
        // A native 256-d WeSpeaker vector, as the diarizer hands it over.
        SpeakerSegment(speakerId: 1, startTime: start, endTime: end,
                       embedding: Array(repeating: Float(0.5), count: 256), qualityScore: 0.9)
    }

    private let audio = Array(repeating: Float(0.01), count: 16_000 * 4)

    // MARK: - Promises

    @MainActor
    func testBuildingTheMeetingStackAroundItLoadsNothing() throws {
        let loader = Loader(result: FixedEmbedder())
        let embedder = makeEmbedder(loader)

        let diarization = DiarizationService(segmentEmbedder: embedder)
        let thresholds = diarization.activeSpeakerThresholds
        let voiceprintModel = diarization.activeRunDescriptor.voiceprintModel
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bg-voiceprint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = SpeakerDatabase(path: root.appendingPathComponent("speakers_test-bg.sqlite").path, thresholds: thresholds)

        XCTAssertEqual(thresholds, .reDimNet2B4, "the database gets the declared model's bars")
        XCTAssertEqual(database.thresholds, .reDimNet2B4)
        XCTAssertEqual(voiceprintModel, "test-bg")
        XCTAssertEqual(loader.calls, 0, "nothing loaded yet")
        XCTAssertEqual(embedder.loadState, .notStarted)
    }

    @MainActor
    func testLoadRunsOffTheWaitingActorWhichKeepsRunning() async {
        let loader = Loader(result: FixedEmbedder(), holds: true)
        let embedder = makeEmbedder(loader)

        let waiter = Task { @MainActor in await embedder.waitUntilLoaded() }
        let reached = await loader.waitUntilReached()
        XCTAssertTrue(reached, "the load started")

        // Back on the main actor while the load is still in flight.
        XCTAssertTrue(Thread.isMainThread)
        XCTAssertEqual(embedder.loadState, .loading)

        loader.release()
        let loaded = await waiter.value
        XCTAssertTrue(loaded)
        XCTAssertEqual(embedder.loadState, .loaded)
        XCTAssertFalse(loader.ranOnMainThread, "the model never loads on the main thread")
    }

    func testMeetingThatReembedsBeforeTheLoadEndsGetsTheLoadedModelsVectors() async throws {
        let model = FixedEmbedder()
        let loader = Loader(result: model, holds: true)
        let embedder = makeEmbedder(loader)
        let diarization = await MainActor.run { DiarizationService(segmentEmbedder: embedder) }
        let audio = self.audio
        let segments = [segment(0, 2), segment(2, 4)]

        let meeting = Task.detached {
            await diarization.waitForBackgroundSegmentEmbedder()
            return diarization.reembedIfNeeded(segments: segments, samples: audio, sampleRate: 16_000)
        }
        // A caller that skipped the wait blocks until the load ends, then embeds.
        let early = Task { await Self.onPlainThread { embedder.embed(samples: audio, sampleRate: 16_000) } }
        let reached = await loader.waitUntilReached()
        XCTAssertTrue(reached)
        loader.release()

        let reembedded = await meeting.value
        XCTAssertEqual(reembedded.map(\.embedding), [model.vector, model.vector])
        let earlyVector = await early.value
        XCTAssertEqual(earlyVector, model.vector, "never nil for being early")
        XCTAssertEqual(loader.calls, 1)
    }

    func testFailedLoadYieldsNoVectorsSoTheModelsDatabaseNeverGetsWeSpeakers() async {
        let loader = Loader(result: nil)
        let embedder = makeEmbedder(loader)
        let diarization = await MainActor.run { DiarizationService(segmentEmbedder: embedder) }

        let loaded = await embedder.waitUntilLoaded()
        XCTAssertFalse(loaded)
        XCTAssertEqual(embedder.loadState, .failed)
        XCTAssertNil(embedder.embed(samples: audio, sampleRate: 16_000))

        await diarization.waitForBackgroundSegmentEmbedder()
        let out = diarization.reembedIfNeeded(segments: [segment(0, 2)], samples: audio, sampleRate: 16_000)
        XCTAssertEqual(out.count, 1, "the segment stays for diarization")
        XCTAssertNil(out[0].embedding, "the native 256-d vector is dropped, not kept")
    }

    func testModelThatIsNotTheDeclaredOneIsRefused() async {
        for wrong in [
            FixedEmbedder(identifier: "someone-else"),
            FixedEmbedder(dimension: 8),
            FixedEmbedder(thresholds: .weSpeaker),
        ] {
            let embedder = makeEmbedder(Loader(result: wrong))
            let loaded = await embedder.waitUntilLoaded()
            XCTAssertFalse(loaded, "\(wrong.identifier) \(wrong.dimension)")
            XCTAssertNil(embedder.embed(samples: audio, sampleRate: 16_000))
        }
    }

    func testManyWaitersShareOneLoad() async {
        let model = FixedEmbedder()
        let loader = Loader(result: model, holds: true)
        let embedder = makeEmbedder(loader)
        let audio = self.audio

        let results = Task.detached { () -> [Bool] in
            await withTaskGroup(of: Bool.self) { group in
                for index in 0..<16 {
                    group.addTask {
                        if index.isMultiple(of: 2) { return await embedder.waitUntilLoaded() }
                        let vector = await Self.onPlainThread { embedder.embed(samples: audio, sampleRate: 16_000) }
                        return vector == model.vector
                    }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
        }
        let reached = await loader.waitUntilReached()
        XCTAssertTrue(reached)
        loader.release()

        let outcomes = await results.value
        XCTAssertEqual(outcomes.count, 16)
        XCTAssertTrue(outcomes.allSatisfy { $0 })
        XCTAssertEqual(loader.calls, 1, "the model loads once")
        let again = await embedder.waitUntilLoaded()
        XCTAssertTrue(again, "a later waiter returns at once")
        XCTAssertEqual(loader.calls, 1)
    }
}
