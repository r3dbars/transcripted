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

    private var refreshTask: Task<Void, Never>?
    private var refreshGeneration = 0
    private var dictationLimit = 10
    private var meetingLimit = 10

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
        isLoading = true
        loadCurrentLimits(isInitialLoad: true)
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

    private func loadCurrentLimits(isInitialLoad: Bool) {
        refreshTask?.cancel()
        refreshGeneration += 1
        isLoading = isInitialLoad
        isLoadingMore = !isInitialLoad
        let generation = refreshGeneration
        let requestedDictationLimit = dictationLimit
        let requestedMeetingLimit = meetingLimit
        refreshTask = Task { @MainActor in
            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: requestedDictationLimit + 1,
                meetingLimit: requestedMeetingLimit + 1,
                includeDictationCounts: true
            )
            guard !Task.isCancelled, generation == self.refreshGeneration else {
                return
            }
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
            self.isLoading = false
            self.isLoadingMore = false
        }
    }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
        refreshGeneration += 1
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
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        let formatter = Self.daySectionFormatter
        return formatter.string(from: day)
    }

    private static let daySectionFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "EEEE, MMM d"
        return f
    }()
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
}

enum HomeActivityTab: String, CaseIterable, Identifiable {
    case dictations
    case meetings

    var id: String { rawValue }

    var label: String {
        switch self {
        case .dictations: return "Dictations"
        case .meetings: return "Meetings"
        }
    }
}

enum HomeHeroMode: String, CaseIterable, Identifiable {
    case meeting
    case dictation

    var id: String { rawValue }

    static let tabOrder: [HomeHeroMode] = [.meeting, .dictation]

    var switchTitle: String {
        switch self {
        case .dictation: return "Dictation"
        case .meeting: return "Meetings"
        }
    }

    var symbolName: String {
        switch self {
        case .dictation: return "mic.fill"
        case .meeting: return "waveform"
        }
    }

    var activityTab: HomeActivityTab {
        switch self {
        case .dictation: return .dictations
        case .meeting: return .meetings
        }
    }
}

// MARK: - Stats summary

struct HomeStatItem: Identifiable {
    let id: String
    let symbolName: String
    let value: String
    let label: String
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
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
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

    init(item: RecentMeetingItem, markdown: String, readError: String? = nil) {
        id = item.id
        title = item.title
        date = item.date
        transcriptURL = item.transcriptURL
        audio = item.audio
        self.markdown = markdown
        self.readError = readError
        feedbackTarget = HomeFeedbackTarget.meeting(item)
    }
}

enum HomeMeetingMarkdownReadResult {
    case success(String)
    case failure(String)
}

// MARK: - Welcome header

struct HomeWelcomeHeader: View {
    let name: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Welcome back, \(name)")
                .font(.system(size: 22, weight: .semibold))
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Hero card

private enum HomeHeroTabMetrics {
    static let width: CGFloat = 172
    static let height: CGFloat = 52
    static let cornerRadius: CGFloat = 14
    static let cardCornerRadius: CGFloat = 18
    static let spacing: CGFloat = 4

    static var surfaceFill: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.82)
    }

    static var inactiveFill: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.56)
    }
}

struct HomeHeroCard<ActivityContent: View>: View {
    @Binding var selectedMode: HomeHeroMode
    private let activityContent: () -> ActivityContent

    @Environment(\.displayScale) private var displayScale

    init(
        selectedMode: Binding<HomeHeroMode>,
        @ViewBuilder activityContent: @escaping () -> ActivityContent
    ) {
        _selectedMode = selectedMode
        self.activityContent = activityContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeHeroModeTabs(selectedMode: $selectedMode)
                .padding(.bottom, -hairline)
                .zIndex(1)

            VStack(alignment: .leading, spacing: 18) {
                activityContent()
            }
            .padding(.top, 20)
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                HomeHeroCardShape(
                    cornerRadius: HomeHeroTabMetrics.cardCornerRadius,
                    squareTopLeft: selectedMode == .meeting
                )
                    .fill(cardFill)
            )
            .overlay(
                HomeHeroCardBorderShape(
                    cornerRadius: HomeHeroTabMetrics.cardCornerRadius,
                    selectedTabMinX: selectedTabLeadingOffset,
                    selectedTabMaxX: selectedTabTrailingOffset,
                    squareTopLeft: selectedMode == .meeting
                )
                    .stroke(Color.primary.opacity(0.08), lineWidth: hairline)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardFill: Color {
        HomeHeroTabMetrics.surfaceFill
    }

    private var hairline: CGFloat {
        1 / max(displayScale, 1)
    }

    private var selectedTabLeadingOffset: CGFloat {
        switch selectedMode {
        case .meeting:
            return 0
        case .dictation:
            return HomeHeroTabMetrics.width + HomeHeroTabMetrics.spacing
        }
    }

    private var selectedTabTrailingOffset: CGFloat {
        selectedTabLeadingOffset + HomeHeroTabMetrics.width
    }
}

private struct HomeHeroModeTabs: View {
    @Binding var selectedMode: HomeHeroMode

    var body: some View {
        HStack(alignment: .top, spacing: HomeHeroTabMetrics.spacing) {
            ForEach(HomeHeroMode.tabOrder) { mode in
                HomeHeroModeTab(
                    mode: mode,
                    isSelected: selectedMode == mode,
                    action: {
                        guard selectedMode != mode else { return }
                        var transaction = Transaction()
                        transaction.animation = nil
                        withTransaction(transaction) {
                            selectedMode = mode
                        }
                    }
                )
            }
        }
        .frame(height: HomeHeroTabMetrics.height, alignment: .topLeading)
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}

private struct HomeHeroModeTab: View {
    let mode: HomeHeroMode
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.displayScale) private var displayScale
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18, height: 18)
                Text(mode.switchTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .frame(width: HomeHeroTabMetrics.width, height: HomeHeroTabMetrics.height)
            .background(
                HomeHeroTabShape(cornerRadius: HomeHeroTabMetrics.cornerRadius)
                    .fill(tabFill)
            )
            .overlay(
                HomeHeroTabBorderShape(cornerRadius: HomeHeroTabMetrics.cornerRadius)
                    .stroke(tabStroke, lineWidth: hairline)
            )
            .contentShape(HomeHeroTabShape(cornerRadius: HomeHeroTabMetrics.cornerRadius))
        }
        .buttonStyle(.plain)
        .help("Show \(mode.switchTitle.lowercased())")
        .zIndex(isSelected ? 1 : 0)
        .onHover { isHovering = $0 }
        .accessibilityLabel(mode.switchTitle)
        .accessibilityValue(isSelected ? "Selected" : "")
    }

    private var tabFill: Color {
        if isSelected {
            return surfaceFill
        }
        if isHovering {
            return Color(nsColor: .controlBackgroundColor).opacity(0.66)
        }
        return HomeHeroTabMetrics.inactiveFill
    }

    private var tabStroke: Color {
        isSelected ? Color.primary.opacity(0.11) : Color.primary.opacity(0.06)
    }

    private var surfaceFill: Color {
        HomeHeroTabMetrics.surfaceFill
    }

    private var hairline: CGFloat {
        1 / max(displayScale, 1)
    }
}

private struct HomeHeroTabShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.width / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

private struct HomeHeroTabBorderShape: Shape {
    let cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.width / 2, rect.height)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        return path
    }
}

private struct HomeHeroCardShape: Shape {
    let cornerRadius: CGFloat
    let squareTopLeft: Bool

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        let topLeftRadius = squareTopLeft ? 0 : radius
        var path = Path()

        path.move(to: CGPoint(x: rect.minX + topLeftRadius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeftRadius))
        if topLeftRadius > 0 {
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + topLeftRadius, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
        }
        path.closeSubpath()
        return path
    }
}

private struct HomeHeroCardBorderShape: Shape {
    let cornerRadius: CGFloat
    let selectedTabMinX: CGFloat
    let selectedTabMaxX: CGFloat
    let squareTopLeft: Bool

    func path(in rect: CGRect) -> Path {
        let radius = min(cornerRadius, rect.width / 2, rect.height / 2)
        let topLeftRadius = squareTopLeft ? 0 : radius
        let topLineStart = rect.minX + topLeftRadius
        let topLineEnd = rect.maxX - radius
        let gapStart = max(rect.minX, min(rect.maxX, rect.minX + selectedTabMinX))
        let gapEnd = max(rect.minX, min(rect.maxX, rect.minX + selectedTabMaxX))
        var path = Path()

        if topLeftRadius > 0 {
            path.move(to: CGPoint(x: rect.minX, y: rect.minY + topLeftRadius))
            path.addQuadCurve(
                to: CGPoint(x: topLineStart, y: rect.minY),
                control: CGPoint(x: rect.minX, y: rect.minY)
            )
        }

        if gapStart > topLineStart {
            path.move(to: CGPoint(x: topLineStart, y: rect.minY))
            path.addLine(to: CGPoint(x: min(gapStart, topLineEnd), y: rect.minY))
        }

        if gapEnd < topLineEnd {
            path.move(to: CGPoint(x: max(gapEnd, topLineStart), y: rect.minY))
            path.addLine(to: CGPoint(x: topLineEnd, y: rect.minY))
        }

        path.move(to: CGPoint(x: topLineEnd, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + topLeftRadius))

        return path
    }
}

// MARK: - Stats rail

struct HomeStatsTopCard: View {
    let stats: [HomeStatItem]
    let streak: Int?

    private let columns = [
        GridItem(.flexible(minimum: 86), spacing: 12),
        GridItem(.flexible(minimum: 86), spacing: 12)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Overall")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)

                Spacer(minLength: 10)

                if let streak, streak > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text("\(streak)d")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Color.primary)
                }
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(stats) { stat in
                    HStack(spacing: 8) {
                        ZStack {
                            Circle()
                                .fill(Color.primary.opacity(0.06))
                            Image(systemName: stat.symbolName)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 24, height: 24)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(stat.value)
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(Color.primary)
                                .lineLimit(1)
                            Text(stat.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 286, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.72))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

struct HomeStatsBadge: View {
    let stats: [HomeStatItem]
    let streak: Int?

    @State private var isHovering = false
    @State private var isShowingDetails = false

    var body: some View {
        Button {
            isShowingDetails = true
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "chart.bar.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.accentColor)
                        Text("Overall")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.5)
                    }

                    Spacer(minLength: 10)

                    Label("View stats", systemImage: "info.circle")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(0.055))
                        )
                }

                LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 9) {
                    ForEach(headlineStats.prefix(4)) { stat in
                        HomeStatsStripMetric(stat: stat)
                    }
                }
            }
            .padding(14)
            .frame(width: 348, alignment: .leading)
            .frame(minHeight: 112)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(isHovering ? 0.98 : 0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(isHovering ? 0.14 : 0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(isHovering ? 0.18 : 0.10), radius: isHovering ? 16 : 10, x: 0, y: isHovering ? 8 : 5)
            .scaleEffect(isHovering ? 1.006 : 1)
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .onHover { isHovering = $0 }
        }
        .buttonStyle(.plain)
        .help("Show more stats")
        .sheet(isPresented: $isShowingDetails) {
            HomeStatsDetailSheet(
                stats: stats,
                streak: streak,
                onDone: { isShowingDetails = false }
            )
        }
    }

    private var metricColumns: [GridItem] {
        [
            GridItem(.flexible(minimum: 130), spacing: 12),
            GridItem(.flexible(minimum: 130), spacing: 12),
        ]
    }

    private var headlineStats: [HomeStatItem] {
        let preferredIDs = ["typing-time-saved", "dictation-words", "meetings", "meeting-hours"]
        let preferredStats = preferredIDs.compactMap { id in
            stats.first(where: { $0.id == id })
        }
        return preferredStats.isEmpty ? Array(stats.prefix(4)) : preferredStats
    }
}

private struct HomeStatsStripMetric: View {
    let stat: HomeStatItem

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(0.055))

                Image(systemName: stat.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(stat.value)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Text(compactLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compactLabel: String {
        stat.id == "dictation-words" ? "words" : stat.label
    }
}

private struct HomeStatsDetailSheet: View {
    let stats: [HomeStatItem]
    let streak: Int?
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
                    Text("A quick read on saved work and time returned.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
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
                            label: "streak"
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
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(stat.label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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

    static func meeting(_ item: RecentMeetingItem) -> HomeArtifactStatus {
        if item.speakerStatus.needsReview {
            return HomeArtifactStatus(text: item.speakerStatus.summary, tone: .warning)
        }
        if item.audio != nil {
            return HomeArtifactStatus(text: "Saved with audio", tone: .ready)
        }
        return HomeArtifactStatus(text: "Transcript saved", tone: .ready)
    }

    static func dictation(_ entry: SavedDictationEntry) -> HomeArtifactStatus {
        switch entry.delivery {
        case .pasted:
            return HomeArtifactStatus(text: "Saved and pasted", tone: .ready)
        case .copied:
            return HomeArtifactStatus(text: "Saved to clipboard", tone: .ready)
        case .failed:
            return HomeArtifactStatus(text: "Saved only", tone: .warning)
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
    let isDestructive: Bool
    let action: () -> Void

    init(title: String, symbolName: String, isDestructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbolName = symbolName
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
                    .frame(width: 26, height: 26)
                    .help("More options")
            }
        }
    }

    private func iconButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct HomeRowMoreMenuButton: NSViewRepresentable {
    let items: [HomeRowMenuItem]

    func makeCoordinator() -> Coordinator {
        Coordinator(items: items)
    }

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: "More options"
        )
        button.contentTintColor = .secondaryLabelColor
        button.target = context.coordinator
        button.action = #selector(Coordinator.showMenu(_:))
        button.setButtonType(.momentaryChange)
        button.setAccessibilityLabel("More options")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) {
        context.coordinator.items = items
        button.isEnabled = !items.isEmpty
    }

    final class Coordinator: NSObject {
        var items: [HomeRowMenuItem]

        init(items: [HomeRowMenuItem]) {
            self.items = items
        }

        @objc func showMenu(_ sender: NSButton) {
            let menu = NSMenu()
            for item in items {
                let menuItem = NSMenuItem(
                    title: item.title,
                    action: #selector(performMenuItem(_:)),
                    keyEquivalent: ""
                )
                menuItem.target = self
                menuItem.representedObject = item.id
                menu.addItem(menuItem)
            }

            menu.popUp(
                positioning: nil,
                at: NSPoint(x: 0, y: sender.bounds.height + 2),
                in: sender
            )
        }

        @objc private func performMenuItem(_ sender: NSMenuItem) {
            guard let id = sender.representedObject as? UUID,
                  let item = items.first(where: { $0.id == id }) else {
                return
            }
            item.action()
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
                .opacity(isHovering ? 1 : 0.55)
                .animation(.easeOut(duration: 0.12), value: isHovering)
            }

            if let bottomAccessory {
                bottomAccessory
                    .padding(.leading, 78)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 5 : 9)
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
        .onHover { isHovering = $0 }
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
            Text(timeString)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
                .padding(.top, 2)

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

                Text(status.text)
                    .font(.caption2)
                    .foregroundStyle(status.foregroundStyle)
                    .lineLimit(1)

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
                }
            }
        }
    }

    private var status: HomeArtifactStatus {
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
    let onReviewSpeakers: () -> Void
    let menuItems: [HomeRowMenuItem]

    var body: some View {
        HomeActivityRowShell(
            timeString: HomeActivityRowFormatting.timeFormatter.string(from: item.date),
            isCopied: isCopied,
            onOpen: onOpen,
            onCopy: onCopy,
            onFlag: onFlag,
            menuItems: menuItems,
            leadingAccessory: reviewSpeakersAccessory,
            compact: true
        ) {
            HStack(alignment: .top, spacing: 10) {
                if !item.speakerStatus.needsReview {
                    Image(systemName: "doc.text")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(status.foregroundStyle)
                        .padding(.top, 2)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)

                    if item.speakerStatus.needsReview {
                        speakerReviewLabel
                    } else {
                        Text(status.text)
                            .font(.caption2)
                            .foregroundStyle(status.foregroundStyle)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var status: HomeArtifactStatus {
        HomeArtifactStatus.meeting(item)
    }

    private var reviewSpeakersAccessory: AnyView? {
        guard item.speakerStatus.needsReview else { return nil }
        return AnyView(
            HomeAttentionActionButton(
                title: "Review",
                isDisabled: false,
                action: onReviewSpeakers
            )
                .help("Review speakers")
        )
    }

    private var speakerReviewLabel: some View {
        Text("Needs speaker names")
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
            .accessibilityLabel("Needs speaker names")
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

                statusLine
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(item.detail)
        }
    }

    private var actions: some View {
        HStack(spacing: 6) {
            if item.hasAudioFiles {
                Button {
                    onRevealAudio()
                } label: {
                    Label("Show Audio", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Show saved audio in Finder")
            }

            if item.isRetryable || item.isRetrying {
                HomeAttentionActionButton(
                    title: item.isRetrying ? "Retrying" : "Try again",
                    isDisabled: retryDisabled,
                    action: onRetry
                )
                .help(retryHelp)
            }

            HomeRowMoreMenuButton(items: [
                HomeRowMenuItem(
                    title: item.hasAudioFiles ? "Delete failed meeting" : "Dismiss",
                    symbolName: item.hasAudioFiles ? "trash" : "xmark",
                    isDestructive: item.hasAudioFiles,
                    action: onClear
                )
            ])
            .frame(width: 26, height: 26)
            .help("More options")
        }
    }

    private var statusLine: some View {
        Text(statusPillText)
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
            .accessibilityLabel(statusPillText)
    }

    private var statusPillText: String {
        item.isRetrying ? "Retrying" : "Needs retry"
    }

    private var retryDisabled: Bool {
        !canRetry || !item.isRetryable || item.isRetrying
    }

    private var retryHelp: String {
        if item.isRetrying {
            return "Retry is already running."
        }
        if !item.isRetryable {
            return "This meeting does not have enough saved audio to retry."
        }
        if let retryUnavailableReason {
            return retryUnavailableReason
        }
        if !canRetry {
            return "Wait for the current meeting work to finish before retrying."
        }
        return "Transcribe this saved audio again."
    }
}

private struct HomeAttentionActionButton: View {
    let title: String
    let isDisabled: Bool
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
    }

    private var foregroundColor: Color {
        isDisabled ? Color.red.opacity(0.55) : Color.white
    }

    private var backgroundColor: Color {
        if isDisabled {
            return Color.red.opacity(0.12)
        }
        return Color.red.opacity(isHovering ? 0.9 : 0.78)
    }

    private var borderColor: Color {
        isDisabled ? Color.red.opacity(0.16) : Color.white.opacity(0.14)
    }

    private var shadowColor: Color {
        isDisabled ? Color.clear : Color.red.opacity(0.16)
    }
}

private struct HomeAudioIconButton: View {
    let title: String
    let symbolName: String
    let isActive: Bool
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isActive ? Color.white : Color.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill(isActive ? Color.accentColor : Color.primary.opacity(0.08)))
                .overlay(
                    Circle()
                        .stroke(isPlaying ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.06), lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
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
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isActive ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isActive ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.10), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)

            if let scrubber {
                scrubber
            }
        }
    }

}

// MARK: - Day-grouped list

struct HomeDayGroupedList<Item, Row: View>: View {
    let sections: [HomeDaySection<Item>]
    let emptyMessage: String
    let getID: (Item) -> AnyHashable
    var sectionSpacing: CGFloat = 12
    var headerSpacing: CGFloat = 2
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        if sections.isEmpty {
            HStack {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.vertical, 28)
            .padding(.horizontal, 4)
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

// MARK: - Activity tabs container

struct HomeActivityTabsCard: View {
    let selectedTab: HomeActivityTab
    let dictationSections: [HomeDaySection<SavedDictationEntry>]
    let meetingSections: [HomeDaySection<HomeMeetingListItem>]
    let isLoading: Bool
    let isLoadingMore: Bool
    let canLoadMoreDictations: Bool
    let canLoadMoreMeetings: Bool
    let copiedRowID: String?
    let canRetryFailedMeetings: Bool
    let failedMeetingRetryUnavailableReason: String?
    let onOpenDictation: (SavedDictationEntry) -> Void
    let onCopyDictation: (SavedDictationEntry) -> Void
    let onFlagDictation: (SavedDictationEntry) -> Void
    let dictationMenuItems: (SavedDictationEntry) -> [HomeRowMenuItem]
    let onOpenMeeting: (RecentMeetingItem) -> Void
    let onCopyMeeting: (RecentMeetingItem) -> Void
    let onFlagMeeting: (RecentMeetingItem) -> Void
    let onReviewMeetingSpeakers: (RecentMeetingItem) -> Void
    let meetingMenuItems: (RecentMeetingItem) -> [HomeRowMenuItem]
    let onRetryFailedMeeting: (MeetingSessionController.FailedMeetingItem) -> Void
    let onRevealFailedMeetingAudio: (MeetingSessionController.FailedMeetingItem) -> Void
    let onClearFailedMeeting: (MeetingSessionController.FailedMeetingItem) -> Void
    let onLoadMoreDictations: () -> Void
    let onLoadMoreMeetings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                switch selectedTab {
                case .dictations:
                    activitySection(
                        sections: dictationSections,
                        emptyMessage: "No recent dictations.",
                        canLoadMore: canLoadMoreDictations,
                        loadMoreTitle: "Load more",
                        loadMoreAction: onLoadMoreDictations,
                        getID: { AnyHashable($0.id) }
                    ) { entry in
                        HomeDictationRow(
                            entry: entry,
                            isCopied: copiedRowID == entry.id,
                            onOpen: { onOpenDictation(entry) },
                            onCopy: { onCopyDictation(entry) },
                            onFlag: { onFlagDictation(entry) },
                            menuItems: dictationMenuItems(entry)
                        )
                    }
                case .meetings:
                    activitySection(
                        sections: meetingSections,
                        emptyMessage: "No recent meetings.",
                        canLoadMore: canLoadMoreMeetings,
                        loadMoreTitle: "Load more",
                        loadMoreAction: onLoadMoreMeetings,
                        getID: { AnyHashable($0.id) }
                    ) { item in
                        switch item {
                        case .saved(let meeting):
                            HomeMeetingRow(
                                item: meeting,
                                isCopied: copiedRowID == meeting.id,
                                onOpen: { onOpenMeeting(meeting) },
                                onCopy: { onCopyMeeting(meeting) },
                                onFlag: { onFlagMeeting(meeting) },
                                onReviewSpeakers: { onReviewMeetingSpeakers(meeting) },
                                menuItems: meetingMenuItems(meeting)
                            )
                        case .failed(let failedMeeting):
                            HomeFailedMeetingInlineRow(
                                item: failedMeeting,
                                canRetry: canRetryFailedMeetings,
                                retryUnavailableReason: failedMeetingRetryUnavailableReason,
                                onRetry: { onRetryFailedMeeting(failedMeeting) },
                                onRevealAudio: { onRevealFailedMeetingAudio(failedMeeting) },
                                onClear: { onClearFailedMeeting(failedMeeting) }
                            )
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func activitySection<Item, Content: View>(
        sections: [HomeDaySection<Item>],
        emptyMessage: String,
        canLoadMore: Bool,
        loadMoreTitle: String,
        loadMoreAction: @escaping () -> Void,
        getID: @escaping (Item) -> AnyHashable,
        @ViewBuilder row: @escaping (Item) -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HomeDayGroupedList(
                sections: sections,
                emptyMessage: emptyMessage,
                getID: getID,
                sectionSpacing: 10,
                headerSpacing: 1,
                row: row
            )

            if canLoadMore || isLoadingMore {
                HomeLoadMoreButton(
                    title: loadMoreTitle,
                    isLoading: isLoadingMore,
                    action: loadMoreAction
                )
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
                Button("Cancel", action: onCancel)
                Spacer()
                Button("Review report") {
                    onSubmit(HomeFeedbackSubmission(
                        target: target,
                        issueKind: issueKind,
                        notes: notes,
                        includeDiagnostics: includeDiagnostics
                    ))
                }
                .buttonStyle(.borderedProminent)
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
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(stroke, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var background: Color {
        isSelected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035)
    }

    private var stroke: Color {
        isSelected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08)
    }
}

// MARK: - Meeting preview

struct HomeMeetingPreviewSheet: View {
    let preview: HomeMeetingPreview
    let onOpenMarkdown: () -> Void
    let onCopyForAgent: () -> Void
    let onReportIssue: () -> Void
    let onDone: () -> Void
    private let readableContent: HomeMeetingPreviewContent

    init(
        preview: HomeMeetingPreview,
        onOpenMarkdown: @escaping () -> Void,
        onCopyForAgent: @escaping () -> Void,
        onReportIssue: @escaping () -> Void,
        onDone: @escaping () -> Void
    ) {
        self.preview = preview
        self.onOpenMarkdown = onOpenMarkdown
        self.onCopyForAgent = onCopyForAgent
        self.onReportIssue = onReportIssue
        self.onDone = onDone
        self.readableContent = HomeMeetingPreviewContent.make(from: preview.markdown)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(preview.title)
                        .font(.system(size: 22, weight: .semibold))
                        .lineLimit(2)
                    Text(HomeMeetingPreviewSheet.dateFormatter.string(from: preview.date))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
            }

            if let audio = preview.audio {
                HomeMeetingPodcastPlayer(audio: audio)
            } else {
                Label("No retained audio", systemImage: "speaker.slash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                    )
            }

            Group {
                if let readError = preview.readError {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Could not preview this meeting", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text(readError)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Transcript")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .tracking(0.6)

                            if readableContent.transcriptLines.isEmpty {
                                Text(readableContent.fallbackText)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(Array(readableContent.transcriptLines.enumerated()), id: \.offset) { _, line in
                                        HomeMeetingTranscriptLineView(line: line)
                                    }
                                }
                                .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.025))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                }
            }

            HStack {
                Button {
                    onOpenMarkdown()
                } label: {
                    Label("Open Markdown", systemImage: "doc.text")
                }

                Button {
                    onCopyForAgent()
                } label: {
                    Label("Copy for agent", systemImage: "square.on.square")
                }

                Button {
                    onReportIssue()
                } label: {
                    Label("Report issue", systemImage: "flag")
                }

                Spacer()
            }
        }
        .padding(24)
        .frame(width: 680, height: 620)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

private struct HomeMeetingPodcastPlayer: View {
    let audio: MeetingAudioAttachment

    @ObservedObject private var playback = MeetingAudioPlayback.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ZStack {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Meeting audio")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.5)

                        Text(playback.compactTimeLabel(for: audio))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }

                HStack(spacing: 14) {
                    HomePodcastPlayerButton(
                        symbolName: "gobackward.15",
                        size: 34,
                        isPrimary: false,
                        isDisabled: !canSeek,
                        help: "Skip back 15 seconds"
                    ) {
                        playback.skip(audio, by: -15)
                    }

                    HomePodcastPlayerButton(
                        symbolName: playback.symbolName(for: audio),
                        size: 46,
                        isPrimary: playback.isActive(audio),
                        isDisabled: false,
                        help: "\(playback.buttonTitle(for: audio)) meeting audio"
                    ) {
                        playback.toggle(audio)
                    }

                    HomePodcastPlayerButton(
                        symbolName: "goforward.15",
                        size: 34,
                        isPrimary: false,
                        isDisabled: !canSeek,
                        help: "Skip forward 15 seconds"
                    ) {
                        playback.skip(audio, by: 15)
                    }
                }
            }

            MeetingAudioScrubber(
                attachment: audio,
                width: nil,
                showsTime: false
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        )
    }

    private var canSeek: Bool {
        playback.isActive(audio) && playback.duration > 0
    }
}

private struct HomePodcastPlayerButton: View {
    let symbolName: String
    let size: CGFloat
    let isPrimary: Bool
    let isDisabled: Bool
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbolName)
                .font(.system(size: size >= 40 ? 15 : 12, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(
                    Circle()
                        .fill(background)
                )
                .overlay(
                    Circle()
                        .stroke(Color.primary.opacity(isPrimary ? 0.0 : 0.08), lineWidth: 1)
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
        .help(help)
    }

    private var foreground: Color {
        if isPrimary { return .white }
        return .secondary
    }

    private var background: Color {
        if isPrimary { return Color.accentColor }
        return Color.primary.opacity(0.08)
    }
}

private struct HomeMeetingTranscriptLineView: View {
    let line: HomeMeetingTranscriptLine

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(line.time)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
                .padding(.top, 4)

            HomeMeetingSpeakerPill(speaker: line.speaker)

            Text(line.text)
                .font(.system(size: 13))
                .foregroundStyle(Color.primary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}

private struct HomeMeetingSpeakerPill: View {
    let speaker: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(speakerColor)
                .frame(width: 6, height: 6)

            Text(speaker)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(speakerColor)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 116, alignment: .leading)
        .background(
            Capsule(style: .continuous)
                .fill(speakerColor.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(speakerColor.opacity(0.24), lineWidth: 1)
        )
    }

    private var speakerColor: Color {
        HomeMeetingSpeakerColor.color(for: speaker)
    }
}

private enum HomeMeetingSpeakerColor {
    static func color(for speaker: String) -> Color {
        let palette: [NSColor] = [
            .systemBlue,
            .systemGreen,
            .systemPurple,
            .systemOrange,
            .systemPink,
            .systemTeal,
            .systemRed,
            .systemIndigo,
        ]

        let normalized = speaker.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalized.unicodeScalars.reduce(UInt32(0)) { partial, scalar in
            partial &+ scalar.value
        }
        let index = Int(value % UInt32(palette.count))
        return Color(nsColor: palette[index])
    }
}

struct HomeLoadMoreButton: View {
    let title: String
    let isLoading: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 13, weight: .semibold))
                }

                Text(isLoading ? "Loading" : title)
                    .font(.subheadline.weight(.medium))
            }
            .foregroundStyle(isLoading ? Color.secondary : Color.primary)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(isHovering ? 0.92 : 0.78))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.primary.opacity(isHovering ? 0.16 : 0.1), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(isHovering ? 0.1 : 0.04), radius: isHovering ? 8 : 4, x: 0, y: isHovering ? 4 : 2)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }
}

// MARK: - Needs-attention card

struct HomeNeedsAttentionCard: View {
    enum Destination {
        case failedMeetings
        case speakers
        case activity
        case privacy
        case models
    }

    struct Issue: Identifiable {
        let id: String
        let symbolName: String
        let title: String
        let detail: String
        let destination: Destination
        let actionTitle: String
    }

    let issues: [Issue]
    let onReview: (Issue) -> Void

    var body: some View {
        if let first = issues.first {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: first.symbolName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(first.title)
                            .font(.subheadline.weight(.semibold))
                        if issues.count > 1 {
                            Text("+\(issues.count - 1)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(first.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                reviewControl(first: first)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.orange.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.orange.opacity(0.28), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func reviewControl(first: Issue) -> some View {
        if issues.count <= 1 {
            Button(first.actionTitle) {
                onReview(first)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        } else {
            Menu {
                ForEach(issues) { issue in
                    Button {
                        onReview(issue)
                    } label: {
                        Label(issue.title, systemImage: issue.symbolName)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("Review")
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                }
            }
            .menuStyle(.borderlessButton)
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }
}

struct HomeFailedMeetingsCard: View {
    let items: [MeetingSessionController.FailedMeetingItem]
    let canRetry: Bool
    let retryUnavailableReason: String?
    let audioAttachment: (MeetingSessionController.FailedMeetingItem) -> MeetingAudioAttachment?
    let onRetry: (MeetingSessionController.FailedMeetingItem) -> Void
    let onRevealAudio: (MeetingSessionController.FailedMeetingItem) -> Void
    let onClear: (MeetingSessionController.FailedMeetingItem) -> Void
    let onOpenMeetings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .foregroundStyle(.orange)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.headline)
                Spacer()
                Button("Review all", action: onOpenMeetings)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.failureKind == .recordingTooShort ? "timer" : "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(item.failureKind == .recordingTooShort ? Color.secondary : Color.orange)
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
                        HomeMeetingAudioControl(
                            title: playback.buttonTitle(for: audio),
                            symbolName: playback.symbolName(for: audio),
                            isActive: playback.isActive(audio),
                            isPlaying: playback.isPlaying && playback.isActive(audio),
                            scrubber: playback.isActive(audio)
                                ? AnyView(MeetingAudioScrubber(attachment: audio, width: 190))
                                : nil
                        ) {
                            playback.toggle(audio)
                        }
                        .help("\(playback.buttonTitle(for: audio)) retained meeting audio")

                        Button {
                            onRevealAudio()
                        } label: {
                            Label("Show Audio", systemImage: "folder")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    } else {
                        Label("No audio kept", systemImage: "speaker.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    if item.isRetryable || item.isRetrying {
                        Button {
                            onRetry()
                        } label: {
                            Label(item.isRetrying ? "Retrying..." : "Try Again", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(retryDisabled)
                        .help(retryHelp)
                    }

                    Button(role: item.hasAudioFiles ? .destructive : nil) {
                        onClear()
                    } label: {
                        Label(item.hasAudioFiles ? "Delete" : "Dismiss", systemImage: item.hasAudioFiles ? "trash" : "xmark")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
    }

    private var retryDisabled: Bool {
        !canRetry || !item.isRetryable || item.isRetrying
    }

    private var retryHelp: String {
        if item.isRetrying {
            return "Retry is already running."
        }
        if !item.isRetryable {
            return "This meeting does not have enough saved audio to retry."
        }
        if let retryUnavailableReason {
            return retryUnavailableReason
        }
        if !canRetry {
            return "Wait for the current meeting work to finish before retrying."
        }
        return "Transcribe this saved audio again."
    }
}
