// ParakeetEngineWorkLifecycleTests.swift
//
// Behavior tests for two pieces ParakeetEngine delegates to: the timed
// audio-engine work runner and the single-flight stop lifecycle. Each runs here
// against fakes (a plain object as the "engine"), so none of this proves real
// AVAudioEngine or AirPods behavior. The hardware checks
// (`bash check.sh hardware`) still cover that.

import Foundation

@MainActor
func testParakeetEngineWorkLifecycle() async {
    await runTimedAudioEngineWorkSuites()
    await runSingleFlightStopSuites()
}

// MARK: - Timed audio-engine work

private final class TimedWorkProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _workRuns = 0
    private var _isCurrent = true
    private var _cancellationCleanups: [ObjectIdentifier] = []
    private var _cleanupRanOnWorker = false
    private var _lateCleanups: [ObjectIdentifier] = []

    var workRuns: Int { lock.withLock { _workRuns } }
    var isCurrent: Bool { lock.withLock { _isCurrent } }
    var cancellationCleanups: [ObjectIdentifier] { lock.withLock { _cancellationCleanups } }
    var cleanupRanOnWorker: Bool { lock.withLock { _cleanupRanOnWorker } }
    var lateCleanups: [ObjectIdentifier] { lock.withLock { _lateCleanups } }

    func recordWork() { lock.withLock { _workRuns += 1 } }
    func setCurrent(_ value: Bool) { lock.withLock { _isCurrent = value } }
    func recordCancellationCleanup(_ resource: AnyObject, onWorker: Bool) {
        lock.withLock {
            _cancellationCleanups.append(ObjectIdentifier(resource))
            _cleanupRanOnWorker = onWorker
        }
    }
    func recordLateCleanup(_ resource: AnyObject) {
        lock.withLock { _lateCleanups.append(ObjectIdentifier(resource)) }
    }
}

private func makeWorkerQueue() -> (DispatchQueue, DispatchSpecificKey<Bool>) {
    let key = DispatchSpecificKey<Bool>()
    let queue = DispatchQueue(label: "test.parakeet.timed-work")
    queue.setSpecific(key: key, value: true)
    return (queue, key)
}

/// Waits for a semaphore off the cooperative pool. The 30 s bound only stops a
/// broken test from hanging forever; nothing asserts on elapsed time.
private func awaitSignal(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 30) == .success)
        }
    }
}

private func runTimedAudioEngineWorkSuites() async {
    await runSuite("Timed engine work returns the work's result on its queue") {
        let limiter = ParakeetTimedAudioEngineWorkLimiter(maximumActiveWorkers: 2)
        let (queue, key) = makeWorkerQueue()
        let engine = NSObject()
        let result = try? await limiter.run(
            on: queue,
            resource: engine,
            operation: "test_success",
            timeoutNanoseconds: 30_000_000_000
        ) { resource -> Bool in
            DispatchQueue.getSpecific(key: key) == true && resource === engine
        }
        assertEqual(result, true, "work runs on the given queue against the given engine")
    }

    await runSuite("Queued engine work whose lease was claimed never touches the engine") {
        let limiter = ParakeetTimedAudioEngineWorkLimiter(maximumActiveWorkers: 2)
        let (queue, _) = makeWorkerQueue()
        let probe = TimedWorkProbe()
        probe.setCurrent(false)
        var caught: Error?
        do {
            _ = try await limiter.run(
                on: queue,
                resource: NSObject(),
                operation: "test_claimed",
                timeoutNanoseconds: 30_000_000_000,
                isWorkCurrent: { probe.isCurrent },
                cleanupAfterCancellation: { probe.recordCancellationCleanup($0, onWorker: true) }
            ) { _ in probe.recordWork() }
        } catch {
            caught = error
        }
        assertTrue(caught is CancellationError, "a claimed start fails as cancelled")
        assertEqual(probe.workRuns, 0, "the stale start never runs against the retired engine")
        assertTrue(probe.cancellationCleanups.isEmpty, "nothing ran, so there is nothing to clean up")
    }

    await runSuite("Engine work cancelled mid-flight is cleaned up on its own worker before the caller resumes") {
        let limiter = ParakeetTimedAudioEngineWorkLimiter(maximumActiveWorkers: 2)
        let (queue, key) = makeWorkerQueue()
        let probe = TimedWorkProbe()
        let engine = NSObject()
        var caught: Error?
        do {
            _ = try await limiter.run(
                on: queue,
                resource: engine,
                operation: "test_cancel_in_flight",
                timeoutNanoseconds: 30_000_000_000,
                isWorkCurrent: { probe.isCurrent },
                cleanupAfterCancellation: { resource in
                    probe.recordCancellationCleanup(
                        resource,
                        onWorker: DispatchQueue.getSpecific(key: key) == true
                    )
                }
            ) { _ in
                probe.recordWork()
                // Stop claims the lease while CoreAudio is still inside start.
                probe.setCurrent(false)
            }
        } catch {
            caught = error
        }
        assertTrue(caught is CancellationError, "a start that lost its lease reports cancellation, not success")
        assertEqual(probe.workRuns, 1, "the in-flight work ran once")
        assertEqual(
            probe.cancellationCleanups,
            [ObjectIdentifier(engine)],
            "the cancelled start's own engine is cleaned before the caller sees the result"
        )
        assertTrue(probe.cleanupRanOnWorker, "cleanup runs on the worker that did the start")
    }

    await runSuite("Engine work that outlives its timeout fails the caller and is cleaned up when it returns") {
        let limiter = ParakeetTimedAudioEngineWorkLimiter(maximumActiveWorkers: 2)
        let (queue, _) = makeWorkerQueue()
        let probe = TimedWorkProbe()
        let engine = NSObject()
        let release = DispatchSemaphore(value: 0)
        let lateCleanupDone = DispatchSemaphore(value: 0)
        var caught: Error?
        do {
            _ = try await limiter.run(
                on: queue,
                resource: engine,
                operation: "test_wedged",
                timeoutNanoseconds: 1_000_000,
                cleanupAfterLateCompletion: { resource in
                    probe.recordLateCleanup(resource)
                    lateCleanupDone.signal()
                }
            ) { _ in
                // Stands in for a CoreAudio call that blocks past the budget.
                _ = release.wait(timeout: .now() + 30)
                probe.recordWork()
            }
        } catch {
            caught = error
        }
        if case .timedOut(let operation, _)? = caught as? ParakeetAudioEngineWorkError {
            assertEqual(operation, "test_wedged", "the timeout names its operation")
        } else {
            assertTrue(false, "a wedged start resumes the caller with a timeout, got \(String(describing: caught))")
        }
        assertTrue(probe.lateCleanups.isEmpty, "late cleanup waits for the blocked work to return")
        release.signal()
        let cleanedUp = await awaitSignal(lateCleanupDone)
        assertTrue(cleanedUp, "late cleanup runs once the blocked work returns")
        assertEqual(probe.lateCleanups, [ObjectIdentifier(engine)], "late cleanup gets the wedged engine, not a successor")
    }

    await runSuite("Engine work fails closed when every worker slot is still held") {
        let limiter = ParakeetTimedAudioEngineWorkLimiter(maximumActiveWorkers: 1)
        let (queue, _) = makeWorkerQueue()
        let probe = TimedWorkProbe()
        let heldLease = limiter.acquire()
        var caught: Error?
        do {
            _ = try await limiter.run(
                on: queue,
                resource: NSObject(),
                operation: "test_circuit",
                timeoutNanoseconds: 30_000_000_000
            ) { _ in probe.recordWork() }
        } catch {
            caught = error
        }
        if case .circuitOpen(let operation, let activeWorkers)? = caught as? ParakeetAudioEngineWorkError {
            assertEqual(operation, "test_circuit", "the refusal names its operation")
            assertEqual(activeWorkers, 1, "the refusal reports the held slot")
        } else {
            assertTrue(false, "a full limiter refuses new work, got \(String(describing: caught))")
        }
        assertEqual(probe.workRuns, 0, "refused work never reaches the engine")
        heldLease?.release()
    }
}

// MARK: - Single-flight stop

@MainActor
private func yieldUntil(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<10_000 {
        if condition() { return true }
        await Task.yield()
    }
    return condition()
}

@MainActor
private func runSingleFlightStopSuites() async {
    await runSuite("A duplicate stop joins the running stop and both wait for its buffer drain") {
        let lifecycle = ParakeetSingleFlightLifecycle()
        let drainGate = ParakeetAsyncInterleavingGate()
        var drainRuns = 0
        var drainFinished = false
        var firstReturned = false
        var secondReturned = false

        assertFalse(lifecycle.isInProgress, "nothing is stopping yet")
        let first = Task { @MainActor in
            await lifecycle.run {
                drainRuns += 1
                await drainGate.wait()
                drainFinished = true
            }
            firstReturned = true
        }
        let started = await yieldUntil { drainRuns == 1 }
        assertTrue(started, "the first stop starts its drain")
        assertTrue(lifecycle.isInProgress, "a stop is visible while its drain is suspended")

        let second = Task { @MainActor in
            await lifecycle.run {
                drainRuns += 1
            }
            secondReturned = true
        }
        for _ in 0..<50 { await Task.yield() }
        assertFalse(secondReturned, "the duplicate stop does not return before the drain finishes")
        assertFalse(firstReturned, "the first stop is still draining")
        assertTrue(lifecycle.isInProgress, "the stop stays visible while a duplicate waits on it")

        await drainGate.open()
        await first.value
        await second.value
        assertTrue(drainFinished, "the drain completed")
        assertEqual(drainRuns, 1, "only the first caller runs stop work")
        assertFalse(lifecycle.isInProgress, "the stop clears once its work returns")
    }

    await runSuite("A stop after the previous one finished runs its own work") {
        let lifecycle = ParakeetSingleFlightLifecycle()
        var runs = 0
        await lifecycle.run { runs += 1 }
        await lifecycle.run { runs += 1 }
        assertEqual(runs, 2, "a finished stop does not swallow the next one")
    }
}
