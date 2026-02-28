import SwiftUI

/// Minimal sidebar navigation for the settings window
/// SuperWhisper-inspired: no branding, no footer, just simple nav items
@available(macOS 14.0, *)
struct SettingsSidebarView: View {

    @Binding var selectedTab: SettingsTab
    @ObservedObject var statsService: StatsService

    @State private var hoveredTab: SettingsTab?

    var body: some View {
        VStack(spacing: 0) {
            // Navigation items — top aligned with generous top padding
            VStack(spacing: Spacing.xs) {
                ForEach(SettingsTab.allCases) { tab in
                    SidebarNavItem(
                        tab: tab,
                        isSelected: selectedTab == tab,
                        isHovered: hoveredTab == tab,
                        onSelect: {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                selectedTab = tab
                            }
                        },
                        onHover: { isHovered in
                            hoveredTab = isHovered ? tab : nil
                        }
                    )
                }
            }
            .padding(.horizontal, Spacing.sm)
            .padding(.top, Spacing.lg)

            Spacer()
        }
        .frame(maxHeight: .infinity)
        .background(Color.panelCharcoalElevated)
    }
}

// MARK: - Sidebar Navigation Item

@available(macOS 14.0, *)
struct SidebarNavItem: View {

    let tab: SettingsTab
    let isSelected: Bool
    let isHovered: Bool
    let onSelect: () -> Void
    let onHover: (Bool) -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Spacing.ms) {
                // Icon
                Image(systemName: tab.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(iconColor)
                    .frame(width: 20)

                // Label
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                    .foregroundColor(textColor)

                Spacer()
            }
            .padding(.horizontal, Spacing.ms)
            .padding(.vertical, Spacing.sm)
            .background {
                RoundedRectangle(cornerRadius: Radius.lawsButton)
                    .fill(backgroundColor)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radius.lawsButton))
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            onHover(hovering)
        }
        .accessibilityLabel(tab.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // Subtle blue-tinted dark for selected, elevated for hover, clear otherwise
    private var backgroundColor: Color {
        if isSelected {
            return Color(hex: "#2A3040")
        } else if isHovered {
            return Color.panelCharcoalSurface
        }
        return .clear
    }

    private var iconColor: Color {
        if isSelected {
            return .accentBlueLight
        } else if isHovered {
            return .panelTextPrimary
        }
        return .panelTextSecondary
    }

    private var textColor: Color {
        if isSelected || isHovered {
            return .panelTextPrimary
        }
        return .panelTextSecondary
    }
}

// MARK: - Preview

@available(macOS 14.0, *)
#Preview {
    HStack(spacing: 0) {
        SettingsSidebarView(
            selectedTab: .constant(.dashboard),
            statsService: StatsService.shared
        )
        .frame(width: 180)

        Color.panelCharcoal
    }
    .frame(width: 400, height: 600)
}
