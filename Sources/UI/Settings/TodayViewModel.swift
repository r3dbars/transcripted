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
    private var trailingRefreshTask: Task<Void, Never>?
    private var refreshGeneration = SupersessionEpoch()
    private var captureRefreshObserver: HomeCaptureRefreshObserver?
    private var lastRefreshStartedAt: Date?
    /// Only the shown page reacts to library changes; the settings view
    /// refreshes it again when it comes back.
    private var isShown = false
    /// The last meeting scan, so the next one only re-reads files that changed
    /// instead of decoding the whole metadata cache (see `loadSearchIndex`).
    private var previousMeetingIndex: [String: RecentMeetingIndexEntry] = [:]

    /// How many Recent context rows to show; Load more adds a page.
    private(set) var recentLimit = TodayRecentActivity.pageSize
    /// Upper bound on the Recent context list, however often Load more is pressed.
    static let maxRecentLimit = 500
    /// Upper bound on dictations read to fill the week's tape.
    static let maxTapeDictations = 1_000
    /// App activation, saves and window opens can each ask for a refresh; a
    /// whole-library scan runs at most this often, with one trailing run so the
    /// last change still shows.
    static let minimumRefreshInterval = SettingsDashboardRefreshPolicy.passiveRefreshMinimumInterval

    init() {
        captureRefreshObserver = HomeCaptureRefreshObserver { _ in
            Task { @MainActor [weak self] in
                guard let self, self.isShown else { return }
                self.refresh()
            }
        }
    }

    func setShown(_ shown: Bool) {
        isShown = shown
    }

    func loadMoreRecent() {
        guard snapshot.canLoadMoreRecent else { return }
        recentLimit = min(Self.maxRecentLimit, recentLimit + TodayRecentActivity.pageSize)
        refresh(force: true)
    }

    /// `force` skips the throttle, for an explicit action like Load more.
    func refresh(force: Bool = false) {
        let now = Date()
        if !force, let delay = passiveRefreshDelay(now: now) {
            scheduleTrailingRefresh(after: delay)
            return
        }
        startRefresh(now: now)
    }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
        trailingRefreshTask?.cancel()
        trailingRefreshTask = nil
        refreshGeneration.invalidate()
        isShown = false
        // Like Meetings, a fresh visit starts from the first page again.
        recentLimit = TodayRecentActivity.pageSize
    }

    private func passiveRefreshDelay(now: Date) -> TimeInterval? {
        if refreshTask != nil { return Self.minimumRefreshInterval }
        guard let lastRefreshStartedAt else { return nil }
        let wait = Self.minimumRefreshInterval - now.timeIntervalSince(lastRefreshStartedAt)
        return wait > 0 ? wait : nil
    }

    private func scheduleTrailingRefresh(after delay: TimeInterval) {
        guard trailingRefreshTask == nil else { return }
        trailingRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.trailingRefreshTask = nil
            self.refresh()
        }
    }

    private func startRefresh(now: Date) {
        trailingRefreshTask?.cancel()
        trailingRefreshTask = nil
        refreshTask?.cancel()
        lastRefreshStartedAt = now
        let generation = refreshGeneration.begin()
        let limit = recentLimit
        let previous = previousMeetingIndex
        refreshTask = Task { @MainActor in
            let work = Task.detached(priority: .utility) {
                Self.loadSnapshot(now: Date(), recentLimit: limit, previousMeetingIndex: previous)
            }
            // A detached task doesn't inherit cancellation; forward it so the
            // `Task.isCancelled` checks in the scan actually stop stale work.
            let loaded = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }
            guard self.refreshGeneration.finishIfCurrent(generation) else { return }
            self.refreshTask = nil
            guard !Task.isCancelled, let loaded else { return }
            self.previousMeetingIndex = loaded.meetingIndex
            self.snapshot = loaded.snapshot
            self.hasLoaded = true
        }
    }

    nonisolated private static func loadSnapshot(
        now: Date,
        recentLimit: Int,
        previousMeetingIndex: [String: RecentMeetingIndexEntry]
    ) -> (snapshot: TodaySnapshot, meetingIndex: [String: RecentMeetingIndexEntry])? {
        let calendar = Calendar.current
        guard let meetingIndex = RecentMeetingsScanner.loadSearchIndex(previous: previousMeetingIndex) else { return nil }
        if Task.isCancelled { return nil }
        let meetingIndexByPath = Dictionary(
            meetingIndex.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
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

        let snapshot = TodaySnapshot(
            stats: stats,
            tapeDays: tapeDays,
            recent: Array(merged.prefix(recentLimit)),
            // At the cap there's nothing more Load more may add.
            canLoadMoreRecent: merged.count > recentLimit && recentLimit < maxRecentLimit,
            builtAt: now
        )
        return (snapshot, meetingIndexByPath)
    }

    nonisolated private static func durationSeconds(of item: RecentMeetingItem) -> Int? {
        guard let start = item.startDate, let end = item.endDate, end > start else { return nil }
        return Int(end.timeIntervalSince(start).rounded())
    }
}
