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

// MARK: - Settings Row Components

/// A simple toggle row for settings
@available(macOS 14.0, *)
struct SettingsToggleRow: View {

    let title: String
    let description: String?
    @Binding var isOn: Bool

    init(
        title: String,
        description: String? = nil,
        isOn: Binding<Bool>
    ) {
        self.title = title
        self.description = description
        self._isOn = isOn
    }

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.bodyMedium)
                    .foregroundColor(.panelTextPrimary)

                if let description = description {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.panelTextMuted)
                }
            }

            Spacer()

            CoralToggle(isOn: $isOn)
        }
    }
}

/// Clean toggle switch — coral when on, dark when off, no glow
@available(macOS 14.0, *)
struct CoralToggle: View {

    @Binding var isOn: Bool

    private let toggleWidth: CGFloat = 44
    private let toggleHeight: CGFloat = 24
    private let knobSize: CGFloat = 20
    private let knobPadding: CGFloat = 2

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                isOn.toggle()
            }
        } label: {
            ZStack {
                // Track
                Capsule()
                    .fill(isOn ? Color.recordingCoral : Color.panelCharcoalSurface)
                    .frame(width: toggleWidth, height: toggleHeight)

                // Knob
                Circle()
                    .fill(Color.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: Color.black.opacity(0.15), radius: 1, y: 1)
                    .offset(x: isOn ? (toggleWidth / 2 - knobSize / 2 - knobPadding) : -(toggleWidth / 2 - knobSize / 2 - knobPadding))
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// A text field row for settings
@available(macOS 14.0, *)
struct SettingsTextField: View {

    let title: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var onVerify: (() -> Void)?

    @State private var isFocused = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(.bodyMedium)
                .foregroundColor(.panelTextPrimary)

            HStack(spacing: Spacing.sm) {
                if isSecure {
                    SecureField(placeholder, text: $text)
                        .textFieldStyle(.plain)
                        .padding(Spacing.sm)
                        .background {
                            RoundedRectangle(cornerRadius: Radius.lawsButton)
                                .fill(Color.panelCharcoalSurface)
                                .overlay {
                                    RoundedRectangle(cornerRadius: Radius.lawsButton)
                                        .stroke(
                                            isFocused ? Color.accentBlue : Color.clear,
                                            lineWidth: 1
                                        )
                                }
                        }
                        .foregroundColor(.panelTextPrimary)
                } else {
                    TextField(placeholder, text: $text)
                        .textFieldStyle(.plain)
                        .padding(Spacing.sm)
                        .background {
                            RoundedRectangle(cornerRadius: Radius.lawsButton)
                                .fill(Color.panelCharcoalSurface)
                                .overlay {
                                    RoundedRectangle(cornerRadius: Radius.lawsButton)
                                        .stroke(
                                            isFocused ? Color.accentBlue : Color.clear,
                                            lineWidth: 1
                                        )
                                }
                        }
                        .foregroundColor(.panelTextPrimary)
                }

                // Verify button
                if let onVerify = onVerify, !text.isEmpty {
                    Button("Verify") {
                        onVerify()
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                }
            }
            .onFocusChange { focused in
                isFocused = focused
            }
        }
    }
}

/// A radio button group for settings
@available(macOS 14.0, *)
struct SettingsRadioGroup<T: Hashable & CustomStringConvertible>: View {

    let title: String
    let options: [T]
    @Binding var selection: T
    var descriptions: [T: String]?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(.bodyMedium)
                .foregroundColor(.panelTextPrimary)

            VStack(alignment: .leading, spacing: Spacing.sm) {
                ForEach(options, id: \.self) { option in
                    RadioButton(
                        label: option.description,
                        description: descriptions?[option],
                        isSelected: selection == option
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selection = option
                        }
                    }
                }
            }
        }
    }
}

/// Individual radio button — clean, no glow
@available(macOS 14.0, *)
struct RadioButton: View {

    let label: String
    let description: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                // Radio indicator
                ZStack {
                    Circle()
                        .stroke(
                            isSelected ? Color.recordingCoral : Color.panelTextMuted,
                            lineWidth: 2
                        )
                        .frame(width: 18, height: 18)

                    if isSelected {
                        Circle()
                            .fill(Color.recordingCoral)
                            .frame(width: 10, height: 10)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.bodySmall)
                        .foregroundColor(isSelected ? .panelTextPrimary : .panelTextSecondary)

                    if let desc = description {
                        Text(desc)
                            .font(.caption)
                            .foregroundColor(.panelTextMuted)
                    }
                }
            }
            .padding(.vertical, 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A button row for settings (like folder picker)
@available(macOS 14.0, *)
struct SettingsPathRow: View {

    let title: String
    let path: String
    let defaultPath: String
    var onChoose: () -> Void

    private var displayPath: String {
        if path.isEmpty {
            return defaultPath
        }
        // Shorten home directory
        let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
        if path.hasPrefix(homeDir) {
            return "~" + path.dropFirst(homeDir.count)
        }
        return path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(.bodyMedium)
                .foregroundColor(.panelTextPrimary)

            HStack(spacing: Spacing.sm) {
                // Path display
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.panelTextMuted)

                    Text(displayPath)
                        .font(.bodySmall)
                        .foregroundColor(.panelTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: Radius.lawsButton)
                        .fill(Color.panelCharcoalSurface)
                }

                Button("Choose...") {
                    onChoose()
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
            }
        }
    }
}

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
