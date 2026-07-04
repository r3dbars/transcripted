import Foundation

enum TimelineBatchAnalysisStatus: Equatable {
    case skippedShort
    case deferred
    case analyzed(cards: [ActivityCardData])
    case failed(kind: TimelineAnalysisFailureKind)
}

actor AnalysisScheduler {
    private var isProcessing = false
    private let planner: BatchPlanner
    private let provider: TimelineLLMProvider
    private let categoryStore: TimelineCategoryStore
    private let idleThreshold: TimeInterval

    init(
        planner: BatchPlanner = BatchPlanner(),
        provider: TimelineLLMProvider,
        categoryStore: TimelineCategoryStore = TimelineCategoryStore(),
        idleThreshold: TimeInterval = 60
    ) {
        self.planner = planner
        self.provider = provider
        self.categoryStore = categoryStore
        self.idleThreshold = idleThreshold
    }

    func analyze(
        screenshots: [TimelineScreenshot],
        observations: [TimelineObservationSegment],
        now: Date
    ) async -> [TimelineBatchAnalysisStatus] {
        guard !isProcessing else { return [] }
        isProcessing = true
        defer { isProcessing = false }

        let plans = planner.plan(screenshots: screenshots, now: now)
        var statuses: [TimelineBatchAnalysisStatus] = []
        for plan in plans {
            switch plan.status {
            case .deferredTrailingShort:
                statuses.append(.deferred)
            case .skippedShort:
                statuses.append(.skippedShort)
            case .pending:
                if plan.screenshots.allSatisfy({ $0.idleSecondsAtCapture >= idleThreshold }) {
                    statuses.append(.analyzed(cards: [CardGenerator.idleCard(for: plan, categoryStore: categoryStore)]))
                    continue
                }

                do {
                    let context = TimelineCardGenerationContext(
                        windowStart: plan.start,
                        windowEnd: plan.end,
                        existingCards: [],
                        fixedCards: [],
                        categories: categoryStore.categories
                    )
                    let generator = CardGenerator(provider: provider, categoryStore: categoryStore)
                    let cards = try await generator.generateCards(observations: observations, context: context)
                    statuses.append(.analyzed(cards: cards))
                } catch {
                    statuses.append(.failed(kind: TimelineProviderFailureClassifier.classify(error)))
                }
            }
        }
        return statuses
    }
}
