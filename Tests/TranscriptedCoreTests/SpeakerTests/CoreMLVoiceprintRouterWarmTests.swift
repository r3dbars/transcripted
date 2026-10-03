import XCTest
import Foundation
@testable import TranscriptedCore

/// Promises for loading and warming a multifunction voiceprint's functions ahead of
/// re-embedding (stand-in functions; no Core ML, no real time asserted):
///   - a call on a loaded function never waits behind another length's load;
///   - two calls for the same length share one load;
///   - `preloadAll` loads every function and never runs one;
///   - `warm` runs exactly the lengths it's given, once each, and again after a release;
///   - a warm-up that returns nothing never disables the function;
///   - an idle release that lands while a function loads leaves it usable and
///     releases it 60 s after the last call;
///   - the embedder warms exactly the call lengths `embed` will use for those turns.
@available(macOS 15.0, *)
final class CoreMLVoiceprintRouterWarmTests: XCTestCase {

    /// Records loads and calls; a length in `gated` blocks its load until opened.
    private final class StandIn: @unchecked Sendable {
        private let lock = NSLock()
        private var loadLog: [Int] = []
        private var callLog: [(length: Int, allZero: Bool)] = []
        let gated: Set<Int>
        let gate = DispatchSemaphore(value: 0)
        let loadEntered = DispatchSemaphore(value: 0)
        let nilOnZeros: Bool

        init(gated: Set<Int> = [], nilOnZeros: Bool = false) {
            self.gated = gated
            self.nilOnZeros = nilOnZeros
        }

        func load(_ length: Int) {
            lock.lock(); loadLog.append(length); lock.unlock()
            if gated.contains(length) {
                loadEntered.signal()
                gate.wait()
            }
        }

        func call(_ window: [Float]) -> [Float]? {
            let zeros = window.allSatisfy { $0 == 0 }
            lock.lock(); callLog.append((window.count, zeros)); lock.unlock()
            if zeros && nilOnZeros { return nil }
            return [1, 0]
        }

        var loads: [Int] { lock.lock(); defer { lock.unlock() }; return loadLog }
        var calls: [(length: Int, allZero: Bool)] { lock.lock(); defer { lock.unlock() }; return callLog }
    }

    private let second = 16_000
    private var lengths: [Int] { [1, 2, 4, 8].map { $0 * second } }

    private func router(
        _ standIn: StandIn, idle: TimeInterval? = nil,
        clock: CoreMLVoiceprintFunctionRouter.IdleClock = .system
    ) -> CoreMLVoiceprintFunctionRouter {
        let byName = Dictionary(uniqueKeysWithValues: lengths.map { ("len_\($0)", $0) })
        return CoreMLVoiceprintFunctionRouter(
            functionsByLength: Dictionary(uniqueKeysWithValues: lengths.map { ($0, "len_\($0)") }),
            idleReleaseSeconds: idle, clock: clock
        ) { name in
            let length = byName[name] ?? 0
            standIn.load(length)
            return { standIn.call($0) }
        }
    }

    private func window(_ length: Int) -> [Float] { [Float](repeating: 0.1, count: length) }

    func testACallOnALoadedFunctionDoesNotWaitForAnotherLengthsLoad() throws {
        let standIn = StandIn(gated: [1 * second])
        let r = router(standIn)
        try r.preload(length: 8 * second)

        let slowDone = expectation(description: "1 s call returns once its load is let through")
        DispatchQueue.global().async {
            _ = r.predict(self.window(1 * self.second))
            slowDone.fulfill()
        }
        standIn.loadEntered.wait()

        let fastDone = expectation(description: "8 s call returns while the 1 s load is held")
        DispatchQueue.global().async {
            XCTAssertNotNil(r.predict(self.window(8 * self.second)))
            fastDone.fulfill()
        }
        let result = XCTWaiter().wait(for: [fastDone], timeout: 30)
        standIn.gate.signal()
        wait(for: [slowDone], timeout: 30)
        XCTAssertEqual(result, .completed)
    }

    func testTwoCallsForTheSameLengthShareOneLoad() {
        let standIn = StandIn(gated: [2 * second])
        let r = router(standIn)
        let done = expectation(description: "both calls return a vector")
        done.expectedFulfillmentCount = 2
        for _ in 0..<2 {
            DispatchQueue.global().async {
                XCTAssertNotNil(r.predict(self.window(2 * self.second)))
                done.fulfill()
            }
        }
        standIn.loadEntered.wait()
        standIn.gate.signal()
        wait(for: [done], timeout: 30)
        XCTAssertEqual(standIn.loads.filter { $0 == 2 * second }.count, 1)
    }

    func testPreloadAllLoadsEveryFunctionAndRunsNone() {
        let standIn = StandIn()
        let r = router(standIn)
        r.preloadAll()
        XCTAssertEqual(standIn.loads.sorted(), lengths)
        XCTAssertTrue(standIn.calls.isEmpty)
        XCTAssertEqual(r.loadedCount, lengths.count)

        r.preloadAll()
        XCTAssertEqual(standIn.loads.count, lengths.count, "already loaded: nothing loads again")
    }

    func testWarmRunsExactlyTheGivenLengthsOnceAndAgainAfterARelease() {
        let standIn = StandIn()
        let r = router(standIn)
        let wanted: Set<Int> = [1 * second, 8 * second]
        r.warm(lengths: wanted)
        XCTAssertEqual(Set(standIn.calls.map(\.length)), wanted)
        XCTAssertEqual(standIn.calls.count, 2)
        XCTAssertTrue(standIn.calls.allSatisfy(\.allZero))

        r.warm(lengths: wanted)
        XCTAssertEqual(standIn.calls.count, 2, "already warm: no second warm-up")

        r.releaseLoadedFunctions()
        r.warm(lengths: wanted)
        XCTAssertEqual(standIn.calls.count, 4, "a reload starts cold, so it warms again")
    }

    func testARealCallCountsAsWarm() {
        let standIn = StandIn()
        let r = router(standIn)
        _ = r.predict(window(4 * second))
        r.warm(lengths: [4 * second])
        XCTAssertEqual(standIn.calls.count, 1)
    }

    func testAWarmUpThatReturnsNothingDoesNotDisableTheFunction() {
        let standIn = StandIn(nilOnZeros: true)
        let r = router(standIn)
        r.warm(lengths: [2 * second])
        XCTAssertNotNil(r.predict(window(2 * second)))
        XCTAssertEqual(standIn.loads, [2 * second])
    }

    func testWarmIgnoresLengthsWithNoFunction() {
        let standIn = StandIn()
        let r = router(standIn)
        r.warm(lengths: [12_345])
        XCTAssertTrue(standIn.loads.isEmpty)
        XCTAssertTrue(standIn.calls.isEmpty)
    }

    func testAnIdleReleaseDuringALoadLeavesTheFunctionUsableAndReleasesItLater() throws {
        let clock = VirtualClock()
        let standIn = StandIn(gated: [4 * second])
        let r = router(standIn, idle: 60, clock: clock.idleClock)
        try r.preload(length: 8 * second)

        let done = expectation(description: "4 s call returns after its load")
        DispatchQueue.global().async {
            XCTAssertNotNil(r.predict(self.window(4 * self.second)))
            done.fulfill()
        }
        standIn.loadEntered.wait()
        clock.advance(by: 61)
        XCTAssertEqual(r.loadedCount, 0, "the idle release ran while the 4 s load was held")
        standIn.gate.signal()
        wait(for: [done], timeout: 30)

        XCTAssertEqual(r.loadedCount, 1)
        XCTAssertEqual(clock.pendingCount, 1, "one release timer, re-armed by the call")
        clock.advance(by: 59)
        XCTAssertEqual(r.loadedCount, 1)
        clock.advance(by: 1)
        XCTAssertEqual(r.loadedCount, 0)
    }

    func testTheEmbedderWarmsExactlyTheCallLengthsItsTurnsUse() throws {
        let plan = try CoreMLSpeakerEmbeddingPlan.resolve(
            minSamples: nil, maxSamples: nil, windowSamples: 8 * second, hopSamples: nil,
            pooling: .talkTimeWeighted, modelLengths: .enumerated(lengths))
        let warmed = WarmLog()
        let embedder = try CoreMLSpeakerSegmentEmbedder(
            identifier: "stand-in", dimension: 2, thresholds: .weSpeaker, plan: plan,
            predict: { _ in [1, 0] }, warmCallLengths: { warmed.record($0) })

        // 0.3 s tiles to 1 s; 3 s tiles to 4 s; 10 s is an 8 s window plus a
        // 2 s tail that tiles to 2 s.
        embedder.prewarm(sampleCounts: [4_800, 3 * second, 10 * second, 0])
        XCTAssertEqual(warmed.calls, [[1 * second, 4 * second, 8 * second, 2 * second]])

        embedder.prewarm(sampleCounts: [])
        XCTAssertEqual(warmed.calls.count, 1, "no turns: nothing to warm")
    }

    // MARK: - Helpers

    private final class WarmLog: @unchecked Sendable {
        private let lock = NSLock()
        private var log: [Set<Int>] = []
        func record(_ lengths: Set<Int>) { lock.lock(); log.append(lengths); lock.unlock() }
        var calls: [Set<Int>] { lock.lock(); defer { lock.unlock() }; return log }
    }

    /// A clock whose time only moves when the test says so.
    private final class VirtualClock: @unchecked Sendable {
        private let lock = NSLock()
        private var time: TimeInterval = 1_000
        private var pending: [(due: TimeInterval, block: @Sendable () -> Void)] = []

        var now: TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
        var pendingCount: Int { lock.lock(); defer { lock.unlock() }; return pending.count }

        var idleClock: CoreMLVoiceprintFunctionRouter.IdleClock {
            CoreMLVoiceprintFunctionRouter.IdleClock(
                now: { [unowned self] in self.now },
                after: { [unowned self] seconds, block in
                    self.lock.lock()
                    self.pending.append((self.time + seconds, block))
                    self.lock.unlock()
                }
            )
        }

        func advance(by seconds: TimeInterval) {
            lock.lock()
            let end = time + seconds
            lock.unlock()
            while true {
                lock.lock()
                guard let next = pending.indices.filter({ pending[$0].due <= end })
                    .min(by: { pending[$0].due < pending[$1].due }) else {
                    time = end
                    lock.unlock()
                    return
                }
                let item = pending.remove(at: next)
                time = max(time, item.due)
                lock.unlock()
                item.block()
            }
        }
    }
}
