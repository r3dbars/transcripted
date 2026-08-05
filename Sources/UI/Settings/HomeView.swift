import AppKit
import SwiftUI
import TranscriptedCore

// MARK: - View model

@MainActor
final class HomeViewModel: ObservableObject {
    @Published private(set) var dictationDaySections: [HomeDaySection<SavedDictationEntry>] = []
    @Published private(set) var meetingDaySections: [HomeDaySection<RecentMeetingItem>] = []
    @Published private(set) var recentDictationCount: Int = 0
    @Published private(set) var recentMeetingCount: Int = 0
    @Published private(set) var totalDictationCount: Int = 0
    @Published private(set) var totalDictationWordCount: Int = 0
    @Published private(set) var todayDictationCount: Int = 0
    @Published private(set) var todayMeetingCount: Int = 0
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var isLoadingMore: Bool = false
    @Published private(set) var canLoadMoreDictations: Bool = false
    @Published private(set) var canLoadMoreMeetings: Bool = false
    /// Set when the meetings-folder scan hits a damaged/broken path. Drives the
    /// Home warning card. `nil` for the normal empty/loaded state.
    @Published private(set) var scanWarning: HomeScanWarningCardModel?

    // Once the user dismisses the warning we stay quiet until they explicitly
    // retry or re-enter Home (`refresh()`), so a silent background reload does
    // not keep re-raising the same card they just cleared.
    private var scanWarningDismissed = false

    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = SupersessionEpoch()
    private var dictationLimit = 10
    private var meetingLimit = 10
    private var didTrackActivationReturnProxy = false
    private var captureRefreshObserver: HomeCaptureRefreshObserver?

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

    /// Silent re-resolution of the currently visible captures after the on-disk
    /// artifacts changed underneath the cache. Keeps the current paging window and
    /// avoids flipping the loading spinners so a passive background refresh does
    /// not flash the UI.
    func refreshAfterCaptureArtifactsChanged() {
        loadCurrentLimits(isInitialLoad: false, isSilent: true)
    }

    // Settings Home must open instantly, even for users with thousands of dictations.
    // Keep the dashboard to a small recent slice and leave deep history to the dedicated pages/files.
    private let initialDictationLimit = 10
    private let initialMeetingLimit = 10

    var welcomeName: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return "there" }
        return full.split(separator: " ").first.map(String.init) ?? full
    }

    func refresh() {
        refreshTask?.cancel()
        dictationLimit = initialDictationLimit
        meetingLimit = initialMeetingLimit
        scanWarningDismissed = false
        isLoading = true
        loadCurrentLimits(isInitialLoad: true)
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

    func reloadVisibleContent() {
        loadCurrentLimits(isInitialLoad: false)
    }

    func removeVisibleMeeting(id: String) {
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
        recentMeetingCount = max(0, recentMeetingCount - 1)
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

    private func loadCurrentLimits(isInitialLoad: Bool, isSilent: Bool = false) {
        refreshTask?.cancel()
        let generation = refreshGeneration.begin()
        isLoading = isInitialLoad && !isSilent
        isLoadingMore = !isInitialLoad && !isSilent
        let requestedDictationLimit = dictationLimit
        let requestedMeetingLimit = meetingLimit
        refreshTask = Task { @MainActor in
            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: requestedDictationLimit + 1,
                meetingLimit: requestedMeetingLimit + 1,
                includeDictationCounts: true
            )
            let diagnosis = await Task.detached(priority: .utility) {
                RecentMeetingsScanner.diagnose()
            }.value
            guard !Task.isCancelled, self.refreshGeneration.finishIfCurrent(generation) else {
                return
            }
            self.scanWarning = self.scanWarningDismissed
                ? nil
                : HomeScanWarningPolicy.card(for: diagnosis)
            let visibleDictations = Array(snapshot.dictations.prefix(requestedDictationLimit))
            let visibleMeetings = Array(snapshot.meetings.prefix(requestedMeetingLimit))
            let calendar = Calendar.current
            self.recentDictationCount = visibleDictations.count
            self.recentMeetingCount = visibleMeetings.count
            self.totalDictationCount = snapshot.dictationCounts.total
            self.totalDictationWordCount = snapshot.dictationCounts.totalWords
            self.todayDictationCount = snapshot.dictationCounts.today
            self.todayMeetingCount = visibleMeetings.lazy.filter { calendar.isDateInToday($0.date) }.count
            self.dictationDaySections = Self.groupByDay(visibleDictations, dateForItem: \.createdAt)
            self.meetingDaySections = Self.groupByDay(visibleMeetings, dateForItem: \.date)
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
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration.invalidate()
        isLoading = false
        isLoadingMore = false
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
        guard !didTrackActivationReturnProxy else { return }

        let dictationCandidates = dictations.map { entry in
            (kind: ActivationTelemetry.ArtifactKind.dictation, date: entry.createdAt)
        }
        let meetingCandidates = meetings.map { item in
            (kind: ActivationTelemetry.ArtifactKind.meeting, date: item.date)
        }
        guard let latest = (dictationCandidates + meetingCandidates).max(by: { $0.date < $1.date }) else {
            return
        }

        didTrackActivationReturnProxy = ActivationTelemetry.trackReturnProxyIfEligible(
            priorArtifactKind: latest.kind,
            priorArtifactDate: latest.date,
            surface: .home
        )
        if didTrackActivationReturnProxy {
            let artifactCount = dictations.count + meetings.count
            ActivationTelemetry.trackHabitLoopAction(
                actionKind: artifactCount >= 2 ? .returnAfterSecondArtifact : .returnAfterFirstArtifact,
                surface: .home,
                artifactKind: latest.kind,
                artifactDate: latest.date,
                artifactCount: artifactCount
            )
        }
    }

}

struct HomeDaySection<Item>: Identifiable {
    let day: Date
    let label: String
    let items: [Item]

    var id: TimeInterval { day.timeIntervalSinceReferenceDate }
}

enum HomeMeetingListItem: Identifiable {
    case saved(RecentMeetingItem)
    case failed(MeetingSessionController.FailedMeetingItem)

    var id: String {
        switch self {
        case .saved(let item):
            return "saved-\(item.id)"
        case .failed(let item):
            return "failed-\(item.id.uuidString)"
        }
    }

    var date: Date {
        switch self {
        case .saved(let item):
            return item.date
        case .failed(let item):
            return item.timestamp
        }
    }
}

struct HomeDeleteConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirmTitle: String
    let perform: () -> Void

    init(
        title: String,
        message: String,
        confirmTitle: String = "Delete",
        perform: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.perform = perform
    }
}

struct HomeDeleteFailure: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let retryTitle: String
    let details: String?
    let retry: () -> Void

    init(
        title: String,
        message: String,
        retryTitle: String = HomeActionFailureCopy.retryTitle,
        details: String? = nil,
        retry: @escaping () -> Void = {}
    ) {
        self.title = title
        self.message = message
        self.retryTitle = retryTitle
        self.details = details
        self.retry = retry
    }
}

// MARK: - Stats summary

struct HomeStatItem: Identifiable {
    let id: String
    let symbolName: String
    let value: String
    let label: String
    let detail: String?

    init(id: String, symbolName: String, value: String, label: String, detail: String? = nil) {
        self.id = id
        self.symbolName = symbolName
        self.value = value
        self.label = label
        self.detail = detail
    }
}

enum HomeFeedbackIssueKind: String, CaseIterable, Identifiable {
    case wrongWords
    case missingText
    case badFormatting
    case wrongSpeakers
    case audioProblem
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .wrongWords: return "Wrong words"
        case .missingText: return "Missing text"
        case .badFormatting: return "Bad formatting"
        case .wrongSpeakers: return "Speaker issue"
        case .audioProblem: return "Audio issue"
        case .other: return "Other"
        }
    }
}

struct HomeFeedbackTarget: Identifiable {
    let id: String
    let sourceKind: String
    let title: String
    let createdAt: Date
    let referenceID: String
    let suggestedIssue: HomeFeedbackIssueKind

    static func dictation(_ entry: SavedDictationEntry) -> HomeFeedbackTarget {
        HomeFeedbackTarget(
            id: "dictation-\(stableReferenceID(for: entry.id))",
            sourceKind: "dictation",
            title: "Dictation at \(HomeActivityRowFormatting.timeFormatter.string(from: entry.createdAt))",
            createdAt: entry.createdAt,
            referenceID: stableReferenceID(for: entry.id),
            suggestedIssue: .wrongWords
        )
    }

    static func meeting(_ item: RecentMeetingItem) -> HomeFeedbackTarget {
        HomeFeedbackTarget(
            id: "meeting-\(stableReferenceID(for: item.id))",
            sourceKind: "meeting",
            title: "Meeting at \(HomeActivityRowFormatting.timeFormatter.string(from: item.date))",
            createdAt: item.date,
            referenceID: stableReferenceID(for: item.id),
            suggestedIssue: .wrongSpeakers
        )
    }

    private static func stableReferenceID(for value: String) -> String {
        HomeStableReferenceID.id(for: value)
    }
}

struct HomeFeedbackSubmission {
    let target: HomeFeedbackTarget
    let issueKind: HomeFeedbackIssueKind
    let notes: String
    let includeDiagnostics: Bool
}

struct HomeMeetingPreview: Identifiable {
    let id: String
    let title: String
    let date: Date
    let transcriptURL: URL
    let audio: MeetingAudioAttachment?
    let markdown: String
    let readError: String?
    let feedbackTarget: HomeFeedbackTarget

    init(
        item: RecentMeetingItem,
        markdown: String,
        readError: String? = nil
    ) {
        id = item.id
        title = item.title
        date = item.date
        transcriptURL = item.transcriptURL
        audio = item.audio
        self.markdown = markdown
        self.readError = readError
        feedbackTarget = HomeFeedbackTarget.meeting(item)
    }

    private init(
        id: String,
        title: String,
        date: Date,
        transcriptURL: URL,
        audio: MeetingAudioAttachment?,
        markdown: String,
        readError: String?,
        feedbackTarget: HomeFeedbackTarget
    ) {
        self.id = id
        self.title = title
        self.date = date
        self.transcriptURL = transcriptURL
        self.audio = audio
        self.markdown = markdown
        self.readError = readError
        self.feedbackTarget = feedbackTarget
    }

    /// Returns a copy reflecting a renamed transcript while keeping the stable `id`
    /// so the open preview sheet updates in place instead of dismissing and re-presenting.
    func updatingAfterRename(
        transcriptURL: URL,
        title: String,
        audio: MeetingAudioAttachment?
    ) -> HomeMeetingPreview {
        HomeMeetingPreview(
            id: id,
            title: title,
            date: date,
            transcriptURL: transcriptURL,
            audio: audio,
            markdown: markdown,
            readError: readError,
            feedbackTarget: feedbackTarget
        )
    }
}

enum HomeMeetingMarkdownReadResult {
    case success(String)
    case failure(String)
}

// MARK: - Canvas header

struct HomeCanvasHeader: View {
    let greeting: String
    let streakText: String?
    let hoursText: String
    let wordsText: String
    let onViewStats: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(greeting)
                .font(.system(size: 28, weight: .light))
                .tracking(0.2)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: { onViewStats() }) {
                HStack(spacing: 9) {
                    if let streakText {
                        stat(streakText, "streak")
                        separatorDot
                    }

                    stat(hoursText, "recorded")
                    separatorDot
                    stat(wordsText, "words dictated")
                }
                .lineLimit(1)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .opacity(isHovering ? 1 : 0.9)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .help("View all stats")
            .accessibilityLabel("View all stats")
            .accessibilityIdentifier("transcripted.home.stats.view")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(value)
                .font(.system(size: 12.5, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Color.primary.opacity(0.9))
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
    }

    private var separatorDot: some View {
        Text("\u{00B7}")
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.tertiary)
    }
}

// MARK: - Needs-attention pills

struct HomeAttentionIssue: Identifiable {
    enum Destination {
        case failedMeetings
        case speakers
        case privacy
        case models
    }

    enum Tone {
        case warning
        case failure
        case progress

        var color: Color {
            switch self {
            case .warning: return .orange
            case .failure: return .red
            case .progress: return .accentColor
            }
        }
    }

    let id: String
    let title: String
    let detail: String
    let tone: Tone
    let destination: Destination
}

struct HomeAttentionPillsRow: View {
    let issues: [HomeAttentionIssue]
    let onSelect: (HomeAttentionIssue) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(issues) { issue in
                HomeAttentionPill(issue: issue) {
                    onSelect(issue)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HomeAttentionPill: View {
    let issue: HomeAttentionIssue
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Circle()
                    .fill(issue.tone.color)
                    .frame(width: 6, height: 6)
                Text(issue.title)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .lineLimit(1)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.055 : 0))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.primary.opacity(isHovering ? 0.16 : 0.09), lineWidth: 1)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help(issue.detail)
        .accessibilityLabel(issue.title)
        .accessibilityHint(issue.detail)
        .accessibilityIdentifier("transcripted.home.needs-attention.review.\(issue.id)")
    }
}

// MARK: - Scan warning card

/// Home warning card shown when the capture-library scan hits a damaged/broken
/// meetings path. Names the issue and keeps a clear action hierarchy: primary
/// Retry, a Reveal-in-Finder escape hatch, and a Dismiss to clear the card.
struct HomeScanWarningCard: View {
    let model: HomeScanWarningCardModel
    let onRetry: () -> Void
    let onReveal: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 34, height: 34)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.title)
                        .font(.headline)
                    Text(model.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("transcripted.home.scan-warning.dismiss")
            }

            HStack(spacing: 8) {
                Button(action: onRetry) {
                    Text(model.retryTitle)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .accessibilityIdentifier("transcripted.home.scan-warning.retry")

                Button(action: onReveal) {
                    Text(model.revealTitle)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("transcripted.home.scan-warning.reveal")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.orange.opacity(0.28), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.home.scan-warning")
    }
}

// MARK: - Stats detail

struct HomeStatsDetailSheet: View {
    let stats: [HomeStatItem]
    let streak: Int?
    let longestStreak: Int?
    let onDone: () -> Void

    private let columns = [
        GridItem(.flexible(minimum: 140), spacing: 12),
        GridItem(.flexible(minimum: 140), spacing: 12),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Overall")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Everything you've captured, and the time dictation gave back.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("transcripted.home.stats.done")
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(stats) { stat in
                    HomeStatsDetailMetric(stat: stat)
                }

                if let streak, streak > 0 {
                    HomeStatsDetailMetric(
                        stat: HomeStatItem(
                            id: "streak",
                            symbolName: "flame.fill",
                            value: "\(streak)d",
                            label: "current streak",
                            detail: "Consecutive days with at least one capture"
                        )
                    )
                }

                if let longestStreak, longestStreak > 0, longestStreak != streak {
                    HomeStatsDetailMetric(
                        stat: HomeStatItem(
                            id: "longest-streak",
                            symbolName: "trophy.fill",
                            value: "\(longestStreak)d",
                            label: "longest streak",
                            detail: "Your best run so far"
                        )
                    )
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct HomeStatsDetailMetric: View {
    let stat: HomeStatItem

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))

                Image(systemName: stat.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 2) {
                Text(stat.value)
                    .font(.system(size: 20, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(stat.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if let detail = stat.detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

enum HomeArtifactStatusTone: Equatable {
    case ready
    case warning
    case failure
}

struct HomeArtifactStatus: Equatable {
    let text: String
    let tone: HomeArtifactStatusTone

    static func dictation(_ entry: SavedDictationEntry) -> HomeArtifactStatus? {
        switch entry.delivery {
        case .pasted, .copied, .savedWithoutPaste:
            return HomeArtifactStatus(text: "Saved to Markdown", tone: .ready)
        case .failed:
            return HomeArtifactStatus(text: "Saved to Markdown only", tone: .warning)
        }
    }

    var foregroundStyle: Color {
        switch tone {
        case .ready:
            return .secondary
        case .warning:
            return .orange
        case .failure:
            return .red
        }
    }
}

// MARK: - Row action buttons

struct HomeRowMenuItem: Identifiable {
    let id = UUID()
    let title: String
    let symbolName: String
    let isEnabled: Bool
    let isDestructive: Bool
    let action: () -> Void

    init(
        title: String,
        symbolName: String,
        isEnabled: Bool = true,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbolName = symbolName
        self.isEnabled = isEnabled
        self.isDestructive = isDestructive
        self.action = action
    }
}

struct HomeRowActionButtons: View {
    let isCopied: Bool
    let onCopy: () -> Void
    let onFlag: () -> Void
    let menuItems: [HomeRowMenuItem]
    var leadingAccessory: AnyView? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let leadingAccessory {
                leadingAccessory
            }

            iconButton(
                systemName: isCopied ? "checkmark" : "square.on.square",
                help: isCopied ? "Copied" : "Copy",
                action: onCopy
            )

            if !menuItems.isEmpty {
                HomeRowMoreMenuButton(items: menuItems)
                    .frame(width: HomeHitTarget.minimum, height: HomeHitTarget.minimum)
                    .help("More options")
            }
        }
    }

    private func iconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .buttonStyle(HomeCompactIconButtonStyle())
        .help(help)
        .accessibilityLabel(Text(help))
        .accessibilityIdentifier("transcripted.home.row.copy")
    }
}

struct HomeRowMoreMenuButton: NSViewRepresentable {
    let items: [HomeRowMenuItem]
    var automationIdentifier = "transcripted.home.row.more"

    func makeCoordinator() -> Coordinator {
        Coordinator(items: items)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = HoverMenuButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: "More options"
        )
        button.contentTintColor = .secondaryLabelColor
        button.target = context.coordinator
        button.retainedActionTarget = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.setButtonType(.momentaryChange)
        button.setAccessibilityLabel("More options")
        button.identifier = NSUserInterfaceItemIdentifier(automationIdentifier)
        button.setAccessibilityIdentifier(automationIdentifier)
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.items = items
        if let hoverButton = button as? HoverMenuButton {
            hoverButton.retainedActionTarget = context.coordinator
        }
        button.target = context.coordinator
        button.isEnabled = !items.isEmpty
        button.identifier = NSUserInterfaceItemIdentifier(automationIdentifier)
        button.setAccessibilityIdentifier(automationIdentifier)
    }

    final class Coordinator: NSObject {
        var items: [HomeRowMenuItem]

        init(items: [HomeRowMenuItem]) {
            self.items = items
        }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            // Without this, AppKit auto-enables every item whose target responds
            // to the action, overriding the per-item isEnabled set below.
            menu.autoenablesItems = false
            for item in items {
                let menuItem = ClosureMenuItem(menuItem: item)
                if let image = NSImage(systemSymbolName: item.symbolName, accessibilityDescription: item.title) {
                    image.isTemplate = true
                    menuItem.image = image.withSymbolConfiguration(
                        NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
                    )
                }
                if item.isDestructive {
                    menuItem.attributedTitle = NSAttributedString(
                        string: item.title,
                        attributes: [.foregroundColor: NSColor.systemRed]
                    )
                }
                menu.addItem(menuItem)
            }

            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.height + 2),
                in: sender
            )
        }
    }

    /// A menu item that owns its action closure and acts as its own target.
    ///
    /// Two things have to hold for a handler to both fire *and* be able to drive
    /// SwiftUI presentation:
    ///   1. The item owns its handler instead of pointing `NSMenuItem.target` at
    ///      a separately, weakly-retained object. The `NSMenu` retains its items
    ///      for the whole `popUp` tracking loop, so the handler can't be torn
    ///      down with the SwiftUI coordinator while the menu is open. (The old
    ///      design's weak target could deallocate first, so closures silently
    ///      never fired — delete, reveal, and report all no-op'd.)
    ///   2. The handler runs on the next main-runloop turn, *after* `popUp`'s
    ///      modal tracking loop exits. A handler that mutates SwiftUI state to
    ///      present an `.alert(item:)`/`.sheet(item:)` (e.g. the Home delete
    ///      confirmation) won't present if it runs synchronously inside that
    ///      loop. The async block captures `handler` strongly, so deferring is
    ///      safe here — the dealloc trap from (1) does not reappear.
    final class ClosureMenuItem: NSMenuItem {
        private let handler: () -> Void

        init(menuItem: HomeRowMenuItem) {
            self.handler = menuItem.action
            super.init(title: menuItem.title, action: #selector(invoke), keyEquivalent: "")
            target = self
            isEnabled = menuItem.isEnabled
        }

        @available(*, unavailable)
        required init(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        @objc private func invoke() {
            guard isEnabled else { return }
            DispatchQueue.main.async { [handler] in handler() }
        }
    }

    final class HoverMenuButton: NSButton {
        var retainedActionTarget: AnyObject?
        private var trackingAreaRef: NSTrackingArea?
        private var hoverBackgroundLayer: CALayer?
        private var isHovering = false {
            didSet { updateAppearance() }
        }

        override var isHighlighted: Bool {
            didSet { updateAppearance() }
        }

        override var isEnabled: Bool {
            didSet { updateAppearance() }
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingAreaRef {
                removeTrackingArea(trackingAreaRef)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingAreaRef = area
        }

        override func layout() {
            super.layout()
            layoutHoverBackgroundLayer()
        }

        override func mouseEntered(with event: NSEvent) {
            guard isEnabled else { return }
            isHovering = true
        }

        override func mouseExited(with event: NSEvent) {
            isHovering = false
        }

        private func updateAppearance() {
            layoutHoverBackgroundLayer()
            guard isEnabled else {
                layer?.backgroundColor = NSColor.clear.cgColor
                hoverBackgroundLayer?.backgroundColor = NSColor.clear.cgColor
                alphaValue = 0.55
                return
            }

            alphaValue = 1
            let color: NSColor
            if isHighlighted {
                color = NSColor.labelColor.withAlphaComponent(0.07)
            } else if isHovering {
                color = NSColor.labelColor.withAlphaComponent(0.04)
            } else {
                color = .clear
            }
            layer?.backgroundColor = NSColor.clear.cgColor
            hoverBackgroundLayer?.backgroundColor = color.cgColor
        }

        private func layoutHoverBackgroundLayer() {
            guard wantsLayer, let layer else { return }
            let backgroundLayer: CALayer
            if let hoverBackgroundLayer {
                backgroundLayer = hoverBackgroundLayer
            } else {
                let createdLayer = CALayer()
                createdLayer.cornerRadius = 7
                layer.insertSublayer(createdLayer, at: 0)
                hoverBackgroundLayer = createdLayer
                backgroundLayer = createdLayer
            }

            let size = HomeHitTarget.compactVisibleSize
            backgroundLayer.frame = CGRect(
                x: floor((bounds.width - size) / 2),
                y: floor((bounds.height - size) / 2),
                width: size,
                height: size
            )
        }
    }
}

// MARK: - Activity rows

private enum HomeActivityRowFormatting {
    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "h:mm a"
        return f
    }()
}

private struct HomeActivityRowShell<Content: View>: View {
    let timeString: String
    var secondaryTimeString: String? = nil
    let isCopied: Bool
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onFlag: () -> Void
    let menuItems: [HomeRowMenuItem]
    var leadingAccessory: AnyView? = nil
    var bottomAccessory: AnyView? = nil
    var trailingAccessory: AnyView? = nil
    var rowTone: HomeArtifactStatusTone? = nil
    var compact: Bool = false
    var showsLeadingTimeColumn: Bool = true
    var opensOnRowClick: Bool = true
    @ViewBuilder let content: () -> Content

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 7) {
            HStack(alignment: .top, spacing: 14) {
                if opensOnRowClick {
                    Button(action: onOpen) {
                        mainContent
                    }
                    .buttonStyle(.plain)
                } else {
                    mainContent
                }

                trailingActions
                .opacity(isHovering ? 1 : 0)
                .animation(.easeOut(duration: 0.12), value: isHovering)
            }

            if let bottomAccessory {
                bottomAccessory
                    .padding(.leading, 78)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 6 : 11)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(rowBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(rowBorder, lineWidth: rowTone == nil ? 0 : 1)
        )
        .overlay(alignment: .leading) {
            if let accent = rowAccent {
                Capsule()
                    .fill(accent)
                    .frame(width: 2)
                    .padding(.vertical, compact ? 7 : 9)
            }
        }
        // The idle row background is Color.clear, so without an explicit hit
        // shape only the opaque title/time text triggers hover — actions then
        // reveal in a narrow band instead of across the full row.
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .animation(SettingsInteractionPalette.animation, value: isHovering)
    }

    private var trailingActions: some View {
        Group {
            if let trailingAccessory {
                trailingAccessory
            } else {
                HomeRowActionButtons(
                    isCopied: isCopied,
                    onCopy: onCopy,
                    onFlag: onFlag,
                    menuItems: menuItems,
                    leadingAccessory: leadingAccessory
                )
            }
        }
    }

    private var rowBackground: Color {
        guard let rowTone else {
            return isHovering ? Color.primary.opacity(0.035) : Color.clear
        }
        switch rowTone {
        case .ready:
            return isHovering ? Color.primary.opacity(0.035) : Color.clear
        case .warning:
            return Color.orange.opacity(isHovering ? 0.075 : 0.04)
        case .failure:
            return Color.red.opacity(isHovering ? 0.08 : 0.045)
        }
    }

    private var rowBorder: Color {
        switch rowTone {
        case .warning:
            return Color.orange.opacity(0.16)
        case .failure:
            return Color.red.opacity(0.18)
        case .ready, .none:
            return Color.clear
        }
    }

    private var rowAccent: Color? {
        switch rowTone {
        case .warning:
            return Color.orange.opacity(0.9)
        case .failure:
            return .red
        case .ready, .none:
            return nil
        }
    }

    private var mainContent: some View {
        HStack(alignment: .top, spacing: 14) {
            if showsLeadingTimeColumn {
                VStack(alignment: .leading, spacing: 1) {
                    Text(timeString)
                        .foregroundStyle(.secondary)
                    if let secondaryTimeString {
                        Text(secondaryTimeString)
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .frame(width: 64, alignment: .leading)
                .padding(.top, 2)
            }

            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
    }
}

struct HomeDictationRow: View {
    let entry: SavedDictationEntry
    let isCopied: Bool
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onFlag: () -> Void
    let menuItems: [HomeRowMenuItem]

    @State private var isExpanded = false

    private let collapsedCharacterLimit = 280
    private let expandedCharacterLimit = 1_600

    var body: some View {
        HomeActivityRowShell(
            timeString: HomeActivityRowFormatting.timeFormatter.string(from: entry.createdAt),
            isCopied: isCopied,
            onOpen: onOpen,
            onCopy: onCopy,
            onFlag: onFlag,
            menuItems: menuItems,
            opensOnRowClick: false
        ) {
            VStack(alignment: .leading, spacing: 6) {
                Text(displayText)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary)
                    .lineLimit(isExpanded ? 12 : 3)
                    .lineSpacing(2)
                    .multilineTextAlignment(.leading)

                if let status {
                    Button(action: onOpen) {
                        Label(status.text, systemImage: "doc.text")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(status.foregroundStyle)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help("Open Markdown")
                    .accessibilityIdentifier("transcripted.home.dictation.open-markdown")
                }

                if canExpand {
                    Button {
                        withAnimation(.snappy(duration: 0.18)) {
                            isExpanded.toggle()
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(isExpanded ? "Show less" : "Show more")
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .bold))
                        }
                        .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .help(isExpanded ? "Collapse dictation" : "Expand dictation")
                    .accessibilityIdentifier("transcripted.home.dictation.expand")
                }
            }
        }
    }

    private var status: HomeArtifactStatus? {
        HomeArtifactStatus.dictation(entry)
    }

    private var previewText: String {
        let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entry.title }
        return trimmed
    }

    private var canExpand: Bool {
        previewText.count > collapsedCharacterLimit || previewText.contains("\n")
    }

    private var displayText: String {
        limitedPreview(characterLimit: isExpanded ? expandedCharacterLimit : collapsedCharacterLimit)
    }

    private func limitedPreview(characterLimit: Int) -> String {
        guard previewText.count > characterLimit else { return previewText }
        let prefix = previewText.prefix(characterLimit)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(prefix)..."
    }
}

struct HomeMeetingRow: View {
    let item: RecentMeetingItem
    let isCopied: Bool
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onFlag: () -> Void
    let menuItems: [HomeRowMenuItem]
    var showsMicBoostHint: Bool = false

    var body: some View {
        HomeActivityRowShell(
            timeString: startTimeString,
            isCopied: isCopied,
            onOpen: onOpen,
            onCopy: onCopy,
            onFlag: onFlag,
            menuItems: menuItems,
            leadingAccessory: leadingRowAccessory,
            compact: true,
            showsLeadingTimeColumn: false
        ) {
            VStack(alignment: .leading, spacing: 2) {
                Text(timeRangeString)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.bottom, 1)

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(item.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help("Preview meeting")
            .accessibilityIdentifier("transcripted.home.meeting.preview")
        }
    }

    private var timeRangeString: String {
        guard let endTimeString else { return startTimeString }
        return "\(startTimeString) - \(endTimeString)"
    }

    private var leadingRowAccessory: AnyView? {
        guard showsMicBoostHint else { return nil }
        return AnyView(
            attentionDot(
                color: .orange,
                help: "Your mic was muffled by another call app"
            )
        )
    }

    private var startTimeString: String {
        HomeActivityRowFormatting.timeFormatter.string(from: item.startDate ?? item.date)
    }

    private var endTimeString: String? {
        guard let endDate = item.endDate else { return nil }
        return HomeActivityRowFormatting.timeFormatter.string(from: endDate)
    }

    private func attentionDot(color: Color, help: String, opacity: Double = 1) -> some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .frame(width: 18, height: 26)
            .opacity(opacity)
            .help(help)
            .accessibilityLabel(help)
    }
}

struct HomeFailedMeetingInlineRow: View {
    let item: MeetingSessionController.FailedMeetingItem
    let canRetry: Bool
    let retryUnavailableReason: String?
    let onRetry: () -> Void
    let onRevealAudio: () -> Void
    let onClear: () -> Void

    var body: some View {
        let presentation = inlinePresentation
        HomeActivityRowShell(
            timeString: HomeActivityRowFormatting.timeFormatter.string(from: item.timestamp),
            isCopied: false,
            onOpen: {},
            onCopy: {},
            onFlag: {},
            menuItems: [],
            trailingAccessory: AnyView(actions),
            compact: true,
            opensOnRowClick: false
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)

                statusLine(presentation: presentation)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(item.detail)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if hasRetainedAudioFiles {
                Button {
                    onRevealAudio()
                } label: {
                    Label("Show Audio", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Show saved audio in Finder")
                .accessibilityIdentifier("transcripted.home.failed-meeting.show-audio")
            }

            if inlinePresentation.canShowRetryAction {
                HomeAttentionActionButton(
                    title: item.isRetrying ? "Retrying" : "Try again",
                    isDisabled: retryDisabled,
                    automationIdentifier: "transcripted.home.failed-meeting.retry",
                    action: onRetry
                )
                .help(retryHelp)
            }

            HomeRowMoreMenuButton(items: [
                HomeRowMenuItem(
                    title: "Delete failed meeting",
                    symbolName: "trash",
                    isDestructive: true,
                    action: onClear
                )
            ], automationIdentifier: "transcripted.home.failed-meeting.more")
            .frame(width: HomeHitTarget.minimum, height: HomeHitTarget.minimum)
            .help("More options")
        }
    }

    private var inlinePresentation: HomeFailedMeetingInlinePresentation {
        HomeFailedMeetingInlinePresentation.make(
            isRetryable: item.isRetryable,
            isRetrying: item.isRetrying,
            hasAudioFiles: item.hasAudioFiles,
            detail: item.detail
        )
    }

    private func statusLine(presentation: HomeFailedMeetingInlinePresentation) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(presentation.statusText)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Color.red)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.red.opacity(0.12))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.red.opacity(0.18), lineWidth: 1)
                )
                .accessibilityLabel(presentation.statusText)

            if let detail = presentation.inlineDetail {
                Text(detail)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
    }

    private var retryDisabled: Bool {
        FailedMeetingRecoveryPresentation.retryDisabled(
            canRetry: canRetry,
            isRetryable: item.isRetryable,
            isRetrying: item.isRetrying,
            hasAudioFiles: item.hasAudioFiles
        )
    }

    private var retryHelp: String {
        FailedMeetingRecoveryPresentation.retryHelp(
            canRetry: canRetry,
            retryUnavailableReason: retryUnavailableReason,
            isRetryable: item.isRetryable,
            isRetrying: item.isRetrying,
            hasAudioFiles: item.hasAudioFiles
        )
    }

    private var hasRetainedAudioFiles: Bool {
        !item.audioURLs.isEmpty
    }
}

private struct HomeAttentionActionButton: View {
    let title: String
    let isDisabled: Bool
    var tint: Color = .red
    var automationIdentifier: String? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 14)
            .frame(height: 26)
            .background(
                Capsule(style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .shadow(color: shadowColor, radius: isHovering && !isDisabled ? 5 : 2, y: 1)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { isHovering = $0 }
        .homeAutomationIdentifier(automationIdentifier)
    }

    private var foregroundColor: Color {
        isDisabled ? tint.opacity(0.55) : Color.white
    }

    private var backgroundColor: Color {
        if isDisabled {
            return tint.opacity(0.12)
        }
        return tint.opacity(isHovering ? 0.9 : 0.78)
    }

    private var borderColor: Color {
        isDisabled ? tint.opacity(0.16) : Color.white.opacity(0.14)
    }

    private var shadowColor: Color {
        isDisabled ? Color.clear : tint.opacity(0.16)
    }
}

enum HomeHitTarget {
    static let minimum: CGFloat = 40
    static let compactVisibleSize: CGFloat = 26
}

private struct HomeCompactIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> Body {
        Body(configuration: configuration)
    }

    struct Body: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .frame(width: HomeHitTarget.compactVisibleSize, height: HomeHitTarget.compactVisibleSize)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(backgroundColor)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(strokeColor, lineWidth: 1)
                )
                .frame(width: HomeHitTarget.minimum, height: HomeHitTarget.minimum)
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.55)
                .onHover { isHovering = $0 }
        }

        private var backgroundColor: Color {
            if configuration.isPressed {
                return Color.primary.opacity(0.10)
            }
            if isHovering {
                return Color.primary.opacity(0.06)
            }
            return Color.clear
        }

        private var strokeColor: Color {
            configuration.isPressed || isHovering ? Color.primary.opacity(0.08) : Color.clear
        }
    }
}

private extension View {
    @ViewBuilder
    func homeAutomationIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

private struct HomeMeetingAudioControl: View {
    let title: String
    let symbolName: String
    let isActive: Bool
    let isPlaying: Bool
    let scrubber: AnyView?
    let action: () -> Void

    init(
        title: String,
        symbolName: String,
        isActive: Bool,
        isPlaying: Bool,
        scrubber: AnyView? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbolName = symbolName
        self.isActive = isActive
        self.isPlaying = isPlaying
        self.scrubber = scrubber
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: symbolName)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(isActive ? Color.white : Color.secondary)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(isActive ? Color.accentColor : Color.primary.opacity(0.10)))

                    Text(title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)

                    if isPlaying {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 5, height: 5)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .buttonStyle(SettingsHoverButtonStyle(
                tone: isActive ? .accent : .neutral,
                cornerRadius: 8,
                normalFill: isActive ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08),
                normalStroke: isActive ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.10)
            ))
            .frame(minHeight: 40, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityLabel(title)
            .accessibilityIdentifier("transcripted.home.audio.inline-toggle")

            if let scrubber {
                scrubber
            }
        }
    }

}

// MARK: - Empty state

/// Friendly first-run empty state for a capture list: a single line describing
/// what the screen is for plus one clear primary action.
struct HomeListEmptyState {
    let symbolName: String
    let title: String
    let message: String
    let actionTitle: String
    let automationIdentifier: String
    let action: () -> Void
    var secondaryActionTitle: String? = nil
    var secondaryAutomationIdentifier: String? = nil
    var secondaryAction: (() -> Void)? = nil
}

private struct HomeEmptyStateView: View {
    let state: HomeListEmptyState

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: state.symbolName)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)

            VStack(spacing: 5) {
                Text(state.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.primary)

                Text(state.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }

            HStack(spacing: 8) {
                Button(action: state.action) {
                    Text(state.actionTitle)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier(state.automationIdentifier)

                if let secondaryTitle = state.secondaryActionTitle,
                   let secondaryAutomationIdentifier = state.secondaryAutomationIdentifier,
                   let secondaryAction = state.secondaryAction {
                    Button(action: secondaryAction) {
                        Text(secondaryTitle)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier(secondaryAutomationIdentifier)
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 16)
    }
}

// MARK: - Day-grouped list

struct HomeDayGroupedList<Item, Row: View>: View {
    let sections: [HomeDaySection<Item>]
    let emptyMessage: String
    var emptyState: HomeListEmptyState? = nil
    let getID: (Item) -> AnyHashable
    var sectionSpacing: CGFloat = 12
    var headerSpacing: CGFloat = 2
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        if sections.isEmpty {
            if let emptyState {
                HomeEmptyStateView(state: emptyState)
            } else {
                HStack {
                    Text(emptyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 28)
                .padding(.horizontal, 4)
            }
        } else {
            LazyVStack(alignment: .leading, spacing: sectionSpacing) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: headerSpacing) {
                        Text(section.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.6)
                            .padding(.bottom, 2)

                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(section.items.enumerated()), id: \.offset) { index, item in
                                row(item)
                                    .id(getID(item))
                                if index < section.items.count - 1 {
                                    Divider()
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Capture list

/// Filter box over the Home meetings list. Matches the user's query against
/// already-loaded meeting metadata (title and date) via
/// `HomeMeetingListFilter`; it never reads transcript bodies, so it stays cheap
/// even for large libraries. Filtering applies to the meetings currently loaded
/// into the dashboard slice — "Show more" pages in older meetings to search.
struct HomeMeetingSearchField: View {
    @Binding var query: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Filter meetings by title or date", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .accessibilityIdentifier("transcripted.home.meeting-search.field")

            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear filter")
                .accessibilityLabel("Clear meeting filter")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

struct HomeCaptureListSection<Item, Row: View>: View {
    let sections: [HomeDaySection<Item>]
    let emptyMessage: String
    var emptyState: HomeListEmptyState? = nil
    let isLoading: Bool
    let isLoadingMore: Bool
    let canLoadMore: Bool
    let getID: (Item) -> AnyHashable
    let onLoadMore: () -> Void
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isLoading {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 28)
            } else {
                HomeDayGroupedList(
                    sections: sections,
                    emptyMessage: emptyMessage,
                    emptyState: emptyState,
                    getID: getID,
                    sectionSpacing: 14,
                    headerSpacing: 2,
                    row: row
                )

                if canLoadMore || isLoadingMore {
                    HomeLoadMoreButton(
                        title: "Load more",
                        isLoading: isLoadingMore,
                        action: onLoadMore
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Row feedback

struct HomeFeedbackSheet: View {
    let target: HomeFeedbackTarget
    let onCancel: () -> Void
    let onSubmit: (HomeFeedbackSubmission) -> Void

    @State private var issueKind: HomeFeedbackIssueKind
    @State private var notes = ""
    @State private var includeDiagnostics = true

    init(
        target: HomeFeedbackTarget,
        onCancel: @escaping () -> Void,
        onSubmit: @escaping (HomeFeedbackSubmission) -> Void
    ) {
        self.target = target
        self.onCancel = onCancel
        self.onSubmit = onSubmit
        _issueKind = State(initialValue: target.suggestedIssue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Report an issue")
                    .font(.system(size: 22, weight: .semibold))
                Text(target.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Issue")
                    .font(.subheadline.weight(.semibold))
                HomeIssueKindSelector(selection: $issueKind)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("What happened?")
                    .font(.subheadline.weight(.semibold))
                TextEditor(text: $notes)
                    .font(.body)
                    .frame(minHeight: 120)
                    .scrollContentBackground(.hidden)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color.primary.opacity(0.035))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
            }

            Toggle("Include safe diagnostics", isOn: $includeDiagnostics)

            Text("Transcripted attaches the capture type, time, app version, a private reference ID, and recent scrubbed logs. It does not attach transcript text, audio, file paths, meeting titles, emails, or raw URLs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                SettingsInlineActionButton(title: "Cancel", action: onCancel)
                Spacer()
                SettingsInlineActionButton(title: "Review report", tone: .accent) {
                    onSubmit(HomeFeedbackSubmission(
                        target: target,
                        issueKind: issueKind,
                        notes: notes,
                        includeDiagnostics: includeDiagnostics
                    ))
                }
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

private struct HomeIssueKindSelector: View {
    @Binding var selection: HomeFeedbackIssueKind

    private let columns = [
        GridItem(.flexible(minimum: 140), spacing: 8),
        GridItem(.flexible(minimum: 140), spacing: 8),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(HomeFeedbackIssueKind.allCases) { kind in
                HomeIssueKindButton(
                    kind: kind,
                    isSelected: selection == kind
                ) {
                    selection = kind
                }
            }
        }
    }
}

private struct HomeIssueKindButton: View {
    let kind: HomeFeedbackIssueKind
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(kind.label)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.9)

                Spacer(minLength: 0)

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(SettingsHoverButtonStyle(
            tone: isSelected ? .accent : .neutral,
            cornerRadius: 8,
            normalFill: background,
            normalStroke: stroke
        ))
    }

    private var background: Color {
        isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035)
    }

    private var stroke: Color {
        isSelected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08)
    }
}

// MARK: - Load more / failed meetings

struct HomeLoadMoreButton: View {
    let title: String
    let isLoading: Bool
    var automationIdentifier = "transcripted.home.load-more"
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack {
            Spacer(minLength: 0)

            Button(action: action) {
                Text(isLoading ? "Loading..." : title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isLoading ? Color.secondary : Color.secondary.opacity(isHovering ? 1 : 0.82))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
                    )
                    .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(isLoading)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .accessibilityIdentifier(automationIdentifier)

            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }
}

struct HomeFailedMeetingsCard: View {
    let items: [MeetingSessionController.FailedMeetingItem]
    let hiddenCount: Int
    let canRetry: Bool
    let retryUnavailableReason: String?
    let audioAttachment: (MeetingSessionController.FailedMeetingItem) -> MeetingAudioAttachment?
    let onRetry: (MeetingSessionController.FailedMeetingItem) -> Void
    let onRevealAudio: (MeetingSessionController.FailedMeetingItem) -> Void
    let onClear: (MeetingSessionController.FailedMeetingItem) -> Void
    let onShowAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .foregroundStyle(.orange)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.headline)
                Spacer()
                if hiddenCount > 0 {
                    SettingsInlineActionButton(
                        title: showAllTitle,
                        tone: .warning,
                        automationIdentifier: "transcripted.home.failed-meetings.show-all",
                        action: onShowAll
                    )
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    HomeFailedMeetingRow(
                        item: item,
                        canRetry: canRetry,
                        retryUnavailableReason: retryUnavailableReason,
                        audio: audioAttachment(item),
                        onRetry: { onRetry(item) },
                        onRevealAudio: { onRevealAudio(item) },
                        onClear: { onClear(item) }
                    )

                    if index < items.count - 1 {
                        Divider()
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.orange.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.orange.opacity(0.32), lineWidth: 1)
        )
    }

    private var title: String {
        items.count == 1 ? "Recover this meeting" : "Recover unfinished meetings"
    }

    private var showAllTitle: String {
        hiddenCount == 1 ? "Show 1 more" : "Show \(hiddenCount) more"
    }
}

private struct HomeFailedMeetingRow: View {
    let item: MeetingSessionController.FailedMeetingItem
    let canRetry: Bool
    let retryUnavailableReason: String?
    let audio: MeetingAudioAttachment?
    let onRetry: () -> Void
    let onRevealAudio: () -> Void
    let onClear: () -> Void

    @ObservedObject private var playback = MeetingAudioPlayback.shared
    @State private var selectedPlaybackChoiceID: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: presentation.iconSystemName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 24)
                .padding(.top, 3)

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))

                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(item.meta)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                HStack(spacing: 8) {
                    if let audio {
                        let selectedChoice = selectedPlaybackChoice(for: audio)
                        HomeMeetingAudioControl(
                            title: playback.buttonTitle(for: audio, choice: selectedChoice),
                            symbolName: playback.symbolName(for: audio, choice: selectedChoice),
                            isActive: playback.isActive(audio, choice: selectedChoice),
                            isPlaying: playback.isPlaying && playback.isActive(audio, choice: selectedChoice),
                            scrubber: playback.isActive(audio)
                                ? AnyView(MeetingAudioScrubber(attachment: audio, width: 190))
                                : nil
                        ) {
                            playback.toggle(audio, choice: selectedChoice)
                        }
                        .help("\(playback.buttonTitle(for: audio, choice: selectedChoice)) retained meeting audio")

                        MeetingAudioSourceMenu(
                            attachment: audio,
                            selectedChoiceID: selectedPlaybackChoiceBinding(for: audio)
                        ) { choice in
                            if playback.isActive(audio) {
                                playback.switchSource(audio, choice: choice)
                            }
                        }

                        SettingsInlineActionButton(
                            title: "Show Audio",
                            symbolName: "folder",
                            automationIdentifier: "transcripted.home.failed-meetings.show-audio"
                        ) {
                            onRevealAudio()
                        }
                    } else {
                        Label("No audio kept", systemImage: "speaker.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    if item.isRetryable || item.isRetrying {
                        SettingsInlineActionButton(
                            title: item.isRetrying ? "Retrying..." : "Try Again",
                            symbolName: "arrow.clockwise",
                            tone: .accent,
                            automationIdentifier: "transcripted.home.failed-meetings.retry"
                        ) {
                            onRetry()
                        }
                        .disabled(presentation.retryDisabled)
                        .help(presentation.retryHelp)
                    }

                    SettingsInlineActionButton(
                        title: "Delete",
                        symbolName: "trash",
                        tone: .destructive,
                        automationIdentifier: "transcripted.home.failed-meetings.delete"
                    ) {
                        onClear()
                    }
                    .frame(width: 78, height: 30)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
    }

    private var presentation: FailedMeetingRecoveryPresentation {
        FailedMeetingRecoveryPresentation.make(
            failureKind: item.failureKind,
            canRetry: canRetry,
            retryUnavailableReason: retryUnavailableReason,
            isRetryable: item.isRetryable,
            isRetrying: item.isRetrying,
            hasAudioFiles: item.hasAudioFiles
        )
    }

    private var iconColor: Color {
        presentation.iconTone == .warning ? Color.orange : Color.secondary
    }

    private func selectedPlaybackChoice(for audio: MeetingAudioAttachment) -> MeetingAudioPlaybackChoice? {
        playback.activeChoice(for: audio) ?? audio.playbackChoice(id: selectedPlaybackChoiceID)
    }

    private func selectedPlaybackChoiceBinding(for audio: MeetingAudioAttachment) -> Binding<String?> {
        Binding(
            get: { selectedPlaybackChoice(for: audio)?.id },
            set: { selectedPlaybackChoiceID = $0 }
        )
    }
}
