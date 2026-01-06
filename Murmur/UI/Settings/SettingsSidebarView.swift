import SwiftUI

/// Sidebar navigation for the settings window
/// Displays app branding at top, navigation items, and version at bottom
@available(macOS 14.0, *)
struct SettingsSidebarView: View {

    @Binding var selectedTab: SettingsTab
    @ObservedObject var statsService: StatsService

    @State private var hoveredTab: SettingsTab?

    var body: some View {
        VStack(spacing: 0) {
            // App branding header
            headerSection
                .padding(.top, Spacing.lg)
                .padding(.bottom, Spacing.xl)

            // Navigation items
            navigationSection

            Spacer()

            // Version footer
            footerSection
                .padding(.bottom, Spacing.lg)
        }
        .frame(maxHeight: .infinity)
        .background(Color.panelCharcoalElevated)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(spacing: Spacing.sm) {
            // App icon placeholder (could be actual app icon)
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [Color.recordingCoral, Color.recordingCoralDeep],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 48, height: 48)

                Image(systemName: "waveform")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(.white)
            }

            // App name
            Text("Transcripted")
                .font(.headingMedium)
                .foregroundColor(.panelTextPrimary)
        }
        .padding(.horizontal, Spacing.md)
    }

    // MARK: - Navigation

    private var navigationSection: some View {
        VStack(spacing: Spacing.xs) {
            ForEach(SettingsTab.allCases) { tab in
                SidebarNavItem(
                    tab: tab,
                    isSelected: selectedTab == tab,
                    isHovered: hoveredTab == tab,
                    onSelect: {
                        withAnimation(.lawsStateChange) {
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
    }

    // MARK: - Footer

    private var footerSection: some View {
        VStack(spacing: Spacing.xs) {
            // Quick stats
            if statsService.totalRecordings > 0 {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.attentionGreen)

                    Text("\(statsService.totalRecordings) recordings")
                        .font(.caption)
                        .foregroundColor(.panelTextMuted)
                }
            }

            // Version
            Text("v1.0.0")
                .font(.tiny)
                .foregroundColor(.panelTextMuted)
        }
        .padding(.horizontal, Spacing.md)
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
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(iconColor)
                    .frame(width: 24)

                // Label
                Text(tab.rawValue)
                    .font(.bodyMedium)
                    .foregroundColor(textColor)

                Spacer()

                // Selection indicator
                if isSelected {
                    Circle()
                        .fill(Color.recordingCoral)
                        .frame(width: 6, height: 6)
                }
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

    private var backgroundColor: Color {
        if isSelected {
            return Color.recordingCoral.opacity(0.15)
        } else if isHovered {
            return Color.panelCharcoalSurface
        }
        return .clear
    }

    private var iconColor: Color {
        if isSelected {
            return .recordingCoral
        } else if isHovered {
            return .panelTextPrimary
        }
        return .panelTextSecondary
    }

    private var textColor: Color {
        if isSelected {
            return .panelTextPrimary
        } else if isHovered {
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
