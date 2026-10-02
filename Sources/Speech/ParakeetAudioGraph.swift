// ParakeetAudioGraph.swift
// The dictation audio graph ParakeetEngine records through: the current
// AVAudioEngine, its serial worker queue, the generation that names the
// current owner, and every operation that tears that graph down or replaces
// it. Each one captures an owner before it suspends and checks it again
// after, so a late completion only ever touches the graph it started on.
//
// The native calls go through `ParakeetAudioGraphDriver`. Production uses
// `ParakeetAVAudioEngineGraphDriver` (ParakeetAudioEngineSupport.swift); the
// fast tests use a recording fake. Side effects that belong to the engine
// (config observers, sample flags, interruption, events) go through
// `ParakeetAudioGraphHost`, which ParakeetEngine implements.
//
// AirPods: nothing in this file touches an input node. The driver's teardown
// calls only look at nodes a graph already has, and `makeEngine()` only
// builds an engine, so no path here binds the macOS default input (which is
// what flips a default Bluetooth headset into call mode).

import Foundation

/// The native `AVAudioEngine` calls the graph makes. Every method except
/// `makeEngine`, `makeQueue` and `retire` runs on the graph's serial queue.
protocol ParakeetAudioGraphDriver: Sendable {
    associatedtype Engine: AnyObject

    func makeEngine() -> Engine
    func makeQueue() -> DispatchQueue
    /// Stops a running graph, lets input callbacks drain, removes the input
    /// tap, then releases stopped voice processing. Never creates an input
    /// node. False when voice processing stayed on.
    func removeInputTap(on engine: Engine) -> Bool
    /// Stops the graph if it runs, then releases stopped voice processing.
    /// False when voice processing stayed on.
    func stop(_ engine: Engine) -> Bool
    func reset(_ engine: Engine)
    /// Whether an input node the graph already has runs voice processing.
    /// Never creates one.
    func usesVoiceProcessing(_ engine: Engine) -> Bool
    /// Hands a replaced engine to delayed release. False when the bounded
    /// retirement store is full.
    func retire(_ engine: Engine, reason: String) -> Bool
}

extension ParakeetAudioGraphDriver {
    /// Cleanup for a start that was cancelled or came back too late.
    func cleanUpLateStart(_ engine: Engine) {
        _ = removeInputTap(on: engine)
        reset(engine)
    }
}

/// What the graph reports back; ParakeetEngine turns each into its log line
/// or diagnostic event.
enum ParakeetAudioGraphEvent: Equatable {
    /// A graph was reset and replaced (`audio_engine_rebuilt`).
    case rebuilt(reason: String)
    /// A blocked graph and its queue were abandoned and replaced.
    case abandoned(reason: String)
    /// A watchdog-confirmed zombie graph was replaced.
    case zombieReplaced
    /// The retirement store was full, so the graph was reset in place.
    case resetInPlaceAtRetirementLimit
    /// The retirement store was full, so a zombie graph was not replaced.
    case zombieReplacementRefused
    /// First refusal at the retirement limit since the last success.
    case retirementLimitReached(reason: String)
}

/// The engine-side effects of graph replacement and teardown.
@MainActor
protocol ParakeetAudioGraphHost: AnyObject {
    var isShuttingDown: Bool { get }
    var isRecording: Bool { get }
    func installAudioEngineConfigObserverIfNeeded()
    func removeAudioEngineConfigObserver()
    func trackAudioEngineRebuildChurn(reason: String)
    /// Forget sample-flow evidence that belonged to the replaced graph.
    func clearGraphSampleFlags()
    func interruptRecordingPreservingRecoveredTimeline()
    func reportAudioGraphEvent(_ event: ParakeetAudioGraphEvent)
}

@MainActor
final class ParakeetAudioGraph<Driver: ParakeetAudioGraphDriver> {
    typealias GraphOwner = ParakeetAudioGraphOwnerToken
    typealias QueueOwner = ParakeetAudioEngineQueueOwnerToken

    /// What a recovery teardown left behind when it kept ownership.
    struct RecoveryTeardown: Equatable, Sendable {
        let owner: QueueOwner
        let releasedVoiceProcessing: Bool
    }

    let driver: Driver
    weak var host: (any ParakeetAudioGraphHost)?
    private let workLimiter: ParakeetTimedAudioEngineWorkLimiter
    private(set) var engine: Driver.Engine
    private(set) var queue: DispatchQueue
    var generation = 0
    var inputTapInstalled = false
    var isPrewarmed = false
    var startAdmission = ParakeetAudioStartAdmissionState()
    let workOwnership = ParakeetTimedAudioEngineWorkOwnership()
    private var didReportRetirementLimit = false

    init(driver: Driver, workLimiter: ParakeetTimedAudioEngineWorkLimiter) {
        self.driver = driver
        self.workLimiter = workLimiter
        engine = driver.makeEngine()
        queue = driver.makeQueue()
    }

    deinit {
        let engine = ParakeetGraphConfined(engine)
        let driver = driver
        queue.async {
            driver.cleanUpLateStart(engine.value)
        }
        _ = driver.retire(engine.value, reason: "deinit")
    }

    // MARK: - Ownership

    var graphOwner: GraphOwner {
        GraphOwner(generation: generation, engine: engine)
    }

    var queueOwner: QueueOwner {
        QueueOwner(generation: generation, engine: engine, queue: queue)
    }

    func owns(_ owner: GraphOwner) -> Bool {
        owner.matches(generation: generation, engine: engine)
    }

    func owns(_ owner: QueueOwner) -> Bool {
        owner.matches(generation: generation, engine: engine, queue: queue)
    }

    // MARK: - Work on the graph queue

    func run<T>(_ work: @escaping (Driver.Engine) -> T) async -> T {
        let queue = queue
        let job = ParakeetGraphConfined((engine, work))
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: job.value.1(job.value.0))
            }
        }
    }

    func runTimed<T>(
        operation: String,
        timeoutNanoseconds: UInt64,
        isWorkCurrent: (() -> Bool)? = nil,
        cleanupAfterCancellation: ((Driver.Engine) -> Void)? = nil,
        cleanupAfterLateCompletion: ((Driver.Engine) -> Void)? = nil,
        _ work: @escaping (Driver.Engine) throws -> T
    ) async throws -> T {
        try await workLimiter.run(
            on: queue,
            resource: engine,
            operation: operation,
            timeoutNanoseconds: timeoutNanoseconds,
            isWorkCurrent: isWorkCurrent,
            cleanupAfterCancellation: cleanupAfterCancellation,
            cleanupAfterLateCompletion: cleanupAfterLateCompletion,
            work
        )
    }

    // MARK: - Teardown

    func removeRecordingTap(force: Bool = false) async {
        guard force || inputTapInstalled else { return }
        let tapOwner = graphOwner
        let driver = driver
        await run { engine in
            // Stop + drain before removing the tap; removing it from a running
            // graph can crash the IO thread with `isSink || tap != nullptr`.
            _ = driver.removeInputTap(on: engine)
        }
        guard owns(tapOwner) else { return }
        inputTapInstalled = false
    }

    @discardableResult
    func stopEngine() async -> Bool {
        let driver = driver
        return await run { engine in
            driver.stop(engine)
        }
    }

    /// Stops the recording graph. `finishRecording` runs only while this stop
    /// still owns the graph, and before a graph that kept voice processing on
    /// is replaced. False when a newer owner took the graph mid-stop.
    @discardableResult
    func stopRecording(finishRecording: () -> Void) async -> Bool {
        let stopOwner = queueOwner
        await removeRecordingTap()
        var stillOwnsStopGraph = owns(stopOwner)
        var releasedVoiceProcessing = true
        if stillOwnsStopGraph {
            releasedVoiceProcessing = await stopEngine()
            stillOwnsStopGraph = owns(stopOwner)
        }
        guard stillOwnsStopGraph, owns(stopOwner) else { return false }
        isPrewarmed = false
        finishRecording()
        if !releasedVoiceProcessing {
            discardStoppedVoiceProcessingGraph(ownedBy: stopOwner)
        }
        return true
    }

    /// Stops this graph for wake or route recovery. A recording keeps what it
    /// heard: `preserveRecording` runs before the tap comes off. Nil when a
    /// newer owner replaced the graph while this waited; that owner's
    /// recording and prewarm state are left alone.
    func stopForRecovery(
        isRecording: Bool,
        preserveRecording: () -> Void,
        markRecordingStopped: () -> Void
    ) async -> RecoveryTeardown? {
        let cleanupOwner = queueOwner
        if isRecording {
            preserveRecording()
            await removeRecordingTap()
            guard owns(cleanupOwner) else { return nil }
            markRecordingStopped()
        }
        let releasedVoiceProcessing = await stopEngine()
        guard owns(cleanupOwner) else { return nil }
        isPrewarmed = false
        return RecoveryTeardown(owner: cleanupOwner, releasedVoiceProcessing: releasedVoiceProcessing)
    }

    /// Releases an idle graph's hardware. `expectedGeneration` drops a cleanup
    /// that a newer owner already superseded. Returns the cleaned owner, or
    /// the replacement owner when voice processing would not turn off.
    @discardableResult
    func releaseIdleHardware(
        removeTap: Bool,
        expectedGeneration: Int? = nil
    ) async -> QueueOwner? {
        if let expectedGeneration, expectedGeneration != generation {
            return nil
        }
        generation += 1
        let idleCleanupOwner = queueOwner
        if removeTap {
            await removeRecordingTap(force: true)
        }
        guard owns(idleCleanupOwner) else { return nil }
        let releasedVoiceProcessing = await stopEngine()
        guard owns(idleCleanupOwner) else { return nil }
        isPrewarmed = false
        if !releasedVoiceProcessing {
            return discardStoppedVoiceProcessingGraph(ownedBy: idleCleanupOwner)
        }
        return idleCleanupOwner
    }

    /// Called only after owned stop/drain work has completed and recording is
    /// idle. A graph that failed to release voice processing is unsafe to keep
    /// for another capture, so it is dropped now rather than retained for the
    /// normal route-churn delay.
    @discardableResult
    func discardStoppedVoiceProcessingGraph(ownedBy owner: QueueOwner) -> QueueOwner? {
        guard owns(owner), host?.isRecording != true else { return nil }
        host?.removeAudioEngineConfigObserver()
        let stoppedEngine = ParakeetGraphConfined(engine)
        let stoppedQueue = queue
        generation += 1
        engine = driver.makeEngine()
        // Let this synchronous owner handoff unwind before releasing our last
        // retained reference on the graph queue. Native disposal may block too.
        Task { @MainActor in
            stoppedQueue.async { withExtendedLifetime(stoppedEngine) {} }
        }
        inputTapInstalled = false
        isPrewarmed = false
        installConfigObserverUnlessShuttingDown()
        return queueOwner
    }

    // MARK: - Replacement

    /// Resets the graph after a start failed before it ever recorded. The
    /// reset holds the start's exact work lease so a user stop can claim and
    /// replace a reset that blocks inside CoreAudio.
    func resetAfterStartFailure(
        reason: String,
        rebuildEngine: Bool
    ) async -> GraphOwner? {
        let resetWorkOwner = queueOwner
        workOwnership.begin(owner: resetWorkOwner, phase: .audioStart)
        defer {
            workOwnership.finish(owner: resetWorkOwner, phase: .audioStart)
        }

        if rebuildEngine {
            return await rebuild(reason: reason)
        }
        generation += 1
        let resetOwner = graphOwner
        let driver = driver
        let releasedVoiceProcessing = await run { engine in
            let released = driver.removeInputTap(on: engine)
            driver.reset(engine)
            return released
        }
        guard owns(resetOwner) else { return nil }
        inputTapInstalled = false
        isPrewarmed = false
        if !releasedVoiceProcessing {
            return discardStoppedVoiceProcessingGraph(ownedBy: queueOwner)?.graphOwner
        }
        return resetOwner
    }

    /// Resets the graph and replaces its engine. With the retirement store
    /// full the engine is reset in place, unless the caller needs a fresh
    /// graph, which then fails closed and interrupts the recording.
    @discardableResult
    func rebuild(
        reason: String,
        requiresFreshGraph: Bool = false
    ) async -> GraphOwner? {
        host?.trackAudioEngineRebuildChurn(reason: reason)
        generation += 1
        let rebuildOwner = graphOwner
        host?.removeAudioEngineConfigObserver()
        defer {
            restoreConfigObserverIfCurrent(rebuildOwner)
        }
        let driver = driver
        let releasedVoiceProcessing = await run { engine in
            let released = driver.removeInputTap(on: engine)
            driver.reset(engine)
            return released
        }
        guard owns(rebuildOwner) else { return nil }
        if !releasedVoiceProcessing {
            return discardStoppedVoiceProcessingGraph(ownedBy: queueOwner)?.graphOwner
        }
        let retiredEngine = engine
        // A stale overlapping rebuild may have restored an observer for the
        // engine being retired. Clear it before binding the replacement.
        host?.removeAudioEngineConfigObserver()
        let didReserveRetiredEngine = reserveRetired(retiredEngine, reason: reason)
        if didReserveRetiredEngine {
            engine = driver.makeEngine()
        }
        inputTapInstalled = false
        isPrewarmed = false
        host?.clearGraphSampleFlags()
        installConfigObserverUnlessShuttingDown()
        guard didReserveRetiredEngine else {
            if requiresFreshGraph {
                host?.interruptRecordingPreservingRecoveredTimeline()
                return nil
            }
            host?.reportAudioGraphEvent(.resetInPlaceAtRetirementLimit)
            return graphOwner
        }
        host?.reportAudioGraphEvent(.rebuilt(reason: reason))
        return graphOwner
    }

    /// Gives up on a graph whose queue may be stuck inside CoreAudio: claims
    /// its pending timed work and replaces both the engine and the queue. The
    /// old engine is cleaned up on its old queue, behind whatever is still
    /// running there. Only `expectedOwner`, when given, may do this.
    @discardableResult
    func abandonBlocked(
        reason: String,
        expectedOwner: QueueOwner? = nil
    ) -> Bool {
        if let expectedOwner, !owns(expectedOwner) {
            return false
        }
        host?.trackAudioEngineRebuildChurn(reason: reason)
        _ = workOwnership.claimPendingWorkForSuccessor(
            currentEngine: engine,
            currentQueue: queue
        )
        generation += 1
        host?.removeAudioEngineConfigObserver()
        let retiredEngine = engine
        let retiredQueue = queue
        guard reserveRetired(retiredEngine, reason: reason) else {
            installConfigObserverUnlessShuttingDown()
            return false
        }
        engine = driver.makeEngine()
        queue = driver.makeQueue()
        let driver = driver
        let confinedEngine = ParakeetGraphConfined(retiredEngine)
        retiredQueue.async {
            driver.cleanUpLateStart(confinedEngine.value)
        }
        inputTapInstalled = false
        isPrewarmed = false
        host?.clearGraphSampleFlags()
        installConfigObserverUnlessShuttingDown()
        host?.reportAudioGraphEvent(.abandoned(reason: reason))
        return true
    }

    /// Claims timed work still pending on the current engine and queue and,
    /// if there is any, replaces both before anything can queue up behind it.
    /// Synchronous on purpose: claim and replacement happen in one MainActor
    /// turn, so a cancelled reset or start can't resume against a successor.
    @discardableResult
    func replaceGraphHoldingPendingWork() -> Bool {
        guard let blockedLease = workOwnership.claimPendingWorkForSuccessor(
            currentEngine: engine,
            currentQueue: queue
        ) else { return false }
        let reason: String
        switch blockedLease.phase {
        case .zombieReset:
            reason = "zombie_engine_reset_cancelled"
        case .audioStart:
            reason = "audio_engine_start_cancelled"
        case .deviceRecoverySnapshot:
            reason = "device_recovery_snapshot_cancelled"
        }
        if blockedLease.phase == .audioStart {
            startAdmission.finish(owner: blockedLease.owner)
        }
        return abandonBlocked(reason: reason)
    }

    /// A start that timed out inside CoreAudio replaces its graph exactly
    /// once. `replacedByCancellation` is what `replaceGraphHoldingPendingWork()`
    /// returned while the start was being cancelled.
    func abandonBlockedStart(reason: String, replacedByCancellation: Bool) {
        guard !replacedByCancellation else { return }
        abandonBlocked(reason: reason)
    }

    /// A watchdog-confirmed zombie graph is stale, so it is reset under a
    /// bounded lease and then replaced, never reused. A reset that times out
    /// abandons the graph and its queue instead. `canContinue` is the zombie
    /// recovery's own currency check against the owner it captured.
    func replaceZombieGraph(
        timeoutNanoseconds: UInt64,
        canContinue: (GraphOwner) -> Bool
    ) async -> Bool {
        host?.trackAudioEngineRebuildChurn(reason: "zombie_engine_recovery")
        generation += 1
        let resetOwner = graphOwner
        let resetQueueOwner = queueOwner
        host?.removeAudioEngineConfigObserver()
        defer {
            restoreConfigObserverIfCurrent(resetOwner)
        }
        let retiredEngine = engine
        workOwnership.begin(owner: resetQueueOwner, phase: .zombieReset)

        let driver = driver
        let workOwnership = workOwnership
        do {
            try await runTimed(
                operation: "zombie_engine_reset",
                timeoutNanoseconds: timeoutNanoseconds
            ) { engine in
                defer {
                    workOwnership.finish(owner: resetQueueOwner, phase: .zombieReset)
                }
                _ = driver.removeInputTap(on: engine)
                driver.reset(engine)
            }
        } catch {
            workOwnership.finish(owner: resetQueueOwner, phase: .zombieReset)
            guard let workError = error as? ParakeetAudioEngineWorkError else { return false }
            guard workError.requiresGraphAbandonment else {
                // No work entered this graph when the process-wide circuit was
                // already full. Keep the current graph and fail this recovery.
                return false
            }
            guard canContinue(resetOwner) else { return false }
            // Only the exact generation+engine owner may abandon a timed-out
            // queue; a newer graph may reuse the same engine instance.
            return abandonBlocked(
                reason: "zombie_engine_reset_timeout",
                expectedOwner: resetQueueOwner
            )
        }

        guard canContinue(resetOwner) else { return false }

        inputTapInstalled = false
        isPrewarmed = false
        host?.clearGraphSampleFlags()
        host?.removeAudioEngineConfigObserver()
        guard reserveRetired(retiredEngine, reason: "zombie_engine_recovery") else {
            // A confirmed zombie is never safe to reuse, even after reset. Fail
            // this attempt and tell the session now, so its listening UI can't
            // stay up while no samples arrive.
            host?.reportAudioGraphEvent(.zombieReplacementRefused)
            host?.interruptRecordingPreservingRecoveredTimeline()
            return false
        }
        engine = driver.makeEngine()
        installConfigObserverUnlessShuttingDown()
        host?.reportAudioGraphEvent(.zombieReplaced)
        return true
    }

    /// Whether a call app launch may downgrade this graph: `isAllowed` holds
    /// before and after a graph-queue read that finds voice processing on,
    /// and the graph wasn't replaced in between. Never creates an input node.
    func callAppMayDowngradeVoiceProcessing(isAllowed: () -> Bool) async -> Bool {
        guard isAllowed() else { return false }
        let owner = queueOwner
        let driver = driver
        let usesVoiceProcessing = await run { engine in
            driver.usesVoiceProcessing(engine)
        }
        // Checked again: the graph-queue hop can outlive the recording.
        return usesVoiceProcessing && owns(owner) && isAllowed()
    }

    // MARK: - Helpers

    func restoreConfigObserverIfCurrent(_ owner: GraphOwner) {
        guard owner.matchesEngine(engine), let host, !host.isShuttingDown else { return }
        host.installAudioEngineConfigObserverIfNeeded()
    }

    private func installConfigObserverUnlessShuttingDown() {
        guard let host, !host.isShuttingDown else { return }
        host.installAudioEngineConfigObserverIfNeeded()
    }

    private func reserveRetired(_ retiredEngine: Driver.Engine, reason: String) -> Bool {
        guard driver.retire(retiredEngine, reason: reason) else {
            guard !didReportRetirementLimit else { return false }
            didReportRetirementLimit = true
            host?.reportAudioGraphEvent(.retirementLimitReached(reason: reason))
            return false
        }
        didReportRetirementLimit = false
        return true
    }
}

/// An engine (or work on it) handed to its own serial graph queue. The queue
/// is the confinement, which the compiler can't see.
struct ParakeetGraphConfined<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
