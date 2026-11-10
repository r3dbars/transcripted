import Foundation

/// One installed tap's startup, recovery and teardown lifetime. WindowServer
/// calls run asynchronously, without the detector lock or callback waiting.
/// Removal cancels queued enables and ignores in-flight old recovery results.
final class PhysicalShortcutTapRecovery: @unchecked Sendable {
    typealias Enqueue = @Sendable (@escaping @Sendable () -> Void) -> Void

    /// One stalled WindowServer call must not consume another worker for
    /// each later wake/reinstall. Invalidated queued enables skip their work;
    /// native teardown still runs for those retired ports.
    private static let recoveryQueue = DispatchQueue(label: "TranscriptedPhysicalShortcutRecovery", qos: .userInteractive)

    private let lock = NSLock()
    private let enqueue: Enqueue
    private var active = true
    private var pending = false
    private var teardownScheduled = false

    init(enqueue: @escaping Enqueue = { work in
        PhysicalShortcutTapRecovery.recoveryQueue.async(execute: work)
    }) {
        self.enqueue = enqueue
    }

    /// Startup shares the native FIFO without hiding a disabled-tap report
    /// behind the ordinary recovery's coalescing slot.
    func requestStartup(enable: @escaping @Sendable () -> Void) {
        lock.lock()
        let shouldEnqueue = active
        lock.unlock()
        guard shouldEnqueue else { return }
        enqueue { [self] in
            lock.lock()
            let shouldEnable = active
            lock.unlock()
            if shouldEnable { enable() }
        }
    }

    func request(
        enable: @escaping @Sendable () -> Bool,
        completed: @escaping @Sendable (Bool) -> Void
    ) {
        lock.lock()
        guard active, !pending else { lock.unlock(); return }
        pending = true
        lock.unlock()

        enqueue { [self] in
            lock.lock()
            let shouldEnable = active
            lock.unlock()
            guard shouldEnable else { return }

            // Never hold either lock across the WindowServer round trip.
            let enabled = enable()

            lock.lock()
            pending = false
            let shouldComplete = active
            lock.unlock()
            if shouldComplete { completed(enabled) }
        }
    }

    func invalidate() {
        lock.lock()
        active = false
        lock.unlock()
    }

    /// Cleanup still belongs to an invalidated lifetime. The same serial worker
    /// finishes an admitted enable before disabling and invalidating its port.
    func invalidate(teardown: @escaping @Sendable () -> Void) {
        lock.lock()
        active = false
        let shouldEnqueue = !teardownScheduled
        teardownScheduled = true
        lock.unlock()
        if shouldEnqueue { enqueue(teardown) }
    }
}
