import Foundation

/// A child process the pool can keep ready and end.
protocol NextSentenceWarmProcess: AnyObject, Sendable {
    var isRunning: Bool { get }
    func terminate()
}

/// One ready process per kind, so a request never waits for one to start. Each process answers one
/// request; taking one starts the next in the background.
///
/// `stop()` wins: it ends every process, ready or answering, and one that finishes starting after it
/// (a background respawn that was already under way) is ended at once instead of kept.
final class NextSentenceWarmPool<Kind: Hashable & Sendable, Process: NextSentenceWarmProcess>: @unchecked Sendable {
    private let lock = NSLock()
    private var ready: [Kind: Process] = [:]
    private var answering: [ObjectIdentifier: Process] = [:]
    /// Bumped by `stop()`. A start that began under an older one is stale.
    private var epoch = 0
    private let spawn: (Kind) -> Process?
    private let background: (@escaping @Sendable () -> Void) -> Void

    /// `spawn` starts a process (slow; never called with the lock held). `background` runs the respawn after a take.
    init(spawn: @escaping (Kind) -> Process?,
         background: @escaping (@escaping @Sendable () -> Void) -> Void = { DispatchQueue.global(qos: .utility).async(execute: $0) }) {
        self.spawn = spawn
        self.background = background
    }

    /// Starts a ready process for each kind that has none.
    func prewarm(_ kinds: [Kind]) {
        let started = currentEpoch()
        for kind in kinds where !hasReady(kind) {
            guard let process = spawn(kind) else { continue }
            keep(process, for: kind, startedIn: started, replacing: false)
        }
    }

    /// A process for one request: the ready one, or one started now. Nil if none could start, or if the
    /// pool was stopped meanwhile. Call `finished` when the request is done.
    func take(_ kind: Kind) -> Process? {
        let started = currentEpoch()
        lock.lock()
        var process = ready.removeValue(forKey: kind)
        lock.unlock()
        if let stale = process, !stale.isRunning {
            stale.terminate()
            process = nil
        }
        if process == nil { process = spawn(kind) }
        // Start the next one now, so it's ready by the next press.
        background { [weak self] in
            guard let self, let next = self.spawn(kind) else { return }
            self.keep(next, for: kind, startedIn: started, replacing: true)
        }
        guard let process else { return nil }
        lock.lock()
        guard epoch == started else {
            lock.unlock()
            process.terminate()
            return nil
        }
        answering[ObjectIdentifier(process)] = process
        lock.unlock()
        return process
    }

    /// The request that took `process` is done with it.
    func finished(_ process: Process) {
        lock.lock()
        answering.removeValue(forKey: ObjectIdentifier(process))
        lock.unlock()
        process.terminate()
    }

    /// Ends every process, ready or answering, and any still starting.
    func stop() {
        lock.lock()
        epoch += 1
        let all = Array(ready.values) + Array(answering.values)
        ready.removeAll()
        answering.removeAll()
        lock.unlock()
        all.forEach { $0.terminate() }
    }

    /// Every process the pool holds right now, ready or answering.
    var liveCount: Int {
        lock.lock(); defer { lock.unlock() }
        return ready.count + answering.count
    }

    private func currentEpoch() -> Int {
        lock.lock(); defer { lock.unlock() }
        return epoch
    }

    private func hasReady(_ kind: Kind) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return ready[kind] != nil
    }

    private func keep(_ process: Process, for kind: Kind, startedIn started: Int, replacing: Bool) {
        lock.lock()
        guard epoch == started, replacing || ready[kind] == nil else {
            lock.unlock()
            process.terminate()
            return
        }
        let old = ready.updateValue(process, forKey: kind)
        lock.unlock()
        old?.terminate()
    }
}
