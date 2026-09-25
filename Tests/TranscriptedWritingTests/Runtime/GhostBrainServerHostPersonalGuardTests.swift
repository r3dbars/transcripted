import Foundation
import Testing
@testable import TranscriptedWritingRuntime
@testable import TranscriptedWritingCore

@Suite("Personal serving mid-word guard")
struct GhostBrainServerHostPersonalGuardTests {
    @Test("Word-boundary context yields tail words")
    func wordBoundaryYieldsTailWords() {
        let tailWords = GhostBrainServerHost.personalTailWords(fromContext: "see you tomorrow ")
        #expect(tailWords == ["you", "tomorrow"])
    }

    @Test("Mid-word context is refused, never handed to the personal model")
    func midWordContextIsRefused() {
        // Cursor sits right after "tomo" — the word isn't finished yet. If
        // this were tokenized as a tail word, a confident personal
        // prediction for "tomorrow" could be glued straight onto it
        // ("tomotomorrow").
        let tailWords = GhostBrainServerHost.personalTailWords(fromContext: "see you tomo")
        #expect(tailWords.isEmpty)
    }

    @Test("Empty context yields no tail words")
    func emptyContextYieldsNoTailWords() {
        #expect(GhostBrainServerHost.personalTailWords(fromContext: "").isEmpty)
    }

    @Test("Turning mid-word continuation on does not open personal serving mid-word")
    func midWordPolicyDoesNotReachPersonal() {
        // The wire now lets "see you tomo" through when the served policy
        // says so — the base model has a prompt shape for a partial word.
        #expect(GhostBrainServerHost.acceptsCompletionContext(
            "see you tomo",
            allowingPunctuation: false,
            allowingMidWord: true
        ))
        // The personal path has none, and refuses the same context anyway.
        #expect(GhostBrainServerHost.personalTailWords(fromContext: "see you tomo").isEmpty)
    }
}

/// The wire is where the two processes could disagree about where a request
/// may start, so acceptance is checked against the served interaction policy.
@Suite("Completion wire acceptance")
struct GhostBrainServerHostWireAcceptanceTests {
    @Test("A word boundary is always accepted")
    func wordBoundaryAlwaysAccepted() {
        for midWord in [false, true] {
            #expect(GhostBrainServerHost.acceptsCompletionContext(
                "see you ",
                allowingPunctuation: false,
                allowingMidWord: midWord
            ))
        }
    }

    @Test("A mid-word context is refused until the served policy allows it")
    func midWordRequiresTheServedPolicy() {
        #expect(!GhostBrainServerHost.acceptsCompletionContext(
            "I am wri",
            allowingPunctuation: false,
            allowingMidWord: false
        ))
        // Punctuation permission is a different door and does not open this one.
        #expect(!GhostBrainServerHost.acceptsCompletionContext(
            "I am wri",
            allowingPunctuation: true,
            allowingMidWord: false
        ))
        #expect(GhostBrainServerHost.acceptsCompletionContext(
            "I am wri",
            allowingPunctuation: false,
            allowingMidWord: true
        ))
    }

    @Test("Mid-word acceptance keeps the shared partial-word bounds")
    func midWordKeepsSharedBounds() {
        // Under the floor the keyboard would not have asked, so the app must
        // not accept it either.
        #expect(!GhostBrainServerHost.acceptsCompletionContext(
            "since we",
            allowingPunctuation: false,
            allowingMidWord: true
        ))
        // A pasted blob is not a word anyone is part-way through typing.
        let blob = String(repeating: "a", count: 64)
        #expect(!GhostBrainServerHost.acceptsCompletionContext(
            "key \(blob)",
            allowingPunctuation: false,
            allowingMidWord: true
        ))
    }

    @Test("Mid-word permission does not smuggle in punctuation starts")
    func midWordDoesNotImplyPunctuation() {
        #expect(!GhostBrainServerHost.acceptsCompletionContext(
            "one thing,",
            allowingPunctuation: false,
            allowingMidWord: true
        ))
        #expect(GhostBrainServerHost.acceptsCompletionContext(
            "one thing,",
            allowingPunctuation: true,
            allowingMidWord: false
        ))
    }

    @Test("An empty context is never a request")
    func emptyContextRefused() {
        #expect(!GhostBrainServerHost.acceptsCompletionContext(
            "",
            allowingPunctuation: true,
            allowingMidWord: true
        ))
    }
}

/// "P99 at every section" (2026-08-18): the personal-brain lookup's
/// duration/outcome instrumentation. `performCapture`-shaped socket code is
/// not unit-testable (see `ScreenCaptureServiceTests`'s doc comment for the
/// same reason), but `awaitPersonalPrediction` itself takes injectable
/// `now`/`diagnostics` closures precisely so this race's outcome vocabulary
/// can be proven without a live socket or a live `PersonalHistoryController`.
@Suite("Personal lookup timing")
struct GhostBrainServerHostPersonalLookupTimingTests {
    private func recordingDiagnostics() -> (
        sink: @Sendable (String, [String: String]) -> Void,
        events: EventBox
    ) {
        let box = EventBox()
        let sink: @Sendable (String, [String: String]) -> Void = { event, metadata in
            box.append((event, metadata))
        }
        return (sink, box)
    }

    @Test("A nil task (gate off, no provider, or no tail words) reports outcome=disabled and waited=0")
    func nilTaskReportsDisabled() async {
        let (sink, events) = recordingDiagnostics()
        let prediction = await GhostBrainServerHost.awaitPersonalPrediction(
            nil,
            now: { Date() },
            diagnostics: sink
        )
        #expect(prediction == nil)
        let logged = events.values.first { $0.0 == "personal-lookup-timing" }
        #expect(logged?.1["outcome"] == "disabled")
        #expect(logged?.1["waitedMilliseconds"] == "0")
    }

    @Test("A task that resolves before the deadline reports outcome=resolved with its own prediction")
    func fastTaskReportsResolved() async {
        let (sink, events) = recordingDiagnostics()
        let race = GhostBrainServerHost.PersonalLookupRace()
        Task { race.resolve(PersonalNextWordPrediction(word: "tomorrow", support: 4, total: 4)) }
        let prediction = await GhostBrainServerHost.awaitPersonalPrediction(
            race,
            now: { Date() },
            diagnostics: sink
        )
        #expect(prediction?.word == "tomorrow")
        let logged = events.values.first { $0.0 == "personal-lookup-timing" }
        #expect(logged?.1["outcome"] == "resolved")
        #expect(logged?.1["waitedMilliseconds"].flatMap { Int($0) }.map { $0 >= 0 } == true)
    }

    @Test("A task that resolves with nil still reports outcome=resolved, not timeout — value and outcome are independent")
    func resolvedNilIsStillResolved() async {
        let (sink, events) = recordingDiagnostics()
        let race = GhostBrainServerHost.PersonalLookupRace()
        race.resolve(nil)
        let prediction = await GhostBrainServerHost.awaitPersonalPrediction(
            race,
            now: { Date() },
            diagnostics: sink
        )
        #expect(prediction == nil)
        let logged = events.values.first { $0.0 == "personal-lookup-timing" }
        #expect(logged?.1["outcome"] == "resolved")
    }

    @Test("A task slower than the 250ms deadline reports outcome=timeout")
    func slowTaskReportsTimeout() async {
        let (sink, events) = recordingDiagnostics()
        let race = GhostBrainServerHost.PersonalLookupRace()
        let slow = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            race.resolve(PersonalNextWordPrediction(word: "late", support: 4, total: 4))
        }
        let started = Date()
        let prediction = await GhostBrainServerHost.awaitPersonalPrediction(
            race,
            now: { Date() },
            diagnostics: sink
        )
        #expect(prediction == nil)
        let logged = events.values.first { $0.0 == "personal-lookup-timing" }
        #expect(logged?.1["outcome"] == "timeout")
        // The deadline is a real bound: nothing waited for the slow provider.
        #expect(Date().timeIntervalSince(started) < 1.5)
        slow.cancel()
    }

    @Test("milliseconds rounds to the nearest whole millisecond, matching ScreenCaptureService's rounding")
    func millisecondsRoundsToNearest() {
        let start = Date(timeIntervalSince1970: 0)
        #expect(GhostBrainServerHost.milliseconds(from: start, to: start.addingTimeInterval(0.1874)) == 187)
        #expect(GhostBrainServerHost.milliseconds(from: start, to: start.addingTimeInterval(0.1876)) == 188)
    }

    @Test("milliseconds floors at zero for a clock that does not advance")
    func millisecondsFloorsAtZero() {
        let instant = Date(timeIntervalSince1970: 1_000)
        #expect(GhostBrainServerHost.milliseconds(from: instant, to: instant) == 0)
        #expect(GhostBrainServerHost.milliseconds(from: instant, to: instant.addingTimeInterval(-1)) == 0)
    }
}

@Suite("Served text keeps a mid-word answer's separator")
struct ServedTextTests {
    @Test("A boundary answer loses its leading space; a mid-word answer keeps it")
    func leadingSpaceRule() {
        #expect(GhostBrainServerHost.servedText(" best part", midWord: false) == "best part")
        #expect(GhostBrainServerHost.servedText(" best part", midWord: true) == " best part")
        #expect(GhostBrainServerHost.servedText("ting the report", midWord: true) == "ting the report")
    }
}
