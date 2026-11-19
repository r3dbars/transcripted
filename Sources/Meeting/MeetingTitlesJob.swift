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
        /// pass, or (before "Transcribe again") the old file showed it was the
        /// app's. Only counts while `title:` still equals it.
        case appMade(String)
        /// This save is an import's, and the import named the file `title`.
        /// Only counts while `title:` still equals it and the file is an
        /// import (`imported_at`).
        case importNamed(String)
        /// The title came from outside the app (a recording's calendar or
        /// requested title), or nothing can vouch for it. Keep it.
        case unknown
    }

    let transcriptURL: URL
    let titleRule: TitleRule

    var key: String { transcriptURL.standardizedFileURL.path }
}

/// Whether the model's title may stand in for a meeting's saved `title:`.
/// Only on positive evidence that the app made it: a title the restyle just
/// generated, the name an import gave the file, a title `ai_title` already
/// stood in for, or (from the file alone) the app's own rule title. A
/// "Meeting with <names>" title counts only when the rule would give exactly
/// that from the file's own speakers today, so a typed "Meeting with Legal"
/// never does; "Meeting at <time>" and "Quick notes" count by shape, so a
/// time-zone or clock-format change doesn't hide them. Anything else (a
/// rename, a calendar event's title, a title nobody can vouch for) is kept,
/// and only the line and summary are written. `title_set_by_user: true` is
/// never inferred: Rename writes it and "Transcribe again" carries it in the
/// replacement write itself.
enum MeetingTitlesTitleOwnership {
    enum Decision: Equatable, Sendable {
        /// `ai_title` may stand in for this saved title.
        case replaceable(String)
        /// Keep the saved title.
        case keep
        /// No saved title to decide about.
        case noTitle
    }

    /// `ruleTitle` is what the app's rule would title this file today
    /// (`MeetingTranscriptStyler.ruleTitle(forMeetingMarkdown:)`); it is only
    /// asked for when the file alone has to decide.
    static func decide(
        values: [String: String],
        rule: MeetingTitlesJob.TitleRule,
        ruleTitle: () -> String? = { nil }
    ) -> Decision {
        guard let saved = values["title"].map(MeetingTitlesKeys.normalizedTitle), !saved.isEmpty else { return .noTitle }
        if values[MeetingTitlesKeys.titleSetByUser] == "true" { return .keep }
        switch rule {
        case .unknown:
            return .keep
        case .appMade(let title):
            // The title changed since the evidence was taken: someone else's.
            return MeetingTitlesKeys.normalizedTitle(title) == saved ? .replaceable(saved) : .keep
        case .importNamed(let title):
            let isImport = !(values["imported_at"] ?? "").isEmpty
            return isImport && MeetingTitlesKeys.normalizedTitle(title) == saved ? .replaceable(saved) : .keep
        case .fromFile:
            break
        }
        if values[MeetingTitlesKeys.titleReplaces].map(MeetingTitlesKeys.normalizedTitle) == saved { return .replaceable(saved) }
        // Labeled before without standing in for this title: that pass kept
        // it (maybe on evidence the file doesn't hold), so a relabel does too.
        if values[MeetingTitlesKeys.version] != nil, values[MeetingTitlesKeys.status] == nil { return .keep }
        if MeetingTranscriptStyler.matchesRuleTitle(saved, ruleTitle: ruleTitle()) { return .replaceable(saved) }
        return .keep
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
    /// The meeting's speaker review still waits for answers. Nothing is
    /// written; the queue holds the job and tries it again later.
    case awaitingSpeakerReview
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
/// meeting actually needs the model, and only after `mayStartEngine` says
/// so (the queue's quiet period). Cancelling the task stops the request, and
/// nothing is written after a cancel.
enum MeetingTitlesJobRunner {
    struct Hooks: Sendable {
        /// True while this meeting's speaker review waits for answers.
        var isAwaitingSpeakerReview: @Sendable (URL, UUID?) async -> Bool = { _, _ in false }
        /// Waits until the engine may start; false means stop (cancelled).
        var mayStartEngine: @Sendable () async -> Bool = { true }
        var generatedAt: @Sendable () -> Date = { Date() }
    }

    static func run(
        _ job: MeetingTitlesJob,
        host: any MeetingTitlesEngineHost,
        hooks: Hooks = Hooks()
    ) async -> MeetingTitlesJobResult {
        let flag = MeetingTitlesCancelFlag()
        return await withTaskCancellationHandler {
            await run(job, host: host, flag: flag, hooks: hooks)
        } onCancel: {
            flag.cancel()
        }
    }

    private static func run(
        _ job: MeetingTitlesJob,
        host: any MeetingTitlesEngineHost,
        flag: MeetingTitlesCancelFlag,
        hooks: Hooks
    ) async -> MeetingTitlesJobResult {
        let url = job.transcriptURL
        let generatedAt = hooks.generatedAt
        let prepared = await Task.detached(priority: .utility) { () -> Prepared in
            prepare(job, flag: flag, generatedAt: generatedAt)
        }.value
        let work: Work
        switch prepared {
        case .skip(let result):
            return flag.isCancelled ? .cancelled : result
        case .ready(let ready):
            work = ready
        }
        if flag.isCancelled { return .cancelled }
        if await hooks.isAwaitingSpeakerReview(url, work.captureID) {
            return flag.isCancelled ? .cancelled : .awaitingSpeakerReview
        }
        guard await hooks.mayStartEngine(), !flag.isCancelled else { return .cancelled }

        let engine: any MeetingTitlesEngine
        do {
            engine = try await host.start()
        } catch {
            return flag.isCancelled ? .cancelled : .engineUnavailable
        }
        let outcome: MeetingTitlesLabeler.Outcome
        do {
            outcome = try await MeetingTitlesLabeler.label(work.turns, engine: engine)
        } catch {
            return flag.isCancelled ? .cancelled : .requestFailed
        }
        if flag.isCancelled { return .cancelled }
        let stamp = generatedAt()
        let speakers = work.speakers
        guard case .labeled(let label, _) = outcome else {
            _ = await Task.detached(priority: .utility) {
                MeetingTitlesFrontmatterWriter.recordNoSummary(
                    .noUsableReply, speakers: speakers, at: url, generatedAt: stamp, shouldWrite: { !flag.isCancelled }
                )
            }.value
            return flag.isCancelled ? .cancelled : .unusableReply
        }
        let replaceableTitle = work.replaceableTitle
        let written = await Task.detached(priority: .utility) {
            MeetingTitlesFrontmatterWriter.apply(
                label, replaceableTitle: replaceableTitle, speakers: speakers, at: url, generatedAt: stamp,
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

    private struct Work {
        let turns: [MeetingTitlesTurn]
        let replaceableTitle: String?
        /// `MeetingTitlesSpeakers.fingerprint` of the names in `turns`.
        let speakers: String
        let captureID: UUID?
    }

    private enum Prepared {
        case skip(MeetingTitlesJobResult)
        case ready(Work)
    }

    private static func prepare(
        _ job: MeetingTitlesJob,
        flag: MeetingTitlesCancelFlag,
        generatedAt: @Sendable () -> Date
    ) -> Prepared {
        let url = job.transcriptURL
        guard let raw = try? String(contentsOf: url, encoding: .utf8),
              let document = TranscriptFrontmatter.document(in: raw),
              document.values["capture_type"] == "meeting" else { return .skip(.unreadable) }
        let turns = MeetingTitlesTranscript.turns(fromMeetingMarkdown: raw)
        let speakers = MeetingTitlesSpeakers.fingerprint(of: turns)
        if MeetingTitlesFrontmatterWriter.isCurrent(values: document.values, speakers: speakers) { return .skip(.alreadyCurrent) }
        guard MeetingTitlesTranscript.wordCount(turns) >= MeetingTitlesTranscript.minimumWords else {
            MeetingTitlesFrontmatterWriter.recordNoSummary(
                .tooShort, speakers: speakers, at: url, generatedAt: generatedAt(), shouldWrite: { !flag.isCancelled }
            )
            return .skip(.tooShort)
        }
        let decision = MeetingTitlesTitleOwnership.decide(values: document.values, rule: job.titleRule) {
            MeetingTranscriptStyler.ruleTitle(forMeetingMarkdown: raw, fallbackURL: url)
        }
        var replaceableTitle: String?
        if case .replaceable(let title) = decision { replaceableTitle = title }
        return .ready(Work(
            turns: turns,
            replaceableTitle: replaceableTitle,
            speakers: speakers,
            captureID: TranscriptFrontmatter.captureID(in: document.values)
        ))
    }
}
