import Testing
@testable import TranscriptedWritingRuntime

@Suite("Aggregate-only usage stats")
struct TildeStatsTests {
    @Test("Lifetime sums every daily aggregate")
    func lifetimeSumsDailyCounters() {
        let values: [String: Any] = [
            "stats.2026-08-09": ["wordsAccepted": 2],
            "stats.2026-08-10": ["wordsAccepted": 3],
            "stats.2026-08-11": ["wordsAccepted": 5],
        ]

        #expect(TildeStats.sumWordsAccepted(in: values) == 10)
    }

    @Test("Late writes change lifetime without a checkpoint")
    func lateWritesRemainVisible() {
        var values: [String: Any] = [
            "stats.2026-08-09": ["wordsAccepted": 2],
            "stats.2026-08-11": ["wordsAccepted": 5],
        ]
        #expect(TildeStats.sumWordsAccepted(in: values) == 7)

        values["stats.2026-08-10"] = ["wordsAccepted": 3]
        #expect(TildeStats.sumWordsAccepted(in: values) == 10)
    }

    @Test("Unrelated defaults are ignored")
    func ignoresNonStatsValues() {
        let values: [String: Any] = [
            "stats.2026-08-11": ["wordsAccepted": 4],
            "stats.2026-08-10": "invalid",
            "GhostSuggestionsEnabled": false,
        ]

        #expect(TildeStats.sumWordsAccepted(in: values) == 4)
    }

    @Test("Shown and accepted sum independently across days")
    func sumsSuggestionCountersIndependently() {
        let values: [String: Any] = [
            "stats.2026-08-09": ["suggestionsShown": 10, "suggestionsAccepted": 2],
            "stats.2026-08-10": ["suggestionsShown": 20, "suggestionsAccepted": 3],
        ]

        #expect(TildeStats.sumSuggestionsShown(in: values) == 30)
        #expect(TildeStats.sumSuggestionsAccepted(in: values) == 5)
    }

    @Test("Acceptance rate rounds to a whole percent and guards zero shown")
    func acceptanceRateMath() {
        #expect(TildeStats.acceptanceRate(accepted: 12, shown: 84) == 14)
        #expect(TildeStats.acceptanceRate(accepted: 1, shown: 3) == 33)
        #expect(TildeStats.acceptanceRate(accepted: 0, shown: 0) == 0)
    }
}
