import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// One meeting at a time, just-saved meetings ahead of the backfill.
///
/// Never starts a job while `isBusy` (a meeting recording, a dictation, or a
/// meeting being transcribed). The app calls `noteBusyStarted` the moment one
/// of those starts, so a running job is cancelled then and there (a poll is
/// only the backstop), the helper stops and the meeting goes back to the
/// front. The helper (about 3.5 GB) starts again only after `quietPeriod`
/// with nothing busy, so a burst of dictations doesn't load and kill it each
/// time. A meeting whose speaker review still waits for answers is held and
/// tried again later. Turning the feature off cancels everything for good.
/// The engine stops whenever the queue runs dry.
@MainActor
final class MeetingTitlesQueue {
    struct Environment {
        var isEnabled: @MainActor () -> Bool
        var isBusy: @MainActor () -> Bool
        /// True while this meeting (file, capture id) has a speaker review
        /// waiting for answers.
        var isAwaitingSpeakerReview: @MainActor (URL, UUID?) -> Bool = { _, _ in false }
        var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
        /// Monotonic seconds. Tests pass a virtual clock that `sleep` moves.
        var now: @MainActor () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var busyPollInterval: Duration = .seconds(5)
        /// How often a running job checks whether the app got busy, behind
        /// the start signal.
        var runningPollInterval: Duration = .seconds(1)
        /// How long nothing may be busy before the helper starts again.
        var quietPeriod: Duration = .seconds(45)
        /// How often meetings held for a speaker review are looked at again.
        var reviewPollInterval: Duration = .seconds(30)
    }

    enum Activity: Equatable {
        case idle
        case waitingForBusy
        case labeling
        case engineUnavailable
    }

    typealias JobRunner = @Sendable (MeetingTitlesJob, any MeetingTitlesEngineHost, MeetingTitlesJobRunner.Hooks) async
        -> MeetingTitlesJobResult

    private let host: any MeetingTitlesEngineHost
    private let environment: Environment
    private(set) var pending: [MeetingTitlesJob] = []
    /// Meetings whose speaker review still waits for answers.
    private(set) var held: [MeetingTitlesJob] = []
    private(set) var activity: Activity = .idle {
        didSet { if activity != oldValue { onActivityChange?(activity) } }
    }
    var onActivityChange: ((Activity) -> Void)?
    var onJobFinished: ((MeetingTitlesJob, MeetingTitlesJobResult) -> Void)?
    var onDrained: (() -> Void)?
    private var drainTask: Task<Void, Never>?
    private var runningJob: Task<MeetingTitlesJobResult, Never>?
    private let jobRunner: JobRunner
    /// When something was last seen busy (`environment.now`).
    private(set) var lastBusyAt: TimeInterval?
    private var wasBusy = false
    /// Set once a job passed the quiet period and may have started the
    /// helper; cleared whenever the queue stops it.
    private var engineMayBeRunning = false

    init(host: any MeetingTitlesEngineHost, environment: Environment, jobRunner: JobRunner? = nil) {
        self.host = host
        self.environment = environment
        self.jobRunner = jobRunner ?? { job, host, hooks in await MeetingTitlesJobRunner.run(job, host: host, hooks: hooks) }
    }

    var isDraining: Bool { drainTask != nil }

    /// A just-saved meeting goes to the front, replacing any older job for
    /// the same file (held ones included). A later save with no evidence of
    /// its own keeps what the waiting job knew about the title.
    func enqueue(_ job: MeetingTitlesJob) {
        guard environment.isEnabled() else { return }
        var job = job
        if job.titleRule == .fromFile, let waiting = (pending + held).first(where: { $0.key == job.key }) {
            job = MeetingTitlesJob(transcriptURL: job.transcriptURL, titleRule: waiting.titleRule)
        }
        pending.removeAll { $0.key == job.key }
        held.removeAll { $0.key == job.key }
        pending.insert(job, at: 0)
        wake()
    }

    /// Backfill jobs keep the caller's order (newest first) behind anything
    /// already waiting; files already queued or held are left where they are.
    func enqueueBackfill(_ jobs: [MeetingTitlesJob]) {
        guard environment.isEnabled() else { return }
        var queued = Set(pending.map(\.key) + held.map(\.key))
        for job in jobs where queued.insert(job.key).inserted {
            pending.append(job)
        }
        wake()
    }

    func wake() {
        guard drainTask == nil, !(pending.isEmpty && held.isEmpty), environment.isEnabled() else { return }
        drainTask = Task { [weak self] in
            await self?.drain()
        }
    }

    /// Drops everything waiting and cancels a running job; nothing it was
    /// working on gets written. The engine stops after it.
    func cancelAll() {
        pending.removeAll()
        held.removeAll()
        runningJob?.cancel()
    }

    /// Waits for the current drain to end (tests and the lab check).
    func waitUntilIdle() async {
        while let task = drainTask { await task.value }
    }

    // MARK: - Busy

    /// A dictation, recording or transcription just started (the app's own
    /// published state said so). Stops a running job now, not on the next
    /// poll, and restarts the quiet period.
    func noteBusyStarted() {
        wasBusy = true
        lastBusyAt = environment.now()
        runningJob?.cancel()
    }

    /// One of the busy sources changed; re-reads `isBusy`.
    func noteBusyChanged() {
        if observeBusy() { runningJob?.cancel() }
    }

    /// Reads `isBusy`, and remembers when it was last true (including the
    /// moment it turned false).
    @discardableResult
    private func observeBusy() -> Bool {
        let busy = environment.isBusy()
        if busy || wasBusy { lastBusyAt = environment.now() }
        wasBusy = busy
        return busy
    }

    /// Seconds of quiet still needed before the helper may start.
    private var remainingQuiet: TimeInterval {
        guard let lastBusyAt else { return 0 }
        return Self.seconds(environment.quietPeriod) - (environment.now() - lastBusyAt)
    }

    /// The job runner's gate before `host.start()`. A helper the queue
    /// already has running needs no wait.
    private func waitForQuietPeriod() async -> Bool {
        while true {
            if Task.isCancelled || !environment.isEnabled() { return false }
            if engineMayBeRunning { return true }
            let busy = observeBusy()
            let remaining = remainingQuiet
            if !busy, remaining <= 0 { break }
            activity = .waitingForBusy
            await environment.sleep(busy ? environment.busyPollInterval : min(.seconds(remaining), environment.busyPollInterval))
        }
        engineMayBeRunning = true
        activity = .labeling
        return true
    }

    private func isAwaitingSpeakerReview(_ url: URL, _ captureID: UUID?) -> Bool {
        environment.isAwaitingSpeakerReview(url, captureID)
    }

    private func stopEngine() async {
        engineMayBeRunning = false
        await host.stop()
    }

    // MARK: - Drain

    private func drain() async {
        defer {
            drainTask = nil
            // A job saved while the engine was stopping starts a new drain.
            if activity != .engineUnavailable, !(pending.isEmpty && held.isEmpty) {
                wake()
            } else {
                onDrained?()
            }
        }
        while true {
            guard environment.isEnabled() else {
                pending.removeAll()
                held.removeAll()
                break
            }
            if pending.isEmpty {
                guard !held.isEmpty else { break }
                // Only meetings waiting on a speaker review are left.
                activity = .waitingForBusy
                await stopEngine()
                await environment.sleep(environment.reviewPollInterval)
                pending.append(contentsOf: held.filter { job in !pending.contains { $0.key == job.key } })
                held.removeAll()
                continue
            }
            if observeBusy() {
                activity = .waitingForBusy
                await stopEngine()
                while observeBusy(), environment.isEnabled() {
                    await environment.sleep(environment.busyPollInterval)
                }
                continue
            }
            let job = pending.removeFirst()
            activity = .labeling
            let result = await runWatched(job)
            onJobFinished?(job, result)
            switch result {
            case .engineUnavailable:
                // Keep the job; the next save or a retry wakes the queue again.
                pending.insert(job, at: 0)
                activity = .engineUnavailable
                await stopEngine()
                return
            case .cancelled:
                await stopEngine()
                // Busy, not switched off: the meeting goes back to the front.
                if environment.isEnabled(), !pending.contains(where: { $0.key == job.key }) {
                    pending.insert(job, at: 0)
                }
            case .awaitingSpeakerReview:
                if !held.contains(where: { $0.key == job.key }) { held.append(job) }
            default:
                break
            }
        }
        activity = .idle
        await stopEngine()
    }

    /// Runs one job. The start signal cancels it at once; a poll every
    /// `runningPollInterval` is the backstop for busy sources without one.
    private func runWatched(_ job: MeetingTitlesJob) async -> MeetingTitlesJobResult {
        let host = self.host
        let runner = jobRunner
        let hooks = MeetingTitlesJobRunner.Hooks(
            isAwaitingSpeakerReview: { [weak self] url, captureID in
                await self?.isAwaitingSpeakerReview(url, captureID) ?? false
            },
            mayStartEngine: { [weak self] in
                await self?.waitForQuietPeriod() ?? false
            }
        )
        let task = Task.detached(priority: .utility) { await runner(job, host, hooks) }
        runningJob = task
        let watcher = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.environment.sleep(self.environment.runningPollInterval)
                if Task.isCancelled { return }
                if self.observeBusy() || !self.environment.isEnabled() {
                    task.cancel()
                    return
                }
            }
        }
        let result = await task.value
        watcher.cancel()
        runningJob = nil
        return result
    }

    nonisolated static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
