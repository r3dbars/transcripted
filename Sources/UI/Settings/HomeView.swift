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
    @Published private(set) var todayDictationCount: Int = 0
    @Published private(set) var todayMeetingCount: Int = 0
    @Published private(set) var isLoading: Bool = false

    private var refreshTask: Task<Void, Never>?

    // Settings Home must open instantly, even for users with thousands of dictations.
    // Keep the dashboard to a small recent slice and leave deep history to the dedicated pages/files.
    private let listLimit = 40

    var welcomeName: String {
        let full = NSFullUserName().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !full.isEmpty else { return "there" }
        return full.split(separator: " ").first.map(String.init) ?? full
    }

    func refresh() {
        refreshTask?.cancel()
        isLoading = true
        let limit = listLimit
        refreshTask = Task { @MainActor in
            let snapshot = await RecentCaptureLoader.load(limit: limit)
            guard !Task.isCancelled else { return }
            let calendar = Calendar.current
            self.recentDictationCount = snapshot.dictations.count
            self.recentMeetingCount = snapshot.meetings.count
            self.todayDictationCount = snapshot.dictations.lazy.filter { calendar.isDateInToday($0.createdAt) }.count
            self.todayMeetingCount = snapshot.meetings.lazy.filter { calendar.isDateInToday($0.date) }.count
            self.dictationDaySections = Self.groupByDay(snapshot.dictations, dateForItem: \.createdAt)
            self.meetingDaySections = Self.groupByDay(snapshot.meetings, dateForItem: \.date)
            self.isLoading = false
        }
    }

    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
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

// MARK: - Stats summary

struct HomeStatItem: Identifiable {
    let id = UUID()
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
    let title: String
    let subtitle: String
    let primaryTitle: String
    let primaryAction: () -> Void
    let secondaryTitle: String
    let secondaryAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.primary)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 14) {
                Button(action: primaryAction) {
                    Label(primaryTitle, systemImage: "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: secondaryAction) {
                    Text(secondaryTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.accentColor.opacity(0.18),
                            Color.accentColor.opacity(0.05)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.accentColor.opacity(0.22), lineWidth: 1)
        )
    }
}

// MARK: - Stats rail

struct HomeStatsRail: View {
    let header: String
    let stats: [HomeStatItem]
    let streak: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(header)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .tracking(0.6)

            VStack(alignment: .leading, spacing: 14) {
                ForEach(stats) { stat in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stat.value)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(Color.primary)
                        Text(stat.label)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
        .padding(18)
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
                    Text(stat.value)
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
                Menu {
                    ForEach(menuItems) { item in
                        if item.isDestructive {
                            Button(role: .destructive, action: item.action) {
                                Label(item.title, systemImage: item.symbolName)
                            }
                        } else {
                            Button(action: item.action) {
                                Label(item.title, systemImage: item.symbolName)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
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

// MARK: - Activity rows

struct HomeDictationRow: View {
    let entry: SavedDictationEntry
    let isCopied: Bool
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onFlag: () -> Void
    let menuItems: [HomeRowMenuItem]

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
        .padding(.vertical, 10)
        .onHover { isHovering = $0 }
    }

    private var timeString: String {
        Self.timeFormatter.string(from: entry.createdAt)
    }

    private var preview: String {
        let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return entry.title }
        return trimmed
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "h:mm a"
        return f
    }()
}

struct HomeMeetingRow: View {
    let item: RecentMeetingItem
    let isCopied: Bool
    let onOpen: () -> Void
    let onCopy: () -> Void
    let onFlag: () -> Void
    let menuItems: [HomeRowMenuItem]

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
        .padding(.vertical, 10)
        .onHover { isHovering = $0 }
    }

    private var timeString: String {
        Self.timeFormatter.string(from: item.date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "h:mm a"
        return f
    }()
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
    @Binding var selectedTab: HomeActivityTab
    let dictationSections: [HomeDaySection<SavedDictationEntry>]
    let meetingSections: [HomeDaySection<RecentMeetingItem>]
    let isLoading: Bool
    let copiedRowID: String?
    let onOpenDictation: (SavedDictationEntry) -> Void
    let onCopyDictation: (SavedDictationEntry) -> Void
    let onFlagDictation: (SavedDictationEntry) -> Void
    let dictationMenuItems: (SavedDictationEntry) -> [HomeRowMenuItem]
    let onOpenMeeting: (RecentMeetingItem) -> Void
    let onCopyMeeting: (RecentMeetingItem) -> Void
    let onFlagMeeting: (RecentMeetingItem) -> Void
    let meetingMenuItems: (RecentMeetingItem) -> [HomeRowMenuItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("", selection: $selectedTab) {
                ForEach(HomeActivityTab.allCases) { tab in
                    Text(tab.label).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320, alignment: .leading)

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
                    HomeDayGroupedList(
                        sections: dictationSections,
                        emptyMessage: "No recent dictations.",
                        getID: { AnyHashable($0.id) },
                        row: { entry in
                            HomeDictationRow(
                                entry: entry,
                                isCopied: copiedRowID == entry.id,
                                onOpen: { onOpenDictation(entry) },
                                onCopy: { onCopyDictation(entry) },
                                onFlag: { onFlagDictation(entry) },
                                menuItems: dictationMenuItems(entry)
                            )
                        }
                    )
                case .meetings:
                    HomeDayGroupedList(
                        sections: meetingSections,
                        emptyMessage: "No recent meetings.",
                        getID: { AnyHashable($0.id) },
                        row: { item in
                            HomeMeetingRow(
                                item: item,
                                isCopied: copiedRowID == item.id,
                                onOpen: { onOpenMeeting(item) },
                                onCopy: { onCopyMeeting(item) },
                                onFlag: { onFlagMeeting(item) },
                                menuItems: meetingMenuItems(item)
                            )
                        }
                    )
                }
            }
        }
        .padding(20)
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
