import Foundation

/// The stop task completes this signal once its recovery-WAV checkpoint has
/// settled (including a failed checkpoint). Termination uses a bounded poll
/// rather than racing `wait()` against a timeout task: a losing continuation
/// would otherwise remain registered until a stalled stop eventually returns.
actor DictationStoppedAudioCheckpointSignal {
    private var isComplete = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isComplete else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func waitForCompletion(timeoutNanoseconds: UInt64) async -> Bool {
        guard !Task.isCancelled else { return false }
        guard !isComplete else { return true }
        let startedAt = DispatchTime.now().uptimeNanoseconds
        while !isComplete {
            guard !Task.isCancelled else { return false }
            let elapsed = DispatchTime.now().uptimeNanoseconds - startedAt
            guard elapsed < timeoutNanoseconds else { return false }
            do {
                try await Task.sleep(nanoseconds: min(100_000_000, timeoutNanoseconds - elapsed))
            } catch {
                return false
            }
        }
        return !Task.isCancelled
    }

    func complete() {
        guard !isComplete else { return }
        isComplete = true
        let pendingWaiters = waiters
        waiters.removeAll()
        pendingWaiters.forEach { $0.resume() }
    }
}
