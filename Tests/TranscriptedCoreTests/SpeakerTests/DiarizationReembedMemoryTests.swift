import XCTest
import Foundation
@testable import TranscriptedCore

/// Promises for re-embedding a meeting's turns:
///   - each turn's autoreleased temporaries (Core ML arrays, in the real models) are
///     freed before the next turn, not held until the whole meeting is embedded,
///     and the vectors come back unchanged and in order;
///   - an embedder that can warm up for known turn lengths is handed exactly the
///     sample counts re-embedding slices; a contextual embedder is not.
/// Stub embedders only; no model needed.
@available(macOS 14.0, *)
final class DiarizationReembedMemoryTests: XCTestCase {

    /// Counts live instances, so a test can see whether an autoreleased object was freed.
    private final class Tracked: NSObject {
        nonisolated(unsafe) static var live = 0
        static let lock = NSLock()
        override init() {
            Self.lock.lock(); Self.live += 1; Self.lock.unlock()
            super.init()
        }
        deinit {
            Self.lock.lock(); Self.live -= 1; Self.lock.unlock()
        }
        static var count: Int { lock.lock(); defer { lock.unlock() }; return live }
    }

    /// Autoreleases one tracked object per call and returns a vector built from the
    /// slice length, so order and content can be checked.
    private final class AutoreleasingEmbedder: SpeakerSegmentEmbedder, @unchecked Sendable {
        let dimension = 2
        let identifier = "autoreleasing-stub"
        let thresholds = SpeakerEmbeddingThresholds.weSpeaker
        func embed(samples: [Float], sampleRate: Int) -> [Float]? {
            _ = Unmanaged.passRetained(Tracked()).autorelease()
            return [Float(samples.count), 1]
        }
    }

    /// Records the sample counts it was asked to warm up for.
    private final class WarmingEmbedder: SpeakerSegmentLengthPrewarming, @unchecked Sendable {
        let dimension = 2
        let identifier = "warming-stub"
        let thresholds = SpeakerEmbeddingThresholds.weSpeaker
        let warmed: XCTestExpectation
        private let lock = NSLock()
        private var log: [[Int]] = []
        init(warmed: XCTestExpectation) { self.warmed = warmed }
        func embed(samples: [Float], sampleRate: Int) -> [Float]? { [1, 0] }
        func prewarm(sampleCounts: [Int]) {
            lock.lock(); log.append(sampleCounts); lock.unlock()
            warmed.fulfill()
        }
        var calls: [[Int]] { lock.lock(); defer { lock.unlock() }; return log }
    }

    /// Contextual and warmable: the warm-up must not run, since contextual embeds
    /// don't use the per-turn slice lengths.
    private final class ContextualWarmingEmbedder: SpeakerSegmentLengthPrewarming,
        ContextualSpeakerSegmentEmbedder, @unchecked Sendable {
        let dimension = 2
        let identifier = "contextual-stub"
        let thresholds = SpeakerEmbeddingThresholds.weSpeaker
        let warmed: XCTestExpectation
        init(warmed: XCTestExpectation) { self.warmed = warmed }
        func embed(samples: [Float], sampleRate: Int) -> [Float]? { [1, 0] }
        func embed(audio: [Float], sampleRate: Int, startSample: Int, endSample: Int) -> [Float]? { [1, 0] }
        func prewarm(sampleCounts: [Int]) { warmed.fulfill() }
    }

    private func segment(_ start: Double, _ end: Double) -> SpeakerSegment {
        SpeakerSegment(speakerId: 1, startTime: start, endTime: end, embedding: nil, qualityScore: 0.9)
    }

    func testEachTurnsTemporariesAreFreedBeforeTheMeetingIsDone() async {
        let service = await MainActor.run { DiarizationService() }
        let embedder = AutoreleasingEmbedder()
        let segments = (0..<50).map { segment(Double($0) * 0.1, Double($0) * 0.1 + 0.05 + Double($0) * 0.001) }
        let samples = [Float](repeating: 0.01, count: 16_000 * 10)
        let baseline = Tracked.count

        let (out, liveBeforeOuterPoolDrains) = reembedInsideOnePool(
            service, segments: segments, samples: samples, embedder: embedder, baseline: baseline)

        XCTAssertEqual(liveBeforeOuterPoolDrains, 0, "every turn's autoreleased objects were already freed")
        let expected = segments.map { s -> [Float]? in
            let a = Int(s.startTime * 16_000), b = Int(s.endTime * 16_000)
            return [Float(b - a), 1]
        }
        XCTAssertEqual(out.map(\.embedding), expected)
    }

    /// Re-embeds inside one outer pool and counts tracked objects still alive
    /// before that pool drains.
    private func reembedInsideOnePool(
        _ service: DiarizationService, segments: [SpeakerSegment], samples: [Float],
        embedder: AutoreleasingEmbedder, baseline: Int
    ) -> ([SpeakerSegment], Int) {
        autoreleasepool {
            let out = service.reembed(segments: segments, samples: samples, sampleRate: 16_000, using: embedder)
            return (out, Tracked.count - baseline)
        }
    }

    func testAWarmableEmbedderGetsTheTurnLengthsReembedSlices() async {
        let service = await MainActor.run { DiarizationService() }
        let warmed = expectation(description: "warm-up handed off")
        let embedder = WarmingEmbedder(warmed: warmed)
        // 0..1 s, 1..3 s, a turn past the end (clamped to 4 s), and an empty one.
        let segments = [segment(0, 1), segment(1, 3), segment(3, 9), segment(2, 2)]
        service.prewarmVoiceprintLengths(for: segments, sampleCount: 4 * 16_000, sampleRate: 16_000, using: embedder)
        await fulfillment(of: [warmed], timeout: 30)
        XCTAssertEqual(embedder.calls, [[16_000, 32_000, 16_000]])
    }

    func testAContextualEmbedderIsNotWarmedByTurnLength() async {
        let service = await MainActor.run { DiarizationService() }
        let warmed = expectation(description: "warm-up must not run")
        warmed.isInverted = true
        let embedder = ContextualWarmingEmbedder(warmed: warmed)
        service.prewarmVoiceprintLengths(
            for: [segment(0, 1)], sampleCount: 16_000, sampleRate: 16_000, using: embedder)
        await fulfillment(of: [warmed], timeout: 0.5)
    }
}
