import SwiftUI

/// Reusable settings section card with icon, title, and content
/// "Night Studio" aesthetic with premium hover effects
@available(macOS 14.0, *)
struct SettingsSectionCard<Content: View>: View {

    let icon: String
    let title: String
    let subtitle: String?
    let content: Content

    @State private var isHovered = false

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
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Header with icon glow
            HStack(spacing: Spacing.sm) {
                ZStack {
                    // Glow effect on hover
                    Circle()
                        .fill(Color.recordingCoral.opacity(isHovered ? 0.2 : 0.1))
                        .frame(width: 32, height: 32)
                        .blur(radius: isHovered ? 6 : 4)

                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.recordingCoral)
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headingSmall)
                        .foregroundColor(.panelTextPrimary)

                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.panelTextMuted)
                    }
                }
            }

            // Content
            content
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .premiumCard(isHovered: isHovered, glowColor: .recordingCoral)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.2)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Settings Row Components

/// A simple toggle row for settings with custom coral toggle
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

/// Custom coral toggle switch with glow effect and smooth animation
@available(macOS 14.0, *)
struct CoralToggle: View {

    @Binding var isOn: Bool

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) var reduceMotion

    private let toggleWidth: CGFloat = 44
    private let toggleHeight: CGFloat = 24
    private let knobSize: CGFloat = 20
    private let knobPadding: CGFloat = 2

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.7)) {
                isOn.toggle()
            }
        } label: {
            ZStack {
                // Track
                Capsule()
                    .fill(isOn ? Color.recordingCoral : Color.panelCharcoalSurface)
                    .frame(width: toggleWidth, height: toggleHeight)
                    .overlay {
                        // Inner shadow
                        Capsule()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.black.opacity(isOn ? 0.2 : 0.1),
                                        Color.white.opacity(isOn ? 0.1 : 0.05)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    }

                // Glow when ON
                if isOn {
                    Capsule()
                        .fill(Color.recordingCoral.opacity(0.3))
                        .frame(width: toggleWidth, height: toggleHeight)
                        .blur(radius: 8)
                }

                // Knob
                Circle()
                    .fill(Color.white)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: Color.black.opacity(0.2), radius: 2, y: 1)
                    .offset(x: isOn ? (toggleWidth / 2 - knobSize / 2 - knobPadding) : -(toggleWidth / 2 - knobSize / 2 - knobPadding))
            }
            .scaleEffect(isHovered ? 1.05 : 1.0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// A text field row for settings with focus glow and validation states
@available(macOS 14.0, *)
struct SettingsTextField: View {

    let title: String
    let placeholder: String
    @Binding var text: String
    var isSecure: Bool = false
    var onVerify: (() -> Void)?

    @State private var isFocused = false
    @State private var shakeOffset: CGFloat = 0
    @State private var glowPulse: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(title)
                .font(.bodyMedium)
                .foregroundColor(.panelTextPrimary)

            HStack(spacing: Spacing.sm) {
                // Text field with focus glow
                ZStack {
                    // Focus glow
                    if isFocused {
                        RoundedRectangle(cornerRadius: Radius.lawsButton)
                            .fill(Color.accentBlue.opacity(glowPulse ? 0.15 : 0.1))
                            .blur(radius: 8)
                    }

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
                                                lineWidth: 1.5
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
                                                lineWidth: 1.5
                                            )
                                    }
                            }
                            .foregroundColor(.panelTextPrimary)
                    }
                }
                .offset(x: shakeOffset)
                .onFocusChange { focused in
                    isFocused = focused
                    if focused {
                        // Pulse glow once then settle
                        withAnimation(.easeInOut(duration: 0.3)) {
                            glowPulse = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            withAnimation(.easeOut(duration: 0.3)) {
                                glowPulse = false
                            }
                        }
                    }
                }

                // Verify button
                if let onVerify = onVerify, !text.isEmpty {
                    Button("Verify") {
                        onVerify()
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())
                }
            }
        }
    }

    /// Trigger shake animation (can be called externally for validation errors)
    func triggerShake() {
        withAnimation(.interpolatingSpring(stiffness: 600, damping: 15)) {
            shakeOffset = 8
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.interpolatingSpring(stiffness: 600, damping: 15)) {
                shakeOffset = -6
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.interpolatingSpring(stiffness: 600, damping: 15)) {
                shakeOffset = 4
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            withAnimation(.interpolatingSpring(stiffness: 600, damping: 15)) {
                shakeOffset = -2
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            withAnimation(.interpolatingSpring(stiffness: 600, damping: 15)) {
                shakeOffset = 0
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
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                            selection = option
                        }
                    }
                }
            }
        }
    }
}

/// Individual radio button with animation
@available(macOS 14.0, *)
struct RadioButton: View {

    let label: String
    let description: String?
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                // Radio indicator with animation
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
                            .transition(.scale.combined(with: .opacity))
                    }

                    // Selection glow
                    if isSelected {
                        Circle()
                            .fill(Color.recordingCoral.opacity(0.3))
                            .frame(width: 18, height: 18)
                            .blur(radius: 4)
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
        .opacity(isHovered ? 0.9 : 1.0)
        .onHover { hovering in
            isHovered = hovering
        }
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

/// Primary button style with coral fill and press effects
@available(macOS 14.0, *)
struct SettingsPrimaryButtonStyle: ButtonStyle {

    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.bodySmall)
            .fontWeight(.medium)
            .foregroundColor(.white)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background {
                ZStack {
                    // Base fill
                    RoundedRectangle(cornerRadius: Radius.lawsButton)
                        .fill(Color.recordingCoral)

                    // Glow on hover
                    if isHovered && !configuration.isPressed {
                        RoundedRectangle(cornerRadius: Radius.lawsButton)
                            .fill(Color.recordingCoral.opacity(0.3))
                            .blur(radius: 8)
                    }

                    // Inner highlight
                    RoundedRectangle(cornerRadius: Radius.lawsButton)
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.2), Color.clear],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1
                        )
                }
            }
            .shadow(
                color: Color.black.opacity(configuration.isPressed ? 0.1 : 0.2),
                radius: configuration.isPressed ? 2 : 4,
                y: configuration.isPressed ? 1 : 2
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovered = hovering
                }
            }
    }
}

/// Secondary button style with subtle styling
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
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.lawsButton)
                        .fill(isHovered ? Color.panelCharcoalSurface.opacity(0.8) : Color.panelCharcoalSurface)

                    if isHovered && !configuration.isPressed {
                        RoundedRectangle(cornerRadius: Radius.lawsButton)
                            .stroke(Color.panelTextMuted.opacity(0.3), lineWidth: 1)
                    }
                }
            }
            .shadow(
                color: Color.black.opacity(configuration.isPressed ? 0.05 : 0.1),
                radius: configuration.isPressed ? 1 : 2,
                y: configuration.isPressed ? 0 : 1
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovered = hovering
                }
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
                ZStack {
                    RoundedRectangle(cornerRadius: Radius.lawsButton)
                        .fill(isHovered ? Color.errorRed : Color.errorRed.opacity(0.15))

                    if !isHovered {
                        RoundedRectangle(cornerRadius: Radius.lawsButton)
                            .stroke(Color.errorRed.opacity(0.3), lineWidth: 1)
                    }
                }
            }
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovered = hovering
                }
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
            .scaleEffect(configuration.isPressed ? 0.9 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.15)) {
                    isHovered = hovering
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
