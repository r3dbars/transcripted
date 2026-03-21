import SwiftUI

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
