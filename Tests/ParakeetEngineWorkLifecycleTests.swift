// ParakeetEngineWorkLifecycleTests.swift
//
// Behavior tests for three pieces ParakeetEngine delegates to: the timed
// audio-engine work runner, the single-flight stop lifecycle, and the
// system-input reconciler. Each runs here against fakes (a plain object as the
// "engine", scripted CoreAudio results), so none of this proves real
// AVAudioEngine, AirPods, or HAL default-input behavior. The hardware checks
// (`bash check.sh hardware`) still cover that.

import CoreAudio
import Foundation

@MainActor
func testParakeetEngineWorkLifecycle() async {
    await runTimedAudioEngineWorkSuites()
    await runSingleFlightStopSuites()
    await runSystemInputReconcilerSuites()
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

// MARK: - System-input reconciliation

private enum FakeCoreAudioOutcome {
    /// Run the work and return its result.
    case complete
    /// Throw a timeout without running the work and keep the late callback.
    case timeout
}

@MainActor
private final class SystemInputHarness {
    var pending = ParakeetOwnerBoundPendingState<ParakeetSystemInputRestoreTarget>()
    var outcomes: [FakeCoreAudioOutcome] = []
    var applyErrors: [String?] = []
    var restoreErrors: [String?] = []
    var operations: [String] = []
    var appliedInputs: [AudioDeviceID] = []
    var restoredTargets: [ParakeetSystemInputRestoreTarget] = []
    var failures: [String] = []
    var lateCallbacks: [(String?) -> Void] = []
    var spawned: [@MainActor () async -> Void] = []
    var blockNextRun: ParakeetAsyncInterleavingGate?
    var runsEntered = 0

    func makeReconciler(attempts: Int = 2) -> ParakeetSystemInputReconciler {
        ParakeetSystemInputReconciler(
            attempts: attempts,
            pendingRestore: { [unowned self] in self.pending },
            runCoreAudio: { [unowned self] operation, late, work in
                self.operations.append(operation)
                self.runsEntered += 1
                if let gate = self.blockNextRun {
                    self.blockNextRun = nil
                    await gate.wait()
                }
                let outcome = self.outcomes.isEmpty ? .complete : self.outcomes.removeFirst()
                switch outcome {
                case .complete:
                    // The fake runs CoreAudio work inline on the MainActor.
                    return work()
                case .timeout:
                    self.lateCallbacks.append(late)
                    throw ParakeetSystemInputWorkError.timedOut(operation: operation, timeoutMs: 1)
                }
            },
            applyInput: { [unowned self] input in
                MainActor.assumeIsolated {
                    self.appliedInputs.append(input)
                    return self.applyErrors.isEmpty ? nil : self.applyErrors.removeFirst()
                }
            },
            restoreIfStillTemporary: { [unowned self] target in
                MainActor.assumeIsolated {
                    self.restoredTargets.append(target)
                    return self.restoreErrors.isEmpty ? nil : self.restoreErrors.removeFirst()
                }
            },
            reportFailure: { [unowned self] operation, kind in
                self.failures.append("\(operation):\(kind)")
            },
            spawn: { [unowned self] work in
                MainActor.assumeIsolated {
                    self.spawned.append(work)
                }
            }
        )
    }

    /// Runs the late-completion work the reconciler handed off, in order.
    func runSpawned() async {
        while !spawned.isEmpty {
            let work = spawned.removeFirst()
            await work()
        }
    }
}

private func restoreRequest(
    _ target: ParakeetSystemInputRestoreTarget,
    clearMarker: Bool = true
) -> ParakeetSystemInputReconciliationRequest {
    ParakeetSystemInputReconciliationRequest(attemptedTarget: target, clearMarkerWhenRestored: clearMarker)
}

@MainActor
private func runSystemInputReconcilerSuites() async {
    let airPods = ParakeetSystemInputRestoreTarget(temporaryInput: 41, previousInput: 7)
    let builtIn = ParakeetSystemInputRestoreTarget(temporaryInput: 52, previousInput: 7)
    let restore = ParakeetSystemInputReconciler.restoreOperation
    let successor = ParakeetSystemInputReconciler.successorOperation

    await runSuite("A CoreAudio error while restoring the input is retried, not taken as restored") {
        let harness = SystemInputHarness()
        harness.restoreErrors = ["kAudioHardwareUnspecifiedError", nil]
        let reconciler = harness.makeReconciler()
        await reconciler.reconcile(restoreRequest(airPods))
        assertEqual(harness.restoredTargets, [airPods, airPods], "an error result gets a second restore attempt")
        assertEqual(harness.failures, ["\(restore):core_audio_error"], "the error is reported once")
    }

    await runSuite("A CoreAudio error while re-applying a newer recording's input is retried") {
        let harness = SystemInputHarness()
        let owner = ParakeetAudioGraphOwnerToken(generation: 2, engine: NSObject())
        harness.pending.replace(builtIn, ownedBy: owner)
        harness.applyErrors = ["kAudioHardwareBadDeviceError", nil]
        let reconciler = harness.makeReconciler()
        await reconciler.reconcile(restoreRequest(airPods))
        assertEqual(harness.appliedInputs, [52, 52], "the successor's route is applied again after the error")
        assertTrue(harness.restoredTargets.isEmpty, "a live successor is never undone by the old restore")
        assertEqual(harness.failures, ["\(successor):core_audio_error"], "the error is reported once")
    }

    await runSuite("Reconciliation gives up after its attempt budget") {
        let harness = SystemInputHarness()
        harness.restoreErrors = ["e1", "e2", "e3", "e4"]
        let reconciler = harness.makeReconciler(attempts: 2)
        await reconciler.reconcile(restoreRequest(airPods))
        assertEqual(harness.restoredTargets.count, 2, "a stuck HAL gets exactly the budgeted attempts")
        assertEqual(
            harness.failures,
            ["\(restore):core_audio_error", "\(restore):core_audio_error"],
            "each failed attempt is reported"
        )
    }

    await runSuite("A late restore that lands after the route converged starts no new work") {
        let harness = SystemInputHarness()
        harness.outcomes = [.timeout, .complete]
        let reconciler = harness.makeReconciler()
        await reconciler.reconcile(restoreRequest(airPods))
        assertEqual(harness.operations, [restore, restore], "the timed-out pass is retried once")
        assertEqual(harness.failures, ["\(restore):timeout"], "the timeout is reported")
        assertEqual(harness.lateCallbacks.count, 1, "the timed-out call can still complete late")

        harness.lateCallbacks[0](nil)
        await harness.runSpawned()
        assertEqual(harness.operations.count, 2, "a late success with unchanged intent is terminal")
    }

    await runSuite("A late restore asks for one more pass when a new recording took the input meanwhile") {
        let harness = SystemInputHarness()
        harness.outcomes = [.timeout, .complete]
        let reconciler = harness.makeReconciler()
        await reconciler.reconcile(restoreRequest(airPods))
        let owner = ParakeetAudioGraphOwnerToken(generation: 3, engine: NSObject())
        harness.pending.replace(builtIn, ownedBy: owner)

        harness.lateCallbacks[0](nil)
        await harness.runSpawned()
        assertEqual(harness.operations, [restore, restore, successor], "the late write is followed by re-applying the new intent")
        assertEqual(harness.appliedInputs, [52], "the newer recording's route wins")
    }

    await runSuite("A late successor write with unchanged intent is terminal, a changed one is not") {
        let harness = SystemInputHarness()
        let firstOwner = ParakeetAudioGraphOwnerToken(generation: 4, engine: NSObject())
        harness.pending.replace(builtIn, ownedBy: firstOwner)
        harness.outcomes = [.timeout, .complete]
        let reconciler = harness.makeReconciler()
        await reconciler.reconcile(restoreRequest(airPods))
        assertEqual(harness.operations, [successor, successor], "the timed-out successor apply is retried")

        harness.lateCallbacks[0](nil)
        await harness.runSpawned()
        assertEqual(harness.operations.count, 2, "late success for the still-current owner needs nothing more")

        harness.outcomes = [.timeout, .complete]
        await reconciler.reconcile(restoreRequest(airPods))
        let secondOwner = ParakeetAudioGraphOwnerToken(generation: 5, engine: NSObject())
        harness.pending.replace(airPods, ownedBy: secondOwner)
        harness.lateCallbacks[1](nil)
        await harness.runSpawned()
        assertEqual(harness.operations.count, 5, "a changed owner during the blocked call earns one more pass")
        assertEqual(harness.appliedInputs.last, 41, "that pass applies the current owner's route")
    }

    await runSuite("A late CoreAudio error is reported and starts no new work") {
        let harness = SystemInputHarness()
        harness.outcomes = [.timeout, .complete]
        let reconciler = harness.makeReconciler()
        await reconciler.reconcile(restoreRequest(airPods))
        let owner = ParakeetAudioGraphOwnerToken(generation: 6, engine: NSObject())
        harness.pending.replace(builtIn, ownedBy: owner)

        harness.lateCallbacks[0]("kAudioHardwareIllegalOperationError")
        await harness.runSpawned()
        assertEqual(harness.operations.count, 2, "an errored late write never recurses into more HAL work")
        assertEqual(
            harness.failures,
            ["\(restore):timeout", "\(restore):core_audio_error"],
            "the late error is reported against the restore operation"
        )
    }

    await runSuite("Reconciliation requests drain through one task and coalesce by route") {
        let harness = SystemInputHarness()
        let gate = ParakeetAsyncInterleavingGate()
        harness.blockNextRun = gate
        let reconciler = harness.makeReconciler()
        var firstReturned = false
        var secondReturned = false
        var thirdReturned = false

        let first = Task { @MainActor in
            await reconciler.reconcile(restoreRequest(airPods))
            firstReturned = true
        }
        let entered = await yieldUntil { harness.runsEntered == 1 }
        assertTrue(entered, "the first request is blocked inside CoreAudio")

        let second = Task { @MainActor in
            await reconciler.reconcile(restoreRequest(builtIn, clearMarker: false))
            secondReturned = true
        }
        let third = Task { @MainActor in
            await reconciler.reconcile(restoreRequest(builtIn, clearMarker: true))
            thirdReturned = true
        }
        for _ in 0..<50 { await Task.yield() }
        assertEqual(harness.runsEntered, 1, "queued requests wait for the running pass instead of starting their own")
        assertFalse(secondReturned || thirdReturned, "queued callers wait for the drain")

        await gate.open()
        await first.value
        await second.value
        await third.value
        assertTrue(firstReturned && secondReturned && thirdReturned, "every caller returns once the queue is empty")
        assertEqual(harness.restoredTargets, [airPods, builtIn], "the two requests for one route ran once")

        await reconciler.reconcile(restoreRequest(airPods))
        assertEqual(harness.restoredTargets.count, 3, "a request after the drain finished starts a new pass")
    }
}
