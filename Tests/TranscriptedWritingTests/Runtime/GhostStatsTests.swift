import TranscriptedWritingCore
import Foundation
import Testing
@testable import TranscriptedKeyboard

@Suite("IME usage stats")
struct GhostStatsTests {
    @Test("Empty flush does not delay the next aggregate")
    func emptyFlushKeepsNextWriteImmediate() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let key = "stats." + formatter.string(from: Date(timeIntervalSince1970: 1_700_000_000))
        let defaults = WritingTestDefaults()
        let queue = DispatchQueue(label: "GhostStatsTests.fixture")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let stats = GhostStatsStore(defaults: defaults, now: { date }, persistenceQueue: queue)

        stats.flush(force: true)
        let before = (defaults.dictionary(forKey: key) as? [String: Int])?["wordsAccepted"] ?? 0
        stats.recordAccepted("one")
        queue.sync {}
        let automatic = (defaults.dictionary(forKey: key) as? [String: Int])?["wordsAccepted"] ?? 0
        #expect(automatic == before + 1)

        stats.recordAccepted("two words")
        queue.sync {}
        #expect((defaults.dictionary(forKey: key) as? [String: Int])?["wordsAccepted"] == before + 1)
        stats.flush(force: true)
        let after = (defaults.dictionary(forKey: key) as? [String: Int])?["wordsAccepted"] ?? 0

        #expect(after == before + 3)
    }

    @Test("Automatic writes retain the twenty-second throttle without sharing a clock")
    func automaticWritesUseTheInjectedClock() {
        let defaults = WritingTestDefaults()
        let queue = DispatchQueue(label: "GhostStatsTests.throttle")
        let clock = Clock()
        let stats = GhostStatsStore(defaults: defaults, now: { clock.now() }, persistenceQueue: queue)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let key = "stats." + formatter.string(from: clock.now())

        stats.recordSuggestionShown()
        queue.sync {}
        #expect((defaults.dictionary(forKey: key) as? [String: Int])?["suggestionsShown"] == 1)
        clock.advance(seconds: 20)
        stats.recordSuggestionShown()
        queue.sync {}
        #expect((defaults.dictionary(forKey: key) as? [String: Int])?["suggestionsShown"] == 1)
        clock.advance(seconds: 1)
        stats.recordSuggestionShown()
        queue.sync {}
        #expect((defaults.dictionary(forKey: key) as? [String: Int])?["suggestionsShown"] == 3)
    }

    @Test("Suggestion shown and accepted counters persist independently")
    func suggestionCountersStayExplicit() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let key = "stats." + formatter.string(from: Date(timeIntervalSince1970: 1_700_000_000))
        let defaults = WritingTestDefaults()
        let queue = DispatchQueue(label: "GhostStatsTests.fixture")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let stats = GhostStatsStore(defaults: defaults, now: { date }, persistenceQueue: queue)

        stats.flush(force: true)
        let before = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        stats.recordSuggestionShown()
        stats.recordSuggestionShown()
        stats.recordSuggestionAccepted()
        stats.flush(force: true)
        let after = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]

        var expected = before
        expected["suggestionsShown", default: 0] += 2
        expected["suggestionsAccepted", default: 0] += 1
        #expect(after == expected)
    }

    @Test("Runtime failures persist as distinct aggregate counters")
    func runtimeFailuresStayExplicit() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let key = "stats." + formatter.string(from: Date(timeIntervalSince1970: 1_700_000_000))
        let defaults = WritingTestDefaults()
        let queue = DispatchQueue(label: "GhostStatsTests.fixture")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let stats = GhostStatsStore(defaults: defaults, now: { date }, persistenceQueue: queue)

        stats.flush(force: true)
        let before = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        stats.recordFailure(.error)
        stats.recordFailure(.timeout)
        stats.recordFailure(.invalidRequest)
        stats.recordFailure(.silence)
        stats.flush(force: true)
        let after = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]

        var expected = before
        expected["completionErrors", default: 0] += 1
        expected["completionTimeouts", default: 0] += 1
        expected["completionInvalidRequests", default: 0] += 1
        #expect(after == expected)
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_700_000_000)

    func now() -> Date { lock.withLock { date } }
    func advance(seconds: TimeInterval) { lock.withLock { date.addTimeInterval(seconds) } }
}
