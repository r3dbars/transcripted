import Foundation

/// Process-wide admission for timed AVAudioEngine work.
///
/// A timeout resumes the caller, but it cannot cancel a CoreAudio call already
/// running on a DispatchQueue. Each queued block therefore keeps its lease
/// until the block actually returns. If CoreAudio never returns, that lease is
/// never recycled and the hard cap prevents replacement queues from creating
/// an unlimited collection of blocked workers and retained native graphs.
final class ParakeetTimedAudioEngineWorkLimiter: @unchecked Sendable {
    typealias TimeoutScheduler = @Sendable (UInt64, @escaping @Sendable () -> Void) -> Void
    static let wallClockTimeouts: TimeoutScheduler = { delay, expire in
        DispatchQueue.global(qos: .userInitiated).asyncAfter(
            deadline: .now() + .nanoseconds(Int(delay)), execute: expire
        )
    }
    let configurationTimeouts: TimeoutScheduler
    let configurationNativeCompletion: @Sendable () -> Void

    final class Lease: @unchecked Sendable {
        private weak var owner: ParakeetTimedAudioEngineWorkLimiter?
        private let lock = NSLock()
        private var isReleased = false
        private var configurationClaimed = false

        /// Transfer capability. The original unclaimed handle cannot release
        /// this worker after ownership moves into a configuration operation.
        final class ConfigurationClaim: @unchecked Sendable {
            private let lease: Lease
            fileprivate init(_ lease: Lease) { self.lease = lease }
            func release() { lease.releaseConfigurationClaim() }
            deinit { release() }
        }

        func claimConfigurationOwnership() -> ConfigurationClaim? {
            lock.withLock {
                guard !isReleased, !configurationClaimed else { return nil }
                configurationClaimed = true
                return ConfigurationClaim(self)
            }
        }

        private func releaseConfigurationClaim() {
            lock.lock()
            let shouldRelease = !isReleased
            isReleased = true
            lock.unlock()
            if shouldRelease { owner?.releaseWorker() }
        }

        fileprivate init(owner: ParakeetTimedAudioEngineWorkLimiter) {
            self.owner = owner
        }

        func release() {
            lock.lock()
            let shouldRelease = !isReleased && !configurationClaimed
            if shouldRelease { isReleased = true }
            lock.unlock()

            guard shouldRelease else { return }
            owner?.releaseWorker()
        }

        deinit {
            release()
        }
    }

    private let lock = NSLock()
    private let maximumActiveWorkers: Int
    private var activeWorkers = 0

    init(
        maximumActiveWorkers: Int =
            ParakeetAudioEngineRetirementPolicy.maximumRetainedEngineCount,
        configurationTimeouts: @escaping TimeoutScheduler = ParakeetTimedAudioEngineWorkLimiter.wallClockTimeouts,
        configurationNativeCompletion: @escaping @Sendable () -> Void = {}
    ) {
        precondition(maximumActiveWorkers > 0)
        self.maximumActiveWorkers = maximumActiveWorkers
        self.configurationTimeouts = configurationTimeouts
        self.configurationNativeCompletion = configurationNativeCompletion
    }

    func acquire() -> Lease? {
        lock.lock()
        defer { lock.unlock() }
        guard activeWorkers < maximumActiveWorkers else { return nil }
        activeWorkers += 1
        return Lease(owner: self)
    }

    var activeWorkerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeWorkers
    }

    private func releaseWorker() {
        lock.lock()
        activeWorkers = max(0, activeWorkers - 1)
        lock.unlock()
    }
}

extension ParakeetTimedAudioEngineWorkLimiter {
    /// Runs `work` against `resource` on `queue`, resuming the caller on
    /// whichever comes first: the work's result or the timeout.
    ///
    /// Queued work whose lease was claimed (`isWorkCurrent` false) never
    /// starts. Work that loses its lease while running is cleaned up on its
    /// own worker before the caller resumes. Work that outlives its timeout
    /// gets `cleanupAfterLateCompletion` once it finally returns.
    /// `ParakeetEngine.runTimedAudioEngineWork` calls this with its current
    /// `AVAudioEngine` and serial queue.
    func run<Resource, T>(
        on queue: DispatchQueue,
        resource: Resource,
        operation: String,
        timeoutNanoseconds: UInt64,
        isWorkCurrent: (() -> Bool)? = nil,
        cleanupAfterCancellation: ((Resource) -> Void)? = nil,
        cleanupAfterLateCompletion: ((Resource) -> Void)? = nil,
        _ work: @escaping (Resource) throws -> T
    ) async throws -> T {
        let timeoutMs = Int(timeoutNanoseconds / 1_000_000)
        guard let workerLease = acquire() else {
            throw ParakeetAudioEngineWorkError.circuitOpen(
                operation: operation,
                activeWorkers: activeWorkerCount
            )
        }
        let resumeGate = ParakeetTimedWorkResumeGate()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            @Sendable func resumeOnce(_ result: Result<T, Error>) {
                guard resumeGate.claim() else { return }
                continuation.resume(with: result)
            }

            // The resource and its callbacks are handed to `queue`, which is
            // their confinement; the compiler can't see that.
            let job = ParakeetGraphConfined((
                resource: resource,
                work: work,
                isWorkCurrent: isWorkCurrent,
                cleanupAfterCancellation: cleanupAfterCancellation,
                cleanupAfterLateCompletion: cleanupAfterLateCompletion
            ))

            queue.async { [workerLease] in
                // A timed-out caller may have moved on to a replacement queue.
                // Keep this lease until the old queue block itself returns; if
                // CoreAudio is permanently wedged, the process-wide slot stays
                // occupied and later work fails closed instead of spawning more
                // blocked queues and native graphs.
                defer { workerLease.release() }
                let (resource, work, isWorkCurrent, cleanupAfterCancellation, cleanupAfterLateCompletion) = job.value
                guard !resumeGate.hasResumed else { return }
                guard isWorkCurrent?() != false else {
                    resumeOnce(.failure(CancellationError()))
                    return
                }

                var result: Result<T, Error>
                do {
                    result = .success(try work(resource))
                } catch {
                    result = .failure(error)
                }

                let workStayedCurrent = isWorkCurrent?() != false
                if !workStayedCurrent {
                    cleanupAfterCancellation?(resource)
                    result = .failure(CancellationError())
                }

                let completedBeforeTimeout = resumeGate.claim()

                if completedBeforeTimeout {
                    continuation.resume(with: result)
                } else if !workStayedCurrent {
                    // Cancellation cleanup already ran synchronously on this
                    // worker before any successor can use the replacement graph.
                } else {
                    cleanupAfterLateCompletion?(resource)
                }
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .nanoseconds(Int(timeoutNanoseconds))
            ) {
                resumeOnce(
                    .failure(
                        ParakeetAudioEngineWorkError.timedOut(
                            operation: operation,
                            timeoutMs: timeoutMs
                        )
                    )
                )
            }
        }
    }
}

/// The one-shot latch that lets either the work or the timeout resume the
/// caller, never both.
private final class ParakeetTimedWorkResumeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false

    var hasResumed: Bool {
        lock.withLock { didResume }
    }

    /// True for the first caller only.
    func claim() -> Bool {
        lock.withLock {
            guard !didResume else { return false }
            didResume = true
            return true
        }
    }
}
