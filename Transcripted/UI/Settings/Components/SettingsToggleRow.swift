import SwiftUI

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
