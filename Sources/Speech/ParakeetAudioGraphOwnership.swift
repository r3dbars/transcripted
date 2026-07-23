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
    case zombieRecoveryStart
}

struct ParakeetTimedAudioEngineWorkLease: Equatable, Sendable {
    let owner: ParakeetAudioEngineQueueOwnerToken
    let phase: ParakeetTimedAudioEngineWorkPhase
}

/// Thread-safe ownership for one bounded zombie-recovery engine operation.
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

enum ParakeetSystemInputWorkError: LocalizedError, Equatable {
    case timedOut(operation: String, timeoutMs: Int)

    var errorDescription: String? {
        switch self {
        case .timedOut(let operation, let timeoutMs):
            return "System input \(operation) timed out after \(timeoutMs)ms"
        }
    }
}

/// Serializes system-input work until an operation exceeds its budget. A timed
/// out queue is retired immediately so later starts are not denied by one stuck
/// HAL call. Work already executing may still finish; callers reconcile that
/// late side effect through `cleanupAfterLateCompletion`.
final class ParakeetReplaceableSystemInputWorkCoordinator: @unchecked Sendable {
    private let lock = NSLock()
    private let label: String
    private var queue: DispatchQueue
    private var generation: UInt64 = 0

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
        let lease = lock.withLock { (queue, generation) }
        let completionLock = NSLock()
        var didComplete = false
        let timeoutMs = Int(timeoutNanoseconds / 1_000_000)

        lease.0.async {
            let shouldRun = completionLock.withLock { !didComplete }
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
                cleanupAfterLateCompletion?(value)
            }
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .nanoseconds(Int(timeoutNanoseconds))
        ) { [weak self] in
            let timedOut = completionLock.withLock {
                guard !didComplete else { return false }
                didComplete = true
                return true
            }
            guard timedOut, let self else { return }

            self.replaceQueue(ifGeneration: lease.1)
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

    private func replaceQueue(ifGeneration expectedGeneration: UInt64) {
        lock.withLock {
            guard generation == expectedGeneration else { return }
            generation &+= 1
            queue = DispatchQueue(label: "\(label).\(generation)", qos: .utility)
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
