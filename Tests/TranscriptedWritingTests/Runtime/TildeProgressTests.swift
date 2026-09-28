import Foundation
import Testing
@testable import TranscriptedWritingRuntime
@testable import TranscriptedWritingCore

@Suite("Your Tilde progress")
struct TildeProgressTests {
    @Test("Learning advances from words to writing days")
    func learningStages() {
        let words = progress(status: status(opportunities: 1_842, activeDays: 6))
        #expect(words.personalizationStage == .learningWords(current: 1_842, goal: 2_000))
        #expect(words.wordsLearnedFrom == 1_842)

        let days = progress(status: status(opportunities: 2_000, activeDays: 6))
        #expect(days.personalizationStage == .buildingConfidence(days: 6, goal: 14))
    }

    @Test("All evidence gates block early accuracy claims")
    func evidenceGates() {
        let early = progress(status: status(
            opportunities: 2_000,
            predictions: 200,
            exactHits: 248,
            baselineExactHits: 216,
            disagreements: 99,
            activeDays: 14
        ))

        #expect(early.personalizationStage == .validating)
        #expect(early.candidateAccuracy == nil)
        #expect(early.baselineAccuracy == nil)
    }

    @Test("A reportable win is tuned and a loss stays calm")
    func tunedOnlyForMeasuredWin() {
        let winning = progress(status: status(
            opportunities: 2_000,
            predictions: 200,
            exactHits: 248,
            baselineExactHits: 216,
            disagreements: 100,
            activeDays: 14
        ))
        #expect(winning.personalizationStage == .tuned(
            candidateAccuracy: 0.124,
            baselineAccuracy: 0.108
        ))

        let tied = progress(status: status(
            opportunities: 2_000,
            predictions: 200,
            exactHits: 216,
            baselineExactHits: 216,
            disagreements: 100,
            activeDays: 14
        ))
        #expect(tied.personalizationStage == .validating)
        #expect(tied.candidateAccuracy == 0.108)
        #expect(tied.baselineAccuracy == 0.108)
    }

    @Test("Disabled and unavailable learning are represented honestly")
    func nonReadyStates() {
        #expect(progress(enabled: false, status: status()).personalizationStage == .off)
        #expect(progress(status: status(phase: .loading)).personalizationStage == .loading)
        #expect(progress(status: status(phase: .unavailable)).personalizationStage == .unavailable)
    }

    @Test("User-facing source counters follow the local calendar")
    func localDayBuckets() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = try! #require(utc.date(from: DateComponents(
            year: 2026, month: 8, day: 12, hour: 0, minute: 50
        )))
        var chicago = Calendar(identifier: .gregorian)
        chicago.timeZone = TimeZone(identifier: "America/Chicago")!
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!

        #expect(PersonalSuggestionStats.dayKey(for: date, calendar: chicago)
            == "personal-suggestions.2026-08-11")
        #expect(PersonalSuggestionStats.dayKey(for: date, calendar: tokyo)
            == "personal-suggestions.2026-08-12")
    }

    private func progress(
        enabled: Bool = true,
        status: PersonalNextWordShadowStatus
    ) -> TildeProgressSnapshot {
        TildeProgress.makeSnapshot(
            wordsSavedToday: 74,
            wordsSavedLifetime: 4_860,
            personalSuggestionsToday: 12,
            personalizationEnabled: enabled,
            status: status
        )
    }

    private func status(
        phase: PersonalNextWordShadowPhase = .ready,
        opportunities: Int = 0,
        predictions: Int = 0,
        exactHits: Int = 0,
        baselineExactHits: Int = 0,
        disagreements: Int = 0,
        activeDays: Int = 0
    ) -> PersonalNextWordShadowStatus {
        PersonalNextWordShadowStatus(
            phase: phase,
            snapshot: PersonalNextWordShadowSnapshot(
                opportunities: opportunities,
                predictions: predictions,
                exactHits: exactHits,
                learnedContexts: 0,
                learnedTransitions: 0,
                capacityLimited: false,
                baselinePredictions: predictions,
                baselineExactHits: baselineExactHits,
                predictionDisagreements: disagreements,
                activeDays: activeDays
            )
        )
    }
}
