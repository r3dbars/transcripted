// CoreMLVoiceprintFunctionRouter.swift
// The multifunction half of `CoreMLSpeakerSegmentEmbedder`: routes each model call
// to the function built for its length, loads functions on first use (or ahead of
// it, through `preloadAll` and `warm`), and releases them all after
// `idleReleaseSeconds` without a call.
//
// Each length loads under its own lock, so a call on a loaded function never waits
// behind another function's load. Loading a function costs a few MB; its GPU memory
// comes with its first prediction (ReDimNet2: about 370 MB for the 8 s function,
// 470-540 MB with all four in use).

import Foundation

/// Sends each model call to the function built for its length. A function loads on
/// its first call (or a preload) and is kept; one that fails to load fails its calls
/// from then on without being loaded again, until a release.
final class CoreMLVoiceprintFunctionRouter: @unchecked Sendable {
    typealias Predictor = @Sendable ([Float]) -> [Float]?

    /// When an idle release runs. `now` is monotonic seconds; `after` runs its
    /// block once, that many seconds from now. Tests pass a virtual clock.
    struct IdleClock: Sendable {
        let now: @Sendable () -> TimeInterval
        let after: @Sendable (_ seconds: TimeInterval, _ block: @escaping @Sendable () -> Void) -> Void

        private static let releaseQueue = DispatchQueue(label: "com.transcripted.voiceprint.idle-release", qos: .utility)

        /// Uptime, like the dispatch deadline it schedules on.
        static let system = IdleClock(
            now: { ProcessInfo.processInfo.systemUptime },
            after: { seconds, block in IdleClock.releaseQueue.asyncAfter(deadline: .now() + seconds, execute: block) }
        )
    }

    /// The lengths that have a function, ascending.
    let lengths: [Int]

    private let functionsByLength: [Int: String]
    private let load: (_ functionName: String) throws -> Predictor
    private let idleReleaseSeconds: TimeInterval?
    private let clock: IdleClock
    private let lock = NSLock()
    /// One per length: held while that length's function loads, so a second call
    /// for it waits for the same load instead of loading again, and other lengths
    /// never wait on it.
    private let loadLocks: [Int: NSLock]
    private var loaded: [Int: Entry] = [:]
    /// Lengths a `warm` call has claimed and not finished.
    private var warming: Set<Int> = []
    /// When the last call (or preload) ended, on `clock`.
    private var lastUse: TimeInterval = 0
    /// One release timer at most. Calls only move `lastUse`; when the timer
    /// fires early it re-arms itself for the time that is left.
    private var releaseTimerArmed = false

    init(
        functionsByLength: [Int: String],
        idleReleaseSeconds: TimeInterval? = nil,
        clock: IdleClock = .system,
        load: @escaping (_ functionName: String) throws -> Predictor
    ) {
        self.functionsByLength = functionsByLength
        self.lengths = functionsByLength.keys.sorted()
        self.loadLocks = functionsByLength.mapValues { _ in NSLock() }
        self.idleReleaseSeconds = idleReleaseSeconds
        self.clock = clock
        self.load = load
    }

    /// How many functions are loaded (or failed to load) right now.
    var loadedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return loaded.count
    }

    /// Drops every loaded function; the next call for a length loads it again. A
    /// call already running keeps its model alive until it returns.
    func releaseLoadedFunctions() {
        lock.lock()
        let count = loaded.count
        loaded.removeAll()
        lock.unlock()
        logRelease(count)
    }

    private func logRelease(_ count: Int) {
        if count > 0 {
            AppLogger.speakers.info("Core ML speaker embedder released idle model functions", ["functions": "\(count)"])
        }
    }

    /// After a call, make sure a release is due `idleReleaseSeconds` after it,
    /// unless another call follows. Arms the one timer only if none is pending.
    private func scheduleIdleRelease() {
        guard let seconds = idleReleaseSeconds else { return }
        lock.lock()
        lastUse = clock.now()
        let arm = !releaseTimerArmed
        releaseTimerArmed = true
        lock.unlock()
        if arm { armReleaseTimer(after: seconds) }
    }

    private func armReleaseTimer(after seconds: TimeInterval) {
        clock.after(seconds) { [weak self] in self?.releaseTimerFired() }
    }

    /// Releases if the last call was at least `idleReleaseSeconds` ago, else
    /// waits out the rest.
    private func releaseTimerFired() {
        guard let seconds = idleReleaseSeconds else { return }
        lock.lock()
        let remaining = lastUse + seconds - clock.now()
        if remaining > 0 {
            lock.unlock()
            armReleaseTimer(after: remaining)
            return
        }
        releaseTimerArmed = false
        let count = loaded.count
        loaded.removeAll()
        lock.unlock()
        logRelease(count)
    }

    /// Loads the function for `length` now; throws if there is none or it fails.
    func preload(length: Int) throws {
        _ = try predictor(forLength: length).get()
        scheduleIdleRelease()
    }

    /// Loads every function not loaded yet, two at a time on utility queues, and
    /// returns when they're done. Never predicts, so it holds no GPU memory.
    /// Blocks; call it off the main thread. Counts as a use for the idle timer.
    func preloadAll() {
        let missing = lengthsNotLoaded(lengths)
        guard !missing.isEmpty else { return }
        // Longest first: the window length is the one most calls use.
        runTwoAtATime(missing.sorted(by: >), qos: .utility) { router, length in
            _ = router.predictor(forLength: length)
        }
        scheduleIdleRelease()
    }

    /// Gets the functions for `lengths` ready to predict at full speed: each that
    /// hasn't predicted since it loaded runs one all-zero window of its length,
    /// two at a time. The output is thrown away, and a nil from it never counts
    /// as a load failure. Blocks; call it off the main thread.
    func warm(lengths wanted: Set<Int>) {
        let claimed = claimUnwarmed(wanted.filter { functionsByLength[$0] != nil })
        guard !claimed.isEmpty else { return }
        runTwoAtATime(claimed.sorted(by: >), qos: .userInitiated) { router, length in
            guard case .success(let run) = router.predictor(forLength: length) else { return }
            router.markWarmed(length)
            autoreleasepool { _ = run([Float](repeating: 0, count: length)) }
        }
        lock.lock()
        warming.subtract(claimed)
        lock.unlock()
        scheduleIdleRelease()
    }

    /// Runs one model call on the function for its length; nil if there is none
    /// or it failed to load.
    func predict(_ window: [Float]) -> [Float]? {
        guard case .success(let run) = predictor(forLength: window.count) else { return nil }
        markWarmed(window.count)
        defer { scheduleIdleRelease() }
        return run(window)
    }

    // MARK: - Loading

    /// A loaded (or failed) function, and whether it has predicted since it
    /// loaded. A release drops the entry, so a reload starts cold again.
    private struct Entry {
        let result: Result<Predictor, Error>
        var warmed = false
    }

    private func lengthsNotLoaded(_ candidates: [Int]) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return candidates.filter { loaded[$0] == nil }
    }

    /// The lengths in `wanted` that haven't predicted since they loaded and that
    /// no other `warm` is on, claimed for this one.
    private func claimUnwarmed(_ wanted: Set<Int>) -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        let claimed = wanted.filter { loaded[$0]?.warmed != true && !warming.contains($0) }
        warming.formUnion(claimed)
        return Array(claimed)
    }

    private func markWarmed(_ length: Int) {
        lock.lock()
        loaded[length]?.warmed = true
        lock.unlock()
    }

    /// Runs `work` for each length on global queues at `qos`, at most two at a
    /// time, and returns when all are done.
    private func runTwoAtATime(
        _ lengths: [Int], qos: DispatchQoS.QoSClass,
        _ work: @escaping @Sendable (CoreMLVoiceprintFunctionRouter, Int) -> Void
    ) {
        let group = DispatchGroup()
        let slots = DispatchSemaphore(value: 2)
        for length in lengths {
            slots.wait()
            DispatchQueue.global(qos: qos).async(group: group) { [self] in
                defer { slots.signal() }
                work(self, length)
            }
        }
        group.wait()
    }

    private func predictor(forLength length: Int) -> Result<Predictor, Error> {
        guard let name = functionsByLength[length], let loadLock = loadLocks[length] else {
            AppLogger.speakers.error("Core ML speaker embedder: no function for this length", [
                "samples": "\(length)",
            ])
            return .failure(CoreMLSpeakerEmbedderError("no model function takes \(length) samples"))
        }
        if let cached = cachedResult(length) { return cached }
        // Load outside `lock`: release, the idle timer and other lengths never
        // wait on a load. A load that lands after a release is kept, and the
        // idle release the caller schedules next re-arms the timer for it.
        loadLock.lock()
        defer { loadLock.unlock() }
        if let cached = cachedResult(length) { return cached }
        let result = Result { try load(name) }
        if case .failure(let error) = result {
            AppLogger.speakers.error("Core ML speaker embedder: model function failed to load", [
                "function": name, "error": (error as? CoreMLSpeakerEmbedderError)?.message ?? "load failed",
            ])
        }
        lock.lock()
        loaded[length] = Entry(result: result)
        lock.unlock()
        return result
    }

    private func cachedResult(_ length: Int) -> Result<Predictor, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return loaded[length]?.result
    }
}
