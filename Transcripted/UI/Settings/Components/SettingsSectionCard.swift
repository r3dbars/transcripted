import SwiftUI

/// Minimal settings section card — plain dark container with gray section header above
/// SuperWhisper-inspired: no gradients, no glow, no hover effects
@available(macOS 14.0, *)
struct SettingsSectionCard<Content: View>: View {

    let icon: String
    let title: String
    let subtitle: String?
    let content: Content

    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Section header — simple gray uppercase label above the card
            Text(title.uppercased())
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.panelTextMuted)
                .tracking(0.8)

            // Plain container
            VStack(alignment: .leading, spacing: Spacing.md) {
                content
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                    .fill(Color.panelCharcoalElevated)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                    .stroke(Color.panelCharcoalSurface, lineWidth: 1)
            }
        }
    }
}

// MARK: - Focus Change Modifier

@available(macOS 14.0, *)
struct FocusChangeModifier: ViewModifier {
    let onChange: (Bool) -> Void
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .onChange(of: isFocused) { _, newValue in
                onChange(newValue)
            }
    }
}

@available(macOS 14.0, *)
extension View {
    func onFocusChange(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(FocusChangeModifier(onChange: action))
    }
}

// MARK: - Preview

@available(macOS 14.0, *)
#Preview {
    VStack(spacing: Spacing.md) {
        SettingsSectionCard(
            icon: "folder.fill",
            title: "Storage",
            subtitle: "Where your transcripts are saved"
        ) {
            SettingsPathRow(
                title: "Save Location",
                path: "",
                defaultPath: "~/Documents/Transcripted/",
                onChoose: {}
            )
        }

        SettingsSectionCard(
            icon: "paintbrush.fill",
            title: "Appearance"
        ) {
            VStack(spacing: Spacing.md) {
                SettingsToggleRow(
                    title: "Aurora Recording Indicator",
                    description: "Flowing color animation during recording",
                    isOn: .constant(true)
                )

                SettingsToggleRow(
                    title: "Sound Feedback",
                    description: "Play sounds when recording starts/stops",
                    isOn: .constant(false)
                )
            }
        }

        // Button showcase
        HStack(spacing: Spacing.md) {
            Button("Primary") {}
                .buttonStyle(SettingsPrimaryButtonStyle())

            Button("Secondary") {}
                .buttonStyle(SettingsSecondaryButtonStyle())

            Button("Delete") {}
                .buttonStyle(SettingsDestructiveButtonStyle())
        }
    }
    .padding()
    .frame(width: 500)
    .background(Color.panelCharcoal)
}
