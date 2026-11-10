import Foundation

/// Queue stop inside the install's run-loop activation, even when removal
/// precedes its first Run. The tap thread retains this handle through Run;
/// an abandoned queued stop must not retain the loop after the thread exits.
final class PhysicalShortcutTapRunLoopStop: @unchecked Sendable {
    typealias Enqueue = @Sendable (@escaping @Sendable () -> Void) -> Void

    private let lock = NSLock()
    private let enqueue: Enqueue
    private let stop: @Sendable () -> Void
    private var requested = false

    init(enqueue: @escaping Enqueue, stop: @escaping @Sendable () -> Void) {
        self.enqueue = enqueue
        self.stop = stop
    }

    func request() {
        lock.lock()
        let shouldEnqueue = !requested
        requested = true
        lock.unlock()
        guard shouldEnqueue else { return }
        enqueue { [weak self] in self?.stop() }
    }
}
