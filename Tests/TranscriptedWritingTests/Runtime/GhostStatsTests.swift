import TranscriptedWritingCore
import Foundation
import Testing
@testable import TranscriptedKeyboard

@Suite("IME usage stats", .serialized)
struct GhostStatsTests {
    @Test("Empty flush does not delay the next aggregate")
    func emptyFlushKeepsNextWriteImmediate() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let key = "stats." + formatter.string(from: Date())
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        defer { defaults.set(original, forKey: key) }

        GhostStats.flush(force: true)
        let before = (defaults.dictionary(forKey: key) as? [String: Int])?["wordsAccepted"] ?? 0
        GhostStats.recordAccepted("one")
        for _ in 0..<50 {
            let current = (defaults.dictionary(forKey: key) as? [String: Int])?["wordsAccepted"] ?? 0
            if current == before + 1 { break }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let automatic = (defaults.dictionary(forKey: key) as? [String: Int])?["wordsAccepted"] ?? 0
        #expect(automatic == before + 1)

        GhostStats.recordAccepted("two words")
        GhostStats.flush(force: true)
        let after = (defaults.dictionary(forKey: key) as? [String: Int])?["wordsAccepted"] ?? 0

        #expect(after == before + 3)
    }

    @Test("Suggestion shown and accepted counters persist independently")
    func suggestionCountersStayExplicit() {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let key = "stats." + formatter.string(from: Date())
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        defer { defaults.set(original, forKey: key) }

        GhostStats.flush(force: true)
        let before = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        GhostStats.recordSuggestionShown()
        GhostStats.recordSuggestionShown()
        GhostStats.recordSuggestionAccepted()
        GhostStats.flush(force: true)
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
        let key = "stats." + formatter.string(from: Date())
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: key)
        defer { defaults.set(original, forKey: key) }

        GhostStats.flush(force: true)
        let before = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        GhostStats.recordFailure(.error)
        GhostStats.recordFailure(.timeout)
        GhostStats.recordFailure(.invalidRequest)
        GhostStats.recordFailure(.silence)
        GhostStats.flush(force: true)
        let after = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]

        var expected = before
        expected["completionErrors", default: 0] += 1
        expected["completionTimeouts", default: 0] += 1
        expected["completionInvalidRequests", default: 0] += 1
        #expect(after == expected)
    }
}
