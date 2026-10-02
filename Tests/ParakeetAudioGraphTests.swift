// ParakeetAudioGraphTests.swift
//
// Behavior tests for ParakeetAudioGraph and the stop, route-change, restart
// and snapshot orderings ParakeetEngine runs on it. A fake driver stands in
// for AVAudioEngine and fake hosts stand in for the engine; all of them write
// to one event log, so a test checks what happened and in which order. A
// driver call can be held open to land a competing owner change mid-flight.
//
// None of this proves real AVAudioEngine, AirPods, or CoreAudio behavior.
// `bash check.sh hardware` still covers that.

import Foundation

@MainActor
func testParakeetAudioGraph() async {
    await runGraphTeardownOwnershipSuites()
    await runGraphReplacementSuites()
    await runGraphCancellationSuites()
    await runStopSequenceSuites()
    await runConfigChangeTeardownSuites()
    await runRouteRestartSuites()
    await runSnapshotSuites()
}

// MARK: - Fakes

private final class FakeAudioEngine {
    let id: Int

    init(id: Int) {
        self.id = id
    }
}

/// One driver call held open until the test releases it.
private final class HeldGraphWork: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
}

/// Everything the fakes did, in order. Driver calls land from graph queues,
/// host calls from the main actor.
private final class GraphTestLog: @unchecked Sendable {
    let queueKey = DispatchSpecificKey<Int>()
    private let lock = NSLock()
    private var entries: [String] = []
    private var engineCount = 0
    private var queueCount = 0
    private var held: [String: HeldGraphWork] = [:]
    private var results: [String: Bool] = [:]

    var events: [String] {
        lock.withLock { entries }
    }

    func record(_ entry: String) {
        lock.withLock { entries.append(entry) }
    }

    func clear() {
        lock.withLock { entries.removeAll() }
    }

    func contains(_ entry: String) -> Bool {
        events.contains(entry)
    }

    func index(of entry: String) -> Int? {
        events.firstIndex(of: entry)
    }

    /// `removeTap`, `stop`, `usesVoiceProcessing` and `retire` default to true,
    /// `usesVoiceProcessing` to false.
    func setResult(_ call: String, _ value: Bool) {
        lock.withLock { results[call] = value }
    }

    func result(_ call: String) -> Bool {
        lock.withLock { results[call] ?? (call != "usesVoiceProcessing") }
    }

    /// Holds the next `call` open until the test releases it.
    func hold(_ call: String) -> HeldGraphWork {
        let work = HeldGraphWork()
        lock.withLock { held[call] = work }
        return work
    }

    func makeEngine() -> FakeAudioEngine {
        let id = lock.withLock { () -> Int in
            engineCount += 1
            return engineCount
        }
        record("makeEngine:e\(id)")
        return FakeAudioEngine(id: id)
    }

    func makeQueue() -> DispatchQueue {
        let id = lock.withLock { () -> Int in
            queueCount += 1
            return queueCount
        }
        let queue = DispatchQueue(label: "test.parakeet.audio-graph.q\(id)")
        queue.setSpecific(key: queueKey, value: id)
        return queue
    }

    func queueID(_ queue: DispatchQueue) -> Int? {
        queue.getSpecific(key: queueKey)
    }

    func driverCall(_ call: String, _ engine: FakeAudioEngine) {
        let queueID = DispatchQueue.getSpecific(key: queueKey).map { "q\($0)" } ?? "main"
        record("\(call):e\(engine.id)@\(queueID)")
        let work = lock.withLock { held.removeValue(forKey: call) }
        if let work {
            work.entered.signal()
            _ = work.release.wait(timeout: .now() + 30)
        }
    }
}

private struct FakeGraphDriver: ParakeetAudioGraphDriver {
    let log: GraphTestLog

    func makeEngine() -> FakeAudioEngine { log.makeEngine() }
    func makeQueue() -> DispatchQueue { log.makeQueue() }

    func removeInputTap(on engine: FakeAudioEngine) -> Bool {
        log.driverCall("removeTap", engine)
        return log.result("removeTap")
    }

    func stop(_ engine: FakeAudioEngine) -> Bool {
        log.driverCall("stop", engine)
        return log.result("stop")
    }

    func reset(_ engine: FakeAudioEngine) {
        log.driverCall("reset", engine)
    }

    func usesVoiceProcessing(_ engine: FakeAudioEngine) -> Bool {
        log.driverCall("usesVoiceProcessing", engine)
        return log.result("usesVoiceProcessing")
    }

    func retire(_ engine: FakeAudioEngine, reason: String) -> Bool {
        log.record("retire:e\(engine.id):\(reason)")
        return log.result("retire")
    }
}

private typealias TestGraph = ParakeetAudioGraph<FakeGraphDriver>

@MainActor
private final class FakeGraphHost: ParakeetAudioGraphHost {
    let log: GraphTestLog
    weak var graph: TestGraph?
    var isShuttingDown = false
    var isRecording = false
    var reported: [ParakeetAudioGraphEvent] = []

    init(log: GraphTestLog) {
        self.log = log
    }

    func installAudioEngineConfigObserverIfNeeded() {
        log.record("observe:e\(graph?.engine.id ?? 0)")
    }

    func removeAudioEngineConfigObserver() {
        log.record("unobserve")
    }

    func trackAudioEngineRebuildChurn(reason: String) {
        log.record("churn:\(reason)")
    }

    func clearGraphSampleFlags() {
        log.record("clearSampleFlags")
    }

    func interruptRecordingPreservingRecoveredTimeline() {
        log.record("interrupt")
    }

    func reportAudioGraphEvent(_ event: ParakeetAudioGraphEvent) {
        reported.append(event)
    }
}

@MainActor
private struct GraphFixture {
    let graph: TestGraph
    let host: FakeGraphHost
    let log: GraphTestLog

    init(workLimiter: ParakeetTimedAudioEngineWorkLimiter = ParakeetTimedAudioEngineWorkLimiter(maximumActiveWorkers: 4)) {
        let log = GraphTestLog()
        let graph = TestGraph(
            driver: FakeGraphDriver(log: log),
            workLimiter: workLimiter
        )
        let host = FakeGraphHost(log: log)
        host.graph = graph
        graph.host = host
        log.clear()
        self.graph = graph
        self.host = host
        self.log = log
    }

    var engineID: Int { graph.engine.id }
    var queueID: Int? { log.queueID(graph.queue) }
}

/// Waits off the cooperative pool. The 30 s bound only stops a broken test
/// from hanging; nothing asserts on elapsed time.
private func waitFor(_ semaphore: DispatchSemaphore) async -> Bool {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async {
            continuation.resume(returning: semaphore.wait(timeout: .now() + 30) == .success)
        }
    }
}

/// Returns once everything already queued on `queue` has run.
private func drain(_ queue: DispatchQueue) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        queue.async { continuation.resume() }
    }
}

/// Starts `operation` and returns once it is parked inside `held`.
@MainActor
private func startHeld<T: Sendable>(
    _ held: HeldGraphWork,
    _ operation: @escaping @MainActor () async -> T
) async -> Task<T, Never> {
    let task = Task { @MainActor in await operation() }
    let entered = await waitFor(held.entered)
    assertTrue(entered, "the operation should reach the held driver call")
    return task
}

// MARK: - Teardown ownership

@MainActor
private func runGraphTeardownOwnershipSuites() async {
    await runSuite("A tap removal that finishes after the graph was replaced leaves the new graph's tap alone") {
        let fixture = GraphFixture()
        let graph = fixture.graph
        graph.inputTapInstalled = true
        let held = fixture.log.hold("removeTap")
        let removal = await startHeld(held) { await graph.removeRecordingTap() }

        graph.abandonBlocked(reason: "test_successor")
        graph.inputTapInstalled = true // the successor's start installed its own tap
        held.release.signal()
        await removal.value
        assertTrue(graph.inputTapInstalled, "a late removal must not clear the successor's tap state")

        await graph.removeRecordingTap()
        assertFalse(graph.inputTapInstalled, "a removal that keeps its graph clears the tap state")
    }

    await runSuite("Idle cleanup that loses the graph mid-way leaves the newer owner's engine and prewarm alone") {
        let fixture = GraphFixture()
        let graph = fixture.graph
        let log = fixture.log

        graph.isPrewarmed = true
        let heldStop = log.hold("stop")
        let cleanup = await startHeld(heldStop) {
            await graph.releaseIdleHardware(removeTap: true)
        }
        graph.generation += 1 // a newer start owns the graph now
        graph.isPrewarmed = true
        heldStop.release.signal()
        assertNil(await cleanup.value, "a cleanup that lost its graph reports no owner")
        assertTrue(graph.isPrewarmed, "the newer owner's prewarm state survives the late stop")

        log.clear()
        let heldTap = log.hold("removeTap")
        let secondCleanup = await startHeld(heldTap) {
            await graph.releaseIdleHardware(removeTap: true)
        }
        graph.generation += 1
        heldTap.release.signal()
        assertNil(await secondCleanup.value, "losing the graph during tap removal ends the cleanup")
        assertFalse(
            log.events.contains { $0.hasPrefix("stop:") },
            "a cleanup that lost the graph during tap removal never stops the successor's engine"
        )

        log.clear()
        assertNil(
            await graph.releaseIdleHardware(removeTap: true, expectedGeneration: graph.generation - 1),
            "a cleanup already superseded before it starts does nothing"
        )
        assertTrue(log.events.isEmpty, "a superseded cleanup makes no driver calls")

        let owner = await graph.releaseIdleHardware(removeTap: true)
        assertNotNil(owner, "an uncontested cleanup returns its owner")
        assertFalse(graph.isPrewarmed, "an uncontested cleanup clears prewarm")
    }

    await runSuite("A failed-start reset stays claimable by a stop and can't touch the successor") {
        let fixture = GraphFixture()
        let graph = fixture.graph
        let log = fixture.log

        let resetLease = graph.queueOwner
        let held = log.hold("removeTap")
        let reset = await startHeld(held) {
            await graph.resetAfterStartFailure(reason: "test_reset", rebuildEngine: false)
        }
        assertTrue(
            graph.workOwnership.isActive(owner: resetLease, phase: .audioStart),
            "the reset holds the failed start's exact lease while CoreAudio is busy"
        )
        assertTrue(graph.replaceGraphHoldingPendingWork(), "a user stop claims the blocked reset and replaces the graph")
        assertTrue(log.contains("churn:audio_engine_start_cancelled"), "the replacement names the cancelled start")
        graph.inputTapInstalled = true
        held.release.signal()
        assertNil(await reset.value, "the late reset reports that it lost the graph")
        assertTrue(graph.inputTapInstalled, "the late reset leaves the successor's tap state alone")
        assertFalse(
            graph.workOwnership.isActive(owner: resetLease, phase: .audioStart),
            "no lease is left behind"
        )

        graph.isPrewarmed = true
        let owner = await graph.resetAfterStartFailure(reason: "test_reset", rebuildEngine: false)
        assertEqual(owner, graph.graphOwner, "an uncontested reset keeps the graph and returns its owner")
        assertFalse(graph.inputTapInstalled, "the reset clears the tap state")
        assertFalse(graph.isPrewarmed, "the reset clears prewarm")
    }

    await runSuite("A recording stop settles the take only while it still owns the graph") {
        let fixture = GraphFixture()
        let graph = fixture.graph
        let log = fixture.log

        let held = log.hold("stop")
        var finishedStaleStop = false
        let staleStop = await startHeld(held) {
            await graph.stopRecording { finishedStaleStop = true }
        }
        graph.generation += 1
        held.release.signal()
        assertFalse(await staleStop.value, "a stop that lost the graph says so")
        assertFalse(finishedStaleStop, "a stop that lost the graph doesn't settle the newer recording")

        graph.isPrewarmed = true
        var finished = false
        assertTrue(await graph.stopRecording { finished = true }, "an uncontested stop keeps its graph")
        assertTrue(finished, "an uncontested stop settles the take")
        assertFalse(graph.isPrewarmed, "an uncontested stop clears prewarm")
    }

    await runSuite("A graph whose voice processing stayed on is dropped after the stop settles, never retained") {
        let fixture = GraphFixture()
        let graph = fixture.graph
        let log = fixture.log
        let stoppedEngine = fixture.engineID
        log.setResult("stop", false)

        var engineWhenSettled: Int?
        let stopped = await graph.stopRecording {
            engineWhenSettled = graph.engine.id
            log.record("settled")
        }
        assertTrue(stopped, "the stop still completes")
        assertEqual(engineWhenSettled, stoppedEngine, "recording state settles while the stopped graph is current")
        if let settled = log.index(of: "settled"), let replaced = log.index(of: "makeEngine:e2") {
            assertTrue(settled < replaced, "the take settles before the graph is replaced")
        } else {
            assertTrue(false, "the stop should settle and then replace the graph, got \(log.events)")
        }
        assertFalse(
            log.events.contains { $0.hasPrefix("retire:") },
            "a graph that kept voice processing on is never held for delayed retirement"
        )

        log.clear()
        let idleOwner = graph.queueOwner
        let replacement = await graph.releaseIdleHardware(removeTap: true)
        assertNotNil(replacement, "idle cleanup hands back the replacement graph")
        assertFalse(replacement == idleOwner, "idle cleanup drops the graph that kept voice processing on")
        assertEqual(replacement, graph.queueOwner, "the replacement is the current graph")

        fixture.host.isRecording = true
        let recordingOwner = graph.queueOwner
        let engineBeforeRefusals = graph.engine.id
        assertNil(
            graph.discardStoppedVoiceProcessingGraph(ownedBy: recordingOwner),
            "a graph that is recording again is not dropped"
        )
        fixture.host.isRecording = false
        graph.generation += 1
        assertNil(
            graph.discardStoppedVoiceProcessingGraph(ownedBy: recordingOwner),
            "only the exact stopped owner may drop its graph"
        )
        assertEqual(graph.engine.id, engineBeforeRefusals, "a refused drop keeps the engine")
    }

    await runSuite("Wake and route teardown keep buffered speech and stop only their own graph") {
        let fixture = GraphFixture()
        let graph = fixture.graph
        let log = fixture.log

        graph.inputTapInstalled = true
        graph.isPrewarmed = true
        let teardown = await graph.stopForRecovery(
            isRecording: true,
            preserveRecording: { log.record("preserve") },
            markRecordingStopped: { log.record("markStopped") }
        )
        assertNotNil(teardown, "an uncontested teardown keeps its graph")
        let order = log.events.filter { !$0.hasPrefix("makeEngine") }
        assertEqual(
            order,
            ["preserve", "removeTap:e1@q1", "markStopped", "stop:e1@q1"],
            "speech is preserved before the tap comes off, and recording stops before the engine does"
        )
        assertFalse(graph.isPrewarmed, "teardown clears prewarm")

        log.clear()
        graph.inputTapInstalled = true
        let held = log.hold("removeTap")
        let lost = await startHeld(held) {
            await graph.stopForRecovery(
                isRecording: true,
                preserveRecording: { log.record("preserve") },
                markRecordingStopped: { log.record("markStopped") }
            )
        }
        graph.generation += 1
        graph.isPrewarmed = true
        held.release.signal()
        assertNil(await lost.value, "a teardown that lost the graph says so")
        assertFalse(log.contains("markStopped"), "it doesn't mark the newer recording stopped")
        assertFalse(log.events.contains { $0.hasPrefix("stop:") }, "it doesn't stop the newer graph")
        assertTrue(graph.isPrewarmed, "it leaves the newer prewarm state alone")
    }
}

// MARK: - Replacement

@MainActor
private func runGraphReplacementSuites() async {
    await runSuite("A rebuild that finishes after a newer owner took the graph leaves that graph alone") {
        let fixture = GraphFixture()
        let graph = fixture.graph
        let log = fixture.log

        let held = log.hold("reset")
        let rebuild = await startHeld(held) { await graph.rebuild(reason: "test_rebuild") }
        graph.abandonBlocked(reason: "test_successor")
        let successorEngine = graph.engine.id
        held.release.signal()
        assertNil(await rebuild.value, "the late rebuild reports that it lost the graph")
        assertEqual(graph.engine.id, successorEngine, "the late rebuild doesn't replace the successor's engine")
        assertFalse(log.contains("retire:e\(successorEngine):test_rebuild"), "the successor's engine is never retired by the late rebuild")
    }

    await runSuite("A rebuild replaces the engine only when the old one can be retired") {
        let fixture = GraphFixture()
        let graph = fixture.graph
        let log = fixture.log
        let host = fixture.host

        let owner = await graph.rebuild(reason: "test_rebuild")
        assertEqual(graph.engine.id, 2, "a retired engine is replaced")
        assertEqual(owner, graph.graphOwner, "the rebuild returns the new owner")
        assertTrue(log.contains("retire:e1:test_rebuild"), "the old engine goes to delayed retirement")
        if let unobserve = log.index(of: "unobserve"),
           let work = log.index(of: "removeTap:e1@q1"),
           let observe = log.index(of: "observe:e2") {
            assertTrue(unobserve < work && work < observe, "the old engine's observer is removed first and the new engine is observed after")
        } else {
            assertTrue(false, "the rebuild should move the config observer to the new engine, got \(log.events)")
        }
        assertFalse(log.contains("observe:e1"), "the retired engine is never observed again")
        assertEqual(host.reported, [.rebuilt(reason: "test_rebuild")], "the rebuild is reported")

        log.clear()
        host.reported = []
        log.setResult("retire", false)
        let inPlaceOwner = await graph.rebuild(reason: "test_full")
        assertEqual(graph.engine.id, 2, "with the retirement store full the engine is reset in place")
        assertEqual(inPlaceOwner, graph.graphOwner, "an in-place reset still hands back the graph")
        assertEqual(
            host.reported,
            [.retirementLimitReached(reason: "test_full"), .resetInPlaceAtRetirementLimit],
            "the limit is reported once, then the in-place reset"
        )

        log.clear()
        host.reported = []
        let freshOwner = await graph.rebuild(reason: "test_fresh", requiresFreshGraph: true)
        assertNil(freshOwner, "a caller that needs a fresh graph fails closed at the retirement limit")
        assertTrue(log.contains("interrupt"), "failing closed interrupts the recording and keeps its audio")
        assertEqual(host.reported, [], "the limit is not reported twice in a row")

        log.setResult("retire", true)
        log.setResult("removeTap", false)
        log.clear()
        let vpioOwner = await graph.rebuild(reason: "test_vpio")
        assertEqual(vpioOwner, graph.graphOwner, "a rebuild whose voice processing stayed on hands back a fresh graph")
        assertFalse(log.events.contains { $0.hasPrefix("retire:") }, "that graph is dropped, not retained")
    }

    await runSuite("An abandoned graph is cleaned up on its old queue, behind work still running there") {
        let fixture = GraphFixture()
        let graph = fixture.graph
        let log = fixture.log
        log.setResult("usesVoiceProcessing", true)
        let oldQueue = graph.queue

        let held = log.hold("usesVoiceProcessing")
        let probe = await startHeld(held) {
            await graph.callAppMayDowngradeVoiceProcessing(isAllowed: { true })
        }
        assertTrue(graph.abandonBlocked(reason: "test_blocked"), "a blocked graph is abandoned")
        assertEqual(graph.engine.id, 2, "the engine is replaced")
        assertEqual(fixture.queueID, 2, "the queue is replaced too")
        assertFalse(log.contains("removeTap:e1@q1"), "cleanup waits behind the work still running on the old queue")

        held.release.signal()
        assertFalse(await probe.value, "the probe that outlived its graph doesn't downgrade the successor")
        await drain(oldQueue)
        if let removed = log.index(of: "removeTap:e1@q1"), let reset = log.index(of: "reset:e1@q1") {
            assertTrue(removed < reset, "the abandoned engine's tap comes off before it is reset")
        } else {
            assertTrue(false, "the abandoned engine should be cleaned up on its own queue, got \(log.events)")
        }

        let refused = graph.abandonBlocked(reason: "test_stale", expectedOwner: ParakeetAudioEngineQueueOwnerToken(
            generation: graph.generation - 1,
            engine: graph.engine,
            queue: graph.queue
        ))
        assertFalse(refused, "only the expected owner may abandon a graph")
        assertEqual(graph.engine.id, 2, "a refused abandon keeps the engine")
    }

    await runSuite("A confirmed zombie graph is reset under its own lease, then replaced, never reused") {
        let fixture = GraphFixture()
        let graph = fixture.graph
        let log = fixture.log
        let host = fixture.host

        let held = log.hold("reset")
        let replacement = await startHeld(held) {
            await graph.replaceZombieGraph(timeoutNanoseconds: 30_000_000_000) { graph.owns($0) }
        }
        let resetLease = graph.queueOwner
        assertTrue(
            graph.workOwnership.isActive(owner: resetLease, phase: .zombieReset),
            "the reset publishes its lease before it can block"
        )
        held.release.signal()
        assertTrue(await replacement.value, "a reset zombie is replaced")
        assertFalse(graph.workOwnership.isActive(owner: resetLease, phase: .zombieReset), "the reset finishes its exact lease")
        assertEqual(graph.engine.id, 2, "the zombie engine is never reused")
        assertTrue(log.contains("retire:e1:zombie_engine_recovery"), "the zombie engine is retired")
        assertTrue(log.contains("observe:e2"), "the replacement is observed")
        assertEqual(host.reported, [.zombieReplaced], "the replacement is reported")

        log.clear()
        host.reported = []
        log.setResult("retire", false)
        assertFalse(
            await graph.replaceZombieGraph(timeoutNanoseconds: 30_000_000_000) { graph.owns($0) },
            "at the retirement limit the recovery fails instead of keeping the zombie"
        )
        assertTrue(log.contains("interrupt"), "the session hears about it right away")
        assertEqual(
            host.reported,
            [.retirementLimitReached(reason: "zombie_engine_recovery"), .zombieReplacementRefused],
            "the refusal is reported"
        )
    }

    await runSuite("A zombie reset that times out abandons the graph only while recovery still owns it") {
        let fixture = GraphFixture()
        let graph = fixture.graph
        let log = fixture.log
        let stuckQueue = graph.queue

        let held = log.hold("reset")
        let replaced = await graph.replaceZombieGraph(timeoutNanoseconds: 1_000_000) { graph.owns($0) }
        assertTrue(replaced, "a reset stuck in CoreAudio is abandoned")
        assertEqual(graph.engine.id, 2, "the stuck engine is replaced")
        assertEqual(fixture.queueID, 2, "the stuck queue is replaced")
        assertTrue(log.contains("churn:zombie_engine_reset_timeout"), "the abandonment names the timeout")
        held.release.signal()
        await drain(stuckQueue)

        let cancelled = GraphFixture()
        let cancelledHeld = cancelled.log.hold("reset")
        let refused = await cancelled.graph.replaceZombieGraph(timeoutNanoseconds: 1_000_000) { _ in false }
        assertFalse(refused, "a recovery that was cancelled meanwhile abandons nothing")
        assertEqual(cancelled.graph.engine.id, 1, "the graph stays")
        cancelledHeld.release.signal()
        await drain(cancelled.graph.queue)
    }

    await runSuite("A zombie reset refused by a full work circuit keeps the current graph") {
        let limiter = ParakeetTimedAudioEngineWorkLimiter(maximumActiveWorkers: 1)
        let fixture = GraphFixture(workLimiter: limiter)
        let graph = fixture.graph
        let heldSlot = limiter.acquire()
        let replaced = await graph.replaceZombieGraph(timeoutNanoseconds: 30_000_000_000) { graph.owns($0) }
        assertFalse(replaced, "with every worker slot held the reset never runs")
        assertEqual(graph.engine.id, 1, "the graph is not abandoned, since no work entered it")
        assertFalse(
            fixture.log.events.contains { $0.hasPrefix("reset:") || $0.hasPrefix("retire:") },
            "nothing touched or retired the graph"
        )
        assertFalse(graph.workOwnership.isActive(owner: graph.queueOwner, phase: .zombieReset), "the refused reset leaves no lease")
        heldSlot?.release()
    }
}

// MARK: - Cancellation

@MainActor
private func runGraphCancellationSuites() async {
    runSuite("Cancelling recovery replaces a graph still holding blocked work, in one step") {
        let fixture = GraphFixture()
        let graph = fixture.graph
        let log = fixture.log

        assertFalse(graph.replaceGraphHoldingPendingWork(), "with no pending work nothing is replaced")
        assertEqual(graph.engine.id, 1, "the graph stays")

        graph.workOwnership.begin(owner: graph.queueOwner, phase: .zombieReset)
        assertTrue(graph.replaceGraphHoldingPendingWork(), "a pending zombie reset is claimed")
        assertEqual(graph.engine.id, 2, "its engine is replaced")
        assertEqual(fixture.queueID, 2, "its queue is replaced")
        assertTrue(log.contains("churn:zombie_engine_reset_cancelled"), "the replacement names the cancelled reset")

        let startOwner = graph.queueOwner
        assertTrue(graph.startAdmission.begin(owner: startOwner), "a start is admitted")
        graph.workOwnership.begin(owner: startOwner, phase: .audioStart)
        assertTrue(graph.replaceGraphHoldingPendingWork(), "a pending start is claimed")
        assertFalse(graph.startAdmission.isInProgress, "the claimed start gives up its admission")
        assertEqual(graph.engine.id, 3, "the start's engine is replaced")

        graph.workOwnership.begin(owner: startOwner, phase: .deviceRecoverySnapshot)
        assertFalse(graph.replaceGraphHoldingPendingWork(), "work leased on an older graph is not claimed again")
        assertEqual(graph.engine.id, 3, "the current graph stays")
    }

    runSuite("A blocked start replaces its graph exactly once") {
        let claimed = GraphFixture()
        claimed.graph.workOwnership.begin(owner: claimed.graph.queueOwner, phase: .audioStart)
        let replacedByCancellation = claimed.graph.replaceGraphHoldingPendingWork()
        claimed.graph.abandonBlockedStart(reason: "test_blocked_start", replacedByCancellation: replacedByCancellation)
        assertEqual(
            claimed.log.events.filter { $0.hasPrefix("retire:") }.count,
            1,
            "a start whose lease was claimed during cancellation isn't replaced again"
        )

        let unclaimed = GraphFixture()
        let replaced = unclaimed.graph.replaceGraphHoldingPendingWork()
        unclaimed.graph.abandonBlockedStart(reason: "test_blocked_start", replacedByCancellation: replaced)
        assertEqual(
            unclaimed.log.events.filter { $0.hasPrefix("retire:") },
            ["retire:e1:test_blocked_start"],
            "a start with no claimed lease is replaced by the timeout itself"
        )
    }

    await runSuite("A call app may downgrade only an owned graph that runs voice processing") {
        let fixture = GraphFixture()
        let graph = fixture.graph
        let log = fixture.log

        var checks = 0
        assertFalse(
            await graph.callAppMayDowngradeVoiceProcessing(isAllowed: { checks += 1; return true }),
            "a graph without voice processing isn't downgraded"
        )
        log.setResult("usesVoiceProcessing", true)
        checks = 0
        assertTrue(
            await graph.callAppMayDowngradeVoiceProcessing(isAllowed: { checks += 1; return true }),
            "an owned voice-processing graph may be downgraded"
        )
        assertEqual(checks, 2, "the gate is checked before and after the graph-queue read")
        assertTrue(log.contains("usesVoiceProcessing:e1@q1"), "voice processing is read on the graph queue")

        log.clear()
        assertFalse(
            await graph.callAppMayDowngradeVoiceProcessing(isAllowed: { false }),
            "a closed gate skips the probe"
        )
        assertTrue(log.events.isEmpty, "a closed gate makes no driver call")

        var allowed = true
        let held = log.hold("usesVoiceProcessing")
        let probe = await startHeld(held) {
            await graph.callAppMayDowngradeVoiceProcessing(isAllowed: { allowed })
        }
        allowed = false // the recording ended while the probe was on the queue
        held.release.signal()
        assertFalse(await probe.value, "a gate that closed during the probe stops the downgrade")
    }
}

// MARK: - Stop

@MainActor
private final class FakeStopHost: ParakeetStopRecordingHost {
    let log: GraphTestLog
    let graph: TestGraph
    var hasSharedMeetingMicClaim = false
    var isSharedMeetingMicResumeInProgress = false
    var activeConfigRecoveryGeneration: UInt64?
    var isRecording = false
    var idleAction: ParakeetIdleStopAction = .settleIdleGraph
    var hasPinnedDictationRecording = false

    init(fixture: GraphFixture) {
        log = fixture.log
        graph = fixture.graph
    }

    func invalidateSharedMeetingMicTransition() { log.record("invalidateSharedMic") }
    func finishSharedMeetingMicStop() { log.record("finishSharedMic") }

    func cancelAudioWatchdog() -> Bool {
        log.record("cancelWatchdog@gen\(graph.generation)")
        return false
    }

    func cancelConfigRecoveryIfCurrent(generation: UInt64) {
        log.record("cancelConfigRecovery:\(generation)")
    }

    func idleStopAction() -> ParakeetIdleStopAction { idleAction }
    func cancelPendingRecordingRecovery() { log.record("cancelPendingRecovery") }
    func clearRecoveredRecordingTimeline(keepingCapacity: Bool) { log.record("clearTimeline") }
    func stopPinnedDictationRecording() async { log.record("stopPinned") }

    func finishStoppedRecording() {
        log.record("finishRecording")
        isRecording = false
    }

    func reportRecordingStopped() { log.record("reportStopped") }
}

@MainActor
private func runStopSequenceSuites() async {
    await runSuite("A stop retires the graph and cancels zombie and route recovery before it suspends") {
        let fixture = GraphFixture()
        let graph = fixture.graph
        let log = fixture.log
        let host = FakeStopHost(fixture: fixture)
        host.isRecording = true
        host.activeConfigRecoveryGeneration = 7
        graph.inputTapInstalled = true
        let recordingOwner = graph.queueOwner

        let held = log.hold("removeTap")
        let stop = await startHeld(held) {
            await ParakeetStopRecordingSequence.run(graph: graph, host: host)
        }
        // The stop is parked inside its first CoreAudio call.
        assertEqual(
            log.events,
            ["cancelWatchdog@gen1", "cancelConfigRecovery:7", "removeTap:e1@q1"],
            "the watchdog and the stop's own route recovery are cancelled, after the graph owner moved, before the first suspension"
        )
        assertFalse(graph.owns(recordingOwner), "the stopped session's graph owner is retired before the stop suspends")
        held.release.signal()
        await stop.value
        assertTrue(log.contains("finishRecording"), "the stop settles the take")
        assertTrue(log.contains("reportStopped"), "the stop reports it")

        log.clear()
        host.activeConfigRecoveryGeneration = 9
        await ParakeetStopRecordingSequence.run(graph: graph, host: host)
        assertEqual(
            log.events,
            ["cancelWatchdog@gen2", "cancelConfigRecovery:9", "clearTimeline"],
            "an idle stop shares the same cancellation and touches no audio hardware"
        )

        log.clear()
        host.activeConfigRecoveryGeneration = nil
        await ParakeetStopRecordingSequence.run(graph: graph, host: host)
        assertFalse(
            log.events.contains { $0.hasPrefix("cancelConfigRecovery") },
            "with no route recovery in flight there is nothing to cancel"
        )
    }

    await runSuite("An idle stop during an in-flight start cancels the start and keeps the timeline") {
        let fixture = GraphFixture()
        let graph = fixture.graph
        let log = fixture.log
        let host = FakeStopHost(fixture: fixture)

        assertTrue(graph.startAdmission.begin(owner: graph.queueOwner), "a start is in flight")
        await ParakeetStopRecordingSequence.run(graph: graph, host: host)
        assertFalse(graph.startAdmission.isInProgress, "the stop cancels the in-flight start's admission")
        assertFalse(log.contains("clearTimeline"), "the in-flight start keeps its timeline")
    }

    await runSuite("A stop with held speech drains it; a stop during a zombie retry releases the idle graph") {
        let fixture = GraphFixture()
        let graph = fixture.graph
        let log = fixture.log
        let host = FakeStopHost(fixture: fixture)

        host.idleAction = .drainRecoveredAudio
        await ParakeetStopRecordingSequence.run(graph: graph, host: host)
        assertTrue(log.contains("cancelPendingRecovery"), "held speech is kept and the pending restart cancelled")
        assertFalse(log.events.contains { $0.contains("@q") }, "draining held speech touches no audio hardware")

        log.clear()
        host.idleAction = .cancelPendingZombieRestart
        assertTrue(graph.startAdmission.begin(owner: graph.queueOwner), "the zombie retry holds a start admission")
        await ParakeetStopRecordingSequence.run(graph: graph, host: host)
        assertFalse(graph.startAdmission.isInProgress, "the pending zombie restart is cancelled")
        assertTrue(log.contains("clearTimeline"), "nothing preserved is kept")
        assertTrue(
            log.events.contains { $0.hasPrefix("removeTap:") } && log.events.contains { $0.hasPrefix("stop:") },
            "the idle graph's hardware is released"
        )
    }

    await runSuite("A stop that borrows the meeting mic or records pinned never touches the engine graph") {
        let fixture = GraphFixture()
        let graph = fixture.graph
        let log = fixture.log
        let host = FakeStopHost(fixture: fixture)
        let generation = graph.generation

        host.hasSharedMeetingMicClaim = true
        await ParakeetStopRecordingSequence.run(graph: graph, host: host)
        assertEqual(log.events, ["invalidateSharedMic", "finishSharedMic"], "a borrowed-mic stop only ends the borrow")
        assertEqual(graph.generation, generation, "the dormant engine graph keeps its owner")

        log.clear()
        host.hasSharedMeetingMicClaim = false
        host.isRecording = true
        host.hasPinnedDictationRecording = true
        await ParakeetStopRecordingSequence.run(graph: graph, host: host)
        assertTrue(log.contains("stopPinned"), "a pinned recording stops through its recorder")
        assertFalse(log.events.contains { $0.contains("@q") }, "a pinned stop touches no engine hardware")
    }
}

// MARK: - Route change

@MainActor
private final class FakeRouteChangeHost: ParakeetConfigChangeRecoveryHost {
    let log: GraphTestLog
    let graph: TestGraph
    var admitsConfigChangeRecovery = true
    var isRecording = false
    var nextGeneration: UInt64 = 40

    init(fixture: GraphFixture) {
        log = fixture.log
        graph = fixture.graph
    }

    func beginConfigChangeRecovery() -> UInt64 {
        nextGeneration += 1
        log.record("beginRecovery:\(nextGeneration)@gen\(graph.generation)")
        return nextGeneration
    }

    func cancelAudioWatchdog() -> Bool {
        log.record("cancelWatchdog")
        return false
    }

    func cancelPrewarmRetry() { log.record("cancelPrewarm") }
    func preserveCurrentRecordingBuffersForRecovery() { log.record("preserve") }

    func markRecordingStoppedForRecovery() {
        log.record("markStopped")
        isRecording = false
    }

    func cancelConfigRecoveryIfCurrent(generation: UInt64) {
        log.record("cancelRecovery:\(generation)")
    }

    func reportGraphReusedAfterConfigChange() { log.record("reuse") }
}

@MainActor
private func runConfigChangeTeardownSuites() async {
    await runSuite("A route change can't take the graph while a stop is in flight") {
        let fixture = GraphFixture()
        let host = FakeRouteChangeHost(fixture: fixture)
        host.admitsConfigChangeRecovery = false
        host.isRecording = true
        let owner = fixture.graph.queueOwner

        let generation = await ParakeetConfigChangeTeardown.run(
            graph: fixture.graph,
            host: host,
            strategy: .rebuildGraph,
            forceForMicrophoneSharing: false
        )
        assertNil(generation, "the change is not admitted")
        assertTrue(fixture.graph.owns(owner), "the stop keeps its graph owner")
        assertTrue(fixture.log.events.isEmpty, "no recovery starts and nothing is torn down, so the stopped take can't be restarted")
    }

    await runSuite("A route change retires the graph before suspending and keeps the speech already heard") {
        let fixture = GraphFixture()
        let log = fixture.log
        let host = FakeRouteChangeHost(fixture: fixture)
        host.isRecording = true
        fixture.graph.inputTapInstalled = true

        let held = log.hold("removeTap")
        let change = await startHeld(held) {
            await ParakeetConfigChangeTeardown.run(
                graph: fixture.graph,
                host: host,
                strategy: .reuseCurrentGraph,
                forceForMicrophoneSharing: false
            )
        }
        assertEqual(
            log.events,
            ["beginRecovery:41@gen1", "cancelWatchdog", "cancelPrewarm", "preserve", "removeTap:e1@q1"],
            "the owner moves, recovery starts and zombie recovery is cancelled before the first suspension; speech is kept before the tap comes off"
        )
        held.release.signal()
        assertEqual(await change.value, 41, "the change hands its recovery generation to the debounced recovery")
        assertTrue(log.contains("markStopped"), "the recording is marked stopped")
        assertTrue(log.contains("reuse"), "a stable route reuses the stopped graph")
    }

    await runSuite("A route change that loses the graph cancels only its own recovery") {
        // Lost during tap removal.
        let duringTap = GraphFixture()
        let tapHost = FakeRouteChangeHost(fixture: duringTap)
        tapHost.isRecording = true
        duringTap.graph.inputTapInstalled = true
        let heldTap = duringTap.log.hold("removeTap")
        let tapChange = await startHeld(heldTap) {
            await ParakeetConfigChangeTeardown.run(graph: duringTap.graph, host: tapHost, strategy: .rebuildGraph, forceForMicrophoneSharing: false)
        }
        duringTap.graph.generation += 1
        heldTap.release.signal()
        assertNil(await tapChange.value, "losing the graph during tap removal ends the change")
        assertTrue(duringTap.log.contains("cancelRecovery:41"), "it cancels its own recovery generation")
        assertFalse(duringTap.log.contains("markStopped"), "it leaves the newer recording alone")
        assertFalse(duringTap.log.events.contains { $0.hasPrefix("stop:") }, "it doesn't stop the newer graph")

        // Lost while stopping the engine.
        let duringStop = GraphFixture()
        let stopHost = FakeRouteChangeHost(fixture: duringStop)
        let heldStop = duringStop.log.hold("stop")
        let stopChange = await startHeld(heldStop) {
            await ParakeetConfigChangeTeardown.run(graph: duringStop.graph, host: stopHost, strategy: .rebuildGraph, forceForMicrophoneSharing: false)
        }
        duringStop.graph.generation += 1
        heldStop.release.signal()
        assertNil(await stopChange.value, "losing the graph during the engine stop ends the change")
        assertTrue(duringStop.log.contains("cancelRecovery:41"), "it cancels its own recovery generation")
        assertFalse(duringStop.log.contains("makeEngine:e2"), "it doesn't rebuild the newer graph")

        // Lost while rebuilding.
        let duringRebuild = GraphFixture()
        let rebuildHost = FakeRouteChangeHost(fixture: duringRebuild)
        let heldReset = duringRebuild.log.hold("reset")
        let rebuildChange = await startHeld(heldReset) {
            await ParakeetConfigChangeTeardown.run(graph: duringRebuild.graph, host: rebuildHost, strategy: .rebuildGraph, forceForMicrophoneSharing: false)
        }
        duringRebuild.graph.generation += 1
        heldReset.release.signal()
        assertNil(await rebuildChange.value, "a rebuild that lost the graph ends the change")
        assertTrue(duringRebuild.log.contains("cancelRecovery:41"), "it cancels its own recovery generation")

        // A fresh graph was needed and the retirement store is full.
        let atLimit = GraphFixture()
        let limitHost = FakeRouteChangeHost(fixture: atLimit)
        atLimit.log.setResult("retire", false)
        assertNil(
            await ParakeetConfigChangeTeardown.run(graph: atLimit.graph, host: limitHost, strategy: .rebuildGraph, forceForMicrophoneSharing: true),
            "a call-app downgrade that can't get a fresh graph ends the change"
        )
        assertTrue(atLimit.log.contains("cancelRecovery:41"), "it cancels its own recovery generation")

        // Uncontested: the change keeps its recovery.
        let clean = GraphFixture()
        let cleanHost = FakeRouteChangeHost(fixture: clean)
        assertEqual(
            await ParakeetConfigChangeTeardown.run(graph: clean.graph, host: cleanHost, strategy: .rebuildGraph, forceForMicrophoneSharing: false),
            41,
            "an uncontested rebuild hands its recovery on"
        )
        assertFalse(clean.log.events.contains { $0.hasPrefix("cancelRecovery") }, "nothing is cancelled")
        assertEqual(clean.graph.engine.id, 2, "the graph was rebuilt")
    }
}

// MARK: - Route restart

@MainActor
private func runRouteRestartSuites() async {
    await runSuite("Route recovery restarts the take through the start path and retries inside its budget") {
        var now: TimeInterval = 100
        var starts = 0
        var sleeps: [UInt64] = []
        let restarted = await ParakeetRouteRecoveryRestart.run(
            startedAtUptime: now,
            nowUptime: { now },
            isCurrent: { true },
            startRecording: {
                starts += 1
                return starts == 2
            },
            shouldRetry: { true },
            sleep: { delay in
                sleeps.append(delay)
                now += Double(delay) / 1_000_000_000
            }
        )
        assertEqual(restarted, .restarted(attempt: 2), "a failure that can clear gets another attempt")
        assertEqual(sleeps, [TranscriptedConstants.recordingRestartRetryDelay], "attempts are spaced by the retry delay")

        starts = 0
        let terminal = await ParakeetRouteRecoveryRestart.run(
            startedAtUptime: now,
            nowUptime: { now },
            isCurrent: { true },
            startRecording: {
                starts += 1
                return false
            },
            shouldRetry: { false },
            sleep: { _ in }
        )
        assertEqual(terminal, .exhausted, "a failure that can't clear ends the restart")
        assertEqual(starts, 1, "a terminal failure isn't retried")

        starts = 0
        var current = true
        let superseded = await ParakeetRouteRecoveryRestart.run(
            startedAtUptime: now,
            nowUptime: { now },
            isCurrent: { current },
            startRecording: {
                starts += 1
                current = false // a newer route change landed while starting
                return true
            },
            shouldRetry: { true },
            sleep: { _ in }
        )
        assertEqual(superseded, .superseded, "a newer route change owns what comes next")
        assertEqual(starts, 1, "a superseded restart doesn't start again")

        starts = 0
        let outOfTime = await ParakeetRouteRecoveryRestart.run(
            startedAtUptime: now,
            nowUptime: { now },
            isCurrent: { true },
            startRecording: {
                starts += 1
                now += 1 // a slow start eats into the window
                return false
            },
            shouldRetry: { true },
            sleep: { delay in now += Double(delay) / 1_000_000_000 }
        )
        assertEqual(outOfTime, .exhausted, "the restart gives up when its window closes")
        assertTrue(
            starts < TranscriptedConstants.recordingRestartAttempts,
            "the admission window, not just the attempt count, bounds the restart"
        )
    }
}

// MARK: - Snapshots

@MainActor
private func runSnapshotSuites() async {
    await runSuite("A route-recovery snapshot holds one lease a stop can claim") {
        let ownership = ParakeetTimedAudioEngineWorkOwnership()
        let engine = NSObject()
        let queue = NSObject()
        let owner = ParakeetAudioEngineQueueOwnerToken(generation: 1, engine: engine, queue: queue)

        let value = try? await ownership.runLeased(owner: owner, phase: .deviceRecoverySnapshot) { isCurrent in
            assertTrue(isCurrent(), "queued snapshot work sees its lease")
            assertTrue(ownership.isActive(owner: owner, phase: .deviceRecoverySnapshot), "the lease is published while the snapshot runs")
            return 7
        }
        assertEqual(value, 7, "an unclaimed snapshot returns its result")
        assertFalse(ownership.isActive(owner: owner, phase: .deviceRecoverySnapshot), "the lease is finished")

        var claimedResult: Int?
        var claimedError: Error?
        do {
            claimedResult = try await ownership.runLeased(owner: owner, phase: .deviceRecoverySnapshot) { isCurrent in
                _ = ownership.claimPendingWorkForSuccessor(currentEngine: engine, currentQueue: queue)
                assertFalse(isCurrent(), "graph work queued after the claim sees it")
                return 8
            }
        } catch {
            claimedError = error
        }
        assertNil(claimedResult, "a snapshot that returns after a stop claimed it is not used")
        assertTrue(claimedError is CancellationError, "it comes back as a cancellation")

        struct SnapshotFailed: Error {}
        var failure: Error?
        do {
            _ = try await ownership.runLeased(owner: owner, phase: .deviceRecoverySnapshot) { _ -> Int in
                throw SnapshotFailed()
            }
        } catch {
            failure = error
        }
        assertTrue(failure is SnapshotFailed, "a failed snapshot keeps its own error")
        assertFalse(ownership.isActive(owner: owner, phase: .deviceRecoverySnapshot), "a failed snapshot still finishes its lease")
    }

    await runSuite("Snapshot admission fails closed and arms the ignore window before any graph read") {
        let builtIn = DictationAudioDevice(id: 1, name: "Built-in", transport: .builtIn, inputChannelCount: 1)
        let airPods = DictationAudioDevice(id: 2, name: "AirPods", transport: .bluetooth, inputChannelCount: 1)
        let followsDefault = DictationInputDeviceSelection(defaultInput: builtIn, selectedInput: builtIn, defaultOutput: nil, reason: .defaultIsSafe)
        let overridesDefault = DictationInputDeviceSelection(defaultInput: airPods, selectedInput: builtIn, defaultOutput: airPods, reason: .defaultIsSafe)

        var events: [String] = []
        func admit(
            _ loaded: DictationInputDeviceSelection?,
            ownsAfterLoad: Bool = true,
            needsWindow: Bool = false,
            stale: Bool = false
        ) async -> Result<DictationInputDeviceSelection, Error> {
            events = []
            var owns = true
            do {
                let selection = try await ParakeetAudioInputSelectionAdmission.admit(
                    loadSelection: {
                        events.append("load")
                        owns = ownsAfterLoad
                        return loaded
                    },
                    ownsGraph: { owns },
                    needsIgnoreWindow: { $0.didOverrideDefault || needsWindow },
                    armIgnoreWindow: { events.append("arm") },
                    isRecoveryStale: { stale }
                )
                return .success(selection)
            } catch {
                return .failure(error)
            }
        }

        if case .failure(let error) = await admit(nil) {
            assertEqual(error as? DictationInputDeviceBindingError, .selectionUnavailable, "a failed lookup fails closed")
        } else {
            assertTrue(false, "a failed lookup must not reach the graph")
        }
        assertEqual(events, ["load"], "a failed lookup arms nothing")

        if case .failure(let error) = await admit(overridesDefault, ownsAfterLoad: false) {
            assertTrue(error is CancellationError, "a graph replaced during the lookup cancels the snapshot")
        } else {
            assertTrue(false, "a replaced graph must not be read")
        }
        assertEqual(events, ["load"], "a replaced graph arms nothing")

        if case .success(let selection) = await admit(overridesDefault) {
            assertEqual(selection, overridesDefault, "the loaded selection comes back")
        } else {
            assertTrue(false, "an owned override should be admitted")
        }
        assertEqual(events, ["load", "arm"], "an override arms the ignore window before the graph read")

        if case .failure(let error) = await admit(overridesDefault, stale: true) {
            assertTrue(error is CancellationError, "a superseded recovery cancels before reading the graph")
        } else {
            assertTrue(false, "a stale recovery must not read the graph")
        }

        if case .success = await admit(followsDefault) {
            assertEqual(events, ["load"], "following an unchanged default input arms nothing")
        } else {
            assertTrue(false, "a plain default selection should be admitted")
        }
        if case .success = await admit(followsDefault, needsWindow: true) {
            assertEqual(events, ["load", "arm"], "a changed selection arms the window too")
        } else {
            assertTrue(false, "a changed selection should be admitted")
        }
    }
}
