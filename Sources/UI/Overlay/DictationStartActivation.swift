import AppKit

/// Optional foreground handshake after a background microphone start has failed.
/// This is a recovery hypothesis, not a microphone-readiness signal. Restoration
/// is requested before returning; AppKit completes it asynchronously.
///
/// Activation requests cannot be revoked or correlated with later activation
/// events. Cleanup is limited to the 500 ms preparation window: retaining it
/// indefinitely could undo a later intentional user activation of Transcripted.
@MainActor
final class DictationStartActivation {
    struct FocusTarget {
        let restore: () -> Void
    }

    private var generation = UUID()
    private var cancelled = false
    private var pendingRestoration: (isActive: () -> Bool, restore: () -> Void)?

    private var stopObserving: (() -> Void)?

    func prepare(sourceApp: NSRunningApplication?, isCurrent: () -> Bool) async -> Bool {
        // The user may have selected another app since the original paste target
        // was captured. Focus restoration and the paste destination are separate.
        let frontmost = NSWorkspace.shared.frontmostApplication
        let target = frontmost?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            ? sourceApp : (frontmost ?? sourceApp)
        return await prepare(
            isCurrent: isCurrent,
            isActive: { NSApp.isActive },
            activate: { NSApp.activate(ignoringOtherApps: true) },
            restore: { target?.activate(options: []) },
            observeExternalActivation: { receive in
                let center = NSWorkspace.shared.notificationCenter
                let observer = center.addObserver(
                    forName: NSWorkspace.didActivateApplicationNotification,
                    object: nil,
                    queue: .main
                ) { notification in
                    MainActor.assumeIsolated {
                        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
                        receive(FocusTarget(restore: { app.activate(options: []) }))
                    }
                }
                return { center.removeObserver(observer) }
            }
        )
    }

    func prepare(
        isCurrent: () -> Bool,
        isActive: @escaping () -> Bool,
        activate: () -> Void,
        restore: @escaping () -> Void,
        observeExternalActivation: (@escaping (FocusTarget) -> Void) -> (() -> Void) = { _ in {} },
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        wait: () async throws -> Void = { try await Task.sleep(nanoseconds: 10_000_000) }
    ) async -> Bool {
        guard !Task.isCancelled, isCurrent() else { return false }
        cancel()
        stopObserving?()
        stopObserving = nil
        generation = UUID()
        cancelled = false
        pendingRestoration = nil
        guard !isActive() else { return true }
        let token = generation
        pendingRestoration = (isActive, restore)
        stopObserving = observeExternalActivation { [weak self] target in
            guard let self, self.generation == token else { return }
            self.pendingRestoration?.restore = target.restore
        }
        defer {
            if generation == token {
                stopObserving?()
                stopObserving = nil
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
        // Restore the latest observed external app, only while we own focus.
        pendingRestoration.restore()
    }
}
