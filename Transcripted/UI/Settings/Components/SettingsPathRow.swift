import SwiftUI

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
