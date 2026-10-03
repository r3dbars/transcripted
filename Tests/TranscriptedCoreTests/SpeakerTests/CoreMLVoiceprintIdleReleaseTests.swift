import XCTest
import Foundation
@testable import TranscriptedCore

/// Promises for releasing a multifunction voiceprint's loaded functions when idle:
///   - they are released `idleReleaseSeconds` after the last call, never sooner;
///   - a busy meeting (thousands of calls) keeps one release timer, not one per call;
///   - after a release the next call loads again and starts a new idle wait.
/// Runs on a virtual clock; no real time passes.
@available(macOS 15.0, *)
final class CoreMLVoiceprintIdleReleaseTests: XCTestCase {

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

        /// Moves time forward by `seconds`, running every block that falls due
        /// (including ones those blocks schedule) at its own due time.
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

    private let second = 16_000

    private func router(_ clock: VirtualClock, idle: TimeInterval? = 60) -> (CoreMLVoiceprintFunctionRouter, () -> Int) {
        let loads = NSLock()
        var count = 0
        let lengths = [1, 2, 4, 8].map { $0 * second }
        let router = CoreMLVoiceprintFunctionRouter(
            functionsByLength: Dictionary(uniqueKeysWithValues: lengths.map { ($0, "len_\($0)") }),
            idleReleaseSeconds: idle,
            clock: clock.idleClock
        ) { _ in
            loads.lock(); count += 1; loads.unlock()
            return { _ in [1, 0] }
        }
        return (router, { loads.lock(); defer { loads.unlock() }; return count })
    }

    private func window(_ seconds: Int) -> [Float] {
        [Float](repeating: 0.1, count: seconds * second)
    }

    func testFunctionsStayLoadedUntilAMinuteAfterTheLastCall() {
        let clock = VirtualClock()
        let (r, _) = router(clock)
        _ = r.predict(window(8))
        clock.advance(by: 30)
        _ = r.predict(window(2))
        clock.advance(by: 20)
        _ = r.predict(window(8))
        XCTAssertEqual(r.loadedCount, 2)

        clock.advance(by: 59)
        XCTAssertEqual(r.loadedCount, 2, "59 s after the last call is still in use")
        clock.advance(by: 1)
        XCTAssertEqual(r.loadedCount, 0, "released 60 s after the last call")
    }

    func testABusyMeetingKeepsOneReleaseTimer() {
        let clock = VirtualClock()
        let (r, _) = router(clock)
        for i in 0..<5_000 {
            _ = r.predict(window(i.isMultiple(of: 3) ? 1 : 8))
            if i.isMultiple(of: 100) { clock.advance(by: 1) }
        }
        XCTAssertEqual(clock.pendingCount, 1)
        XCTAssertEqual(r.loadedCount, 2)
    }

    func testAfterAReleaseTheNextCallReloadsAndWaitsAgain() {
        let clock = VirtualClock()
        let (r, loads) = router(clock)
        try? r.preload(length: 8 * second)
        clock.advance(by: 60)
        XCTAssertEqual(r.loadedCount, 0)

        _ = r.predict(window(8))
        XCTAssertEqual(loads(), 2)
        clock.advance(by: 59.5)
        XCTAssertEqual(r.loadedCount, 1)
        clock.advance(by: 0.5)
        XCTAssertEqual(r.loadedCount, 0)
        XCTAssertEqual(clock.pendingCount, 0)
    }

    func testWithoutAnIdleSettingNothingIsScheduled() {
        let clock = VirtualClock()
        let (r, _) = router(clock, idle: nil)
        _ = r.predict(window(4))
        clock.advance(by: 3_600)
        XCTAssertEqual(r.loadedCount, 1)
        XCTAssertEqual(clock.pendingCount, 0)
    }
}
