import SwiftUI

struct SettingsSidebarSection {
    let pages: [TranscriptedSettingsPage]

    /// Content-first rows that are always visible: Today, the capture library, plus the agent connection.
    static let primarySection = SettingsSidebarSection(
        pages: [.today, .home, .dictations, .writing, .people, .connectAgent]
    )

    /// Configuration lives on one combined scrolling page (.general),
    /// reached from the sidebar's Settings toggle. No tab strip.
    static func isSettingsPage(_ page: TranscriptedSettingsPage) -> Bool {
        page == .general
    }
}

/// Quiet hover treatment for the sidebar's bottom-line controls (gear,
/// version): the same rounded fill the nav rows use, no strokes or glows.
struct SidebarQuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyleBody(configuration: configuration)
    }

    private struct StyleBody: View {
        let configuration: Configuration
        @State private var isHovering = false

        var body: some View {
            configuration.label
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? Color.primary.opacity(0.045) : Color.clear)
                )
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { isHovering = $0 }
        }
    }
}

struct SettingsSidebarRow: View {
    let page: TranscriptedSettingsPage
    let isSelected: Bool

    @State private var isHovering = false
    // Observed, so the badge goes away as soon as the Writing page sets it.
    @AppStorage(WritingSidebarNewBadge.dismissedDefaultsKey) private var writingNewBadgeDismissed = false

    var body: some View {
        // Flat, Things-style row: a quiet fill for selection, a fainter one
        // on hover — no strokes, glows, or shadows.
        HStack(spacing: 6) {
            Label(page.title, systemImage: page.systemImage)
                .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.72))

            Spacer(minLength: 0)

            if WritingSidebarNewBadge.isShown(for: page, dismissed: writingNewBadgeDismissed) {
                SettingsSidebarNewBadge()
            }
        }
        .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        .padding(.horizontal, 9)
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(
                    isSelected
                        ? Color.primary.opacity(0.09)
                        : (isHovering ? Color.primary.opacity(0.045) : Color.clear)
                )
        )
        .accessibilityIdentifier(page.automationIdentifier)
        .help(page.navigationHelp)
        .onHover { isHovering = $0 }
    }
}

/// Trailing "New" on a sidebar row, drawn like the footer's update badge:
/// a small orange dot and quiet text, no pill or stroke.
struct SettingsSidebarNewBadge: View {
    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(Color.orange)
                .frame(width: 5, height: 5)
            Text("New")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LibraryTokens.ink2)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("New")
    }
}
