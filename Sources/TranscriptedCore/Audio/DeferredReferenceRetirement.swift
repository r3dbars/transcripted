import Foundation

/// Releases this box's ownership after a main handoff and an explicit worker
/// clear. Other owners keep their existing lifetimes and release behavior.
final class DeferredReferenceRetirement: @unchecked Sendable {
    typealias Delivery = @Sendable (@escaping @Sendable () -> Void) -> Void

    private let lock = NSLock()
    private var value: AnyObject?
    private var scheduled = false
    private let enqueueMain: Delivery
    private let enqueueWorker: Delivery

    init(
        retaining value: AnyObject,
        enqueueMain: @escaping Delivery,
        enqueueWorker: @escaping Delivery
    ) {
        self.value = value
        self.enqueueMain = enqueueMain
        self.enqueueWorker = enqueueWorker
    }

    /// Both injected deliveries run outside the lock, including when a test
    /// scheduler invokes its job synchronously or reenters retire().
    func retire() {
        lock.lock()
        guard !scheduled else {
            lock.unlock()
            return
        }
        scheduled = true
        lock.unlock()

        enqueueMain { [self] in
            enqueueWorker { [self] in
                clearOnWorker()
            }
        }
    }

    private func clearOnWorker() {
        lock.lock()
        // Retain before clearing so no value destructor runs under the lock.
        let retiring = value
        value = nil
        lock.unlock()

        // Clear explicitly: a retained main job may still own this box after
        // the worker returns, so relying on box deinit would release too late.
        withExtendedLifetime(retiring) {}
    }
}
