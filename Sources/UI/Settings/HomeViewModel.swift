import SwiftUI
import TranscriptedCore

// MARK: - View model

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var dictationDaySections: [HomeDaySection<SavedDictationEntry>] = []
    @Published private(set) var meetingDaySections: [HomeDaySection<RecentMeetingItem>] = []
    @Published private(set) var todayDictationCount: Int = 0
    @Published private(set) var todayMeetingCount: Int = 0
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isLoadingMore: Bool = false
    @Published private(set) var canLoadMoreDictations: Bool = false
    @Published private(set) var canLoadMoreMeetings: Bool = false
    /// Set when the meetings-folder scan hits a damaged/broken path. Drives the
    /// Home warning card. `nil` for the normal empty/loaded state.
    @Published private(set) var scanWarning: HomeScanWarningCardModel?
    /// Matches across every saved meeting for the Home search box. `nil` while
    /// no search is active, or before the first search pass for a query lands
    /// (the view keeps filtering the loaded slice until then).
    @Published private(set) var meetingSearchResults: [RecentMeetingItem]?
    @Published private(set) var isSearchingMeetings: Bool = false
    @Published private(set) var canLoadMoreMeetingSearchResults: Bool = false

    // Once the user dismisses the warning we stay quiet until they explicitly
    // retry or re-enter Home (`refresh()`), so a silent background reload does
    // not keep re-raising the same card they just cleared.
    private var scanWarningDismissed = false

    private var refreshTask: Task<Void, Never>?
    private var refreshState = CoalescedRefreshState(isEnabled: false)
    private var pendingLoadIsInitial = false
    private var pendingLoadIsSilent = true
    private var refreshGeneration = SupersessionEpoch()
    private var dictationLimit = 10
    private var meetingLimit = 10
    private var didTrackActivationReturnProxy = false
    private var captureRefreshObserver: HomeCaptureRefreshObserver?

    private var meetingSearchQuery = ""
    private var meetingSearchLimit = HomeMeetingSearchPaging.pageSize
    private var meetingSearchIndex: HomeMeetingSearchIndex?
    private var meetingSearchIndexIsStale = true
    private var meetingSearchTask: Task<Void, Never>?
    private var meetingSearchGeneration = SupersessionEpoch()

    init() {
        // Background post-save work (WAV->M4A recompression, transcript rename)
        // rewrites the files whose URLs this cache resolved at scan time. Re-resolve
        // from disk whenever that happens so cached transcript/audio URLs never
        // outlive the real files. The broadcaster is already debounced.
        captureRefreshObserver = HomeCaptureRefreshObserver { _ in
            Task { @MainActor [weak self] in
                self?.refreshAfterCaptureArtifactsChanged()
            }
        }
    }

    func setShown(_ shown: Bool) {
        let revealed = shown && !refreshState.isEnabled
        refreshState.isEnabled = shown
        // A change held while Home was hidden reads now. The view's reveal
        // refresh can be throttled, so it can't be the only thing that starts
        // it, and nothing claims a load is running unless one starts.
        if revealed, refreshState.startPending() { startCurrentLimitsLoad() }
        if !shown {
            meetingSearchTask?.cancel()
            meetingSearchGeneration.invalidate()
            isSearchingMeetings = false
        }
    }

    /// Silent re-resolution of the currently visible captures after the on-disk
    /// artifacts changed underneath the cache. Keeps the current paging window and
    /// avoids flipping the loading spinners so a passive background refresh does
    /// not flash the UI.
    func refreshAfterCaptureArtifactsChanged() {
        loadCurrentLimits(isInitialLoad: false, isSilent: true)
        invalidateMeetingSearchIndex()
    }

    // Settings Home must open instantly, even for users with thousands of dictations.
    // Keep the dashboard to a small recent slice and leave deep history to the dedicated pages/files.
    private let initialDictationLimit = 10
    private let initialMeetingLimit = 10

    func refresh() {
        dictationLimit = initialDictationLimit
        meetingLimit = initialMeetingLimit
        scanWarningDismissed = false
        isLoading = true
        loadCurrentLimits(isInitialLoad: true)
        invalidateMeetingSearchIndex()
    }

    /// Retry from the scan warning card: clear the dismissed latch and reload
    /// from disk so a fixed path clears the card on its own.
    func retryScan() {
        refresh()
    }

    func dismissScanWarning() {
        scanWarning = nil
        scanWarningDismissed = true
    }

    func removeVisibleMeeting(id: String) {
        meetingSearchIndex?.removeMeeting(id: id)
        meetingSearchResults?.removeAll { $0.id == id }
        if isSearchingMeetings {
            // An in-flight pass captured the index before this removal and
            // would publish it back; restart it on the trimmed index.
            runMeetingSearch(debounce: false)
        }

        var didRemove = false
        meetingDaySections = meetingDaySections.compactMap { section in
            let remainingItems = section.items.filter { item in
                let shouldKeep = item.id != id
                if !shouldKeep {
                    didRemove = true
                }
                return shouldKeep
            }
            guard !remainingItems.isEmpty else { return nil }
            return HomeDaySection(day: section.day, label: section.label, items: remainingItems)
        }

        guard didRemove else { return }
        todayMeetingCount = meetingDaySections
            .flatMap(\.items)
            .filter { Calendar.current.isDateInToday($0.date) }
            .count
    }

    func loadMoreDictations() {
        guard !isLoading, !isLoadingMore, canLoadMoreDictations else { return }
        dictationLimit += initialDictationLimit
        loadCurrentLimits(isInitialLoad: false)
    }

    func loadMoreMeetings() {
        guard !isLoading, !isLoadingMore, canLoadMoreMeetings else { return }
        meetingLimit += initialMeetingLimit
        loadCurrentLimits(isInitialLoad: false)
    }

    // MARK: - Meetings search

    /// Search every saved meeting, not just the loaded slice. Called on each
    /// edit of the Home search box; typing is debounced, and the index is
    /// built once and then reused until captures change on disk.
    func updateMeetingSearch(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != meetingSearchQuery else { return }
        meetingSearchQuery = trimmed
        meetingSearchLimit = HomeMeetingSearchPaging.pageSize
        // Keep the previous results on screen until this query's pass lands:
        // the view re-applies the current query to them, so they can't show a
        // non-match, and clearing them would flash the list on every pause.
        // An emptied query clears them in `runMeetingSearch`. Their Load more
        // belongs to the old query, though.
        canLoadMoreMeetingSearchResults = false
        runMeetingSearch(debounce: true)
    }

    func loadMoreMeetingSearchResults() {
        guard !meetingSearchQuery.isEmpty, !isSearchingMeetings, canLoadMoreMeetingSearchResults else { return }
        meetingSearchLimit += HomeMeetingSearchPaging.pageSize
        runMeetingSearch(debounce: false)
    }

    /// Captures changed on disk (or Home was re-entered). Rebuild lazily: right
    /// away if a search is showing, otherwise on the next search.
    private func invalidateMeetingSearchIndex() {
        meetingSearchIndexIsStale = true
        if refreshState.isEnabled, !meetingSearchQuery.isEmpty {
            runMeetingSearch(debounce: false)
        }
    }

    private func runMeetingSearch(debounce: Bool) {
        meetingSearchTask?.cancel()
        let query = meetingSearchQuery
        guard !query.isEmpty else {
            meetingSearchTask = nil
            meetingSearchGeneration.invalidate()
            meetingSearchResults = nil
            isSearchingMeetings = false
            canLoadMoreMeetingSearchResults = false
            return
        }

        guard refreshState.isEnabled else { return }
        let generation = meetingSearchGeneration.begin()
        let limit = meetingSearchLimit
        let existingIndex = meetingSearchIndex
        // A new day makes the cached "Today"/"Yesterday" words wrong.
        let needsRebuild = meetingSearchIndexIsStale
            || existingIndex == nil
            || existingIndex?.isCurrent() == false
        isSearchingMeetings = true

        meetingSearchTask = Task { @MainActor in
            if debounce {
                try? await Task.sleep(nanoseconds: HomeMeetingSearchPaging.debounceNanoseconds)
                guard !Task.isCancelled else { return }
            }

            let work = Task.detached(priority: .userInitiated) { () -> (HomeMeetingSearchIndex, HomeMeetingSearchIndex.SearchResult)? in
                let index: HomeMeetingSearchIndex
                if !needsRebuild, let existingIndex {
                    index = existingIndex
                } else {
                    guard let scanned = RecentMeetingsScanner.loadSearchIndex(
                        previous: existingIndex?.scannedEntriesByPath ?? [:]
                    ) else { return nil }
                    index = HomeMeetingSearchIndex(scanned: scanned, previous: existingIndex)
                }
                guard !Task.isCancelled else { return nil }
                let found = index.search(query: query, limit: limit)
                // Audio is resolved only for the rows that will show.
                let withAudio = found.items.map { item in
                    item.withAudio(MeetingAudioArchiveResolver.attachment(forTranscript: item.transcriptURL))
                }
                guard !Task.isCancelled else { return nil }
                return (index, HomeMeetingSearchIndex.SearchResult(items: withAudio, hasMore: found.hasMore))
            }
            let outcome = await withTaskCancellationHandler {
                await work.value
            } onCancel: {
                work.cancel()
            }

            guard !Task.isCancelled,
                  let outcome,
                  self.meetingSearchGeneration.finishIfCurrent(generation) else {
                return
            }
            self.meetingSearchIndex = outcome.0
            if needsRebuild {
                self.meetingSearchIndexIsStale = false
            }
            self.meetingSearchResults = outcome.1.items
            self.canLoadMoreMeetingSearchResults = outcome.1.hasMore
            self.isSearchingMeetings = false
        }
    }

    private func loadCurrentLimits(isInitialLoad: Bool, isSilent: Bool = false) {
        pendingLoadIsInitial = pendingLoadIsInitial || isInitialLoad
        pendingLoadIsSilent = pendingLoadIsSilent && isSilent
        guard refreshState.request() else { return }
        startCurrentLimitsLoad()
    }

    private func startCurrentLimitsLoad() {
        let generation = refreshGeneration.begin()
        isLoading = pendingLoadIsInitial && !pendingLoadIsSilent
        isLoadingMore = !pendingLoadIsInitial && !pendingLoadIsSilent
        pendingLoadIsInitial = false
        pendingLoadIsSilent = true
        let requestedDictationLimit = dictationLimit
        let requestedMeetingLimit = meetingLimit
        refreshTask = Task { @MainActor in
            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: requestedDictationLimit + 1,
                meetingLimit: requestedMeetingLimit + 1,
                dictationCountScope: .todayOnly
            )
            defer {
                self.refreshTask = nil
                if self.refreshState.finished() { self.startCurrentLimitsLoad() }
            }
            guard !Task.isCancelled, self.refreshGeneration.finishIfCurrent(generation) else {
                return
            }
            self.scanWarning = self.scanWarningDismissed
                ? nil
                : HomeScanWarningPolicy.card(for: snapshot.meetingScanDiagnosis)
            let visibleDictations = Array(snapshot.dictations.prefix(requestedDictationLimit))
            let visibleMeetings = Array(snapshot.meetings.prefix(requestedMeetingLimit))
            let calendar = Calendar.current
            self.todayDictationCount = snapshot.todayDictationCount ?? 0
            self.todayMeetingCount = visibleMeetings.lazy.filter { calendar.isDateInToday($0.listDate) }.count
            self.dictationDaySections = Self.groupByDay(visibleDictations, dateForItem: \.createdAt)
            self.meetingDaySections = Self.groupByDay(visibleMeetings, dateForItem: \.listDate)
            self.canLoadMoreDictations = snapshot.dictations.count > requestedDictationLimit
            self.canLoadMoreMeetings = snapshot.meetings.count > requestedMeetingLimit
            self.trackActivationReturnProxyIfNeeded(
                dictations: visibleDictations,
                meetings: visibleMeetings
            )
            self.isLoading = false
            self.isLoadingMore = false
        }
    }

    func cancel() {
        setShown(false)
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration.invalidate()
        isLoading = false
        isLoadingMore = false
        // Forget the query too: the view re-sends it on appear, and a stale
        // query here would swallow that call as "unchanged".
        meetingSearchQuery = ""
        runMeetingSearch(debounce: false)
    }

    // MARK: - Helpers

    static func groupByDay<Item>(
        _ items: [Item],
        dateForItem: (Item) -> Date
    ) -> [HomeDaySection<Item>] {
        let calendar = Calendar.current
        var buckets: [(day: Date, items: [Item])] = []

        for item in items {
            let day = calendar.startOfDay(for: dateForItem(item))
            if let lastIndex = buckets.indices.last, buckets[lastIndex].day == day {
                buckets[lastIndex].items.append(item)
            } else if let existing = buckets.firstIndex(where: { $0.day == day }) {
                buckets[existing].items.append(item)
            } else {
                buckets.append((day: day, items: [item]))
            }
        }

        return buckets.map { bucket in
            HomeDaySection(day: bucket.day, label: dayLabel(for: bucket.day), items: bucket.items)
        }
    }

    private static func dayLabel(for day: Date) -> String {
        HomeDaySectionLabel.label(for: day)
    }

    private func trackActivationReturnProxyIfNeeded(
        dictations: [SavedDictationEntry],
        meetings: [RecentMeetingItem]
    ) {
        let dictationCandidates = dictations.map { entry in
            (kind: ActivationTelemetry.ArtifactKind.dictation, date: entry.createdAt)
        }
        let meetingCandidates = meetings.map { item in
            (kind: ActivationTelemetry.ArtifactKind.meeting, date: item.date)
        }
        trackActivationReturnProxyIfNeeded(candidates: dictationCandidates + meetingCandidates, surface: .home)
    }

    /// Today is the page the window opens on, so it reports the return signal
    /// through the same once-per-window latch as Meetings.
    func trackActivationReturnProxyIfNeeded(todayRecent: [TodayRecentItem]) {
        let candidates = todayRecent.map { item in
            (
                kind: item.kind == .meeting
                    ? ActivationTelemetry.ArtifactKind.meeting
                    : ActivationTelemetry.ArtifactKind.dictation,
                date: item.date
            )
        }
        trackActivationReturnProxyIfNeeded(candidates: candidates, surface: .today)
    }

    private func trackActivationReturnProxyIfNeeded(
        candidates: [(kind: ActivationTelemetry.ArtifactKind, date: Date)],
        surface: ActivationTelemetry.Surface
    ) {
        guard !didTrackActivationReturnProxy else { return }
        guard let latest = candidates.max(by: { $0.date < $1.date }) else {
            return
        }

        didTrackActivationReturnProxy = ActivationTelemetry.trackReturnProxyIfEligible(
            priorArtifactKind: latest.kind,
            priorArtifactDate: latest.date,
            surface: surface
        )
        if didTrackActivationReturnProxy {
            let artifactCount = candidates.count
            ActivationTelemetry.trackHabitLoopAction(
                actionKind: artifactCount >= 2 ? .returnAfterSecondArtifact : .returnAfterFirstArtifact,
                surface: surface,
                artifactKind: latest.kind,
                artifactDate: latest.date,
                artifactCount: artifactCount
            )
        }
    }

}
