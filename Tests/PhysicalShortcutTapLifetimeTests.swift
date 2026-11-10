import Foundation

// Actual recovery/stop helpers, with a controlled FIFO and synthetic actions.
// No detector, event tap, run loop or permission API is constructed here.
@MainActor
func testPhysicalShortcutTapLifetime() async {
    runSuite("Tap startup queues enable and returns before the fake worker runs") {
        let queue = TapLifetimeQueue()
        let calls = TapLifetimeTrace()
        let recovery = PhysicalShortcutTapRecovery(enqueue: { queue.enqueue($0) })
        recovery.requestStartup { calls.add("enable") }
        assertEqual(calls.events, [], "startup must not enable on the caller")
        assertEqual(queue.count, 1, "startup must enter the worker FIFO")
        queue.runNext()
        assertEqual(calls.events, ["enable"], "worker performs the admitted startup once")
        assertEqual(queue.count, 0)
    }

    runSuite("Tap startup refuses inactive admission and skips invalidated queued work") {
        let queue = TapLifetimeQueue()
        let calls = TapLifetimeTrace()
        let inactive = PhysicalShortcutTapRecovery(enqueue: { queue.enqueue($0) })
        inactive.invalidate()
        inactive.requestStartup { calls.add("inactive") }
        assertEqual(queue.count, 0, "inactive startup must not enqueue")
        let queued = PhysicalShortcutTapRecovery(enqueue: { queue.enqueue($0) })
        queued.requestStartup { calls.add("queued") }
        assertEqual(queue.count, 1)
        queued.invalidate()
        queue.runNext()
        assertEqual(calls.events, [], "invalidating the queued install revokes its enable")
    }

    runSuite("Tap startup leaves ordinary recovery available and preserves its Bool completion") {
        let queue = TapLifetimeQueue()
        let calls = TapLifetimeTrace()
        let recovery = PhysicalShortcutTapRecovery(enqueue: { queue.enqueue($0) })
        recovery.requestStartup { calls.add("startup") }
        recovery.request(enable: { calls.add("recover"); return false }, completed: {
            calls.add($0 ? "result-true" : "result-false")
        })
        recovery.request(enable: { calls.add("duplicate"); return true }, completed: { _ in calls.add("duplicate-result") })
        assertEqual(queue.count, 2, "startup and one recovery occupy separate FIFO slots")
        assertEqual(calls.events, [], "both native actions are deferred")
        queue.runNext()
        assertEqual(calls.events, ["startup"])
        queue.runNext()
        assertEqual(calls.events, ["startup", "recover", "result-false"])
        recovery.request(enable: { calls.add("retry"); return true }, completed: {
            calls.add($0 ? "retry-true" : "retry-false")
        })
        assertEqual(queue.count, 1, "completed recovery permits a later notification")
        queue.runNext()
        assertEqual(calls.events, ["startup", "recover", "result-false", "retry", "retry-true"])
    }

    runSuite("Tap invalidation inside admitted recovery suppresses late reporting and queues cleanup") {
        let queue = TapLifetimeQueue()
        let calls = TapLifetimeTrace()
        let recovery = PhysicalShortcutTapRecovery(enqueue: { queue.enqueue($0) })
        recovery.request(enable: {
            calls.add("enable-begin")
            recovery.invalidate(teardown: { calls.add("teardown") })
            calls.add("enable-end")
            return true
        }, completed: { _ in calls.add("late-result") })
        queue.runNext()
        assertEqual(calls.events, ["enable-begin", "enable-end"], "invalidation may reenter while native work runs")
        assertEqual(queue.count, 1, "cleanup follows the admitted enable on the same worker")
        recovery.requestStartup { calls.add("stale-startup") }
        recovery.request(enable: { calls.add("stale-recovery"); return true }, completed: { _ in calls.add("stale-result") })
        assertEqual(queue.count, 1, "retirement synchronously rejects later native work")
        queue.runNext()
        assertEqual(calls.events, ["enable-begin", "enable-end", "teardown"])
    }

    runSuite("Tap retirement still queues cleanup after prior no-argument invalidation") {
        let queue = TapLifetimeQueue()
        let calls = TapLifetimeTrace()
        let recovery = PhysicalShortcutTapRecovery(enqueue: { queue.enqueue($0) })
        recovery.invalidate()
        recovery.invalidate(teardown: {
            calls.add("cleanup")
            // Teardown may reenter the lifetime without a recovery lock held.
            recovery.invalidate()
        })
        assertEqual(calls.events, [], "cleanup must not execute inline")
        assertEqual(queue.count, 1, "prior invalidation cannot lose native cleanup")
        queue.runNext()
        assertEqual(calls.events, ["cleanup"])
    }

    runSuite("Tap retirement queues exactly one teardown before and after worker completion") {
        let queue = TapLifetimeQueue()
        let calls = TapLifetimeTrace()
        let recovery = PhysicalShortcutTapRecovery(enqueue: { queue.enqueue($0) })
        recovery.invalidate(teardown: { calls.add("first") })
        recovery.invalidate(teardown: { calls.add("duplicate-before") })
        assertEqual(queue.count, 1)
        queue.runNext()
        recovery.invalidate(teardown: { calls.add("duplicate-after") })
        assertEqual(queue.count, 0, "finished retirement cannot be admitted again")
        assertEqual(calls.events, ["first"])
    }

    runSuite("Old tap cleanup precedes replacement enable and cannot report against it") {
        let queue = TapLifetimeQueue()
        let calls = TapLifetimeTrace()
        let old = PhysicalShortcutTapRecovery(enqueue: { queue.enqueue($0) })
        let replacement = PhysicalShortcutTapRecovery(enqueue: { queue.enqueue($0) })
        old.request(enable: {
            calls.add("old-begin")
            old.invalidate(teardown: { calls.add("old-cleanup") })
            replacement.request(enable: { calls.add("new-enable"); return true }, completed: {
                calls.add($0 ? "new-result" : "new-failed")
            })
            calls.add("old-end")
            return true
        }, completed: { _ in calls.add("old-result") })
        queue.runNext()
        assertEqual(calls.events, ["old-begin", "old-end"])
        assertEqual(queue.count, 2)
        queue.runNext()
        assertEqual(calls.events, ["old-begin", "old-end", "old-cleanup"])
        queue.runNext()
        assertEqual(calls.events, ["old-begin", "old-end", "old-cleanup", "new-enable", "new-result"])
    }

    runSuite("Queued retirement retains callback context until native cleanup returns") {
        let queue = TapLifetimeQueue()
        let calls = TapLifetimeTrace()
        let recovery = PhysicalShortcutTapRecovery(enqueue: { queue.enqueue($0) })
        let weakContext = TapLifetimeWeakContext()
        queueTapContextRetirement(recovery: recovery, observer: weakContext, calls: calls)
        assertTrue(weakContext.isAlive, "the queued cleanup owns its callback context after the fake thread owner is released")
        assertEqual(calls.events, [], "retaining context must not run cleanup inline")
        queue.runNext()
        assertEqual(calls.events, ["cleanup-context", "context-released"], "context stays alive through cleanup and releases after the worker returns")
        assertFalse(weakContext.isAlive, "no thread owner is needed after cleanup completes")
    }

    runSuite("Tap loop stop requested before activation survives fake start reset") {
        let queue = TapLifetimeQueue()
        let loop = TapLifetimeLoop()
        let handle = PhysicalShortcutTapRunLoopStop(enqueue: { queue.enqueue($0) }, stop: { loop.stop() })
        handle.request()
        assertEqual(loop.stops, 0, "stop must not execute inline before Run")
        assertEqual(queue.count, 1)
        loop.activate()
        assertTrue(loop.active, "fake activation resets its prestart state before queued work runs")
        queue.runNext()
        assertEqual(loop.stops, 1, "the queued action reaches the now-active loop")
        assertEqual(loop.stopsWhileActive, 1, "a pre-Run request must not vanish during activation")
        assertFalse(loop.active)
    }

    runSuite("Tap loop stop handle enqueues once even after its callback executes") {
        let queue = TapLifetimeQueue()
        let loop = TapLifetimeLoop()
        let handle = PhysicalShortcutTapRunLoopStop(enqueue: { queue.enqueue($0) }, stop: { loop.stop() })
        handle.request()
        handle.request()
        assertEqual(queue.count, 1, "duplicate stop requests share the admitted callback")
        assertEqual(loop.stops, 0)
        queue.runNext()
        handle.request()
        assertEqual(queue.count, 0, "execution does not reopen stop admission")
        assertEqual(loop.stops, 1)
    }

    runSuite("Queued tap loop stop weakly references its expired install handle") {
        let queue = TapLifetimeQueue()
        let loop = TapLifetimeLoop()
        var handle: PhysicalShortcutTapRunLoopStop? = PhysicalShortcutTapRunLoopStop(enqueue: { queue.enqueue($0) }, stop: { loop.stop() })
        weak var weakHandle = handle
        handle?.request()
        handle = nil
        assertNil(weakHandle, "queued stop must not extend the install lifetime")
        assertEqual(queue.count, 1, "the scheduler still owns the inert callback")
        queue.runNext()
        assertEqual(loop.stops, 0, "an expired install cannot stop a loop")
    }

    runSuite("Separate tap loop stop handles never target a successor install") {
        let queue = TapLifetimeQueue()
        let oldLoop = TapLifetimeLoop()
        let newLoop = TapLifetimeLoop()
        let old = PhysicalShortcutTapRunLoopStop(enqueue: { queue.enqueue($0) }, stop: { oldLoop.stop() })
        let successor = PhysicalShortcutTapRunLoopStop(enqueue: { queue.enqueue($0) }, stop: { newLoop.stop() })
        old.request()
        oldLoop.activate()
        newLoop.activate()
        queue.runNext()
        assertEqual(oldLoop.stops, 1)
        assertEqual(newLoop.stops, 0, "old queued stop retains the old literal target")
        assertTrue(newLoop.active)
        successor.request()
        queue.runNext()
        assertEqual(oldLoop.stops, 1)
        assertEqual(newLoop.stops, 1, "the successor has independent stop admission")
    }
}

private final class TapLifetimeQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var jobs: [@Sendable () -> Void] = []
    var count: Int { lock.withLock { jobs.count } }
    func enqueue(_ job: @escaping @Sendable () -> Void) { lock.withLock { jobs.append(job) } }
    func runNext() {
        let job: (@Sendable () -> Void)? = lock.withLock {
            guard !jobs.isEmpty else { return nil }
            return jobs.removeFirst()
        }
        assertTrue(job != nil, "the controlled FIFO must contain the expected worker")
        job?() // No fake queue lock is held across production or native callbacks.
    }
}

private final class TapLifetimeTrace: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var events: [String] { lock.withLock { recorded } }
    func add(_ event: String) { lock.withLock { recorded.append(event) } }
}

private final class TapLifetimeLoop: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var stopCount = 0
    private var activeStopCount = 0
    var active: Bool { lock.withLock { running } }
    var stops: Int { lock.withLock { stopCount } }
    var stopsWhileActive: Int { lock.withLock { activeStopCount } }
    func activate() { lock.withLock { running = true } }
    func stop() {
        lock.withLock {
            stopCount += 1
            if running { activeStopCount += 1 }
            running = false
        }
    }
}

private final class TapLifetimeContext: Sendable {
    let calls: TapLifetimeTrace
    init(calls: TapLifetimeTrace) { self.calls = calls }
    func cleanUp() { calls.add("cleanup-context") }
    deinit { calls.add("context-released") }
}

private final class TapLifetimeThreadOwner {
    let context: TapLifetimeContext
    init(context: TapLifetimeContext) { self.context = context }
}

private final class TapLifetimeWeakContext: @unchecked Sendable {
    private let lock = NSLock()
    private weak var context: TapLifetimeContext?
    var isAlive: Bool { lock.withLock { context != nil } }
    func observe(_ value: TapLifetimeContext) { lock.withLock { context = value } }
}

private func queueTapContextRetirement(
    recovery: PhysicalShortcutTapRecovery,
    observer: TapLifetimeWeakContext,
    calls: TapLifetimeTrace
) {
    let owner = TapLifetimeThreadOwner(context: TapLifetimeContext(calls: calls))
    let context = owner.context
    observer.observe(context)
    recovery.invalidate(teardown: {
        context.cleanUp()
        assertTrue(observer.isAlive, "callback context must be alive during native cleanup")
    })
    // This helper's owner and context locals cannot retain the context after return.
}
