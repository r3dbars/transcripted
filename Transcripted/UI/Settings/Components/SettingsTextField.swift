import SwiftUI

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
