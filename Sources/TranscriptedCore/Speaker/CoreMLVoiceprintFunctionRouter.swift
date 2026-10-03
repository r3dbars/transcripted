// CoreMLVoiceprintFunctionRouter.swift
// The multifunction half of `CoreMLSpeakerSegmentEmbedder`: routes each model call
// to the function built for its length, loads functions on first use, and releases
// them all after `idleReleaseSeconds` without a call.

import Foundation

/// Sends each model call to the function built for its length. A function loads on
/// its first call and is kept; one that fails to load fails its calls from then on
/// without being loaded again.
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
    private var loaded: [Int: Result<Predictor, Error>] = [:]
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

    /// Runs `window` on the function for its length; nil if there is none or it
    /// failed to load.
    func predict(_ window: [Float]) -> [Float]? {
        guard case .success(let run) = predictor(forLength: window.count) else { return nil }
        defer { scheduleIdleRelease() }
        return run(window)
    }

    private func predictor(forLength length: Int) -> Result<Predictor, Error> {
        guard let name = functionsByLength[length] else {
            AppLogger.speakers.error("Core ML speaker embedder: no function for this length", [
                "samples": "\(length)",
            ])
            return .failure(CoreMLSpeakerEmbedderError("no model function takes \(length) samples"))
        }
        lock.lock()
        defer { lock.unlock() }
        if let cached = loaded[length] { return cached }
        let result = Result { try load(name) }
        if case .failure(let error) = result {
            AppLogger.speakers.error("Core ML speaker embedder: model function failed to load", [
                "function": name, "error": (error as? CoreMLSpeakerEmbedderError)?.message ?? "load failed",
            ])
        }
        loaded[length] = result
        return result
    }
}
