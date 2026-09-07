import Combine
import Foundation

/// A caller-owned wait. Finishing releases its observation and timer, but never
/// cancels the shared model initialization that other sessions may still need.
@MainActor
final class ModelLoadProgressWaiter {
    private var continuation: CheckedContinuation<Void, Never>?
    private var observation: AnyCancellable?
    private var timer: Task<Void, Never>?

    static func wait(for changes: AnyPublisher<Void, Never>, until deadline: TimeInterval) async {
        let waiter = ModelLoadProgressWaiter()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiter.continuation = continuation
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard !Task.isCancelled, remaining > 0 else {
                    waiter.finish()
                    return
                }
                waiter.observation = changes.sink { [weak waiter] in
                    Task { @MainActor in waiter?.finish() }
                }
                waiter.timer = Task { @MainActor [weak waiter] in
                    do { try await Task.sleep(for: .seconds(remaining)) }
                    catch { return }
                    waiter?.finish()
                }
            }
        } onCancel: {
            Task { @MainActor in waiter.finish() }
        }
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        observation?.cancel()
        observation = nil
        timer?.cancel()
        timer = nil
        continuation.resume()
    }
}
