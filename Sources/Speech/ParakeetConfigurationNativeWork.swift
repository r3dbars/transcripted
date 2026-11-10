import Foundation

/// Exclusive cleanup authority for one pre-admitted route operation. The old
/// resource is queued under its transferred permit before recovery publication
/// can reenter; a gate keeps native calls behind recording-buffer preservation.
/// `nativeWorkFinished` means calls returned, not proof that hardware is off.
final class ParakeetConfigurationNativeWork<Engine: AnyObject>: @unchecked Sendable {
    let owner: ParakeetAudioEngineQueueOwnerToken
    let engine: Engine
    let queue: DispatchQueue
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var permit: ParakeetTimedAudioEngineWorkLimiter.Lease.ConfigurationClaim?
    private var enqueued = false
    private var started = false
    private var expired = false
    private var cleanupRequired = false
    private var finished = false
    private var waited = false
    private var result: Result<ParakeetConfigurationNativeResult, Error>?
    private var waiter: CheckedContinuation<ParakeetConfigurationNativeResult, Error>?

    init?(owner: ParakeetAudioEngineQueueOwnerToken, engine: Engine, queue: DispatchQueue,
          permit: ParakeetTimedAudioEngineWorkLimiter.Lease) {
        guard let claim = permit.claimConfigurationOwnership() else { return nil }
        self.owner = owner
        self.engine = engine
        self.queue = queue
        self.permit = claim
    }

    /// A true answer is backed by an already queued leased block, or by its
    /// returned native calls. No separate unleased cleanup may be appended.
    func claimCleanup(owner requestedOwner: ParakeetAudioEngineQueueOwnerToken,
                      engine: AnyObject, queue: AnyObject) -> Bool {
        guard owner.matchesResources(engine: engine, queue: queue) else { return false }
        return lock.withLock {
            guard enqueued else { return false }
            // In-flight cancellation follows resources across the stop's
            // generation bump. Returned work proves only its exact lifecycle.
            guard !finished || owner == requestedOwner else { return false }
            cleanupRequired = true
            return true
        }
    }

    var nativeWorkFinished: Bool { lock.withLock { finished } }

    func allowNativeCalls() {
        let signal = lock.withLock {
            guard !started else { return false }
            started = true
            return true
        }
        if signal { ready.signal() }
    }

    private func deliver(_ value: Result<ParakeetConfigurationNativeResult, Error>) {
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        result = value
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(with: value)
    }

    private func expire(timeoutNanoseconds: UInt64) {
        let won = lock.withLock {
            guard !finished, !expired else { return false }
            expired = true
            cleanupRequired = true
            return true
        }
        guard won else { return }
        deliver(.failure(ParakeetAudioEngineWorkError.timedOut(
            operation: "configuration_change_teardown",
            timeoutMs: Int(timeoutNanoseconds / 1_000_000)
        )))
    }

    /// Transfers the permit exactly once into the queued block. The block owns
    /// cleanup even if timeout/cancellation wins before it reaches native work.
    func enqueue(
        timeoutNanoseconds: UInt64,
        scheduleTimeout: ParakeetTimedAudioEngineWorkLimiter.TimeoutScheduler,
        isCurrent: @escaping () -> Bool,
        cleanup: @escaping (Engine) -> Void,
        nativeCompletion: @escaping () -> Void,
        didFinishNativeCalls: @escaping @Sendable () -> Void,
        work: @escaping (Engine) throws -> ParakeetConfigurationNativeResult
    ) -> Bool {
        lock.lock()
        guard !enqueued, let permit else { lock.unlock(); return false }
        self.permit = nil
        enqueued = true
        lock.unlock()
        let job = ParakeetGraphConfined((isCurrent, cleanup, nativeCompletion, didFinishNativeCalls, work))
        queue.async { [self, permit] in
            let (isCurrent, cleanup, nativeCompletion, didFinishNativeCalls, work) = job.value
            defer { nativeCompletion(); permit.release() }
            ready.wait()
            var value: Result<ParakeetConfigurationNativeResult, Error>
            do {
                guard isCurrent(), !lock.withLock({ expired }) else { throw CancellationError() }
                value = .success(try work(engine))
            } catch { value = .failure(error) }
            if !isCurrent() { value = .failure(CancellationError()) }
            let success: Bool
            if case .success = value { success = true } else { success = false }
            lock.lock()
            if cleanupRequired || !success {
                lock.unlock()
                cleanup(engine)
                lock.lock()
            }
            finished = true
            let shouldDeliver = !expired
            lock.unlock()
            // Test injection only; production is a no-op. This is on the old
            // worker with its permit held, never a callback into the host actor.
            didFinishNativeCalls()
            if shouldDeliver { deliver(value) }
        }
        scheduleTimeout(timeoutNanoseconds) { [self] in expire(timeoutNanoseconds: timeoutNanoseconds) }
        return true
    }

    func value() async throws -> ParakeetConfigurationNativeResult {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            guard !waited else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
            waited = true
            if let result { lock.unlock(); continuation.resume(with: result) }
            else { waiter = continuation; lock.unlock() }
        }
    }
}

struct ParakeetConfigurationNativeResult {
    let action: ParakeetConfigChangeGraphAction
    let resetReleasedVoiceProcessing: Bool?
}

/// The actual production mailbox loop, usable without constructing an engine.
@MainActor
enum ParakeetInputDeviceRefreshDrain {
    static func run(mailbox: ParakeetInputDeviceRefreshMailbox, isStopped: () -> Bool,
                    process: (ParakeetInputDeviceRefreshRequest) async -> Void) async {
        while !Task.isCancelled, !isStopped(), let request = mailbox.takeNext() { await process(request) }
    }
}
