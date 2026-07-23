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

/// Serializes system-input selection, apply, and restore work. A replacement
/// recording therefore observes and applies its route only after any restore
/// already taken by an older graph owner has completed.
final class ParakeetSerialSystemInputWorkCoordinator: @unchecked Sendable {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .utility)
    }

    func run<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }

    func schedule(_ work: @escaping () -> Void) {
        queue.async {
            work()
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
