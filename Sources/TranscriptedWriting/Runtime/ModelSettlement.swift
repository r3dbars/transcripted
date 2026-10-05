import Foundation

/// Completion of one model lifecycle generation. Cancelling an individual
/// waiter leaves the shared download alone; finishing releases every waiter.
final class ModelSettlement: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// Useful for deterministic lifecycle tests without timing assumptions.
    var waiterCount: Int { lock.withLock { waiters.count } }

    func wait() async {
        let identifier = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock {
                    // Cancellation can run before this registration. Reading
                    // it under the same lock closes that lost-wakeup race.
                    guard !finished, !Task.isCancelled else { return true }
                    waiters[identifier] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let continuation = self.lock.withLock { self.waiters.removeValue(forKey: identifier) }
            continuation?.resume()
        }
    }

    func finish() {
        let pending = lock.withLock {
            finished = true
            let pending = Array(waiters.values)
            waiters.removeAll()
            return pending
        }
        for continuation in pending { continuation.resume() }
    }
}
