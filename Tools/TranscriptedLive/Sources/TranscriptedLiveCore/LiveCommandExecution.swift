import Foundation

/// Completes output cleanup before the CLI reports success or failure.
public enum LiveCommandExecution {
    public static func run(
        operation: () async throws -> Void,
        shutdown: () -> Void,
        reportError: (Error) -> Void
    ) async -> Int32 {
        defer { shutdown() }
        do {
            try await operation()
            return 0
        } catch is CancellationError {
            return 0
        } catch {
            reportError(error)
            return 1
        }
    }
}
