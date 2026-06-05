import SwiftUI

struct SettingsSidebarSection: Identifiable {
    let id: String
    let title: String?
    let pages: [TranscriptedSettingsPage]

    static let defaultSections = [
        SettingsSidebarSection(id: "home", title: nil, pages: [.home]),
        SettingsSidebarSection(id: "setup", title: "Setup", pages: [.general, .storage, .connectAgent, .beta]),
        SettingsSidebarSection(id: "trust", title: "Trust", pages: [.support, .about])
    ]
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
            .onHover { isHovering = $0 }
    }
}
