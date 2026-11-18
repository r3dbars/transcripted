import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// One meeting waiting for an on-device title and summary.
struct MeetingTitlesJob: Equatable, Sendable {
    /// What the caller knows for certain about who made the saved `title:`.
    enum TitleRule: Equatable, Sendable {
        /// No outside evidence: decide from the file
        /// (`MeetingTitlesTitleOwnership`). The rescan and later saves.
        case fromFile
        /// The app made this exact title: the restyle generated it in this
        /// pass, an import named the file, or (before "Transcribe again")
        /// the old file showed it was the app's. Only counts while `title:`
        /// still equals it.
        case appMade(String)
        /// The file had `title_set_by_user: true` before "Transcribe again"
        /// wrote a fresh one; carry the mark over.
        case userSet
        /// Nothing says who made it ("Transcribe again" of a title the old
        /// file couldn't vouch for). Keep it, mark nothing.
        case unknown
    }

    let transcriptURL: URL
    let titleRule: TitleRule

    var key: String { transcriptURL.standardizedFileURL.path }
}

/// Whether the model's title may stand in for a meeting's saved `title:`.
/// Only on positive evidence that the app made it: a title the restyle just
/// generated, the name an import gave the file, a title `ai_title` already
/// stood in for, or a title with the shape of the app's rule titles
/// ("Meeting with …", "Meeting at …", "Quick notes"). Anything else (a
/// rename, a calendar event's title, a title nobody can vouch for) is kept,
/// and only the line and summary are written. `title_set_by_user: true` is
/// never inferred: only Rename writes it, and "Transcribe again" carries it
/// over.
enum MeetingTitlesTitleOwnership {
    enum Decision: Equatable, Sendable {
        /// `ai_title` may stand in for this saved title.
        case replaceable(String)
        /// Keep the saved title. `carryMark` writes `title_set_by_user: true`
        /// back after "Transcribe again" dropped it.
        case keep(carryMark: Bool)
        /// No saved title to decide about.
        case noTitle
    }

    static func decide(values: [String: String], rule: MeetingTitlesJob.TitleRule) -> Decision {
        guard let saved = values["title"].map(MeetingTitlesKeys.normalizedTitle), !saved.isEmpty else { return .noTitle }
        if values[MeetingTitlesKeys.titleSetByUser] == "true" { return .keep(carryMark: false) }
        switch rule {
        case .userSet:
            return .keep(carryMark: true)
        case .unknown:
            return .keep(carryMark: false)
        case .appMade(let title):
            // The title changed since the evidence was taken: someone else's.
            return MeetingTitlesKeys.normalizedTitle(title) == saved ? .replaceable(saved) : .keep(carryMark: false)
        case .fromFile:
            break
        }
        if values[MeetingTitlesKeys.titleReplaces].map(MeetingTitlesKeys.normalizedTitle) == saved { return .replaceable(saved) }
        if MeetingTranscriptStyler.hasRuleTitleShape(saved) { return .replaceable(saved) }
        return .keep(carryMark: false)
    }
}

enum MeetingTitlesJobResult: Equatable, Sendable {
    case written
    case alreadyCurrent
    /// Too short to label; recorded (`ai_summary_status: too_short`) so it
    /// isn't read again until the version changes.
    case tooShort
    /// The model's reply had nothing usable; recorded the same way
    /// (`ai_summary_status: no_usable_reply`).
    case unusableReply
    case unreadable
    case writeSkipped
    /// Transient: the request failed. Not recorded; the next rescan retries.
    case requestFailed
    /// Transient: the helper couldn't start. The job waits in the queue.
    case engineUnavailable
    /// Stopped part way (the app got busy or the feature was turned off).
    /// Nothing was written.
    case cancelled
}

/// Set when the job's task is cancelled; checked inside the serialized
/// write, right before the file is replaced.
final class MeetingTitlesCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Reads, labels and writes one meeting. The engine is started only once a
/// meeting actually needs the model. Cancelling the task stops the request,
/// and nothing is written after a cancel.
enum MeetingTitlesJobRunner {
    static func run(
        _ job: MeetingTitlesJob,
        host: any MeetingTitlesEngineHost,
        generatedAt: @escaping @Sendable () -> Date = { Date() }
    ) async -> MeetingTitlesJobResult {
        let flag = MeetingTitlesCancelFlag()
        return await withTaskCancellationHandler {
            await run(job, host: host, flag: flag, generatedAt: generatedAt)
        } onCancel: {
            flag.cancel()
        }
    }

    private static func run(
        _ job: MeetingTitlesJob,
        host: any MeetingTitlesEngineHost,
        flag: MeetingTitlesCancelFlag,
        generatedAt: @escaping @Sendable () -> Date
    ) async -> MeetingTitlesJobResult {
        let url = job.transcriptURL
        let prepared = await Task.detached(priority: .utility) { () -> Prepared in
            prepare(job, flag: flag, generatedAt: generatedAt)
        }.value
        let turns: [MeetingTitlesTurn]
        let replaceableTitle: String?
        switch prepared {
        case .skip(let result):
            return flag.isCancelled ? .cancelled : result
        case .ready(let readyTurns, let title):
            turns = readyTurns
            replaceableTitle = title
        }
        if flag.isCancelled { return .cancelled }

        let engine: any MeetingTitlesEngine
        do {
            engine = try await host.start()
        } catch {
            return flag.isCancelled ? .cancelled : .engineUnavailable
        }
        let outcome: MeetingTitlesLabeler.Outcome
        do {
            outcome = try await MeetingTitlesLabeler.label(turns, engine: engine)
        } catch {
            return flag.isCancelled ? .cancelled : .requestFailed
        }
        if flag.isCancelled { return .cancelled }
        let stamp = generatedAt()
        guard case .labeled(let label, _) = outcome else {
            _ = await Task.detached(priority: .utility) {
                MeetingTitlesFrontmatterWriter.recordNoSummary(.noUsableReply, at: url, generatedAt: stamp, shouldWrite: { !flag.isCancelled })
            }.value
            return flag.isCancelled ? .cancelled : .unusableReply
        }
        let written = await Task.detached(priority: .utility) {
            MeetingTitlesFrontmatterWriter.apply(
                label, replaceableTitle: replaceableTitle, at: url, generatedAt: stamp,
                shouldWrite: { !flag.isCancelled }
            )
        }.value
        if flag.isCancelled { return .cancelled }
        switch written {
        case .written: return .written
        case .skipped: return .writeSkipped
        case .failed: return .unreadable
        }
    }

    private enum Prepared {
        case skip(MeetingTitlesJobResult)
        case ready([MeetingTitlesTurn], replaceableTitle: String?)
    }

    /// Decides title ownership first and carries a rename mark over right
    /// away, so it lands even when the model never runs.
    private static func prepare(
        _ job: MeetingTitlesJob,
        flag: MeetingTitlesCancelFlag,
        generatedAt: @Sendable () -> Date
    ) -> Prepared {
        let url = job.transcriptURL
        guard var raw = try? String(contentsOf: url, encoding: .utf8),
              let document = TranscriptFrontmatter.document(in: raw),
              document.values["capture_type"] == "meeting" else { return .skip(.unreadable) }
        let decision = MeetingTitlesTitleOwnership.decide(values: document.values, rule: job.titleRule)
        if case .keep(carryMark: true) = decision {
            MeetingTitlesFrontmatterWriter.markTitleSetByUser(at: url, shouldWrite: { !flag.isCancelled })
            raw = (try? String(contentsOf: url, encoding: .utf8)) ?? raw
        }
        if MeetingTitlesFrontmatterWriter.isCurrent(values: document.values) { return .skip(.alreadyCurrent) }
        guard let turns = MeetingTitlesLabeler.labelableTurns(fromMeetingMarkdown: raw) else {
            MeetingTitlesFrontmatterWriter.recordNoSummary(.tooShort, at: url, generatedAt: generatedAt(), shouldWrite: { !flag.isCancelled })
            return .skip(.tooShort)
        }
        if case .replaceable(let title) = decision {
            return .ready(turns, replaceableTitle: title)
        }
        return .ready(turns, replaceableTitle: nil)
    }
}

/// One meeting at a time, just-saved meetings ahead of the backfill. Never
/// starts a job while `isBusy` (a meeting recording, a dictation, or a
/// meeting being transcribed). A job already running when the app gets busy
/// is cancelled, the helper stops, and the meeting goes back to the front of
/// the queue; turning the feature off cancels it for good. The engine stops
/// whenever the queue runs dry.
@MainActor
final class MeetingTitlesQueue {
    struct Environment {
        var isEnabled: @MainActor () -> Bool
        var isBusy: @MainActor () -> Bool
        var sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
        var busyPollInterval: Duration = .seconds(5)
        /// How often a running job checks whether the app got busy.
        var runningPollInterval: Duration = .seconds(1)
    }

    enum Activity: Equatable {
        case idle
        case waitingForBusy
        case labeling
        case engineUnavailable
    }

    private let host: any MeetingTitlesEngineHost
    private let environment: Environment
    private(set) var pending: [MeetingTitlesJob] = []
    private(set) var activity: Activity = .idle {
        didSet { if activity != oldValue { onActivityChange?(activity) } }
    }
    var onActivityChange: ((Activity) -> Void)?
    var onJobFinished: ((MeetingTitlesJob, MeetingTitlesJobResult) -> Void)?
    var onDrained: (() -> Void)?
    private var drainTask: Task<Void, Never>?
    private var runningJob: Task<MeetingTitlesJobResult, Never>?
    private var jobRunner: @Sendable (MeetingTitlesJob, any MeetingTitlesEngineHost) async -> MeetingTitlesJobResult

    init(
        host: any MeetingTitlesEngineHost,
        environment: Environment,
        jobRunner: (@Sendable (MeetingTitlesJob, any MeetingTitlesEngineHost) async -> MeetingTitlesJobResult)? = nil
    ) {
        self.host = host
        self.environment = environment
        self.jobRunner = jobRunner ?? { job, host in await MeetingTitlesJobRunner.run(job, host: host) }
    }

    var isDraining: Bool { drainTask != nil }

    /// A just-saved meeting goes to the front, replacing any older job for
    /// the same file.
    func enqueue(_ job: MeetingTitlesJob) {
        guard environment.isEnabled() else { return }
        pending.removeAll { $0.key == job.key }
        pending.insert(job, at: 0)
        wake()
    }

    /// Backfill jobs keep the caller's order (newest first) behind anything
    /// already waiting; files already queued are left where they are.
    func enqueueBackfill(_ jobs: [MeetingTitlesJob]) {
        guard environment.isEnabled() else { return }
        var queued = Set(pending.map(\.key))
        for job in jobs where queued.insert(job.key).inserted {
            pending.append(job)
        }
        wake()
    }

    func wake() {
        guard drainTask == nil, !pending.isEmpty, environment.isEnabled() else { return }
        drainTask = Task { [weak self] in
            await self?.drain()
        }
    }

    /// Drops everything waiting and cancels a running job; nothing it was
    /// working on gets written. The engine stops after it.
    func cancelAll() {
        pending.removeAll()
        runningJob?.cancel()
    }

    /// Waits for the current drain to end (tests and the lab check).
    func waitUntilIdle() async {
        while let task = drainTask { await task.value }
    }

    private func drain() async {
        defer {
            drainTask = nil
            // A job saved while the engine was stopping starts a new drain.
            if activity != .engineUnavailable, !pending.isEmpty {
                wake()
            } else {
                onDrained?()
            }
        }
        while !pending.isEmpty {
            guard environment.isEnabled() else {
                pending.removeAll()
                break
            }
            if environment.isBusy() {
                activity = .waitingForBusy
                await host.stop()
                while environment.isBusy(), environment.isEnabled() {
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
                await host.stop()
                return
            case .cancelled:
                await host.stop()
                // Busy, not switched off: the meeting goes back to the front.
                if environment.isEnabled(), !pending.contains(where: { $0.key == job.key }) {
                    pending.insert(job, at: 0)
                }
            default:
                break
            }
        }
        activity = .idle
        await host.stop()
    }

    /// Runs one job while checking, every `runningPollInterval`, that the app
    /// hasn't got busy and the feature is still on. Either one cancels it.
    private func runWatched(_ job: MeetingTitlesJob) async -> MeetingTitlesJobResult {
        let host = self.host
        let runner = jobRunner
        let task = Task.detached(priority: .utility) { await runner(job, host) }
        runningJob = task
        let watcher = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.environment.sleep(self.environment.runningPollInterval)
                if Task.isCancelled { return }
                if self.environment.isBusy() || !self.environment.isEnabled() {
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
}
