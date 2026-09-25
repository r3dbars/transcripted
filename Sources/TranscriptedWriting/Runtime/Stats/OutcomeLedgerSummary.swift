import Foundation
#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif

/// Read-only, aggregate-only reader for the owner's outcome ledger.
///
/// The ledger is a text-free JSONL file (`TextFreeOnlineEvent`). This reader
/// answers four owner questions and nothing else: how much typing Tilde
/// saved, how much of that survived half a minute, when Tilde was helpful in
/// a run, and when it deliberately stayed quiet. It never writes, never
/// deletes, and never leaves the device.
///
/// Privacy: `OutcomeLedgerFact` is the complete set of event fields this file
/// consumes — a date, a session hash, three booleans/counters, one enum raw
/// value, and one retention observation. `readKeys` names them, and
/// `OutcomeLedgerFactProjectionTests` proves nothing else is read. The ledger
/// carries no text in the first place; this is the second lock.

/// Why Tilde stayed quiet, in the five words a person would use.
enum HeldBackReason: String, CaseIterable, Sendable {
    /// Most actionable first: `topReason` breaks ties in this order.
    case notReady
    case sensitive
    case modelHadNothing
    case filtersNotConfident
    case keptTyping

    /// Fits "mostly because …".
    var phrase: String {
        switch self {
        case .keptTyping: "you kept typing"
        case .sensitive: "the conversation looked sensitive"
        case .modelHadNothing: "the model had nothing"
        case .filtersNotConfident: "the filters were not confident"
        case .notReady: "Tilde was not ready"
        }
    }

    /// Groups the flight recorder's terminal reasons into the five a person
    /// can act on. Every `SuggestionDecisionReason` except `.shown` lands in
    /// exactly one bucket.
    init?(reason: SuggestionDecisionReason) {
        switch reason {
        case .shown:
            return nil
        case .supersededByTyping, .notAtGrowingEdge, .fieldTargetLost:
            self = .keptTyping
        case .sensitiveScene, .promptInjectionScene:
            self = .sensitive
        case .emptyOutput, .noSuggestion, .emptyPrompt, .behindVisibleGhost:
            self = .modelHadNothing
        case .runtimeUnavailable, .timeout, .protocolError, .suggestionsPaused:
            self = .notReady
        case .noIncomingTurn, .resolvedConversation, .ambiguousChoice,
             .nonActionableScene, .completeSentenceScene, .multipleQuestionsScene,
             .ambiguousReferenceScene, .unsafeCharacter, .promptLeak,
             .prefixReplay, .contextReplay, .selfRepetition, .sceneEcho,
             .unsupportedFact:
            self = .filtersNotConfident
        }
    }
}

/// The only fields of a ledger line this reader is allowed to look at.
struct OutcomeLedgerFact: Equatable, Sendable {
    let occurredAt: Date
    /// SHA-256 of the session identifier. A hash, never a name.
    let sessionDigestSHA256: String
    let displayed: Bool
    let acceptedCharacters: Int
    let heldBackReason: HeldBackReason?
    /// `nil` when the horizon was never observed. Missing is not zero.
    let retainedCharactersAt30Seconds: Int?

    /// Every ledger key this reader touches. All numeric, boolean, enum, or
    /// hash — no field that could carry writing.
    static let readKeys: Set<String> = [
        "occurredAt",
        "sessionDigestSHA256",
        "displayed",
        "acceptedCharacters",
        "guardReason",
        "retentionAt30Seconds",
    ]
}

extension OutcomeLedgerFact {
    /// In an extension so the memberwise initializer survives for tests.
    init(event: TextFreeOnlineEvent) {
        self.init(
            occurredAt: event.occurredAt,
            sessionDigestSHA256: event.sessionDigestSHA256,
            displayed: event.displayed,
            acceptedCharacters: max(0, event.acceptedCharacters),
            heldBackReason: event.displayed
                ? nil
                : event.guardReason
                    .flatMap(SuggestionDecisionReason.init(rawValue:))
                    .flatMap(HeldBackReason.init(reason:)),
            retainedCharactersAt30Seconds: event.retentionAt30Seconds.retainedCharacters
        )
    }
}

struct OutcomeLedgerSummary: Equatable, Sendable {
    /// Accepted characters today. The headline number.
    let keystrokesSavedToday: Int
    let ghostsShownToday: Int
    let acceptedGhostsToday: Int
    /// Character-weighted share of accepted text still in place 30 s later,
    /// over the seven-day window. `nil` when no accepted ghost in the window
    /// has an observed 30 s horizon — never a manufactured zero.
    let keptAfter30SecondsShare: Double?
    /// Accepted ghosts that actually reached the 30 s horizon.
    let keptAfter30SecondsObservations: Int
    /// Runs of three or more accepts close together in one session, today.
    let helpfulStreaksToday: Int
    let longestHelpfulStreakToday: Int
    let heldBackTodayByReason: [HeldBackReason: Int]
    let keystrokesSavedLast7Days: Int
    /// The tail cap was hit, so older lines in the window were not read.
    let truncated: Bool

    static let empty = OutcomeLedgerSummary(
        keystrokesSavedToday: 0,
        ghostsShownToday: 0,
        acceptedGhostsToday: 0,
        keptAfter30SecondsShare: nil,
        keptAfter30SecondsObservations: 0,
        helpfulStreaksToday: 0,
        longestHelpfulStreakToday: 0,
        heldBackTodayByReason: [:],
        keystrokesSavedLast7Days: 0,
        truncated: false
    )

    var heldBackToday: Int { heldBackTodayByReason.values.reduce(0, +) }

    /// True once the ledger has told us anything at all today.
    var hasTodayEvidence: Bool {
        keystrokesSavedToday > 0 || ghostsShownToday > 0 || heldBackToday > 0
    }

    /// The most common reason Tilde stayed quiet today. Ties break toward the
    /// most actionable reason, in `HeldBackReason.allCases` order.
    var topHeldBackReason: HeldBackReason? {
        // `max` keeps the first of equals, which is the documented tie-break.
        let top = HeldBackReason.allCases.max { (heldBackTodayByReason[$0] ?? 0) < (heldBackTodayByReason[$1] ?? 0) }
        return top.flatMap { (heldBackTodayByReason[$0] ?? 0) > 0 ? $0 : nil }
    }

    // MARK: - Aggregation

    /// Two or more accepts more than this far apart are separate runs.
    static let streakGapSeconds: TimeInterval = 120
    static let streakMinimumAccepts = 3
    static let windowDays = 7

    static func make(
        facts: [OutcomeLedgerFact],
        now: Date,
        calendar: Calendar = .current,
        truncated: Bool = false
    ) -> OutcomeLedgerSummary {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfWindow = calendar.date(
            byAdding: .day,
            value: -(windowDays - 1),
            to: startOfToday
        ) ?? startOfToday

        let window = facts.filter { $0.occurredAt >= startOfWindow }
        let today = window.filter { $0.occurredAt >= startOfToday }

        let acceptedToday = today.filter { $0.displayed && $0.acceptedCharacters > 0 }
        let streaks = helpfulStreaks(in: acceptedToday)

        var byReason: [HeldBackReason: Int] = [:]
        for fact in today {
            guard let reason = fact.heldBackReason else { continue }
            byReason[reason, default: 0] += 1
        }

        var retainedTotal = 0
        var acceptedTotalWithHorizon = 0
        var observations = 0
        for fact in window where fact.displayed && fact.acceptedCharacters > 0 {
            // Missing horizon: excluded from numerator and denominator both.
            guard let retained = fact.retainedCharactersAt30Seconds else { continue }
            observations += 1
            acceptedTotalWithHorizon += fact.acceptedCharacters
            retainedTotal += min(max(0, retained), fact.acceptedCharacters)
        }
        let share = acceptedTotalWithHorizon > 0
            ? min(1, Double(retainedTotal) / Double(acceptedTotalWithHorizon))
            : nil

        return OutcomeLedgerSummary(
            keystrokesSavedToday: today.reduce(0) { $0 + $1.acceptedCharacters },
            ghostsShownToday: today.count(where: { $0.displayed }),
            acceptedGhostsToday: acceptedToday.count,
            keptAfter30SecondsShare: share,
            keptAfter30SecondsObservations: observations,
            helpfulStreaksToday: streaks.count,
            longestHelpfulStreakToday: streaks.longest,
            heldBackTodayByReason: byReason,
            keystrokesSavedLast7Days: window.reduce(0) { $0 + $1.acceptedCharacters },
            truncated: truncated
        )
    }

    /// Maximal runs of `streakMinimumAccepts` or more accepts inside one
    /// session digest, with no gap longer than `streakGapSeconds`.
    static func helpfulStreaks(
        in acceptedFacts: [OutcomeLedgerFact]
    ) -> (count: Int, longest: Int) {
        var bySession: [String: [Date]] = [:]
        for fact in acceptedFacts {
            bySession[fact.sessionDigestSHA256, default: []].append(fact.occurredAt)
        }

        var count = 0
        var longest = 0
        func closeRun(_ run: Int) {
            guard run >= streakMinimumAccepts else { return }
            count += 1
            longest = max(longest, run)
        }
        for (_, unsorted) in bySession {
            let times = unsorted.sorted()
            var run = 1
            for index in times.indices.dropFirst() {
                if times[index].timeIntervalSince(times[index - 1]) <= streakGapSeconds {
                    run += 1
                } else {
                    closeRun(run)
                    run = 1
                }
            }
            closeRun(run)
        }
        return (count, longest)
    }
}

/// Bounded tail read of the JSONL ledger. Cheap by construction: it opens
/// the file once, seeks to at most `maximumTailBytes` from the end, and
/// never holds more than that in memory.
enum OutcomeLedgerReader {
    /// One encoded event is about a kilobyte, and a heavy day with the
    /// flight recorder on can write well over a thousand, so the tail must
    /// hold several thousand lines per day to cover the seven-day window.
    /// Twelve mebibytes is read off the main thread, at most once per
    /// refresh interval; when even that is not enough, `truncated` says so
    /// and every surface labels its totals partial.
    static let maximumTailBytes = 12 * 1_048_576

    struct Tail: Equatable, Sendable {
        let lines: [Data]
        let truncated: Bool

        static let empty = Tail(lines: [], truncated: false)
    }

    /// Reads the last `maximumBytes` of `url` and splits it into whole lines.
    /// A missing file, an unreadable file, or a partially written first or
    /// last line all degrade to fewer lines, never to an error.
    static func readTail(
        url: URL,
        maximumBytes: Int = maximumTailBytes
    ) -> Tail {
        guard maximumBytes > 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return .empty }
        defer { try? handle.close() }

        guard let end = try? handle.seekToEnd(), end > 0 else { return .empty }
        let truncated = end > UInt64(maximumBytes)
        let offset = truncated ? end - UInt64(maximumBytes) : 0
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: maximumBytes),
              !data.isEmpty else { return .empty }

        var lines = data.split(separator: UInt8(0x0A), omittingEmptySubsequences: true).map { Data($0) }
        // A tail cut lands mid-line; drop that fragment rather than guess.
        if truncated, !lines.isEmpty { lines.removeFirst() }
        // The writer appends a newline per line, so a trailing fragment means
        // a partially written last line. Drop it too.
        if data.last != 0x0A, !lines.isEmpty { lines.removeLast() }
        return Tail(lines: lines, truncated: truncated)
    }

    /// Decodes a tail into facts, skipping any line that is not a clean v3
    /// production event.
    static func facts(in tail: Tail) -> [OutcomeLedgerFact] {
        tail.lines.compactMap { line in
            guard let event = try? TextFreeOnlineEvent.decodeProductionLine(line) else {
                return nil
            }
            return OutcomeLedgerFact(event: event)
        }
    }

    /// Off-main-thread load. The whole read, decode, and aggregation happens
    /// on a background task; callers await a value type.
    static func summary(
        url: URL,
        now: Date = Date(),
        maximumBytes: Int = maximumTailBytes
    ) async -> OutcomeLedgerSummary {
        await Task.detached(priority: .utility) {
            let tail = readTail(url: url, maximumBytes: maximumBytes)
            return OutcomeLedgerSummary.make(
                facts: facts(in: tail),
                now: now,
                truncated: tail.truncated
            )
        }.value
    }
}

/// Words for the two places the summary is shown. Pure and testable so the
/// restraint rules are proved, not eyeballed.
enum OutcomeLedgerPresentation {
    /// Below the numbers in Your Tilde. `nil` when there is nothing honest
    /// to say. Considered silence must never read as a broken product: when
    /// Tilde could not answer, or Screen Access is off, the line says so and
    /// names the fix.
    static func heldBackLine(
        summary: OutcomeLedgerSummary,
        screenAccessGranted: Bool
    ) -> String? {
        if !screenAccessGranted {
            // The current state only: the ledger cannot establish that a
            // whole day was silent, and the legacy counters may say otherwise.
            return "Screen Access is off now, so Tilde is not suggesting. Turn it on to get suggestions back."
        }
        guard summary.heldBackToday > 0, let reason = summary.topHeldBackReason else {
            return nil
        }
        let times = summary.heldBackToday == 1 ? "once" : "\(summary.heldBackToday.formatted()) times"
        if reason == .notReady {
            return "Tilde held back \(times) today because it was not ready. Open Tilde to check the model and Screen Access."
        }
        return "Tilde held back \(times) today, mostly because \(reason.phrase)."
    }

    /// The menu bar's one line under the status. Falls back to the old words
    /// count until the ledger has something to say.
    static func menuDetail(
        summary: OutcomeLedgerSummary,
        wordsToday: Int,
        screenAccessGranted: Bool
    ) -> String {
        guard summary.hasTodayEvidence else {
            if !screenAccessGranted {
                return "Screen Access is off now — Tilde is not suggesting"
            }
            return "\(wordsToday.formatted()) words with Tilde today"
        }
        let saved = "\(summary.keystrokesSavedToday.formatted()) keystrokes saved today"
        if !screenAccessGranted {
            return "\(saved) · Screen Access is off"
        }
        guard summary.heldBackToday > 0 else { return saved }
        if summary.topHeldBackReason == .notReady {
            return "\(saved) · quiet \(summary.heldBackToday.formatted())×, Tilde was not ready"
        }
        return "\(saved) · held back \(summary.heldBackToday.formatted())×"
    }

    /// "92% kept after 30 seconds" — or nothing, when no horizon was observed.
    static func keptAfter30SecondsLine(summary: OutcomeLedgerSummary) -> String? {
        guard let share = summary.keptAfter30SecondsShare else { return nil }
        return "\(share.formatted(.percent.precision(.fractionLength(0)))) kept after 30 seconds"
    }

    /// "3 helpful streaks today" — only once there is one.
    static func helpfulStreakLine(summary: OutcomeLedgerSummary) -> String? {
        guard summary.helpfulStreaksToday > 0 else { return nil }
        if summary.helpfulStreaksToday == 1 {
            return "1 helpful streak today (\(summary.longestHelpfulStreakToday) in a row)"
        }
        return "\(summary.helpfulStreaksToday) helpful streaks today (best \(summary.longestHelpfulStreakToday) in a row)"
    }
}
