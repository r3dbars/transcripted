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
        SettingsSidebarSection(id: "setup", title: "Setup", pages: [.general, .storage, .beta]),
        SettingsSidebarSection(id: "trust", title: "Trust", pages: [.support, .about])
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
        Label(page.title, systemImage: page.systemImage)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .padding(.horizontal, 9)
            .contentShape(Rectangle())
            .settingsHoverGlow(
                isActive: isHovering && !isSelected,
                cornerRadius: 8,
                fill: Color.primary.opacity(0.032),
                stroke: Color.accentColor.opacity(0.14),
                shadow: Color.accentColor.opacity(0.08),
                shadowRadius: 7
            )
            .accessibilityIdentifier(page.automationIdentifier)
            .onHover { isHovering = $0 }
    }
}
