import Foundation
import TranscriptedCore

/// Everything the Today page shows, built from local capture files.
struct TodaySnapshot: Sendable {
    let stats: TodayContextStats
    /// Last seven days for the tape, oldest first.
    let tapeDays: [TodayTapeDay]
    let recent: [TodayRecentItem]
    let canLoadMoreRecent: Bool
    let builtAt: Date

    static let empty = TodaySnapshot(stats: .empty, tapeDays: [], recent: [], canLoadMoreRecent: false, builtAt: .distantPast)
}

/// Loads the Today snapshot off the main thread. Sources are the same local
/// libraries Meetings and Dictations use: the cached meeting index
/// (`RecentMeetingsScanner.loadSearchIndex`) and the dictation day files.
/// Nothing leaves the Mac.
@MainActor
final class TodayViewModel: ObservableObject {
    @Published private(set) var snapshot: TodaySnapshot = .empty
    @Published private(set) var hasLoaded = false

    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = SupersessionEpoch()
    private var captureRefreshObserver: HomeCaptureRefreshObserver?

    /// How many Recent context rows to show; Load more adds a page.
    private(set) var recentLimit = TodayRecentActivity.pageSize
    /// Upper bound on the Recent context list, however often Load more is pressed.
    static let maxRecentLimit = 500
    /// Upper bound on dictations read to fill the week's tape.
    static let maxTapeDictations = 1_000

    init() {
        captureRefreshObserver = HomeCaptureRefreshObserver { _ in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
    }

    func loadMoreRecent() {
        guard snapshot.canLoadMoreRecent else { return }
        recentLimit = min(Self.maxRecentLimit, recentLimit + TodayRecentActivity.pageSize)
        refresh()
    }

    func refresh() {
        refreshTask?.cancel()
        let generation = refreshGeneration.begin()
        let limit = recentLimit
        refreshTask = Task { @MainActor in
            let snapshot = await Task.detached(priority: .utility) {
                Self.loadSnapshot(now: Date(), recentLimit: limit)
            }.value
            guard !Task.isCancelled,
                  let snapshot,
                  self.refreshGeneration.finishIfCurrent(generation) else { return }
            self.snapshot = snapshot
            self.hasLoaded = true
        }
    }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration.invalidate()
    }

    nonisolated private static func loadSnapshot(now: Date, recentLimit: Int) -> TodaySnapshot? {
        let calendar = Calendar.current
        guard let meetingIndex = RecentMeetingsScanner.loadSearchIndex() else { return nil }
        if Task.isCancelled { return nil }
        let meetings = meetingIndex.map(\.item).sorted { $0.date > $1.date }

        let meetingFacts = meetings.map { item in
            TodayMeetingFact(date: item.date, durationSeconds: durationSeconds(of: item))
        }

        // Covers both this calendar week and the rolling seven-day tape.
        let todayStart = calendar.startOfDay(for: now)
        let tapeStart = calendar.date(byAdding: .day, value: -(TodayTapeBuilder.dayCount - 1), to: todayStart) ?? todayStart
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? tapeStart
        let lookbackStart = min(tapeStart, weekStart)
        let dictationDays = DictationTranscriptStore
            .savedDictationDayCounts(since: lookbackStart, calendar: calendar)
            .map { TodayDictationDayFact(day: $0.day, entries: $0.entries, words: $0.words) }
        if Task.isCancelled { return nil }

        let stats = TodayStatsBuilder.build(
            meetings: meetingFacts,
            dictationDays: dictationDays,
            now: now,
            calendar: calendar
        )

        func meetingItem(_ item: RecentMeetingItem) -> TodayRecentItem {
            TodayRecentItem(
                kind: .meeting,
                id: "meeting-\(item.id)",
                title: item.title,
                date: item.date,
                durationSeconds: durationSeconds(of: item),
                transcriptURL: item.transcriptURL
            )
        }
        // Meetings are sorted newest first, so the week is a prefix.
        let weekMeetings = meetings.prefix { $0.date >= tapeStart }.map(meetingItem)
        let recentMeetings = meetings.prefix(recentLimit + 1).map(meetingItem)

        // Enough dictation entries to place every one from the last seven days.
        let weekDictationCount = dictationDays.filter { $0.day >= tapeStart }.reduce(0) { $0 + $1.entries }
        let savedDictations = DictationTranscriptStore.recentSavedDictations(
            limit: min(maxTapeDictations, max(recentLimit + 1, weekDictationCount))
        )
        let dictationItems = savedDictations.map { entry in
            TodayRecentItem(
                kind: .dictation,
                id: "dictation-\(entry.id)",
                title: TodayRecentActivity.dictationTitle(text: entry.text, fallback: entry.title),
                date: entry.createdAt,
                durationSeconds: nil,
                transcriptURL: nil
            )
        }
        let tapeDays = TodayTapeBuilder.days(
            captures: weekMeetings + dictationItems.filter { $0.date >= tapeStart },
            now: now,
            calendar: calendar
        )
        let recentDictations = dictationItems.prefix(recentLimit + 1)
        if Task.isCancelled { return nil }

        // One extra row tells us whether Load more has anything to add.
        let merged = TodayRecentActivity.merge(
            meetings: Array(recentMeetings),
            dictations: Array(recentDictations),
            limit: recentLimit + 1
        )

        return TodaySnapshot(
            stats: stats,
            tapeDays: tapeDays,
            recent: Array(merged.prefix(recentLimit)),
            canLoadMoreRecent: merged.count > recentLimit,
            builtAt: now
        )
    }

    nonisolated private static func durationSeconds(of item: RecentMeetingItem) -> Int? {
        guard let start = item.startDate, let end = item.endDate, end > start else { return nil }
        return Int(end.timeIntervalSince(start).rounded())
    }
}
