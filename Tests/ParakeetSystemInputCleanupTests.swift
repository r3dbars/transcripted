import Foundation

func testParakeetSystemInputCleanup() async {
    await runSuite("Timed-out HAL work keeps its circuit capacity until late cleanup returns") {
        let timers = CleanupTestTimeouts()
        let coordinator = ParakeetReplaceableSystemInputWorkCoordinator(
            label: "test.system-input.late-cleanup",
            scheduleTimeout: { budget, expire in timers.schedule(budget, expire) }
        )
        let releaseCleanup = DispatchSemaphore(value: 0)
        let cleanupFinished = CleanupTestSignal()
        let completionCount = CleanupTestCounter()
        let probeCount = CleanupTestCounter()

        for attempt in 0..<2 {
            let workEntered = CleanupTestSignal()
            let cleanupEntered = CleanupTestSignal()
            let releaseWork = DispatchSemaphore(value: 0)
            let caller = Task {
                try await coordinator.run(
                    operation: "suspended_\(attempt)",
                    timeoutNanoseconds: 1,
                    cleanupAfterLateCompletion: { _ in
                        Task { await cleanupEntered.signal() }
                        // Stand in for native hardware teardown still running.
                        releaseCleanup.wait()
                        if completionCount.increment() == 2 {
                            Task { await cleanupFinished.signal() }
                        }
                    }
                ) {
                    Task { await workEntered.signal() }
                    releaseWork.wait()
                    return true
                }
            }
            await workEntered.wait()
            timers.expireNext()
            do {
                _ = try await caller.value
                assertTrue(false, "the expired caller must report a timeout")
            } catch {
                assertTrue((error as? ParakeetSystemInputWorkError)?.isTimedOut == true, "the original caller gets its timeout")
            }
            releaseWork.signal()
            await cleanupEntered.wait()
        }

        assertEqual(
            coordinator.circuitOpenError(operation: "probe"),
            .circuitOpen(operation: "probe", activeTimeouts: 2),
            "two suspended late cleanups still occupy the two-worker circuit"
        )
        for _ in 0..<5 {
            do {
                _ = try await coordinator.run(operation: "probe", timeoutNanoseconds: 1) {
                    probeCount.increment()
                }
                assertTrue(false, "a late-cleanup circuit must refuse further work")
            } catch {
                assertTrue((error as? ParakeetSystemInputWorkError)?.isCircuitOpen == true, "requests fail closed while native cleanup remains active")
            }
        }
        assertEqual(probeCount.value, 0, "later requests cannot allocate another active worker")

        releaseCleanup.signal()
        releaseCleanup.signal()
        await cleanupFinished.wait()
        while coordinator.circuitOpenError(operation: "after_cleanup") != nil { await Task.yield() }
        let afterCleanup = try? await coordinator.run(operation: "after_cleanup", timeoutNanoseconds: 1) { 42 }
        assertEqual(afterCleanup, 42, "capacity returns after native cleanup actually finishes")
    }
}

private final class CleanupTestTimeouts: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [@Sendable () -> Void] = []

    func schedule(_ ignored: UInt64, _ expire: @escaping @Sendable () -> Void) {
        lock.withLock { pending.append(expire) }
    }

    func expireNext() {
        let expire = lock.withLock { pending.removeFirst() }
        expire()
    }
}

private final class CleanupTestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    @discardableResult func increment() -> Int {
        lock.withLock { count += 1; return count }
    }
}

private actor CleanupTestSignal {
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func signal() {
        signaled = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
