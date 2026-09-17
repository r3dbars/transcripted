import Foundation

/// Gives a background hotkey start the foreground handshake already supplied by
/// opening the menu. Restore the editor before starting audio, just as the menu
/// does. This is not microphone readiness: the existing audio retry budget still
/// owns that, including when macOS declines the activation request.
@MainActor
final class DictationStartActivation {
    private var generation = UUID()
    private var cancelled = false
    private var pendingRestoration: (isActive: () -> Bool, restore: () -> Void)?

    func prepare(
        isCurrent: () -> Bool,
        isActive: @escaping () -> Bool,
        activate: () -> Void,
        restore: @escaping () -> Void,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wait: () async throws -> Void = { try await Task.sleep(nanoseconds: 10_000_000) }
    ) async -> Bool {
        guard !Task.isCancelled, isCurrent() else { return false }
        cancel()
        generation = UUID()
        cancelled = false
        pendingRestoration = nil
        guard !isActive() else { return true }
        let token = generation
        pendingRestoration = (isActive, restore)
        defer {
            if generation == token {
                restoreIfActive()
                pendingRestoration = nil
            }
        }
        let deadline = now() + 0.5
        activate()
        while !isActive(), now() < deadline {
            guard generation == token else { return false }
            if cancelled, pendingRestoration == nil { return false }
            // An activation request cannot be retracted. Even after release,
            // observe its completion within the original budget to restore
            // focus; the cancelled session must never proceed to microphone IO.
            do {
                try await wait()
            } catch {
                // A cancelled caller's sleep throws immediately. Use an
                // independent, bounded sleep for focus cleanup only.
                await Task { try? await Task.sleep(nanoseconds: 10_000_000) }.value
            }
        }
        return !Task.isCancelled && !cancelled && isCurrent() && generation == token
    }

    /// Restore synchronously when possible. If activation is still pending,
    /// prepare owns its bounded cleanup; a newer prepare supersedes that owner.
    func cancel() {
        cancelled = true
        restoreIfActive()
    }

    private func restoreIfActive() {
        guard let pendingRestoration, pendingRestoration.isActive() else { return }
        self.pendingRestoration = nil
        // Never pull focus back from a third app the user switched to.
        pendingRestoration.restore()
    }
}
