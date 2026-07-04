import Foundation

actor CardGenerator {
    let provider: TimelineLLMProvider
    let categoryStore: TimelineCategoryStore
    let minimumDuration: TimeInterval
    let maximumDuration: TimeInterval

    init(
        provider: TimelineLLMProvider,
        categoryStore: TimelineCategoryStore = TimelineCategoryStore(),
        minimumDuration: TimeInterval = 600,
        maximumDuration: TimeInterval = 3600
    ) {
        self.provider = provider
        self.categoryStore = categoryStore
        self.minimumDuration = minimumDuration
        self.maximumDuration = maximumDuration
    }

    func generateCards(
        observations: [TimelineObservationSegment],
        context: TimelineCardGenerationContext
    ) async throws -> [ActivityCardData] {
        let rawCards = try await provider.generateCards(observations: observations, context: context)
        return Self.normalizedCards(
            rawCards,
            windowStart: context.windowStart,
            windowEnd: context.windowEnd,
            categoryStore: categoryStore,
            minimumDuration: minimumDuration,
            maximumDuration: maximumDuration
        )
    }

    static func normalizedCards(
        _ cards: [ActivityCardData],
        windowStart: Date,
        windowEnd: Date,
        categoryStore: TimelineCategoryStore = TimelineCategoryStore(),
        minimumDuration: TimeInterval = 600,
        maximumDuration: TimeInterval = 3600
    ) -> [ActivityCardData] {
        let bounded = cards.compactMap { card -> ActivityCardData? in
            var next = card
            next.startTs = maxDate(windowStart, minDate(card.startTs, windowEnd))
            next.endTs = maxDate(windowStart, minDate(card.endTs, windowEnd))
            guard next.endTs > next.startTs else { return nil }
            next.category = categoryStore.normalizedName(for: next.category)
            next.title = next.title.trimmingCharacters(in: .whitespacesAndNewlines)
            next.summary = next.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if next.title.isEmpty { next.title = next.category }
            if next.summary.isEmpty { next.summary = next.title }
            return next
        }.sorted { $0.startTs < $1.startTs }

        guard !bounded.isEmpty else { return [] }

        var continuous = bounded
        continuous[0].startTs = windowStart
        for index in continuous.indices {
            if index > 0 {
                continuous[index].startTs = continuous[index - 1].endTs
            }
            if index == continuous.count - 1 {
                continuous[index].endTs = windowEnd
            } else if continuous[index].endTs <= continuous[index].startTs {
                continuous[index].endTs = bounded[index + 1].startTs
            }
            if continuous[index].endTs <= continuous[index].startTs {
                continuous[index].endTs = continuous[index].startTs.addingTimeInterval(1)
            }
        }

        var merged = mergeSameWorkstream(continuous, maximumDuration: maximumDuration)
        merged = foldShortCards(merged, minimumDuration: minimumDuration)
        merged = splitLongCards(merged, maximumDuration: maximumDuration)
        return closeContinuity(merged, windowStart: windowStart, windowEnd: windowEnd)
    }

    static func cardsToReplace(in cards: [ActivityCardData]) -> [ActivityCardData] {
        cards.filter { $0.kind == .activity || $0.kind == .idle }
    }

    static func idleCard(
        for batch: TimelineBatchPlan,
        categoryStore: TimelineCategoryStore = TimelineCategoryStore()
    ) -> ActivityCardData {
        ActivityCardData(
            id: "idle-\(Int(batch.start.timeIntervalSince1970))-\(Int(batch.end.timeIntervalSince1970))",
            startTs: batch.start,
            endTs: batch.end,
            kind: .idle,
            title: "Idle",
            summary: "The Mac was idle during this window.",
            category: categoryStore.idleCategoryName()
        )
    }

    private static func mergeSameWorkstream(
        _ cards: [ActivityCardData],
        maximumDuration: TimeInterval
    ) -> [ActivityCardData] {
        var output: [ActivityCardData] = []
        for card in cards {
            guard var previous = output.popLast() else {
                output.append(card)
                continue
            }

            let sameStream = previous.kind == card.kind &&
                previous.category.caseInsensitiveCompare(card.category) == .orderedSame &&
                previous.title.caseInsensitiveCompare(card.title) == .orderedSame
            let mergedDuration = card.endTs.timeIntervalSince(previous.startTs)
            if sameStream && mergedDuration <= maximumDuration {
                previous.endTs = card.endTs
                previous.summary = mergeText(previous.summary, card.summary)
                output.append(previous)
            } else {
                output.append(previous)
                output.append(card)
            }
        }
        return output
    }

    private static func foldShortCards(
        _ cards: [ActivityCardData],
        minimumDuration: TimeInterval
    ) -> [ActivityCardData] {
        var output: [ActivityCardData] = []
        for card in cards {
            if card.duration >= minimumDuration || output.isEmpty {
                output.append(card)
                continue
            }

            var previous = output.removeLast()
            previous.endTs = card.endTs
            previous.summary = mergeText(previous.summary, card.summary)
            output.append(previous)
        }

        if output.count > 1, let last = output.last, last.duration < minimumDuration {
            output.removeLast()
            var previous = output.removeLast()
            previous.endTs = last.endTs
            previous.summary = mergeText(previous.summary, last.summary)
            output.append(previous)
        }

        return output
    }

    private static func splitLongCards(
        _ cards: [ActivityCardData],
        maximumDuration: TimeInterval
    ) -> [ActivityCardData] {
        var output: [ActivityCardData] = []
        for card in cards {
            guard card.duration > maximumDuration else {
                output.append(card)
                continue
            }

            var cursor = card.startTs
            var part = 1
            while cursor < card.endTs {
                let nextEnd = minDate(cursor.addingTimeInterval(maximumDuration), card.endTs)
                var split = card
                split.id = "\(card.id)-part-\(part)"
                split.startTs = cursor
                split.endTs = nextEnd
                output.append(split)
                cursor = nextEnd
                part += 1
            }
        }
        return output
    }

    private static func closeContinuity(
        _ cards: [ActivityCardData],
        windowStart: Date,
        windowEnd: Date
    ) -> [ActivityCardData] {
        guard !cards.isEmpty else { return [] }
        var output = cards.sorted { $0.startTs < $1.startTs }
        output[0].startTs = windowStart
        for index in output.indices {
            if index > 0 {
                output[index].startTs = output[index - 1].endTs
            }
            if index == output.count - 1 {
                output[index].endTs = windowEnd
            }
        }
        return output.filter { $0.endTs > $0.startTs }
    }

    private static func mergeText(_ left: String, _ right: String) -> String {
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        guard left != right else { return left }
        return "\(left) \(right)"
    }

    private static func minDate(_ left: Date, _ right: Date) -> Date {
        left <= right ? left : right
    }

    private static func maxDate(_ left: Date, _ right: Date) -> Date {
        left >= right ? left : right
    }
}
