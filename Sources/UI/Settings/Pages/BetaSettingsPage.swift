import SwiftUI

/// The Settings > Beta page. Feature state, setup work, telemetry, and
/// navigation stay in `TranscriptedSettingsView`; this view only renders the
/// controls and forwards changes through bindings.
struct BetaSettingsPage: View {
    @Binding var nemotronModelEnabled: Bool
    let nemotronRemainsPreferred: Bool
    let fallbackTranscriptionModelTitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Beta",
                summary: "Turn on experimental local features when you want to test them."
            )

            SettingsSection(
                title: "Experimental Features",
                detail: "These are off by default. Nothing runs automatically unless you turn it on here."
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    SettingsToggleRow(
                        title: "Nemotron streaming model (beta)",
                        detail: nemotronModelEnabled
                            ? "On. Nemotron appears as a transcription model choice in General settings; its ~600 MB download happens only if you select it."
                            : "Adds a local streaming transcription model covering 40 languages to the model picker. Parakeet stays the default.",
                        isOn: $nemotronModelEnabled,
                        help: "Opt in to the Nemotron streaming transcription model.",
                        automationIdentifier: "transcripted.settings.beta.nemotron-streaming-model"
                    )

                    if !nemotronModelEnabled && nemotronRemainsPreferred {
                        Text("Nemotron is still your saved preference, but with the beta off Transcripted uses \(fallbackTranscriptionModelTitle).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityIdentifier("transcripted.settings.page.beta")
    }
}
