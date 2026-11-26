import Foundation
import TranscriptedCore

/// Everything the Stats page shows, built off-main from local capture files.
struct TodaySnapshot: Sendable {
    let overview: TodayStatsOverview
    /// Most recent meetings for the quick-jump list on Stats.
    let recentMeetings: [TodayRecentItem]
    /// Latest captures across kinds; the shell's return signal reads them.
    let recent: [TodayRecentItem]
    let builtAt: Date

    static let empty = TodaySnapshot(overview: .empty, recentMeetings: [], recent: [], builtAt: .distantPast)
}

/// Loads the Stats snapshot off the main thread. Sources are the same local
/// libraries Meetings and Dictations use: bounded meeting metadata
/// (`RecentMeetingsScanner.loadTodayIndex`), cached dictation day counts,
/// and optional writing day files. Nothing leaves the Mac.
@MainActor
final class TodayViewModel: ObservableObject {
    @Published private(set) var snapshot: TodaySnapshot = .empty
    @Published private(set) var hasLoaded = false
    @Published private(set) var isRefreshing = false

    private var refreshTask: Task<Void, Never>?
    private var trailingRefreshTask: Task<Void, Never>?
    private var refreshGeneration = SupersessionEpoch()
    private var captureRefreshObserver: HomeCaptureRefreshObserver?
    nonisolated(unsafe) private var writingObserver: NSObjectProtocol?
    private var lastRefreshStartedAt: Date?
    /// Only the shown page reacts to library changes; the settings view
    /// refreshes it again when it comes back.
    private var isShown = false
    /// The last bounded metadata scan, so unchanged files need no content read.
    private var previousMeetingIndex: [String: RecentMeetingIndexEntry] = [:]
    /// While the window is closed, a finished rebuild waits here instead of
    /// publishing, so the hidden window doesn't re-render. The window
    /// controller drives it (`windowDidClose` / `windowWillShow`).
    private var windowHold = SettingsWindowSnapshotHold<TodaySnapshot>()

    /// How many latest captures the snapshot keeps for the return signal.
    nonisolated static let recentLimit = TodayRecentActivity.pageSize
    /// How many recent meetings the Stats quick-jump list shows.
    nonisolated static let recentMeetingsLimit = 5
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
        writingObserver = NotificationCenter.default.addObserver(
            forName: .writingDayFileDidSave,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor [weak self] in
                guard let self, self.isShown else { return }
                self.refresh()
            }
        }
    }

    deinit {
        if let writingObserver { NotificationCenter.default.removeObserver(writingObserver) }
    }

    func setShown(_ shown: Bool) {
        isShown = shown
    }

    /// Finish an existing read, but do not start more scans for a hidden page.
    func windowDidClose() {
        windowHold.windowDidClose()
        trailingRefreshTask?.cancel()
        trailingRefreshTask = nil
    }

    /// Reuse any read that finished after close, then represent the reveal
    /// refresh before the first frame. Presentation starts the current read.
    func windowWillShow() {
        if let held = windowHold.windowWillShow() { publish(held) }
        isRefreshing = true
    }

    private func publish(_ snapshot: TodaySnapshot) {
        self.snapshot = snapshot
        hasLoaded = true
        isRefreshing = trailingRefreshTask != nil
    }

    /// `force` skips the time throttle, never the single in-flight read.
    /// Presentation explicitly refreshes again, so hidden notifications need no scan.
    func refresh(force: Bool = false) {
        guard windowHold.isWindowOpen else { return }
        let now = Date()
        let skipThrottle = force || TodayClockPolicy.needsRollover(storedDay: snapshot.builtAt, now: now)
        if refreshTask != nil {
            scheduleTrailingRefresh(after: Self.minimumRefreshInterval)
            return
        }
        if !skipThrottle, let delay = passiveRefreshDelay(now: now) {
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
        isRefreshing = false
        isShown = false
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
        isRefreshing = true
        let generation = refreshGeneration.begin()
        let limit = Self.recentLimit
        let meetingsLimit = Self.recentMeetingsLimit
        let previous = previousMeetingIndex
        refreshTask = Task { @MainActor in
            let work = Task.detached(priority: .utility) {
                Self.loadSnapshot(
                    now: Date(),
                    recentLimit: limit,
                    recentMeetingsLimit: meetingsLimit,
                    previousMeetingIndex: previous
                )
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
            guard !Task.isCancelled, let loaded else {
                self.isRefreshing = false
                return
            }
            self.previousMeetingIndex = loaded.meetingIndex
            if let shown = self.windowHold.deliver(loaded.snapshot) {
                self.publish(shown)
            }
        }
    }

    nonisolated private static func loadSnapshot(
        now: Date,
        recentLimit: Int,
        recentMeetingsLimit: Int,
        previousMeetingIndex: [String: RecentMeetingIndexEntry]
    ) -> (snapshot: TodaySnapshot, meetingIndex: [String: RecentMeetingIndexEntry])? {
        let calendar = Calendar.current
        guard let meetingIndex = RecentMeetingsScanner.loadTodayIndex(previous: previousMeetingIndex) else { return nil }
        if Task.isCancelled { return nil }
        let meetingIndexByPath = Dictionary(
            meetingIndex.map { ($0.path, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let meetings = meetingIndex.map(\.item)

        let meetingFacts = meetings.map { item in
            TodayMeetingFact(date: item.date, durationSeconds: durationSeconds(of: item))
        }

        let dictationDays = DictationTranscriptStore
            .savedDictationDayCounts(since: nil, calendar: calendar)
            .map { TodayDictationDayFact(day: $0.day, entries: $0.entries, words: $0.words) }
        if Task.isCancelled { return nil }

        let writing = loadWriting(calendar: calendar)
        if Task.isCancelled { return nil }

        let overview = TodayStatsBuilder.buildOverview(
            meetings: meetingFacts,
            dictationDays: dictationDays,
            writingDays: writing.map(\.summary),
            now: now,
            calendar: calendar
        )

        func meetingItem(_ item: RecentMeetingItem) -> TodayRecentItem {
            TodayRecentItem(
                kind: .meeting,
                id: "meeting-\(item.id)",
                title: item.displayTitle,
                date: item.date,
                durationSeconds: durationSeconds(of: item),
                transcriptURL: item.transcriptURL
            )
        }
        let recentMeetings = Array(meetings.prefix(recentMeetingsLimit).map(meetingItem))
        let recentMeetingsForReturn = Array(meetings.prefix(recentLimit).map(meetingItem))

        let savedDictations = DictationTranscriptStore.recentSavedDictations(limit: recentLimit)
        let recentDictations = savedDictations.map { entry in
            TodayRecentItem(
                kind: .dictation,
                id: TodayRecentItem.dictationIDPrefix + entry.id,
                title: TodayRecentActivity.dictationTitle(text: entry.text, fallback: entry.title),
                date: entry.createdAt,
                durationSeconds: nil,
                transcriptURL: nil,
                preview: entry.text,
                appName: entry.sourceAppName.isEmpty ? nil : entry.sourceAppName,
                words: entry.text.split(whereSeparator: \.isWhitespace).count
            )
        }
        let recentWriting = writing
            .filter { $0.summary.entryCount > 0 }
            .sorted { ($0.summary.latestEntryDate ?? $0.summary.day) > ($1.summary.latestEntryDate ?? $1.summary.day) }
            .prefix(recentLimit)
            .map { entry in
                TodayRecentItem(
                    kind: .writing,
                    id: "writing-\(entry.file.lastPathComponent)",
                    title: "Writing",
                    date: entry.summary.latestEntryDate ?? entry.summary.day,
                    durationSeconds: nil,
                    transcriptURL: entry.file,
                    words: entry.summary.wordCount
                )
            }
        if Task.isCancelled { return nil }

        let merged = TodayRecentActivity.merge(
            meetings: recentMeetingsForReturn,
            dictations: recentDictations,
            writing: recentWriting,
            limit: recentLimit
        )

        let snapshot = TodaySnapshot(
            overview: overview,
            recentMeetings: recentMeetings,
            recent: merged,
            builtAt: now
        )
        return (snapshot, meetingIndexByPath)
    }

    /// Lightweight per-day writing summaries from `Writing_<date>.md` day files
    /// in the capture library's `writing/` folder, cached by file signature.
    nonisolated private static func loadWriting(
        calendar: Calendar
    ) -> [(summary: TodayWritingDaySummary, file: URL)] {
        let folder = FileManager.writingDirectory(in: FileManager.default.transcriptedCaptureLibraryDir)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        let cache = TodayWritingDayFileCache.shared
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.calendar = calendar
        parser.timeZone = calendar.timeZone
        parser.dateFormat = "yyyy-MM-dd"
        var result: [(summary: TodayWritingDaySummary, file: URL)] = []
        var scanned: [URL] = []
        for file in files {
            if Task.isCancelled { return [] }
            let name = file.lastPathComponent
            guard name.hasPrefix("Writing_"), name.hasSuffix(".md"),
                  let parsedDate = parser.date(from: String(name.dropFirst(8).dropLast(3))) else { continue }
            let day = calendar.startOfDay(for: parsedDate)
            scanned.append(file)
            guard let summary = cache.summary(
                for: file,
                day: day,
                signature: TodayWritingDayFileCache.signature(of: file),
                read: { try? String(contentsOf: file, encoding: .utf8) }
            ) else { continue }
            result.append((summary, file))
        }
        cache.retainOnly(scanned)
        return result
    }

    nonisolated private static func durationSeconds(of item: RecentMeetingItem) -> Int? {
        guard let start = item.startDate, let end = item.endDate, end > start else { return nil }
        return Int(end.timeIntervalSince(start).rounded())
    }
}
