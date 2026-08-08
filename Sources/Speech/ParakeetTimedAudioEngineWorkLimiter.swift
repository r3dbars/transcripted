import Foundation

/// Process-wide admission for timed AVAudioEngine work.
///
/// A timeout resumes the caller, but it cannot cancel a CoreAudio call already
/// running on a DispatchQueue. Each queued block therefore keeps its lease
/// until the block actually returns. If CoreAudio never returns, that lease is
/// never recycled and the hard cap prevents replacement queues from creating
/// an unlimited collection of blocked workers and retained native graphs.
final class ParakeetTimedAudioEngineWorkLimiter: @unchecked Sendable {
    final class Lease: @unchecked Sendable {
        private weak var owner: ParakeetTimedAudioEngineWorkLimiter?
        private let lock = NSLock()
        private var isReleased = false

        fileprivate init(owner: ParakeetTimedAudioEngineWorkLimiter) {
            self.owner = owner
        }

        func release() {
            lock.lock()
            let shouldRelease = !isReleased
            isReleased = true
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
            ParakeetAudioEngineRetirementPolicy.maximumRetainedEngineCount
    ) {
        precondition(maximumActiveWorkers > 0)
        self.maximumActiveWorkers = maximumActiveWorkers
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
