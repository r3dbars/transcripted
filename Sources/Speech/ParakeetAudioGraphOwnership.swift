import CoreAudio
import Foundation

struct ParakeetAudioGraphOwnerToken: Equatable, Sendable {
    let generation: Int
    let engineIdentity: ObjectIdentifier

    init(generation: Int, engine: AnyObject) {
        self.generation = generation
        engineIdentity = ObjectIdentifier(engine)
    }

    func matches(generation: Int, engine: AnyObject) -> Bool {
        self.generation == generation && engineIdentity == ObjectIdentifier(engine)
    }

    func matchesEngine(_ engine: AnyObject) -> Bool {
        engineIdentity == ObjectIdentifier(engine)
    }
}

struct ParakeetAudioEngineQueueOwnerToken: Equatable, Sendable {
    let graphOwner: ParakeetAudioGraphOwnerToken
    let queueIdentity: ObjectIdentifier

    init(generation: Int, engine: AnyObject, queue: AnyObject) {
        graphOwner = ParakeetAudioGraphOwnerToken(generation: generation, engine: engine)
        queueIdentity = ObjectIdentifier(queue)
    }

    func matches(generation: Int, engine: AnyObject, queue: AnyObject) -> Bool {
        graphOwner.matches(generation: generation, engine: engine)
            && queueIdentity == ObjectIdentifier(queue)
    }

    func matchesResources(engine: AnyObject, queue: AnyObject) -> Bool {
        graphOwner.engineIdentity == ObjectIdentifier(engine)
            && queueIdentity == ObjectIdentifier(queue)
    }
}

/// Coalesces idle readiness probes on the same native graph/queue. A forced
/// graph replacement may proceed even if an old native stop never returns.
struct ParakeetPrewarmAdmissionState {
    private(set) var owner: ParakeetAudioEngineQueueOwnerToken?

    mutating func begin(owner: ParakeetAudioEngineQueueOwnerToken) -> Bool {
        guard self.owner?.graphOwner.engineIdentity != owner.graphOwner.engineIdentity
                || self.owner?.queueIdentity != owner.queueIdentity else { return false }
        self.owner = owner
        return true
    }

    mutating func transfer(from previous: ParakeetAudioEngineQueueOwnerToken, to next: ParakeetAudioEngineQueueOwnerToken) -> Bool {
        guard owner == previous else { return false }
        owner = next
        return true
    }

    mutating func finish(owner: ParakeetAudioEngineQueueOwnerToken) {
        if self.owner == owner { self.owner = nil }
    }
}

/// Owns the single admitted audio-start task. Finishing or cancelling an older
/// start cannot clear a successor that already owns a replacement graph.
struct ParakeetAudioStartAdmissionState: Equatable {
    private(set) var owner: ParakeetAudioEngineQueueOwnerToken?

    var isInProgress: Bool {
        owner != nil
    }

    mutating func begin(owner: ParakeetAudioEngineQueueOwnerToken) -> Bool {
        guard self.owner == nil else { return false }
        self.owner = owner
        return true
    }

    mutating func transfer(
        from previousOwner: ParakeetAudioEngineQueueOwnerToken,
        to nextOwner: ParakeetAudioEngineQueueOwnerToken
    ) -> Bool {
        guard owner == previousOwner else { return false }
        owner = nextOwner
        return true
    }

    @discardableResult
    mutating func finish(owner: ParakeetAudioEngineQueueOwnerToken) -> Bool {
        guard self.owner == owner else { return false }
        self.owner = nil
        return true
    }

    @discardableResult
    mutating func cancel() -> ParakeetAudioEngineQueueOwnerToken? {
        defer { owner = nil }
        return owner
    }
}

enum ParakeetTimedAudioEngineWorkPhase: String, Equatable, Sendable {
    case zombieReset
    case audioStart
    case deviceRecoverySnapshot
}

struct ParakeetTimedAudioEngineWorkLease: Equatable, Sendable {
    let owner: ParakeetAudioEngineQueueOwnerToken
    let phase: ParakeetTimedAudioEngineWorkPhase
}

/// Thread-safe ownership for one bounded audio-engine operation.
/// Completion clears only its exact lease; a newer MainActor owner can claim
/// still-pending work by engine+queue identity after advancing the generation.
final class ParakeetTimedAudioEngineWorkOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var pendingLease: ParakeetTimedAudioEngineWorkLease?

    func begin(
        owner: ParakeetAudioEngineQueueOwnerToken,
        phase: ParakeetTimedAudioEngineWorkPhase
    ) {
        lock.lock()
        pendingLease = ParakeetTimedAudioEngineWorkLease(owner: owner, phase: phase)
        lock.unlock()
    }

    @discardableResult
    func finish(
        owner: ParakeetAudioEngineQueueOwnerToken,
        phase: ParakeetTimedAudioEngineWorkPhase
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let lease = ParakeetTimedAudioEngineWorkLease(owner: owner, phase: phase)
        guard pendingLease == lease else { return false }
        pendingLease = nil
        return true
    }

    func isActive(
        owner: ParakeetAudioEngineQueueOwnerToken,
        phase: ParakeetTimedAudioEngineWorkPhase
    ) -> Bool {
        lock.withLock {
            pendingLease == ParakeetTimedAudioEngineWorkLease(owner: owner, phase: phase)
        }
    }

    func claimPendingWorkForSuccessor(
        currentEngine: AnyObject,
        currentQueue: AnyObject
    ) -> ParakeetTimedAudioEngineWorkLease? {
        lock.lock()
        defer { lock.unlock() }
        guard let pendingLease,
              pendingLease.owner.matchesResources(engine: currentEngine, queue: currentQueue) else {
            return nil
        }
        self.pendingLease = nil
        return pendingLease
    }
}

/// Bridges an audio start from cancellable worker work into a committed
/// recording. The tap may deliver only while the start is active or committed;
/// stop turns both queued work and any late callbacks into no-ops.
final class ParakeetAudioStartCancellationState: @unchecked Sendable {
    private enum State {
        case active
        case committed
        case cancelled
    }

    private let lock = NSLock()
    private var state: State = .active

    var canRunWork: Bool {
        lock.withLock { state == .active }
    }

    var canDeliverSamples: Bool {
        lock.withLock { state != .cancelled }
    }

    @discardableResult
    func commit() -> Bool {
        lock.withLock {
            guard state != .cancelled else { return false }
            state = .committed
            return true
        }
    }

    func cancel() {
        lock.withLock {
            state = .cancelled
        }
    }
}

enum ParakeetSystemInputWorkError: LocalizedError, Equatable {
    case timedOut(operation: String, timeoutMs: Int)
    case circuitOpen(operation: String, activeTimeouts: Int)

    var isTimedOut: Bool {
        if case .timedOut = self { return true }
        return false
    }

    var isCircuitOpen: Bool {
        if case .circuitOpen = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .timedOut(let operation, let timeoutMs):
            return "System input \(operation) timed out after \(timeoutMs)ms"
        case .circuitOpen(let operation, let activeTimeouts):
            return "System input \(operation) skipped while \(activeTimeouts) timed-out operations are still running"
        }
    }
}

/// Serializes system-input work until an operation exceeds its budget. The
/// first timed-out queue may be replaced so one stuck HAL call does not deny
/// the next start. Two still-running timeouts open a hard circuit; later work
/// fails immediately instead of allocating more blocked queues and threads.
/// Work already executing may still finish, and callers reconcile that late
/// side effect through `cleanupAfterLateCompletion`.
final class ParakeetReplaceableSystemInputWorkCoordinator: @unchecked Sendable {
    private static let maximumTimedOutWorkers = 2

    private let lock = NSLock()
    private let label: String
    private var queue: DispatchQueue
    private var generation: UInt64 = 0
    private var activeTimedOutWorkerCount = 0

    init(label: String) {
        self.label = label
        queue = DispatchQueue(label: "\(label).0", qos: .utility)
    }

    func run<T>(
        operation: String,
        timeoutNanoseconds: UInt64,
        cleanupAfterLateCompletion: ((T) -> Void)? = nil,
        _ work: @escaping () -> T
    ) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            schedule(
                operation: operation,
                timeoutNanoseconds: timeoutNanoseconds,
                cleanupAfterLateCompletion: cleanupAfterLateCompletion,
                completion: { continuation.resume(with: $0) },
                work
            )
        }
    }

    func schedule<T>(
        operation: String,
        timeoutNanoseconds: UInt64,
        cleanupAfterLateCompletion: ((T) -> Void)? = nil,
        completion: @escaping (Result<T, Error>) -> Void,
        _ work: @escaping () -> T
    ) {
        let admission = lock.withLock {
            (
                lease: activeTimedOutWorkerCount < Self.maximumTimedOutWorkers
                    ? (queue, generation)
                    : nil,
                activeTimeouts: activeTimedOutWorkerCount
            )
        }
        guard let lease = admission.lease else {
            completion(
                .failure(
                    ParakeetSystemInputWorkError.circuitOpen(
                        operation: operation,
                        activeTimeouts: admission.activeTimeouts
                    )
                )
            )
            return
        }

        let completionLock = NSLock()
        var didComplete = false
        var didStart = false
        let timeoutMs = Int(timeoutNanoseconds / 1_000_000)

        lease.0.async { [self] in
            let shouldRun = completionLock.withLock {
                guard !didComplete else { return false }
                didStart = true
                return true
            }
            guard shouldRun else { return }

            let value = work()
            let completedBeforeTimeout = completionLock.withLock {
                guard !didComplete else { return false }
                didComplete = true
                return true
            }

            if completedBeforeTimeout {
                completion(.success(value))
            } else {
                timedOutWorkerCompleted()
                cleanupAfterLateCompletion?(value)
            }
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .nanoseconds(Int(timeoutNanoseconds))
        ) { [self] in
            let timedOut = completionLock.withLock { () -> Bool in
                guard !didComplete else { return false }
                didComplete = true
                handleTimeout(
                    ifGeneration: lease.1,
                    workStarted: didStart
                )
                return true
            }
            guard timedOut else { return }

            completion(
                .failure(
                    ParakeetSystemInputWorkError.timedOut(
                        operation: operation,
                        timeoutMs: timeoutMs
                    )
                )
            )
        }
    }

    private func handleTimeout(
        ifGeneration expectedGeneration: UInt64,
        workStarted: Bool
    ) {
        lock.withLock {
            if workStarted {
                activeTimedOutWorkerCount += 1
            }
            guard generation == expectedGeneration else { return }
            guard activeTimedOutWorkerCount < Self.maximumTimedOutWorkers else { return }
            generation &+= 1
            queue = DispatchQueue(label: "\(label).\(generation)", qos: .utility)
        }
    }

    private func timedOutWorkerCompleted() {
        lock.withLock {
            activeTimedOutWorkerCount = max(0, activeTimedOutWorkerCount - 1)
        }
    }
}

/// Pending route state is consumed by the graph owner that captured it. A new
/// recording replaces the entry with a new owner, making delayed cleanup a
/// no-op instead of restoring the replacement recording's system input.
struct ParakeetOwnerBoundPendingState<Value: Equatable>: Equatable {
    private struct Entry: Equatable {
        let owner: ParakeetAudioGraphOwnerToken
        let value: Value
    }

    private var entry: Entry?

    var owner: ParakeetAudioGraphOwnerToken? {
        entry?.owner
    }

    var hasPendingValue: Bool {
        entry != nil
    }

    mutating func replace(_ value: Value, ownedBy owner: ParakeetAudioGraphOwnerToken) {
        entry = Entry(owner: owner, value: value)
    }

    mutating func clear() {
        entry = nil
    }

    @discardableResult
    mutating func clear(ownedBy owner: ParakeetAudioGraphOwnerToken) -> Bool {
        guard entry?.owner == owner else { return false }
        entry = nil
        return true
    }

    mutating func take(ownedBy owner: ParakeetAudioGraphOwnerToken) -> Value? {
        guard entry?.owner == owner else { return nil }
        defer { entry = nil }
        return entry?.value
    }

    func value(ownedBy owner: ParakeetAudioGraphOwnerToken) -> Value? {
        guard entry?.owner == owner else { return nil }
        return entry?.value
    }
}

enum ParakeetZombieRecoveryOwnershipPolicy {
    static func canContinue(
        taskIsCancelled: Bool,
        recoveryIsCurrent: Bool,
        expectedOwner: ParakeetAudioGraphOwnerToken,
        currentGraphGeneration: Int,
        currentEngine: AnyObject
    ) -> Bool {
        !taskIsCancelled
            && recoveryIsCurrent
            && expectedOwner.matches(generation: currentGraphGeneration, engine: currentEngine)
    }
}

/// Copied stopped audio belongs to a recording, not to the AVAudioEngine that
/// captured it. Idle prewarm and route notifications may replace that graph
/// while a checkpoint conversion is in flight. A fresh recording or explicit
/// timeline mutation still revokes the copied samples.
struct ParakeetRecordedSamplesClaim: Equatable {
    let recordingIdentity: UUID
    let revision: UInt64

    func isCurrent(recordingIdentity: UUID, revision: UInt64, cancelled: Bool) -> Bool {
        !cancelled && recordingIdentity == self.recordingIdentity && revision == self.revision
    }
}

/// Finishing an old conversion/ASR task may release only its own admission.
/// A replacement recording can revoke that admission without waiting for the
/// old task, and its late completion cannot clear successor audio or busy UI.
struct ParakeetRecordedTranscriptionLease: Equatable {
    let identity: UUID
    let recordingIdentity: UUID
}

struct ParakeetRecordedTranscriptionOwnership {
    private(set) var activeLease: ParakeetRecordedTranscriptionLease?

    mutating func begin(recordingIdentity: UUID) -> ParakeetRecordedTranscriptionLease? {
        guard activeLease == nil else { return nil }
        let lease = ParakeetRecordedTranscriptionLease(identity: UUID(), recordingIdentity: recordingIdentity)
        activeLease = lease
        return lease
    }

    func owns(_ lease: ParakeetRecordedTranscriptionLease, recordingIdentity: UUID) -> Bool {
        activeLease == lease && lease.recordingIdentity == recordingIdentity
    }

    @discardableResult
    mutating func finish(_ lease: ParakeetRecordedTranscriptionLease, recordingIdentity: UUID) -> Bool {
        guard owns(lease, recordingIdentity: recordingIdentity) else { return false }
        activeLease = nil
        return true
    }

    mutating func revoke() {
        activeLease = nil
    }
}

/// One run at a time. A second caller joins the run already in flight instead
/// of starting its own, and the run counts as in progress until its work
/// returns. `ParakeetEngine.stopRecording` uses this so duplicate stops await
/// one tap removal and buffer drain, and config recovery can see a stop for
/// its whole lifetime (`audioStopInProgress`).
@MainActor
final class ParakeetSingleFlightLifecycle {
    private var task: Task<Void, Never>?

    var isInProgress: Bool {
        task != nil
    }

    func run(_ work: @escaping @MainActor () async -> Void) async {
        if let task {
            await task.value
            return
        }
        let task = Task { @MainActor in
            await work()
        }
        self.task = task
        await task.value
        self.task = nil
    }
}

struct ParakeetSystemInputRestoreTarget: Equatable, Sendable {
    let temporaryInput: AudioDeviceID
    let previousInput: AudioDeviceID
}

struct ParakeetSystemInputReconciliationRequest: Equatable, Sendable {
    let attemptedTarget: ParakeetSystemInputRestoreTarget
    let clearMarkerWhenRestored: Bool
}

/// Converges timed-out CoreAudio default-input writes back onto current
/// MainActor intent. A timed-out write can still land after its queue was
/// retired, so each request re-applies the pending successor's route, or
/// restores the attempted route when no successor exists, for a bounded number
/// of attempts. Requests drain through one task, and a late completion asks
/// for another pass only when intent changed while that HAL call was blocked.
///
/// The CoreAudio calls, the pending-restore state, and failure reporting are
/// injected; `ParakeetEngine.makeSystemInputReconciler()` wires the real ones.
@MainActor
final class ParakeetSystemInputReconciler {
    typealias CoreAudioRun = @MainActor (
        _ operation: String,
        _ cleanupAfterLateCompletion: @escaping (String?) -> Void,
        _ work: @escaping () -> String?
    ) async throws -> String?

    static let successorOperation = "late_completion_successor_reconcile"
    static let restoreOperation = "late_completion_restore_reconcile"

    private let attempts: Int
    private let pendingRestore: @MainActor () -> ParakeetOwnerBoundPendingState<ParakeetSystemInputRestoreTarget>
    private let runCoreAudio: CoreAudioRun
    private let applyInput: (AudioDeviceID) -> String?
    private let restoreIfStillTemporary: (ParakeetSystemInputRestoreTarget) -> String?
    private let reportFailure: @MainActor (_ operation: String, _ failureKind: String) -> Void
    private let spawn: (@escaping @MainActor () async -> Void) -> Void
    private var pendingRequests: [ParakeetSystemInputReconciliationRequest] = []
    private var drainTask: Task<Void, Never>?

    init(
        attempts: Int,
        pendingRestore: @escaping @MainActor () -> ParakeetOwnerBoundPendingState<ParakeetSystemInputRestoreTarget>,
        runCoreAudio: @escaping CoreAudioRun,
        applyInput: @escaping (AudioDeviceID) -> String?,
        restoreIfStillTemporary: @escaping (ParakeetSystemInputRestoreTarget) -> String?,
        reportFailure: @escaping @MainActor (_ operation: String, _ failureKind: String) -> Void,
        spawn: @escaping (@escaping @MainActor () async -> Void) -> Void = { work in
            Task { @MainActor in await work() }
        }
    ) {
        self.attempts = attempts
        self.pendingRestore = pendingRestore
        self.runCoreAudio = runCoreAudio
        self.applyInput = applyInput
        self.restoreIfStillTemporary = restoreIfStillTemporary
        self.reportFailure = reportFailure
        self.spawn = spawn
    }

    /// Queue `request` and return once every queued request has been worked.
    func reconcile(_ request: ParakeetSystemInputReconciliationRequest) async {
        enqueue(request)
        if let drainTask {
            await drainTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.drain()
        }
        drainTask = task
        await task.value
    }

    private func enqueue(_ request: ParakeetSystemInputReconciliationRequest) {
        if let existingIndex = pendingRequests.firstIndex(where: {
            $0.attemptedTarget == request.attemptedTarget
        }) {
            let existing = pendingRequests[existingIndex]
            pendingRequests[existingIndex] = ParakeetSystemInputReconciliationRequest(
                attemptedTarget: request.attemptedTarget,
                clearMarkerWhenRestored: existing.clearMarkerWhenRestored || request.clearMarkerWhenRestored
            )
        } else {
            pendingRequests.append(request)
        }
    }

    private func drain() async {
        while !pendingRequests.isEmpty {
            let request = pendingRequests.removeFirst()
            await perform(request)
        }
        drainTask = nil
    }

    private func perform(_ request: ParakeetSystemInputReconciliationRequest) async {
        let applyInput = applyInput
        let restoreIfStillTemporary = restoreIfStillTemporary
        let spawn = spawn
        for _ in 0..<attempts {
            let pending = pendingRestore()
            if let successorOwner = pending.owner,
               let successorTarget = pending.value(ownedBy: successorOwner) {
                let applyError: String?
                do {
                    applyError = try await runCoreAudio(
                        Self.successorOperation,
                        { [weak self] lateError in
                            spawn { [weak self] in
                                await self?.handleLateCompletion(
                                    coreAudioError: lateError,
                                    intendedOwner: successorOwner,
                                    intendedTarget: successorTarget,
                                    request: request
                                )
                            }
                        },
                        { applyInput(successorTarget.temporaryInput) }
                    )
                } catch {
                    reportFailure(Self.successorOperation, "timeout")
                    continue
                }
                guard applyError == nil else {
                    reportFailure(Self.successorOperation, "core_audio_error")
                    continue
                }
                let current = pendingRestore()
                if current.owner == successorOwner,
                   current.value(ownedBy: successorOwner) == successorTarget {
                    return
                }
                continue
            }

            let restoreError: String?
            do {
                restoreError = try await runCoreAudio(
                    Self.restoreOperation,
                    { [weak self] lateError in
                        spawn { [weak self] in
                            await self?.handleLateCompletion(
                                coreAudioError: lateError,
                                intendedOwner: nil,
                                intendedTarget: nil,
                                request: request
                            )
                        }
                    },
                    { restoreIfStillTemporary(request.attemptedTarget) }
                )
            } catch {
                reportFailure(Self.restoreOperation, "timeout")
                continue
            }
            guard restoreError == nil else {
                reportFailure(Self.restoreOperation, "core_audio_error")
                continue
            }
            if !pendingRestore().hasPendingValue {
                return
            }
        }
    }

    /// Timed-out reconciliation work may complete after a replacement queue has
    /// already converged the route. The late result needs more work only when
    /// MainActor intent changed while that HAL call was blocked. An unchanged
    /// successful intent is terminal, which prevents timeout callbacks from
    /// recursively creating an unbounded queue/task chain.
    private func handleLateCompletion(
        coreAudioError: String?,
        intendedOwner: ParakeetAudioGraphOwnerToken?,
        intendedTarget: ParakeetSystemInputRestoreTarget?,
        request: ParakeetSystemInputReconciliationRequest
    ) async {
        guard coreAudioError == nil else {
            reportFailure(
                intendedOwner == nil ? Self.restoreOperation : Self.successorOperation,
                "core_audio_error"
            )
            return
        }

        let pending = pendingRestore()
        if let intendedOwner, let intendedTarget {
            if pending.owner == intendedOwner,
               pending.value(ownedBy: intendedOwner) == intendedTarget {
                return
            }
        } else if !pending.hasPendingValue {
            return
        }

        await reconcile(
            ParakeetSystemInputReconciliationRequest(
                attemptedTarget: request.attemptedTarget,
                clearMarkerWhenRestored: true
            )
        )
    }
}
