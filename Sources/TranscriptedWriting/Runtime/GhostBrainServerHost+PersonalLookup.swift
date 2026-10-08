#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation
import Security

extension GhostBrainServerHost {
    /// The personal model must only ever see finished words. Mid-word
    /// requests (cursor inside a word, no trailing whitespace) now do reach
    /// here — `acceptsCompletionContext` lets them through whenever the
    /// served interaction policy turns mid-word continuation on — and this
    /// guard is what keeps personal serving word-boundary only regardless:
    /// a partial word fed to the model as a finished tail word could
    /// resolve to a confident prediction that gets glued onto the very word
    /// still being typed (e.g. "tomo" + "tomorrow" → "tomotomorrow"). The
    /// base model has a prompt shape for a partial word
    /// (`RawContinuationPrompt.partialWordToComplete`); the personal
    /// next-word path has none, so it declines. `internal`, not `private`,
    /// so it is directly testable.
    static func personalTailWords(fromContext context: String) -> [String] {
        guard RawContinuationPrompt.endsAtWordBoundary(context) else { return [] }
        return PersonalSuggestionPolicy.tailWords(fromContext: context)
    }

    /// The most a ready base ghost may be held up by a still-running
    /// personal-history lookup. `PersonalHistoryController` is a single
    /// actor shared with ingest/training work, so it can be busy; this
    /// keeps that from ever lengthening a request past a short, fixed
    /// budget — past the deadline the base ghost serves alone (`.base`
    /// source), exactly as if personal suggestions had produced nothing.
    private static let personalPredictionDeadlineNanoseconds: UInt64 = 250_000_000

    /// The most the FIRST streamed prefix may be held while the personal
    /// lookup races (`PartialResponseSink`). Deliberately far shorter than
    /// the 250ms terminal deadline above: that budget protects a finished
    /// answer nobody is looking at yet, this one delays a ghost the writer
    /// would otherwise already be reading. The lookup it waits on is one
    /// read of an in-memory table behind a shared actor — sub-millisecond
    /// unless that actor is busy with ingest or training — so tens of
    /// milliseconds covers the ordinary case, and anything slower simply
    /// streams and lets the terminal line honour the base ghost.
    ///
    /// Not an `InteractionPolicy`/`DecisionPolicy` knob: it is inert unless
    /// the owner-visible "Personal suggestions (experimental)" toggle is on,
    /// so putting it in the configuration digest would re-key all three
    /// shipped digests for a number no default configuration can reach.
    static let personalStreamHoldNanoseconds: UInt64 = 60_000_000

    /// The streaming observer's ceiling: generous, because it is bounded by
    /// the request's own lifetime (the observer is cancelled when the
    /// terminal line is written) and exists only so an abandoned race can
    /// never hold a waiter forever.
    static let personalObserverCeilingNanoseconds: UInt64 = 30_000_000_000

    /// One arm of the 250ms race actually decided the request; the other
    /// resolving too (or not at all) is irrelevant to the outcome. A plain
    /// `PersonalNextWordPrediction??` cannot tell "the model resolved with
    /// nothing" apart from "the deadline fired first" — both read as `nil`
    /// — so the race itself has to report which branch won, not just the
    /// value it produced.
    enum PersonalLookupRaceResult {
        case predicted(PersonalNextWordPrediction?)
        case timedOut
    }

    /// `now`/`diagnostics` are injectable for testability, same pattern as
    /// `ScreenCaptureService`'s clock/diagnostics closures — production call
    /// sites take the defaults (`Date.init`, `DiagnosticsLog.shared.record`)
    /// unchanged. Internal, not private, so `waitedMilliseconds`/`outcome`
    /// can be proven directly without a live socket.
    static func awaitPersonalPrediction(
        _ race: PersonalLookupRace?,
        now: @Sendable () -> Date = Date.init,
        diagnostics: @Sendable (String, [String: String]) -> Void = { event, metadata in
            DiagnosticsLog.shared.record(event, metadata: metadata)
        }
    ) async -> PersonalNextWordPrediction? {
        guard let race else {
            // No provider, the gate was off, or the context had no tail
            // words — no race ever ran, so `waitedMilliseconds` is exactly
            // 0, not "however long the caller happened to take to get here".
            diagnostics("personal-lookup-timing", ["waitedMilliseconds": "0", "outcome": "disabled"])
            return nil
        }
        let waitStartedAt = now()
        let raceResult = await race.value(deadlineNanoseconds: personalPredictionDeadlineNanoseconds)
        let waitedMilliseconds = milliseconds(from: waitStartedAt, to: now())
        let prediction: PersonalNextWordPrediction?
        let outcome: String
        switch raceResult {
        case let .predicted(value):
            prediction = value
            outcome = "resolved"
        case .timedOut:
            prediction = nil
            outcome = "timeout"
        }
        diagnostics("personal-lookup-timing", [
            "waitedMilliseconds": String(waitedMilliseconds),
            "outcome": outcome,
        ])
        return prediction
    }

    /// What goes on the wire for a cleaned suggestion. At a word or
    /// punctuation boundary the leading whitespace is stripped and the
    /// keyboard restores the separator it needs; inside a word a leading
    /// space is the answer's meaning — "start a new word" rather than
    /// "finish this one" — and stripping it glued the ghost onto the
    /// writer's last letter ("thebest"). `internal` for tests.
    static func servedText(_ visibleText: String, midWord: Bool) -> String {
        midWord ? visibleText : String(visibleText.drop(while: \Character.isWhitespace))
    }

    /// The personal lookup as a race every interested party can join and
    /// leave on its own clock. The provider resolves it once when it
    /// finishes; each waiter registers a continuation and a deadline, and
    /// is resumed by whichever comes first — the answer, or its own
    /// deadline. A waiter that times out is removed, so a slow provider
    /// leaves nothing suspended behind it. `internal` for tests.
    final class PersonalLookupRace: @unchecked Sendable {
        private let lock = NSLock()
        private var result: PersonalLookupRaceResult?
        private var waiters: [UUID: CheckedContinuation<PersonalLookupRaceResult, Never>] = [:]

        init() {}

        /// The provider's one answer. Later calls are ignored.
        func resolve(_ prediction: PersonalNextWordPrediction?) {
            let released: [CheckedContinuation<PersonalLookupRaceResult, Never>] = lock.withLock {
                guard result == nil else { return [] }
                result = .predicted(prediction)
                defer { waiters.removeAll() }
                return Array(waiters.values)
            }
            for waiter in released { waiter.resume(returning: .predicted(prediction)) }
        }

        /// Resumes with the answer, or `.timedOut` at the deadline or when
        /// the waiting task is cancelled — either way the waiter is removed.
        func value(deadlineNanoseconds: UInt64) async -> PersonalLookupRaceResult {
            let ticket = UUID()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    let immediate: PersonalLookupRaceResult? = lock.withLock {
                        if let result { return result }
                        waiters[ticket] = continuation
                        return nil
                    }
                    if let immediate {
                        continuation.resume(returning: immediate)
                        return
                    }
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: deadlineNanoseconds)
                        self?.timeOut(ticket)
                    }
                }
            } onCancel: {
                timeOut(ticket)
            }
        }

        private func timeOut(_ ticket: UUID) {
            let waiter: CheckedContinuation<PersonalLookupRaceResult, Never>? = lock.withLock {
                waiters.removeValue(forKey: ticket)
            }
            waiter?.resume(returning: .timedOut)
        }
    }
}
