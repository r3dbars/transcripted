import Dispatch
import Foundation

// Component-only proof: every engine is an in-memory identity. No native driver,
// ParakeetEngine, AVAudioEngine, device, model, preferences or filesystem is used.
@MainActor
func testParakeetConfigChangeDeadline() async {
    runSuite("A configuration capability transfers one permit and releases it exactly once") {
        let timers = DeadlineTimers()
        let limiter = ParakeetTimedAudioEngineWorkLimiter(maximumActiveWorkers: 1,
            configurationTimeouts: { timers.schedule($0, $1) })
        var nextLease: ParakeetTimedAudioEngineWorkLimiter.Lease?
        do {
            guard let lease = limiter.acquire() else { assertTrue(false, "initial admission failed"); return }
            guard let claim = lease.claimConfigurationOwnership() else {
                lease.release(); assertTrue(false, "first ownership transfer failed"); return
            }
            defer { claim.release(); lease.release() }
            assertEqual(limiter.activeWorkerCount, 1)
            assertNil(lease.claimConfigurationOwnership(), "one lease cannot transfer its capability twice")
            lease.release()
            lease.release()
            assertEqual(limiter.activeWorkerCount, 1, "the original lease cannot free the transferred permit")
            assertNil(limiter.acquire(), "the claimed permit still fills the one-worker circuit")
            claim.release()
            assertEqual(limiter.activeWorkerCount, 0)
            claim.release()
            assertEqual(limiter.activeWorkerCount, 0, "double release cannot underflow admission accounting")
            withExtendedLifetime((lease, claim)) {
                nextLease = limiter.acquire()
                assertNotNil(nextLease, "released capacity is usable again")
                assertEqual(limiter.activeWorkerCount, 1)
                claim.release()
                lease.release()
                assertEqual(limiter.activeWorkerCount, 1, "old releases cannot free a later worker's permit")
            }
        }
        assertEqual(limiter.activeWorkerCount, 1, "old capability deinitialization cannot free the new lease")
        nextLease?.release()
        assertEqual(limiter.activeWorkerCount, 0)
        assertEqual(timers.intervals, [], "capability transfer schedules no native deadline or queue work")
    }

    await runSuite("A native deadline lets the real mailbox drain recover the latest request on a successor") {
        let fixture = ConfigDeadlineFixture(capacity: 2)
        let oldEngine = fixture.graph.engine
        let oldQueue = fixture.graph.queue
        let heldNative = fixture.driver.block("remove", engine: oldEngine.id, occurrence: 1)
        let firstReturned = DeadlineSignal()
        let freshStartAllowed = DeadlineBlock()
        let mailbox = ParakeetInputDeviceRefreshMailbox()
        var processed: [Double] = []
        var results: [UInt64?] = []
        assertTrue(mailbox.submit(configChangeSource: .defaultInputDevice, observedAt: 1))
        let drain = Task { @MainActor in
            await ParakeetInputDeviceRefreshDrain.run(mailbox: mailbox, isStopped: { false }) { request in
                processed.append(request.observedAt ?? -1)
                results.append(await fixture.run())
                if processed.count == 1 {
                    firstReturned.signal()
                    await freshStartAllowed.waitAsync()
                }
            }
        }
        defer { heldNative.open(); freshStartAllowed.open(); mailbox.close() }
        await heldNative.entered.wait()
        assertFalse(mailbox.submit(configChangeSource: .audioEngine, observedAt: 2))
        assertFalse(mailbox.submit(configChangeSource: .defaultInputDevice, observedAt: 3))
        assertTrue(fixture.deadlines.fire(0))
        await firstReturned.wait()
        assertEqual(results.count, 1)
        if let firstResult = results.first { assertEqual(firstResult, nil) }
        assertTrue(fixture.graph.engine !== oldEngine, "production timeout repair must replace the blocked graph")
        assertTrue(fixture.graph.queue !== oldQueue, "the latest work must have a fresh serial executor")
        assertEqual(heldNative.isOpen, false, "the old native call is still held")
        assertEqual(fixture.limiter.activeWorkerCount, 1, "the held old worker still owns its permit")
        // This is an explicit new user intent in the fake host, not an automatic
        // restart invented by a later notification. Actual start/audio is outside this test.
        fixture.host.beginFreshUserRecording()
        let successor = fixture.graph.engine
        let successorQueue = fixture.graph.queue
        freshStartAllowed.open()
        await drain.value
        await deadlineQueueBarrier(successorQueue)
        assertEqual(processed, [1, 3], "the intermediate pending notification is coalesced")
        assertEqual(results.count, 2)
        assertTrue(results.count == 2 && results[1] != nil, "the latest actual teardown must succeed, not merely be admission-refused")
        assertEqual(fixture.driver.operations(engine: successor.id), ["remove", "stop"])
        assertEqual(fixture.driver.events.filter { $0.engine == successor.id }.map(\.activeWorkers), [2, 2],
                    "the successor native steps need their own permit in addition to the held old worker")
        assertEqual(fixture.limiter.activeWorkerCount, 1, "only the old permit remains after successor completion")
        assertEqual(heldNative.isOpen, false)
        let successorTrace = fixture.driver.operations(engine: successor.id)
        heldNative.open()
        await fixture.driver.resetFinished(engine: oldEngine.id).wait()
        await deadlineQueueBarrier(oldQueue)
        assertTrue(fixture.graph.engine === successor)
        assertEqual(fixture.driver.operations(engine: successor.id), successorTrace,
                    "late old work and cleanup cannot touch the successor")
        assertEqual(fixture.limiter.activeWorkerCount, 0)
    }

    await runSuite("Circuit refusal leaves graph and recovery truth unchanged") {
        let fixture = ConfigDeadlineFixture(capacity: 1)
        guard let occupied = fixture.limiter.acquire() else { assertTrue(false); return }
        defer { occupied.release() }
        let owner = fixture.graph.graphOwner
        let engine = fixture.graph.engine
        let queue = fixture.graph.queue
        let calls = fixture.host.calls
        let result = await fixture.run()
        assertEqual(result, nil)
        assertTrue(fixture.graph.owns(owner))
        assertTrue(fixture.graph.engine === engine)
        assertTrue(fixture.graph.queue === queue)
        assertEqual(fixture.graph.inputTapInstalled, true)
        assertEqual(fixture.graph.isPrewarmed, true)
        assertEqual(fixture.host.recording, true)
        assertEqual(fixture.host.activeConfigRecoveryGeneration, nil)
        assertEqual(fixture.host.calls, calls + ["blocked:1"])
        assertEqual(fixture.driver.events.count, 0, "refusal must not enter a driver operation")
        assertEqual(fixture.deadlines.intervals, [])
    }

    await runSuite("One four-second native deadline covers ordered teardown rather than restarting per stage") {
        let fixture = ConfigDeadlineFixture(capacity: 2)
        let oldEngine = fixture.graph.engine
        let oldQueue = fixture.graph.queue
        let heldStop = fixture.driver.block("stop", engine: oldEngine.id, occurrence: 1)
        let work = Task { @MainActor in await fixture.run(strategy: .rebuildGraph) }
        defer { heldStop.open() }
        await heldStop.entered.wait()
        assertEqual(fixture.driver.operations(engine: oldEngine.id), ["remove", "stop"])
        assertEqual(fixture.deadlines.intervals, [4_000_000_000])
        assertTrue(fixture.deadlines.fire(0))
        let result = await work.value
        assertEqual(result, nil, "the overall deadline resolves while stop is held")
        assertEqual(heldStop.isOpen, false)
        assertEqual(fixture.deadlines.intervals, [4_000_000_000], "no second timer can extend the native block")
        heldStop.open()
        await fixture.driver.resetFinished(engine: oldEngine.id).wait()
        await deadlineQueueBarrier(oldQueue)
        assertEqual(fixture.limiter.activeWorkerCount, 0)
    }

    await runSuite("A deadline before native entry cleans once and retains the permit until cleanup returns") {
        let queueBlock = DeadlineBlock()
        let fixture = ConfigDeadlineFixture(capacity: 1, firstQueueBlock: queueBlock)
        let oldEngine = fixture.graph.engine
        let oldQueue = fixture.graph.queue
        let cleanup = fixture.driver.block("reset", engine: oldEngine.id, occurrence: 1)
        let work = Task { @MainActor in await fixture.run() }
        defer { queueBlock.open(); cleanup.open() }
        await fixture.deadlines.registered.wait(atLeast: 1)
        assertEqual(fixture.driver.events.count, 0)
        assertTrue(fixture.deadlines.fire(0))
        let result = await work.value
        assertEqual(result, nil)
        assertEqual(fixture.limiter.activeWorkerCount, 1, "a timed-out queued native call still owns its permit")
        queueBlock.open()
        await cleanup.entered.wait()
        assertEqual(fixture.limiter.activeWorkerCount, 1, "cleanup cannot run after its permit was released")
        assertEqual(fixture.driver.operations(engine: oldEngine.id), ["remove", "reset"])
        assertTrue(fixture.driver.events.allSatisfy { $0.activeWorkers > 0 })
        cleanup.open()
        await deadlineQueueBarrier(oldQueue)
        assertEqual(fixture.driver.operations(engine: oldEngine.id), ["remove", "reset"], "one cleanup only")
        assertEqual(fixture.limiter.activeWorkerCount, 0)
    }

    await runSuite("Native completion before actor commit cannot append duplicate old cleanup") {
        let completion = DeadlineBlock()
        let fixture = ConfigDeadlineFixture(capacity: 2, completionBlock: completion)
        let oldEngine = fixture.graph.engine
        let oldQueue = fixture.graph.queue
        let owner = fixture.graph.queueOwner
        let work = Task { @MainActor in await fixture.run() }
        defer { completion.open() }
        await completion.entered.wait()
        assertEqual(fixture.driver.operations(engine: oldEngine.id), ["remove", "stop"])
        assertEqual(fixture.limiter.activeWorkerCount, 1)
        _ = fixture.graph.abandonBlocked(reason: "synthetic completion race", expectedOwner: owner)
        let currentEngine = fixture.graph.engine
        let currentOwner = fixture.graph.graphOwner
        completion.open()
        _ = await work.value
        await deadlineQueueBarrier(oldQueue)
        assertEqual(fixture.driver.operations(engine: oldEngine.id), ["remove", "stop"],
                    "same-epoch quiescent native work needs no second remove/reset")
        assertTrue(fixture.graph.engine === currentEngine)
        assertTrue(fixture.graph.owns(currentOwner))
        assertTrue(fixture.driver.events.allSatisfy { $0.activeWorkers > 0 })
        assertEqual(fixture.limiter.activeWorkerCount, 0)
    }

    await runSuite("Old quiescence cannot suppress cleanup after the same resources enter a new epoch") {
        let completion = DeadlineBlock()
        let fixture = ConfigDeadlineFixture(capacity: 2, completionBlock: completion)
        let oldEngine = fixture.graph.engine
        let oldQueue = fixture.graph.queue
        let work = Task { @MainActor in await fixture.run() }
        defer { completion.open() }
        await completion.entered.wait()
        // Public ownership-epoch seam models reuse by a new lifecycle. This is
        // deliberately not claimed as full ParakeetEngine stop/shutdown proof.
        fixture.graph.generation += 1
        let newEpoch = fixture.graph.queueOwner
        assertTrue(fixture.graph.abandonBlocked(reason: "synthetic new epoch", expectedOwner: newEpoch))
        let successor = fixture.graph.engine
        completion.open()
        let result = await work.value
        assertEqual(result, nil)
        await fixture.driver.resetFinished(engine: oldEngine.id).wait()
        await deadlineQueueBarrier(oldQueue)
        assertEqual(fixture.driver.operations(engine: oldEngine.id), ["remove", "stop", "remove", "reset"],
                    "a different epoch requires exactly one new cleanup")
        assertTrue(fixture.graph.engine === successor)
        let oldEvents = fixture.driver.events.filter { $0.engine == oldEngine.id }
        assertTrue(oldEvents.prefix(2).allSatisfy { $0.activeWorkers > 0 }, "the route-owned native steps hold a permit")
        // This genuinely new epoch uses the unchanged default cleanup path
        // after the old route permit returns. It proves stale-proof revocation,
        // not route-lease coverage or a global bound for legacy cleanup.
        assertTrue(oldEvents.suffix(2).allSatisfy { $0.activeWorkers == 0 })
        assertEqual(fixture.limiter.activeWorkerCount, 0)
    }

    await runSuite("Actual user stop supersedes held recovery and late work leaves its successor alone") {
        let fixture = ConfigDeadlineFixture(capacity: 2)
        let oldEngine = fixture.graph.engine
        let oldQueue = fixture.graph.queue
        let held = fixture.driver.block("remove", engine: oldEngine.id, occurrence: 1)
        let work = Task { @MainActor in await fixture.run() }
        defer { held.open() }
        await held.entered.wait()
        fixture.host.replaceBlockedOnWatchdogCancel = true
        await ParakeetStopRecordingSequence.run(graph: fixture.graph, host: fixture.host)
        assertEqual(fixture.host.recording, false)
        assertEqual(fixture.host.activeConfigRecoveryGeneration, nil)
        let successor = fixture.graph.engine
        assertTrue(successor !== oldEngine)
        assertTrue(fixture.deadlines.fire(0))
        let result = await work.value
        assertEqual(result, nil)
        held.open()
        await fixture.driver.resetFinished(engine: oldEngine.id).wait()
        await deadlineQueueBarrier(oldQueue)
        assertTrue(fixture.graph.engine === successor)
        assertEqual(fixture.host.recording, false, "late completion cannot restart a stopped take")
        assertEqual(fixture.limiter.activeWorkerCount, 0)
    }

    await runSuite("User stop can claim finished native work before its actor commit without duplicate cleanup") {
        let completion = DeadlineBlock()
        let fixture = ConfigDeadlineFixture(capacity: 2, completionBlock: completion)
        let oldEngine = fixture.graph.engine
        let oldQueue = fixture.graph.queue
        let recovery = Task { @MainActor in await fixture.run() }
        defer { completion.open() }
        await completion.entered.wait()
        let stopReachedClaim = DeadlineSignal()
        fixture.host.watchdogCancellationObserved = stopReachedClaim
        fixture.host.replaceBlockedOnWatchdogCancel = true
        let stopped = Task { @MainActor in
            await ParakeetStopRecordingSequence.run(graph: fixture.graph, host: fixture.host)
        }
        await stopReachedClaim.wait()
        let successor = fixture.graph.engine
        assertTrue(successor !== oldEngine, "the stop's explicit pending-work replacement must claim the old phase")
        completion.open()
        await stopped.value
        let result = await recovery.value
        assertEqual(result, nil)
        await deadlineQueueBarrier(oldQueue)
        await deadlineQueueBarrier(fixture.graph.queue)
        assertEqual(fixture.driver.operations(engine: oldEngine.id), ["remove", "stop"],
                    "finished old work must not gain a duplicate remove/reset after generation changes")
        assertTrue(fixture.driver.events.filter { $0.engine == oldEngine.id }.allSatisfy { $0.activeWorkers > 0 },
                   "only the old route-owned events are covered by the route permit")
        assertTrue(fixture.graph.engine === successor)
        assertEqual(fixture.host.recording, false)
        assertEqual(fixture.limiter.activeWorkerCount, 0)
    }

    await runSuite("Closing the real mailbox during held teardown discards pending requests without touching the successor") {
        let fixture = ConfigDeadlineFixture(capacity: 2)
        let oldEngine = fixture.graph.engine
        let oldQueue = fixture.graph.queue
        let held = fixture.driver.block("remove", engine: oldEngine.id, occurrence: 1)
        let mailbox = ParakeetInputDeviceRefreshMailbox()
        var processed = 0
        assertTrue(mailbox.submit(configChangeSource: .defaultInputDevice, observedAt: 1))
        let drain = Task { @MainActor in
            await ParakeetInputDeviceRefreshDrain.run(mailbox: mailbox, isStopped: { false }) { _ in
                processed += 1
                _ = await fixture.run()
            }
        }
        defer { held.open(); mailbox.close() }
        await held.entered.wait()
        assertFalse(mailbox.submit(configChangeSource: .audioEngine, observedAt: 2))
        mailbox.close()
        assertTrue(fixture.deadlines.fire(0))
        await drain.value
        assertEqual(processed, 1, "closing the mailbox prevents the pending request from entering teardown")
        assertNil(mailbox.takeNext())
        let successor = fixture.graph.engine
        held.open()
        await fixture.driver.resetFinished(engine: oldEngine.id).wait()
        await deadlineQueueBarrier(oldQueue)
        assertTrue(fixture.graph.engine === successor)
        assertEqual(fixture.limiter.activeWorkerCount, 0)
    }

    await runSuite("Closing the real mailbox drops pending work and stopped drains admit no new request") {
        let mailbox = ParakeetInputDeviceRefreshMailbox()
        assertTrue(mailbox.submit(configChangeSource: .defaultInputDevice, observedAt: 1))
        mailbox.close()
        var processed = 0
        await ParakeetInputDeviceRefreshDrain.run(mailbox: mailbox, isStopped: { true }) { _ in processed += 1 }
        assertEqual(processed, 0)
        assertEqual(mailbox.submit(configChangeSource: .audioEngine, observedAt: 2), false)
        assertNil(mailbox.takeNext())
    }
}

@MainActor
private func deadlineQueueBarrier(_ queue: DispatchQueue) async {
    await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
}

private final class DeadlineSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() {
        lock.lock(); fired = true; let pending = waiters; waiters.removeAll(); lock.unlock()
        for waiter in pending { waiter.resume() }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if fired { lock.unlock(); continuation.resume() }
            else { waiters.append(continuation); lock.unlock() }
        }
    }
}

private final class DeadlineCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func increment() {
        lock.lock(); value += 1
        let ready = waiters.filter { $0.0 <= value }; waiters.removeAll { $0.0 <= value }; lock.unlock()
        for (_, waiter) in ready { waiter.resume() }
    }
    func wait(atLeast target: Int) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if value >= target { lock.unlock(); continuation.resume() }
            else { waiters.append((target, continuation)); lock.unlock() }
        }
    }
}

private final class DeadlineBlock: @unchecked Sendable {
    let entered = DeadlineSignal()
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private let asyncRelease = DeadlineSignal()
    private var released = false
    private var completionClaimed = false
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return released }
    func holdWorker() { entered.signal(); semaphore.wait() }
    func holdFirstCompletion() {
        lock.lock(); let shouldHold = !completionClaimed; completionClaimed = true; lock.unlock()
        if shouldHold { holdWorker() }
    }
    func waitAsync() async { entered.signal(); await asyncRelease.wait() }
    func open() {
        lock.lock(); let wasReleased = released; released = true; lock.unlock()
        if !wasReleased { semaphore.signal(); asyncRelease.signal() }
    }
}

private final class DeadlineTimers: @unchecked Sendable {
    let registered = DeadlineCount()
    private let lock = NSLock()
    private var entries: [(UInt64, @Sendable () -> Void)] = []
    var intervals: [UInt64] { lock.lock(); defer { lock.unlock() }; return entries.map(\.0) }
    func schedule(_ interval: UInt64, _ callback: @escaping @Sendable () -> Void) {
        lock.lock(); entries.append((interval, callback)); lock.unlock(); registered.increment()
    }
    func fire(_ index: Int) -> Bool {
        lock.lock()
        guard entries.indices.contains(index) else { lock.unlock(); return false }
        let callback = entries[index].1; lock.unlock(); callback(); return true
    }
}

private final class DeadlineEngine: @unchecked Sendable {
    let id: Int
    init(id: Int) { self.id = id }
}

private final class DeadlineDriver: ParakeetAudioGraphDriver, @unchecked Sendable {
    struct Event { let engine: Int; let operation: String; let activeWorkers: Int }
    private let lock = NSLock()
    private var nextEngine = 0
    private var nextQueue = 0
    private var recorded: [Event] = []
    private var blocks: [String: DeadlineBlock] = [:]
    private var resets: [Int: DeadlineSignal] = [:]
    let activeWorkers: @Sendable () -> Int
    let firstQueueBlock: DeadlineBlock?
    init(activeWorkers: @escaping @Sendable () -> Int, firstQueueBlock: DeadlineBlock?) {
        self.activeWorkers = activeWorkers; self.firstQueueBlock = firstQueueBlock
    }
    var events: [Event] { lock.lock(); defer { lock.unlock() }; return recorded }
    func operations(engine: Int) -> [String] { events.filter { $0.engine == engine }.map(\.operation) }
    func block(_ operation: String, engine: Int, occurrence: Int) -> DeadlineBlock {
        let block = DeadlineBlock(); lock.lock(); blocks["\(engine):\(operation):\(occurrence)"] = block; lock.unlock(); return block
    }
    func resetFinished(engine: Int) -> DeadlineSignal {
        lock.lock(); defer { lock.unlock() }
        if let signal = resets[engine] { return signal }
        let signal = DeadlineSignal(); resets[engine] = signal; return signal
    }
    func makeEngine() -> DeadlineEngine {
        lock.lock(); nextEngine += 1; let id = nextEngine; lock.unlock(); return DeadlineEngine(id: id)
    }
    func makeQueue() -> DispatchQueue {
        lock.lock(); nextQueue += 1; let id = nextQueue; lock.unlock()
        let queue = DispatchQueue(label: "synthetic.config-deadline.\(id)")
        if id == 1, let firstQueueBlock { queue.async { firstQueueBlock.holdWorker() } }
        return queue
    }
    private func perform(_ operation: String, engine: DeadlineEngine) {
        let count = activeWorkers()
        lock.lock()
        let occurrence = recorded.filter { $0.engine == engine.id && $0.operation == operation }.count + 1
        recorded.append(Event(engine: engine.id, operation: operation, activeWorkers: count))
        let block = blocks["\(engine.id):\(operation):\(occurrence)"]; lock.unlock()
        block?.holdWorker()
    }
    func removeInputTap(on engine: DeadlineEngine) -> Bool { perform("remove", engine: engine); return true }
    func stop(_ engine: DeadlineEngine) -> Bool { perform("stop", engine: engine); return true }
    func reset(_ engine: DeadlineEngine) { perform("reset", engine: engine); resetFinished(engine: engine.id).signal() }
    func usesVoiceProcessing(_ engine: DeadlineEngine) -> Bool { false }
    func retire(_ engine: DeadlineEngine, reason: String) -> Bool { true }
}

@MainActor
private final class ConfigDeadlineHost: ParakeetConfigChangeRecoveryHost, ParakeetAudioGraphHost, ParakeetStopRecordingHost {
    weak var graph: ParakeetAudioGraph<DeadlineDriver>?
    var recording = true
    var admitsConfigChangeRecovery = true
    var isShuttingDown = false
    var isRecording: Bool { recording }
    var activeConfigRecoveryGeneration: UInt64?
    var calls: [String] = []
    var replaceBlockedOnWatchdogCancel = false
    var watchdogCancellationObserved: DeadlineSignal?
    private var nextGeneration: UInt64 = 0
    private var recoveryOwner: ParakeetAudioEngineQueueOwnerToken?
    func beginFreshUserRecording() { calls.append("explicit-fresh-user-start"); recording = true }
    func beginConfigChangeRecovery() -> UInt64 {
        nextGeneration += 1; activeConfigRecoveryGeneration = nextGeneration
        recoveryOwner = graph?.queueOwner; calls.append("begin"); return nextGeneration
    }
    func cancelAudioWatchdog() -> Bool {
        calls.append("cancel-watchdog")
        let replaced = replaceBlockedOnWatchdogCancel ? graph?.replaceGraphHoldingPendingWork() ?? false : false
        watchdogCancellationObserved?.signal()
        return replaced
    }
    func cancelPrewarmRetry() { calls.append("cancel-prewarm") }
    func preserveCurrentRecordingBuffersForRecovery() { calls.append("preserve") }
    func markRecordingStoppedForRecovery() { calls.append("mark-stopped"); recording = false }
    func cancelConfigRecoveryIfCurrent(generation: UInt64) {
        if activeConfigRecoveryGeneration == generation { activeConfigRecoveryGeneration = nil; calls.append("cancel-generation") }
    }
    func reportGraphReusedAfterConfigChange() { calls.append("reused") }
    func reportConfigChangeAdmissionBlocked(activeWorkers: Int) { calls.append("blocked:\(activeWorkers)") }
    func configChangeNativeWorkTimedOut(generation: UInt64, wasRecording: Bool) async {
        guard let graph else { return }
        await ParakeetDeviceRecoverySequence.runTimeout(generation: generation, wasRecording: wasRecording, steps: .init(
            timeoutRecovery: { [self] requested in
                guard activeConfigRecoveryGeneration == requested else { return false }
                activeConfigRecoveryGeneration = nil; calls.append("timed-out"); return true
            },
            clearTimeoutTask: { [self] in calls.append("clear-timeout") },
            releaseRecordingIntent: { [self] in calls.append("release-intent") },
            publishRecoveryState: { [self] in calls.append("publish-recovery") },
            reportTimedOut: { [self] _ in calls.append("report-timeout") },
            interruptPreservingTimeline: { [self] in recording = false; calls.append("interrupt") },
            reportRecordingInterrupted: { [self] in calls.append("report-interrupted") },
            graph: .init(
                currentOwner: { [self] in recoveryOwner ?? graph.queueOwner },
                ownsQueue: { graph.owns($0) },
                rebuildOnQueue: { _ in false },
                abandonBlockedGraph: { graph.abandonBlocked(reason: $0, expectedOwner: $1) },
                scheduleFreshPrewarmRetry: { [self] in calls.append("retry-prewarm") }
            )
        ))
    }
    func installAudioEngineConfigObserverIfNeeded() { calls.append("install-observer") }
    func removeAudioEngineConfigObserver() { calls.append("remove-observer") }
    func trackAudioEngineRebuildChurn(reason: String) { calls.append("rebuild") }
    func clearGraphSampleFlags() { calls.append("clear-samples") }
    func interruptRecordingPreservingRecoveredTimeline() { recording = false; calls.append("graph-interrupt") }
    func reportAudioGraphEvent(_ event: ParakeetAudioGraphEvent) { calls.append("graph-event") }
    var hasSharedMeetingMicClaim: Bool { false }
    var isSharedMeetingMicResumeInProgress: Bool { false }
    func invalidateSharedMeetingMicTransition() { calls.append("invalidate-shared") }
    func flushSharedMeetingMicBuffers() async { calls.append("flush-shared") }
    func finishSharedMeetingMicStop() { recording = false }
    func idleStopAction() -> ParakeetIdleStopAction { .drainRecoveredAudio }
    func cancelPendingRecordingRecovery() { activeConfigRecoveryGeneration = nil; calls.append("cancel-pending") }
    func clearRecoveredRecordingTimeline(keepingCapacity: Bool) { calls.append("clear-timeline") }
    var hasPinnedDictationRecording: Bool { false }
    func stopPinnedDictationRecording() async { recording = false }
    func finishStoppedRecording() { recording = false; calls.append("finish-stop") }
    func reportRecordingStopped() { calls.append("report-stop") }
    func endRecordingContinuity() { calls.append("end-continuity") }
}

@MainActor
private final class ConfigDeadlineFixture {
    let driver: DeadlineDriver
    let limiter: ParakeetTimedAudioEngineWorkLimiter
    let graph: ParakeetAudioGraph<DeadlineDriver>
    let host = ConfigDeadlineHost()
    let deadlines: DeadlineTimers
    init(capacity: Int, firstQueueBlock: DeadlineBlock? = nil, completionBlock: DeadlineBlock? = nil) {
        let timers = DeadlineTimers(); deadlines = timers
        let limiter = ParakeetTimedAudioEngineWorkLimiter(maximumActiveWorkers: capacity,
            configurationTimeouts: { timers.schedule($0, $1) },
            configurationNativeCompletion: {
                // Only the first observed native completion is held. Successor
                // work and deferred cleanup must remain independently drainable.
                completionBlock?.holdFirstCompletion()
            })
        self.limiter = limiter
        driver = DeadlineDriver(activeWorkers: { limiter.activeWorkerCount }, firstQueueBlock: firstQueueBlock)
        graph = ParakeetAudioGraph(driver: driver, workLimiter: limiter)
        graph.inputTapInstalled = true; graph.isPrewarmed = true
        host.graph = graph; graph.host = host
    }
    func run(strategy: ParakeetConfigChangeGraphStrategy = .reuseCurrentGraph) async -> UInt64? {
        await ParakeetConfigChangeTeardown.run(graph: graph, host: host, strategy: strategy, forceForMicrophoneSharing: false)
    }
}
