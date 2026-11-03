import Foundation

/// WhisperKit is a shared, non-isolated class. MainActor callers can reenter
/// while its async decode, detection, load or unload is suspended. Keep one
/// operation admitted until it actually returns; cancellation alone cannot
/// release native model state that is still in use.
@MainActor
final class WhisperOperationGate {
    private var busy = false
    private let waiters = ASRInferenceWaiterQueue()

    var waiterCount: Int { waiters.count }

    func run<Value>(_ operation: @MainActor () async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        if busy {
            try await waiters.wait()
        } else {
            busy = true
        }
        // A resumed waiter owns the reserved slot, even if cancellation won
        // the race with its handoff. Always release before reporting cancel.
        defer { finish() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func finish() {
        if waiters.isEmpty {
            busy = false
        } else {
            // Keep busy true through the handoff so a new caller cannot pass
            // the resumed waiter while it waits to get back on MainActor.
            waiters.resumeFirst()
        }
    }
}
