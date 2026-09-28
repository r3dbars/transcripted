#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

struct TildeProgressSnapshot: Equatable, Sendable {
    let wordsWrittenWithTildeToday: Int
    let wordsWrittenWithTildeLifetime: Int
    let wordsLearnedFrom: Int
    let activeWritingDays: Int
    let personalSuggestionsToday: Int
    let personalizationStage: PersonalizationStage
    let candidateAccuracy: Double?
    let baselineAccuracy: Double?
}

enum PersonalizationStage: Equatable, Sendable {
    case off
    case loading
    case unavailable
    case learningWords(current: Int, goal: Int)
    case buildingConfidence(days: Int, goal: Int)
    case validating
    case tuned(candidateAccuracy: Double, baselineAccuracy: Double)
}

enum TildeProgress {
    static func snapshot(
        personalHistory: PersonalHistoryController,
        settings: TildeSettings = TildeSettings()
    ) async -> TildeProgressSnapshot {
        let status = await personalHistory.nextWordStatus()
        let personalCounts = PersonalSuggestionStats.todayCounts()
        return makeSnapshot(
            wordsSavedToday: TildeStats.todayWordsAccepted(),
            wordsSavedLifetime: TildeStats.lifetimeWordsAccepted(),
            personalSuggestionsToday: personalCounts[PersonalSuggestionSource.personal.rawValue] ?? 0,
            personalizationEnabled: settings.personalHistoryEnabled,
            status: status
        )
    }

    static func makeSnapshot(
        wordsSavedToday: Int,
        wordsSavedLifetime: Int,
        personalSuggestionsToday: Int,
        personalizationEnabled: Bool,
        status: PersonalNextWordShadowStatus
    ) -> TildeProgressSnapshot {
        let experiment = status.snapshot
        let isReportable = experiment.opportunities
            >= PersonalNextWordShadowStatus.reportingOpportunityMinimum
            && experiment.predictions >= PersonalNextWordShadowStatus.reportingPredictionMinimum
            && experiment.predictionDisagreements
                >= PersonalNextWordShadowStatus.reportingDisagreementMinimum
            && experiment.activeDays >= PersonalNextWordShadowStatus.reportingActiveDayMinimum

        let candidateAccuracy = isReportable
            ? accuracy(hits: experiment.exactHits, opportunities: experiment.opportunities)
            : nil
        let baselineAccuracy = isReportable
            ? accuracy(hits: experiment.baselineExactHits, opportunities: experiment.opportunities)
            : nil

        let stage: PersonalizationStage
        if !personalizationEnabled || status.phase == .inactive {
            stage = .off
        } else {
            switch status.phase {
            case .inactive:
                stage = .off
            case .loading:
                stage = .loading
            case .unavailable:
                stage = .unavailable
            case .ready where experiment.opportunities
                < PersonalNextWordShadowStatus.reportingOpportunityMinimum:
                stage = .learningWords(
                    current: experiment.opportunities,
                    goal: PersonalNextWordShadowStatus.reportingOpportunityMinimum
                )
            case .ready where experiment.activeDays
                < PersonalNextWordShadowStatus.reportingActiveDayMinimum:
                stage = .buildingConfidence(
                    days: experiment.activeDays,
                    goal: PersonalNextWordShadowStatus.reportingActiveDayMinimum
                )
            case .ready:
                if let candidateAccuracy, let baselineAccuracy,
                   candidateAccuracy > baselineAccuracy {
                    stage = .tuned(
                        candidateAccuracy: candidateAccuracy,
                        baselineAccuracy: baselineAccuracy
                    )
                } else {
                    stage = .validating
                }
            }
        }

        return TildeProgressSnapshot(
            wordsWrittenWithTildeToday: max(0, wordsSavedToday),
            wordsWrittenWithTildeLifetime: max(0, wordsSavedLifetime),
            wordsLearnedFrom: max(0, experiment.opportunities),
            activeWritingDays: max(0, experiment.activeDays),
            personalSuggestionsToday: max(0, personalSuggestionsToday),
            personalizationStage: stage,
            candidateAccuracy: candidateAccuracy,
            baselineAccuracy: baselineAccuracy
        )
    }

    private static func accuracy(hits: Int, opportunities: Int) -> Double {
        guard opportunities > 0 else { return 0 }
        return Double(hits) / Double(opportunities)
    }
}
