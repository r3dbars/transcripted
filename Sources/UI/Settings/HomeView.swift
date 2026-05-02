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

    private static func groupByDay<Item>(
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

struct HomeDeleteConfirmation: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let perform: () -> Void
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

    var title: String {
        switch self {
        case .dictation: return "Dictate anywhere"
        case .meeting: return "Record meetings"
        }
    }

    var subtitle: String {
        switch self {
        case .dictation:
            return "Speak once. Clean text lands back at your cursor."
        case .meeting:
            return "Capture the call. Save searchable local notes."
        }
    }

    var actionTitle: String {
        switch self {
        case .dictation: return "Start dictation"
        case .meeting: return "Record meeting"
        }
    }

    var learnTitle: String {
        switch self {
        case .dictation: return "Works anywhere you write."
        case .meeting: return "Saved as local Markdown."
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
    let id = UUID()
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
    let markdown: String
    let readError: String?
    let feedbackTarget: HomeFeedbackTarget

    init(item: RecentMeetingItem, markdown: String, readError: String? = nil) {
        id = item.id
        title = item.title
        date = item.date
        transcriptURL = item.transcriptURL
        self.markdown = markdown
        self.readError = readError
        feedbackTarget = HomeFeedbackTarget.meeting(item)
    }
}

// MARK: - Welcome header

struct HomeWelcomeHeader: View {
    let name: String
    let summary: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Welcome back, \(name)")
                .font(.system(size: 28, weight: .semibold))
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Hero card

struct HomeHeroCard<ActivityContent: View>: View {
    @Binding var selectedMode: HomeHeroMode
    let onStartDictation: () -> Void
    let onStartMeeting: () -> Void
    private let activityContent: () -> ActivityContent

    init(
        selectedMode: Binding<HomeHeroMode>,
        onStartDictation: @escaping () -> Void,
        onStartMeeting: @escaping () -> Void,
        @ViewBuilder activityContent: @escaping () -> ActivityContent
    ) {
        _selectedMode = selectedMode
        self.onStartDictation = onStartDictation
        self.onStartMeeting = onStartMeeting
        self.activityContent = activityContent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HomeHeroModeTabs(selectedMode: $selectedMode)
                .padding(.leading, 36)
                .padding(.bottom, -12)
                .zIndex(1)

            VStack(alignment: .leading, spacing: 18) {
                heroCopy

                Divider()
                    .opacity(0.55)

                activityContent()
            }
            .padding(.top, 30)
            .padding(.horizontal, 28)
            .padding(.bottom, 22)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(cardFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 9) {
                Text(selectedMode.title)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(selectedMode.subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button(action: selectedAction) {
                    Label(selectedMode.actionTitle, systemImage: selectedMode.symbolName)
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .help(selectedMode.actionTitle)

                HStack(spacing: 6) {
                    Text(selectedMode.learnTitle)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardFill: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.82)
    }

    private var selectedAction: () -> Void {
        switch selectedMode {
        case .dictation: return onStartDictation
        case .meeting: return onStartMeeting
        }
    }
}

private struct HomeHeroModeTabs: View {
    @Binding var selectedMode: HomeHeroMode

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(HomeHeroMode.tabOrder) { mode in
                HomeHeroModeTab(
                    mode: mode,
                    isSelected: selectedMode == mode,
                    action: {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            selectedMode = mode
                        }
                    }
                )
            }
        }
        .background(alignment: .bottom) {
            Rectangle()
                .fill(surfaceFill)
                .frame(height: 18)
                .offset(y: 10)
                .padding(.horizontal, -1)
        }
    }

    private var surfaceFill: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.82)
    }
}

private struct HomeHeroModeTab: View {
    let mode: HomeHeroMode
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: mode.symbolName)
                    .font(.system(size: 12, weight: .semibold))
                Text(mode.switchTitle)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 18)
            .padding(.top, isSelected ? 12 : 10)
            .padding(.bottom, isSelected ? 11 : 9)
            .background(
                HomeHeroTabShape(cornerRadius: 12)
                    .fill(tabFill)
            )
            .overlay(
                HomeHeroTabBorderShape(cornerRadius: 12)
                    .stroke(tabStroke, lineWidth: 1)
            )
            .overlay(alignment: .bottom) {
                if isSelected {
                    Rectangle()
                        .fill(surfaceFill)
                        .frame(height: 14)
                        .offset(y: 8)
                }
            }
        }
        .buttonStyle(.plain)
        .help("Show \(mode.switchTitle.lowercased())")
        .zIndex(isSelected ? 1 : 0)
    }

    private var tabFill: Color {
        if isSelected {
            return surfaceFill
        }
        return surfaceFill.opacity(0.62)
    }

    private var tabStroke: Color {
        isSelected ? Color.primary.opacity(0.08) : Color.primary.opacity(0.03)
    }

    private var surfaceFill: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.82)
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

    var body: some View {
        HStack(spacing: 4) {
            iconButton(
                systemName: isCopied ? "checkmark" : "square.on.square",
                help: isCopied ? "Copied" : "Copy",
                action: onCopy
            )

            iconButton(
                systemName: "flag",
                help: "Report issue",
                action: onFlag
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
    var compact: Bool = false
    @ViewBuilder let content: () -> Content

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Button(action: onOpen) {
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
            .buttonStyle(.plain)

            HomeRowActionButtons(
                isCopied: isCopied,
                onCopy: onCopy,
                onFlag: onFlag,
                menuItems: menuItems
            )
            .opacity(isHovering ? 1 : 0.55)
            .animation(.easeOut(duration: 0.12), value: isHovering)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, compact ? 5 : 9)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.035) : Color.clear)
        )
        .onHover { isHovering = $0 }
    }
}

struct HomeDictationRow: View {
    let entry: SavedDictationEntry
    let isCopied: Bool
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onFlag: () -> Void
    let menuItems: [HomeRowMenuItem]

    var body: some View {
        HomeActivityRowShell(
            timeString: HomeActivityRowFormatting.timeFormatter.string(from: entry.createdAt),
            isCopied: isCopied,
            onOpen: onOpen,
            onCopy: onCopy,
            onFlag: onFlag,
            menuItems: menuItems
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text(preview)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private var preview: String {
        let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entry.title }
        return trimmed
    }
}

struct HomeMeetingRow: View {
    let item: RecentMeetingItem
    let isCopied: Bool
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onFlag: () -> Void
    let menuItems: [HomeRowMenuItem]

    var body: some View {
        HomeActivityRowShell(
            timeString: HomeActivityRowFormatting.timeFormatter.string(from: item.date),
            isCopied: isCopied,
            onOpen: onOpen,
            onCopy: onCopy,
            onFlag: onFlag,
            menuItems: menuItems,
            compact: true
        ) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                Text(item.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
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
    let meetingSections: [HomeDaySection<RecentMeetingItem>]
    let isLoading: Bool
    let isLoadingMore: Bool
    let canLoadMoreDictations: Bool
    let canLoadMoreMeetings: Bool
    let copiedRowID: String?
    let onOpenDictation: (SavedDictationEntry) -> Void
    let onCopyDictation: (SavedDictationEntry) -> Void
    let onFlagDictation: (SavedDictationEntry) -> Void
    let dictationMenuItems: (SavedDictationEntry) -> [HomeRowMenuItem]
    let onOpenMeeting: (RecentMeetingItem) -> Void
    let onCopyMeeting: (RecentMeetingItem) -> Void
    let onFlagMeeting: (RecentMeetingItem) -> Void
    let meetingMenuItems: (RecentMeetingItem) -> [HomeRowMenuItem]
    let onLoadMoreDictations: () -> Void
    let onLoadMoreMeetings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(selectedTab.label)
                        .font(.system(size: 15, weight: .semibold))
                }

                Spacer(minLength: 12)
            }

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
                        loadMoreTitle: "Load more dictations",
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
                        loadMoreTitle: "Load more meetings",
                        loadMoreAction: onLoadMoreMeetings,
                        getID: { AnyHashable($0.id) }
                    ) { item in
                        HomeMeetingRow(
                            item: item,
                            isCopied: copiedRowID == item.id,
                            onOpen: { onOpenMeeting(item) },
                            onCopy: { onCopyMeeting(item) },
                            onFlag: { onFlagMeeting(item) },
                            menuItems: meetingMenuItems(item)
                        )
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

            Picker("Issue", selection: $issueKind) {
                ForEach(HomeFeedbackIssueKind.allCases) { kind in
                    Text(kind.label).tag(kind)
                }
            }
            .pickerStyle(.segmented)

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

// MARK: - Meeting preview

struct HomeMeetingPreviewSheet: View {
    let preview: HomeMeetingPreview
    let onOpenMarkdown: () -> Void
    let onCopyForAgent: () -> Void
    let onReportIssue: () -> Void
    let onDone: () -> Void

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

                            if transcriptLines.isEmpty {
                                Text(cleanedMarkdown)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(Array(transcriptLines.enumerated()), id: \.offset) { _, line in
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

    private var cleanedMarkdown: String {
        Self.readableMarkdown(from: preview.markdown)
    }

    private var transcriptLines: [HomeMeetingTranscriptLine] {
        cleanedMarkdown
            .split(separator: "\n", omittingEmptySubsequences: false)
            .compactMap { Self.parseTranscriptLine(String($0)) }
    }

    private static func readableMarkdown(from markdown: String) -> String {
        var lines = markdown.components(separatedBy: .newlines)

        if lines.first?.trimmingCharacters(in: .whitespacesAndNewlines) == "---",
           let endIndex = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "---" }) {
            lines.removeSubrange(...endIndex)
        }

        if let transcriptIndex = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines) == "## Full Transcript" }) {
            lines = Array(lines.dropFirst(transcriptIndex + 1))
        }

        lines = lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed != "---" && !trimmed.hasPrefix("*Generated by Transcripted")
        }

        return lines
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseTranscriptLine(_ rawLine: String) -> HomeMeetingTranscriptLine? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("["),
              let timeEnd = line.firstIndex(of: "]") else { return nil }

        let time = String(line[line.index(after: line.startIndex)..<timeEnd])
        var remainder = line[line.index(after: timeEnd)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var speaker = "Speaker"
        if remainder.hasPrefix("["),
           let speakerEnd = remainder.firstIndex(of: "]") {
            speaker = String(remainder[remainder.index(after: remainder.startIndex)..<speakerEnd])
            remainder = remainder[remainder.index(after: speakerEnd)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard !remainder.isEmpty else { return nil }
        return HomeMeetingTranscriptLine(time: time, speaker: speaker, text: remainder)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

private struct HomeMeetingTranscriptLine {
    let time: String
    let speaker: String
    let text: String
}

private struct HomeMeetingTranscriptLineView: View {
    let line: HomeMeetingTranscriptLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(line.time)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)

            Text(line.speaker)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 92, alignment: .leading)

            Text(line.text)
                .font(.system(size: 13))
                .foregroundStyle(Color.primary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

struct HomeLoadMoreButton: View {
    let title: String
    let isLoading: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }

                Text(isLoading ? "Loading" : title)
                    .font(.subheadline.weight(.medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
        .buttonStyle(.borderless)
        .disabled(isLoading)
    }
}

// MARK: - Needs-attention card

struct HomeNeedsAttentionCard: View {
    struct Issue: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
    }

    let issues: [Issue]
    let onOpenPrivacy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 14, weight: .semibold))
                Text("Needs attention")
                    .font(.headline)
                Spacer()
                Button("Review", action: onOpenPrivacy)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(issues) { issue in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 5, height: 5)
                            .padding(.top, 7)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(issue.title)
                                .font(.subheadline.weight(.semibold))
                            Text(issue.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
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
}
