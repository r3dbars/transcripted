import Foundation

func testTimelineAnalysis() async {
    runSuite("BatchPlanner splits batches on gaps larger than 120 seconds") {
        let base = Date(timeIntervalSince1970: 1_000)
        let screenshots = [
            timelineShot(1, base),
            timelineShot(2, base.addingTimeInterval(60)),
            timelineShot(3, base.addingTimeInterval(181)),
            timelineShot(4, base.addingTimeInterval(250))
        ]

        let plans = BatchPlanner().plan(screenshots: screenshots, now: base.addingTimeInterval(1_000))

        assertEqual(plans.count, 2, "large capture gaps should start a new batch")
        assertEqual(plans[0].screenshots.map(\.id), [1, 2], "first batch should contain pre-gap screenshots")
        assertEqual(plans[1].screenshots.map(\.id), [3, 4], "second batch should contain post-gap screenshots")
    }

    runSuite("BatchPlanner defers a trailing short batch while it is still growing") {
        let base = Date(timeIntervalSince1970: 2_000)
        let screenshots = [
            timelineShot(1, base),
            timelineShot(2, base.addingTimeInterval(120))
        ]

        let plans = BatchPlanner().plan(screenshots: screenshots, now: base.addingTimeInterval(130))

        assertEqual(plans.count, 1, "short trailing capture should still produce a plan")
        assertEqual(plans[0].status, .deferredTrailingShort, "recent trailing short batch should be deferred")
    }

    runSuite("BatchPlanner marks old short batches as skipped_short") {
        let base = Date(timeIntervalSince1970: 3_000)
        let screenshots = [
            timelineShot(1, base),
            timelineShot(2, base.addingTimeInterval(120))
        ]

        let plans = BatchPlanner().plan(screenshots: screenshots, now: base.addingTimeInterval(600))

        assertEqual(plans.count, 1, "old short capture should produce a terminal plan")
        assertEqual(plans[0].status, .skippedShort, "old short batch should be skipped")
    }

    await runSuite("AnalysisScheduler turns fully-idle pending batches into Idle cards without provider calls") {
        let base = Date(timeIntervalSince1970: 4_000)
        let screenshots = stride(from: 0, through: 360, by: 60).enumerated().map { index, offset in
            timelineShot(Int64(index + 1), base.addingTimeInterval(TimeInterval(offset)), idle: 90)
        }
        let failingProvider = MockTimelineLLMProvider(
            cards: [],
            error: TimelineAnalysisFailure(kind: .unknown, reason: "provider should not be called")
        )
        let scheduler = AnalysisScheduler(provider: failingProvider)

        let statuses = await scheduler.analyze(
            screenshots: screenshots,
            observations: [],
            now: base.addingTimeInterval(1_000)
        )

        guard case let .analyzed(cards) = statuses.first else {
            assertTrue(false, "idle batch should analyze into a direct Idle card")
            return
        }
        assertEqual(cards.count, 1, "idle shortcut should create one card")
        assertEqual(cards[0].kind, .idle, "idle shortcut should create an idle card")
        assertEqual(cards[0].category, "Idle", "idle shortcut should use the idle category")
    }

    runSuite("TimelineDayBoundary keys times before 4 AM to the previous logical day") {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let boundary = TimelineDayBoundary(calendar: calendar)
        let beforeFour = date("2026-07-03 03:59:00", timeZone: calendar.timeZone)
        let afterFour = date("2026-07-03 04:00:00", timeZone: calendar.timeZone)

        assertEqual(boundary.day(for: beforeFour), "2026-07-02", "3:59 AM should belong to the prior logical day")
        assertEqual(boundary.day(for: afterFour), "2026-07-03", "4:00 AM should start the new logical day")
    }

    runSuite("TimelineDayBoundary stays stable across DST transitions") {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let boundary = TimelineDayBoundary(calendar: calendar)
        let springBefore = date("2026-03-08 03:30:00", timeZone: calendar.timeZone)
        let fallBefore = date("2026-11-01 03:30:00", timeZone: calendar.timeZone)

        assertEqual(boundary.day(for: springBefore), "2026-03-07", "spring-forward pre-4 AM should still map to prior day")
        assertEqual(boundary.day(for: fallBefore), "2026-10-31", "fall-back pre-4 AM should still map to prior day")
    }

    runSuite("CardGenerator normalizes gaps and overlaps away") {
        let base = Date(timeIntervalSince1970: 10_000)
        let cards = [
            timelineCard(base.addingTimeInterval(120), base.addingTimeInterval(900), title: "Planning"),
            timelineCard(base.addingTimeInterval(840), base.addingTimeInterval(1_800), title: "Build")
        ]

        let normalized = CardGenerator.normalizedCards(
            cards,
            windowStart: base,
            windowEnd: base.addingTimeInterval(1_800)
        )

        assertEqual(normalized.first?.startTs, base, "first card should be extended to window start")
        assertEqual(normalized[0].endTs, normalized[1].startTs, "overlaps should be resolved at one boundary")
        assertEqual(normalized.last?.endTs, base.addingTimeInterval(1_800), "last card should end at window end")
    }

    runSuite("CardGenerator folds sub-10-minute cards into a neighbor") {
        let base = Date(timeIntervalSince1970: 20_000)
        let cards = [
            timelineCard(base, base.addingTimeInterval(900), title: "Build"),
            timelineCard(base.addingTimeInterval(900), base.addingTimeInterval(1_200), title: "Tiny interruption"),
            timelineCard(base.addingTimeInterval(1_200), base.addingTimeInterval(1_800), title: "Review")
        ]

        let normalized = CardGenerator.normalizedCards(
            cards,
            windowStart: base,
            windowEnd: base.addingTimeInterval(1_800)
        )

        assertEqual(normalized.count, 2, "sub-10-minute card should be folded into a neighbor")
        assertEqual(normalized[0].endTs, base.addingTimeInterval(1_200), "short middle card should extend the previous card")
    }

    runSuite("CardGenerator splits cards longer than 60 minutes") {
        let base = Date(timeIntervalSince1970: 30_000)
        let cards = [
            timelineCard(base, base.addingTimeInterval(7_200), title: "Long focus")
        ]

        let normalized = CardGenerator.normalizedCards(
            cards,
            windowStart: base,
            windowEnd: base.addingTimeInterval(7_200)
        )

        assertEqual(normalized.count, 2, "two-hour card should split into one-hour chunks")
        assertTrue(normalized.allSatisfy { $0.duration <= 3_600 }, "split cards should respect max duration")
        assertEqual(normalized[0].endTs, normalized[1].startTs, "split cards should remain continuous")
    }

    runSuite("CardGenerator is merge-biased for adjacent same-stream cards") {
        let base = Date(timeIntervalSince1970: 40_000)
        let cards = [
            timelineCard(base, base.addingTimeInterval(900), title: "Debugging"),
            timelineCard(base.addingTimeInterval(900), base.addingTimeInterval(1_800), title: "debugging")
        ]

        let normalized = CardGenerator.normalizedCards(
            cards,
            windowStart: base,
            windowEnd: base.addingTimeInterval(1_800)
        )

        assertEqual(normalized.count, 1, "same-stream neighboring cards should merge by default")
        assertEqual(normalized[0].startTs, base, "merged card should keep the first start")
        assertEqual(normalized[0].endTs, base.addingTimeInterval(1_800), "merged card should keep the final end")
    }

    runSuite("TimelineCategoryStore normalizes labels case-insensitively and falls back safely") {
        let store = TimelineCategoryStore()

        assertEqual(store.normalizedName(for: "work"), "Work", "category normalization should be case-insensitive")
        assertEqual(store.normalizedName(for: "not-a-category"), "Work", "unknown categories should fall back to the first descriptor")
    }

    runSuite("CardGenerator replacement filter leaves meeting and dictation cards alone") {
        let base = Date(timeIntervalSince1970: 50_000)
        let cards = [
            timelineCard(base, base.addingTimeInterval(600), kind: .activity, title: "Work"),
            timelineCard(base.addingTimeInterval(600), base.addingTimeInterval(1_200), kind: .idle, title: "Idle", category: "Idle"),
            timelineCard(base.addingTimeInterval(1_200), base.addingTimeInterval(1_800), kind: .meeting, title: "Standup", category: "Meetings"),
            timelineCard(base.addingTimeInterval(1_800), base.addingTimeInterval(2_400), kind: .dictation, title: "Notes", category: "Meetings")
        ]

        let replaceable = CardGenerator.cardsToReplace(in: cards)

        assertEqual(replaceable.map(\.kind), [.activity, .idle], "regen should only replace activity and idle cards")
    }

    await runSuite("Provider stubs are inert and classify rate limits without network calls") {
        let base = Date(timeIntervalSince1970: 60_000)
        let context = TimelineCardGenerationContext(
            windowStart: base,
            windowEnd: base.addingTimeInterval(900),
            existingCards: [],
            fixedCards: [],
            categories: TimelineCategoryStore.defaults
        )

        do {
            _ = try await GeminiProvider(hasUserConsent: false).generateCards(observations: [], context: context)
            assertTrue(false, "Gemini stub should not generate without explicit consent")
        } catch {
            assertEqual(TimelineProviderFailureClassifier.classify(error), .unavailable, "disabled Gemini stub should be unavailable")
        }

        let rateLimit = TimelineAnalysisFailure(kind: .rateLimited, reason: "HTTP 429 quota")
        assertEqual(TimelineProviderFailureClassifier.classify(rateLimit), .rateLimited, "rate-limit errors should stay classified")
    }
}

private func timelineShot(
    _ id: Int64,
    _ capturedAt: Date,
    idle: TimeInterval = 0
) -> TimelineScreenshot {
    TimelineScreenshot(
        id: id,
        capturedAt: capturedAt,
        idleSecondsAtCapture: idle,
        appBundleID: "app.\(id)",
        appName: "App \(id)",
        windowTitle: "Window \(id)"
    )
}

private func timelineCard(
    _ start: Date,
    _ end: Date,
    kind: TimelineCardKind = .activity,
    title: String,
    category: String = "Work"
) -> ActivityCardData {
    ActivityCardData(
        id: title.lowercased().replacingOccurrences(of: " ", with: "-"),
        startTs: start,
        endTs: end,
        kind: kind,
        title: title,
        summary: title,
        category: category
    )
}

private func date(_ rawValue: String, timeZone: TimeZone) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter.date(from: rawValue)!
}
