import SwiftUI

struct SettingsSidebarSection: Identifiable {
    let id: String
    let title: String?
    let pages: [TranscriptedSettingsPage]

    /// Content-first rows that are always visible: the capture library plus the agent connection.
    static let primarySection = SettingsSidebarSection(
        id: "primary",
        title: nil,
        pages: [.home, .dictations, .people, .connectAgent]
    )

    /// Configuration rows, demoted behind the sidebar's Settings toggle.
    static let settingsSections = [
        SettingsSidebarSection(id: "setup", title: "Setup", pages: [.general, .storage]),
        SettingsSidebarSection(id: "trust", title: "Trust", pages: [.about])
    ]

    static func isSettingsPage(_ page: TranscriptedSettingsPage) -> Bool {
        settingsSections.contains { $0.pages.contains(page) }
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
            .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
            .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.72))
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
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
