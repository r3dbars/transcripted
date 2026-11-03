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
}
