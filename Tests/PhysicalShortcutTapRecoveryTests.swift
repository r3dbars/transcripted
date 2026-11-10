import Foundation

private final class ShortcutRecoveryTestQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var work: [@Sendable () -> Void] = []
    private var enabled = 0
    private var reported: [Bool] = []

    func enqueue(_ operation: @escaping @Sendable () -> Void) {
        lock.lock(); work.append(operation); lock.unlock()
    }

    var queued: Int {
        lock.lock(); defer { lock.unlock() }; return work.count
    }

    var enableCount: Int {
        lock.lock(); defer { lock.unlock() }; return enabled
    }

    var completions: [Bool] {
        lock.lock(); defer { lock.unlock() }; return reported
    }

    func enable() -> Bool {
        lock.lock(); enabled += 1; lock.unlock(); return true
    }

    func report(_ value: Bool) {
        lock.lock(); reported.append(value); lock.unlock()
    }

    func runNext() {
        lock.lock(); let operation = work.removeFirst(); lock.unlock()
        operation()
    }
}

func testPhysicalShortcutTapRecovery() {
    runSuite("A disabled tap returns before the WindowServer recovery call runs") {
        let queue = ShortcutRecoveryTestQueue()
        let recovery = PhysicalShortcutTapRecovery(enqueue: { queue.enqueue($0) })
        recovery.request(enable: { queue.enable() }, completed: { queue.report($0) })
        assertEqual(queue.enableCount, 0, "the callback never waits for the OS call")
        assertEqual(queue.queued, 1)
        queue.runNext()
        assertEqual(queue.enableCount, 1)
        assertEqual(queue.completions, [true])
    }

    runSuite("Removing a tap cancels its queued re-enable") {
        let queue = ShortcutRecoveryTestQueue()
        let recovery = PhysicalShortcutTapRecovery(enqueue: { queue.enqueue($0) })
        recovery.request(enable: { queue.enable() }, completed: { queue.report($0) })
        recovery.invalidate()
        queue.runNext()
        assertEqual(queue.enableCount, 0, "an obsolete tap is not re-enabled")
        assertEqual(queue.completions, [])
        recovery.request(enable: { queue.enable() }, completed: { queue.report($0) })
        assertEqual(queue.queued, 0, "a removed lifetime admits no more recovery")
    }

    runSuite("Removal during the OS call takes no recovery lock and discards its late result") {
        let queue = ShortcutRecoveryTestQueue()
        let recovery = PhysicalShortcutTapRecovery(enqueue: { queue.enqueue($0) })
        recovery.request(enable: {
            // Invalidate while the external call is still in progress. This
            // would deadlock if request held its lock across that call.
            recovery.invalidate()
            return queue.enable()
        }, completed: { queue.report($0) })
        queue.runNext()
        assertEqual(queue.enableCount, 1)
        assertEqual(queue.completions, [], "an old result cannot describe the replacement tap")

        let replacement = PhysicalShortcutTapRecovery(enqueue: { queue.enqueue($0) })
        replacement.request(enable: { queue.enable() }, completed: { queue.report($0) })
        queue.runNext()
        assertEqual(queue.completions, [true], "replacement recovery has its own lifetime")
    }

    runSuite("Disabled callbacks during enable coalesce into one follow-up recovery") {
        let queue = ShortcutRecoveryTestQueue()
        let recovery = PhysicalShortcutTapRecovery(enqueue: { queue.enqueue($0) })
        recovery.request(enable: {
            let enabled = queue.enable()
            recovery.request(enable: { queue.enable() }, completed: { queue.report($0) })
            recovery.request(enable: { queue.enable() }, completed: { queue.report($0) })
            assertEqual(queue.completions, [], "the first recovery is still in its enable call")
            assertEqual(queue.queued, 1, "two callbacks during enable retain exactly one follow-up")
            return enabled
        }, completed: { queue.report($0) })
        assertEqual(queue.queued, 1)
        assertEqual(queue.enableCount, 0, "the manual queue has not executed recovery yet")
        queue.runNext()
        assertEqual(queue.enableCount, 1, "the follow-up does not run inside the first enable")
        assertEqual(queue.completions, [true], "the first run completes before the follow-up executes")
        assertEqual(queue.queued, 1, "the follow-up survives completion of the first run")
        if queue.queued == 1 { queue.runNext() }
        assertEqual(queue.enableCount, 2, "the retained follow-up enables the tap once more")
        assertEqual(queue.completions, [true, true], "both runs report completion")
        assertEqual(queue.queued, 0, "the two overlapping requests need no third recovery")
    }

    runSuite("Repeated disabled callbacks share one outstanding recovery and can retry afterward") {
        let queue = ShortcutRecoveryTestQueue()
        let recovery = PhysicalShortcutTapRecovery(enqueue: { queue.enqueue($0) })
        recovery.request(enable: { queue.enable() }, completed: { queue.report($0) })
        recovery.request(enable: { queue.enable() }, completed: { queue.report($0) })
        assertEqual(queue.queued, 1)
        queue.runNext()
        recovery.request(enable: { false }, completed: { queue.report($0) })
        queue.runNext()
        assertEqual(queue.completions, [true, false])
    }

    runSuite("A tap disabled again while its re-enable is in flight gets one more recovery") {
        let queue = ShortcutRecoveryTestQueue()
        let recovery = PhysicalShortcutTapRecovery(enqueue: { queue.enqueue($0) })
        recovery.request(enable: {
            // macOS reports the tap disabled again before the first enable returns.
            recovery.request(enable: { queue.enable() }, completed: { queue.report($0) })
            recovery.request(enable: { queue.enable() }, completed: { queue.report($0) })
            return queue.enable()
        }, completed: { queue.report($0) })
        queue.runNext()
        assertEqual(queue.queued, 1, "the later disable is not dropped, and repeats still share one job")
        queue.runNext()
        assertEqual(queue.enableCount, 2, "the tap is re-enabled again after the first attempt")
        assertEqual(queue.completions, [true, true])
    }
}
