import Foundation

/// One active status read and one latest pending request. Cancellation makes
/// an old read obsolete, but it keeps its slot until preparation really returns.
@MainActor
final class WritingKeyboardRefreshCoordinator<Output> {
    typealias Currency = @MainActor () -> Bool
    typealias Operation = @MainActor (@escaping Currency) async -> Output?

    private struct Request {
        let revision: UInt64
        let operation: Operation
        let publish: @MainActor (Output) -> Void
    }

    private var isEnabled = false
    private var revision: UInt64 = 0
    private var active: Task<Void, Never>?
    private var pending: Request?

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if !enabled { cancel() }
    }

    func request(operation: @escaping Operation, publish: @escaping @MainActor (Output) -> Void) {
        revision &+= 1
        active?.cancel()
        guard isEnabled else { return }
        pending = Request(revision: revision, operation: operation, publish: publish)
        startPending()
    }

    /// Invalidates outstanding work without changing whether new reads may start.
    func cancel() {
        revision &+= 1
        pending = nil
        active?.cancel()
    }

    private func startPending() {
        guard isEnabled, active == nil, let request = pending else { return }
        pending = nil
        active = Task { @MainActor [weak self] in
            let current: Currency = { [weak self] in
                guard let self else { return false }
                return self.isEnabled && self.revision == request.revision && !Task.isCancelled
            }
            let output: Output?
            if current() {
                output = await request.operation(current)
            } else {
                output = nil
            }
            guard let self else { return }
            if current(), let output { request.publish(output) }
            self.active = nil
            self.startPending()
        }
    }
}
