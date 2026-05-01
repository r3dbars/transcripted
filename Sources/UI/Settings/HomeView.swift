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
    case dictation
    case meeting

    var id: String { rawValue }

    var switchTitle: String {
        switch self {
        case .dictation: return "Dictation"
        case .meeting: return "Meetings"
        }
    }

    var title: String {
        switch self {
        case .dictation: return "Speak anywhere. It types where you were writing."
        case .meeting: return "Record the call. Keep the notes."
        }
    }

    var subtitle: String {
        switch self {
        case .dictation:
            return "Use your shortcut, say the thought, and Transcripted pastes cleaned text back into the app you were using."
        case .meeting:
            return "Capture local mic and system audio, then turn the conversation into searchable local Markdown."
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
        case .dictation: return "Works in any app with a text cursor."
        case .meeting: return "Saved locally for review and agent context."
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

struct HomeHeroCard: View {
    @Binding var selectedMode: HomeHeroMode
    let onStartDictation: () -> Void
    let onStartMeeting: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .center) {
                Label("Capture", systemImage: selectedMode.symbolName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.6)

                Spacer()

                Picker("", selection: $selectedMode) {
                    ForEach(HomeHeroMode.allCases) { mode in
                        Text(mode.switchTitle).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
            }

            heroCopy
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var heroCopy: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 9) {
                Text(selectedMode.title)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(selectedMode.subtitle)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 12) {
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
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selectedAction: () -> Void {
        switch selectedMode {
        case .dictation: return onStartDictation
        case .meeting: return onStartMeeting
        }
    }
}

// MARK: - Stats rail

struct HomeStatsRail: View {
    let header: String
    let stats: [HomeStatItem]
    let streak: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(header)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)

            VStack(alignment: .leading, spacing: 12) {
                ForEach(stats) { stat in
                    HStack(alignment: .top, spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(Color.primary.opacity(0.06))
                            Image(systemName: stat.symbolName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 26, height: 26)
                        .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(stat.value)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Color.primary)
                            Text(stat.label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let streak, streak > 0 {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(.orange)
                        Text("\(streak) day streak")
                            .font(.subheadline.weight(.semibold))
                    }
                    Text(streak == 1 ? "Keep it going tomorrow." : "Nice run.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}

// MARK: - Inline stats strip (narrow layout fallback)

struct HomeStatsStrip: View {
    let stats: [HomeStatItem]
    let streak: Int?

    var body: some View {
        HStack(spacing: 22) {
            ForEach(stats) { stat in
                VStack(alignment: .leading, spacing: 2) {
                    Label(stat.value, systemImage: stat.symbolName)
                        .font(.system(size: 18, weight: .semibold))
                    Text(stat.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if let streak, streak > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .foregroundStyle(.orange)
                        Text("\(streak)")
                            .font(.system(size: 18, weight: .semibold))
                    }
                    Text("day streak")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
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
                help: "Send feedback",
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
        .padding(.vertical, 9)
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
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if !entry.sourceAppName.isEmpty, entry.sourceAppName != "Unknown" {
                    Text(entry.sourceAppName)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
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
            menuItems: menuItems
        ) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
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
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 4) {
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
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Recent activity")
                        .font(.system(size: 15, weight: .semibold))
                    Text(activitySubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)
            }

            if isLoading {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading recent activity")
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
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
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
        VStack(alignment: .leading, spacing: 12) {
            HomeDayGroupedList(
                sections: sections,
                emptyMessage: emptyMessage,
                getID: getID,
                row: row
            )

            if canLoadMore {
                HomeLoadMoreButton(
                    title: loadMoreTitle,
                    isLoading: isLoadingMore,
                    action: loadMoreAction
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activitySubtitle: String {
        switch selectedTab {
        case .dictations:
            return canLoadMoreDictations ? "Showing the latest 10 dictations" : "Latest dictations"
        case .meetings:
            return canLoadMoreMeetings ? "Showing the latest 10 meetings" : "Latest meetings"
        }
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
