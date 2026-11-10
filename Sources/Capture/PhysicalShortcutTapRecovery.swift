import Foundation

/// One installed tap's recovery lifetime. WindowServer calls run asynchronously,
/// without holding the detector's state lock or delaying its event callback.
/// A removed tap cancels queued work and ignores an in-flight old result.
final class PhysicalShortcutTapRecovery: @unchecked Sendable {
    typealias Enqueue = @Sendable (@escaping @Sendable () -> Void) -> Void

    /// One stalled WindowServer call must not consume another worker for
    /// each later wake/reinstall. Invalidated queued lifetimes skip their work.
    private static let recoveryQueue = DispatchQueue(label: "TranscriptedPhysicalShortcutRecovery", qos: .userInteractive)

    private let lock = NSLock()
    private let enqueue: Enqueue
    private var active = true
    private var pending = false

    init(enqueue: @escaping Enqueue = { work in
        PhysicalShortcutTapRecovery.recoveryQueue.async(execute: work)
    }) {
        self.enqueue = enqueue
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
            // Cleared before the OS call, not after it. macOS sends no second
            // "disabled" event for a tap that stays disabled, so a disable that
            // lands while this re-enable is in flight must queue one more
            // attempt behind it instead of being dropped.
            pending = false
            lock.unlock()
            guard shouldEnable else { return }

            // Never hold either lock across the WindowServer round trip.
            let enabled = enable()

            lock.lock()
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
}
