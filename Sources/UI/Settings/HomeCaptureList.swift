import SwiftUI

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

/// Cached header formatter; `HomeDayGroupedList` is generic, so the static
/// storage lives here.
private enum HomeDayGroupedListFormatting {
    static let headerFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMMM d"
        return formatter
    }()
}

struct HomeDayGroupedList<Item, Row: View>: View {
    let sections: [HomeDaySection<Item>]
    let emptyMessage: String
    var emptyState: HomeListEmptyState? = nil
    let getID: (Item) -> AnyHashable
    var sectionSpacing: CGFloat = 12
    var headerSpacing: CGFloat = 2
    @ViewBuilder let row: (Item) -> Row

    private static var headerFormatter: DateFormatter {
        HomeDayGroupedListFormatting.headerFormatter
    }

    /// Plain-words day header: "Today", "Yesterday", or "Monday, August 3" —
    /// nothing the reader has to decode.
    static func headerTitle(for section: HomeDaySection<Item>) -> String {
        if section.label == "Today" || section.label == "Yesterday" {
            return section.label
        }
        return headerFormatter.string(from: section.day)
    }

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
                        Text(Self.headerTitle(for: section))
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(0.88)
                            .textCase(.uppercase)
                            .foregroundStyle(LibraryTokens.ink2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 6)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(LibraryTokens.hairline)
                                    .frame(height: 1)
                            }

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

/// Search box over the Home meetings list. `HomeViewModel` matches the query
/// against every saved meeting's title, date, and named speakers through
/// `HomeMeetingSearchIndex`; it never reads transcript bodies, so it stays
/// cheap even for large libraries.
struct HomeMeetingSearchField: View {
    @Binding var query: String
    /// Bump to move keyboard focus into the field (⌘F, or the header
    /// magnifier revealing the bar). Also focuses on first appearance when
    /// the token is already non-zero, so a request made while the bar was
    /// hidden lands once it mounts.
    var focusRequestToken: Int = 0

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Find meetings", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .task(id: focusRequestToken) {
                    guard focusRequestToken > 0 else { return }
                    isFocused = true
                }
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
