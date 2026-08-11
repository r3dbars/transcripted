import SwiftUI

struct SettingsSidebarSection {
    let pages: [TranscriptedSettingsPage]

    /// Content-first rows that are always visible: the capture library plus the agent connection.
    static let primarySection = SettingsSidebarSection(
        pages: [.home, .dictations, .people, .connectAgent]
    )

    /// Configuration lives on one combined scrolling page, reached from the
    /// sidebar's Settings toggle. No tab strip.
    static let settingsSections = [
        SettingsSidebarSection(pages: [.general])
    ]

    static func isSettingsPage(_ page: TranscriptedSettingsPage) -> Bool {
        settingsSections.contains { $0.pages.contains(page) }
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

    var body: some View {
        // Flat, Things-style row: a quiet fill for selection, a fainter one
        // on hover — no strokes, glows, or shadows.
        Label(page.title, systemImage: page.systemImage)
            .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.72))
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
