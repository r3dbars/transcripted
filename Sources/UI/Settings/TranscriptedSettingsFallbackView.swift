import SwiftUI

/// What the SwiftUI Settings scene shows if some system path opens it
/// directly. The app owns a richer AppKit Settings window, and ⌘, is replaced
/// by `TranscriptedMenuCommandCatalog.settings`, so this scene is only a
/// recovery surface: one visible action that opens the real window.
enum TranscriptedSettingsFallback {
    static let title = "Transcripted Settings"
    static let message = "Open the full Transcripted window to change settings."
    static let buttonTitle = "Open Settings"
    static let buttonAutomationIdentifier = "transcripted.settings.fallback.open"

    /// The button's action: close the fallback scene first, then open the real
    /// window, so the empty scene never sits on top of it.
    static func open(dismiss: () -> Void, openSettings: () -> Void) {
        dismiss()
        openSettings()
    }
}

struct TranscriptedSettingsFallbackView: View {
    @Environment(\.dismiss) private var dismiss
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Text(TranscriptedSettingsFallback.title)
                .font(.headline)
            Text(TranscriptedSettingsFallback.message)
                .foregroundStyle(.secondary)
            Button(TranscriptedSettingsFallback.buttonTitle) {
                TranscriptedSettingsFallback.open(dismiss: { dismiss() }, openSettings: openSettings)
            }
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier(TranscriptedSettingsFallback.buttonAutomationIdentifier)
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(width: 360, height: 180)
    }
}
