import SwiftUI

// MARK: - Button Styles

/// Primary button style — coral fill, simple press feedback
@available(macOS 14.0, *)
struct SettingsPrimaryButtonStyle: ButtonStyle {

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.bodySmall)
            .fontWeight(.medium)
            .foregroundColor(.white)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background {
                RoundedRectangle(cornerRadius: Radius.lawsButton)
                    .fill(Color.recordingCoral)
            }
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

/// Secondary button style — subtle background
@available(macOS 14.0, *)
struct SettingsSecondaryButtonStyle: ButtonStyle {

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.bodySmall)
            .foregroundColor(isHovered ? .panelTextPrimary : .panelTextSecondary)
            .padding(.horizontal, Spacing.ms)
            .padding(.vertical, Spacing.sm)
            .background {
                RoundedRectangle(cornerRadius: Radius.lawsButton)
                    .fill(Color.panelCharcoalSurface)
            }
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

/// Destructive button style for dangerous actions
@available(macOS 14.0, *)
struct SettingsDestructiveButtonStyle: ButtonStyle {

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.bodySmall)
            .fontWeight(.medium)
            .foregroundColor(isHovered ? .white : .errorRed)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background {
                RoundedRectangle(cornerRadius: Radius.lawsButton)
                    .fill(isHovered ? Color.errorRed : Color.errorRed.opacity(0.15))
            }
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

/// Icon button style (for toolbar-style buttons)
@available(macOS 14.0, *)
struct SettingsIconButtonStyle: ButtonStyle {

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundColor(isHovered ? .panelTextPrimary : .panelTextSecondary)
            .frame(width: 28, height: 28)
            .background {
                Circle()
                    .fill(isHovered ? Color.panelCharcoalSurface : Color.clear)
            }
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .onHover { hovering in
                isHovered = hovering
            }
    }
}
