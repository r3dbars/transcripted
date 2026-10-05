import Foundation
import TranscriptedCore

/// Everything the Today page shows, built from local capture files.
struct TodaySnapshot: Sendable {
    let stats: TodayContextStats
    /// Last seven days for the tape, oldest first.
    let tapeDays: [TodayTapeDay]
    /// Latest captures across kinds; the shell's return signal reads them.
    let recent: [TodayRecentItem]
    let builtAt: Date

    static let empty = TodaySnapshot(stats: .empty, tapeDays: [], recent: [], builtAt: .distantPast)
}

/// Loads the Today snapshot off the main thread. Sources are the same local
/// libraries Meetings and Dictations use: bounded meeting metadata
/// (`RecentMeetingsScanner.loadTodayIndex`), the dictation day files, and
/// Save my writing's day files.
/// Nothing leaves the Mac.
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
    /// Upper bound on dictations read to fill the week's tape.
    nonisolated static let maxTapeDictations = 1_000
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
        // Set before the retained view becomes visible: an old empty snapshot
        // must not announce "Nothing captured" while the reveal read is pending.
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
        if refreshTask != nil {
            scheduleTrailingRefresh(after: Self.minimumRefreshInterval)
            return
        }
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

        // Covers both this calendar week and the rolling seven-day tape.
        let todayStart = calendar.startOfDay(for: now)
        let tapeStart = calendar.date(byAdding: .day, value: -(TodayTapeBuilder.dayCount - 1), to: todayStart) ?? todayStart
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? tapeStart
        let lookbackStart = min(tapeStart, weekStart)
        let dictationDays = DictationTranscriptStore
            .savedDictationDayCounts(since: lookbackStart, calendar: calendar)
            .map { TodayDictationDayFact(day: $0.day, entries: $0.entries, words: $0.words) }
        if Task.isCancelled { return nil }
        let writing = loadWriting(since: lookbackStart, calendar: calendar)
        if Task.isCancelled { return nil }

        let stats = TodayStatsBuilder.build(
            meetings: meetingFacts,
            dictationDays: dictationDays,
            writing: writing.map(\.fact),
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
        let recentMeetings = meetings.prefix(recentLimit).map(meetingItem)

        // Enough dictation entries to place every one from the last seven days.
        let weekDictationCount = dictationDays.filter { $0.day >= tapeStart }.reduce(0) { $0 + $1.entries }
        let savedDictations = DictationTranscriptStore.recentSavedDictations(
            limit: min(maxTapeDictations, max(recentLimit, weekDictationCount))
        )
        let dictationItems = savedDictations.map { entry in
            TodayRecentItem(
                kind: .dictation,
                id: "dictation-\(entry.id)",
                title: TodayRecentActivity.dictationTitle(text: entry.text, fallback: entry.title),
                date: entry.createdAt,
                durationSeconds: nil,
                transcriptURL: nil,
                preview: entry.text,
                appName: entry.sourceAppName.isEmpty ? nil : entry.sourceAppName,
                words: entry.text.split(whereSeparator: \.isWhitespace).count
            )
        }
        let writingItems = writing.map { entry in
            TodayRecentItem(
                kind: .writing,
                id: "writing-\(entry.fact.entryID)",
                title: TodayWritingParser.title(for: entry.fact.text),
                date: entry.fact.date,
                durationSeconds: TodayWritingParser.estimatedSeconds(words: entry.fact.words),
                transcriptURL: entry.file,
                preview: entry.fact.text,
                appName: entry.fact.appName,
                words: entry.fact.words,
                acceptedWords: entry.fact.acceptedWords
            )
        }.sorted { $0.date > $1.date }
        let tapeDays = TodayTapeBuilder.days(
            captures: weekMeetings + dictationItems.filter { $0.date >= tapeStart } + writingItems.filter { $0.date >= tapeStart },
            now: now,
            calendar: calendar
        )
        let recentDictations = dictationItems.prefix(recentLimit)
        if Task.isCancelled { return nil }

        let merged = TodayRecentActivity.merge(
            meetings: Array(recentMeetings),
            dictations: Array(recentDictations),
            writing: Array(writingItems.prefix(recentLimit)),
            limit: recentLimit
        )

        let snapshot = TodaySnapshot(
            stats: stats,
            tapeDays: tapeDays,
            recent: merged,
            builtAt: now
        )
        return (snapshot, meetingIndexByPath)
    }

    /// Writing entries from day files on or after `since`. Reads only the
    /// `Writing_<date>.md` files in the capture library's `writing/` folder.
    nonisolated private static func loadWriting(
        since: Date,
        calendar: Calendar
    ) -> [(fact: TodayWritingFact, file: URL)] {
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
        let firstDay = calendar.startOfDay(for: since)
        var result: [(fact: TodayWritingFact, file: URL)] = []
        var scanned: [URL] = []
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix("Writing_"), name.hasSuffix(".md"),
                  let day = parser.date(from: String(name.dropFirst(8).dropLast(3))),
                  day >= firstDay else { continue }
            scanned.append(file)
            // Unchanged day files reuse their last parse.
            guard let facts = cache.facts(
                for: file,
                signature: TodayWritingDayFileCache.signature(of: file),
                read: { try? String(contentsOf: file, encoding: .utf8) }
            ) else { continue }
            if Task.isCancelled { return [] }
            result += facts
                .filter { $0.date >= since }
                .map { ($0, file) }
        }
        cache.retainOnly(scanned)
        return result
    }

    nonisolated private static func durationSeconds(of item: RecentMeetingItem) -> Int? {
        guard let start = item.startDate, let end = item.endDate, end > start else { return nil }
        return Int(end.timeIntervalSince(start).rounded())
    }
}
