import Foundation

@MainActor
func testMeetingPromptCalendarRefresh() async {
    await runSuite("Forced calendar refreshes during one fetch coalesce and retain the newer snapshot") {
        let fetcher = CalendarRefreshFetchFixture()
        let detector = fetcher.makeDetector()
        let first = Task { @MainActor in await detector.evaluate() }
        await fetcher.waitForFirstFetch()

        await detector.evaluate(forceCalendarRefresh: true)
        await detector.evaluate(forceCalendarRefresh: true)
        await detector.evaluate(forceCalendarRefresh: true)
        assertEqual(fetcher.fetchCount, 1, "force requests must not overlap the held fetch")

        fetcher.releaseFirstFetch()
        await first.value
        assertEqual(fetcher.fetchCount, 2, "a burst of invalidations needs exactly one follow-up")
        assertEqual(fetcher.maximumConcurrentFetches, 1)
        assertEqual(detector.calendarEventSnapshots.map(\.id), ["synthetic-calendar-2"],
                    "the follow-up snapshot must replace the first result")
    }

    await runSuite("Ordinary calendar evaluations reuse a fetch already in flight") {
        let fetcher = CalendarRefreshFetchFixture()
        let detector = fetcher.makeDetector()
        let first = Task { @MainActor in await detector.evaluate() }
        await fetcher.waitForFirstFetch()

        await detector.evaluate()
        await detector.evaluate()
        await detector.evaluate()
        assertEqual(fetcher.fetchCount, 1)

        fetcher.releaseFirstFetch()
        await first.value
        assertEqual(fetcher.fetchCount, 1, "ordinary requests do not dirty the calendar cache")
        assertEqual(fetcher.maximumConcurrentFetches, 1)
        assertEqual(detector.calendarEventSnapshots.map(\.id), ["synthetic-calendar-1"])
    }

    await runSuite("Revoked calendar permission rejects a suspended result and regrant refreshes immediately") {
        let fetcher = CalendarRefreshFetchFixture()
        let detector = fetcher.makeDetector()
        let first = Task { @MainActor in await detector.evaluate() }
        await fetcher.waitForFirstFetch()

        fetcher.permissionGranted = false
        await detector.evaluate()
        fetcher.releaseFirstFetch()
        await first.value
        assertTrue(detector.calendarEventSnapshots.isEmpty,
                   "a pre-revocation fetch must not repopulate the calendar cache")
        assertEqual(fetcher.fetchCount, 1, "revocation must not start another fetch")

        // Request again on regrant without sleeping out the cache lifetime.
        fetcher.permissionGranted = true
        await detector.evaluate()
        assertEqual(fetcher.fetchCount, 2, "regrant must not reuse the rejected result's freshness")
        assertEqual(fetcher.maximumConcurrentFetches, 1)
        assertEqual(detector.calendarEventSnapshots.map(\.id), ["synthetic-calendar-2"])
    }

    await runSuite("A forced refresh during the follow-up fetch is retained for the next snapshot") {
        let fetcher = CalendarRefreshFetchFixture()
        let detector = fetcher.makeDetector()
        fetcher.duringSecondFetch = { [weak detector] in
            assertTrue(detector?.calendarEventSnapshots.isEmpty == true,
                       "an invalidated result must stay unpublished while its follow-up is fetched")
            await detector?.evaluate(forceCalendarRefresh: true)
        }
        defer { fetcher.duringSecondFetch = nil }
        let first = Task { @MainActor in await detector.evaluate() }
        await fetcher.waitForFirstFetch()

        await detector.evaluate(forceCalendarRefresh: true)
        fetcher.releaseFirstFetch()
        await first.value
        assertEqual(fetcher.fetchCount, 3, "a new invalidation during the follow-up requires a third fetch")
        assertEqual(fetcher.maximumConcurrentFetches, 1)
        assertEqual(detector.calendarEventSnapshots.map(\.id), ["synthetic-calendar-3"])
    }
}

/// An EventKit-like suspended fetch, entirely in memory. Only the first call
/// waits for the test; later calls complete immediately, so missing follow-ups
/// fail through counts/cache output instead of leaving a test waiting for them.
@MainActor
private final class CalendarRefreshFetchFixture {
    var permissionGranted = true
    private(set) var fetchCount = 0
    private(set) var maximumConcurrentFetches = 0
    var duringSecondFetch: (() async -> Void)?

    private var activeFetches = 0
    private var firstEntered = false
    private var firstEntryWaiters: [CheckedContinuation<Void, Never>] = []
    private var firstCompletion: CheckedContinuation<[MeetingPromptCalendarEventSnapshot], Never>?
    private var firstSnapshot: MeetingPromptCalendarEventSnapshot?

    func makeDetector() -> MeetingPromptDetector {
        let detector = MeetingPromptDetector(
            calendarAccessGranted: { [self] in permissionGranted },
            calendarEventSnapshots: [],
            refreshesCalendarEventSnapshots: true,
            fetchCalendarEventSnapshots: { [self] start, end in await fetch(start: start, end: end) },
            learnedBackoffDefaults: nil,
            meetingShortcutDisplay: { "synthetic-shortcut" }
        )
        detector.frontmostBundleIDProvider = { nil }
        detector.runningBundleIDsProvider = { [] }
        detector.browserWindowTitlesProvider = { _ in [] }
        detector.callShortcutProvider = { _ in nil }
        detector.isAutoRecordEnabled = { false }
        detector.isOwnCaptureActive = { false }
        return detector
    }

    func waitForFirstFetch() async {
        guard !firstEntered else { return }
        await withCheckedContinuation { firstEntryWaiters.append($0) }
    }

    func releaseFirstFetch() {
        guard let completion = firstCompletion, let snapshot = firstSnapshot else {
            assertTrue(false, "the first synthetic fetch must be held before release")
            return
        }
        firstCompletion = nil
        firstSnapshot = nil
        completion.resume(returning: [snapshot])
    }

    private func fetch(start: Date, end: Date) async -> [MeetingPromptCalendarEventSnapshot] {
        fetchCount += 1
        let ordinal = fetchCount
        activeFetches += 1
        maximumConcurrentFetches = max(maximumConcurrentFetches, activeFetches)
        defer { activeFetches -= 1 }
        // The middle of this query window is hours beyond the prompt lead
        // window, while remaining a plausible result from the calendar reader.
        let midpoint = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
        let snapshot = MeetingPromptCalendarEventSnapshot(
            id: "synthetic-calendar-\(ordinal)",
            title: "Synthetic calendar fixture",
            startDate: midpoint,
            endDate: midpoint.addingTimeInterval(600),
            isAllDay: false,
            url: URL(string: "https://zoom.us/j/123"),
            location: nil,
            notes: nil
        )
        if ordinal == 1 {
            firstSnapshot = snapshot
            return await withCheckedContinuation { completion in
                firstCompletion = completion
                firstEntered = true
                let waiters = firstEntryWaiters
                firstEntryWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
        if ordinal == 2 { await duringSecondFetch?() }
        return [snapshot]
    }
}
