import SwiftUI

/// The Settings > Beta page. Feature state, setup work, telemetry, and
/// navigation stay in `TranscriptedSettingsView`; this view only renders the
/// controls and forwards changes through bindings.
struct BetaSettingsPage<LocalSummarySetupStatus: View, LiveSidecarSetupStatus: View>: View {
    @Binding var localMeetingSummariesEnabled: Bool
    @Binding var localMeetingSummaryProvider: LocalMeetingSummaryProvider
    let isLocalSummaryModelPreparing: Bool
    @Binding var liveMeetingSidecarEnabled: Bool
    @Binding var nemotronModelEnabled: Bool
    let nemotronRemainsPreferred: Bool
    let fallbackTranscriptionModelTitle: String
    let localSummarySetupStatus: () -> LocalSummarySetupStatus
    let liveSidecarSetupStatus: () -> LiveSidecarSetupStatus

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
                        title: "AI meeting summaries",
                        detail: localMeetingSummariesEnabled
                            ? "On. Transcripted may prepare Gemma now; meeting summaries still run only when you choose Run AI summary."
                            : "Create private meeting summaries on this Mac. Turning this on may download or warm Gemma before your first summary.",
                        isOn: $localMeetingSummariesEnabled,
                        help: "Opt in to local meeting summaries on Home.",
                        automationIdentifier: "transcripted.settings.beta.ai-meeting-summaries"
                    )

                    Picker("Summary provider", selection: $localMeetingSummaryProvider) {
                        ForEach(LocalMeetingSummaryProvider.allCases, id: \.self) { provider in
                            Text(provider.title).tag(provider)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(isLocalSummaryModelPreparing)
                    .help(isLocalSummaryModelPreparing
                        ? "Finish or cancel the current model setup before switching providers."
                        : "")

                    Text(localMeetingSummaryProvider.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    localSummarySetupStatus()
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    SettingsToggleRow(
                        title: "Live meeting sidecar",
                        detail: liveMeetingSidecarEnabled
                            ? "On. Transcripted prepares a local folder that Codex or Claude Cowork can watch during active meetings."
                            : "Let Codex or Claude Cowork follow an active meeting through a local sidecar folder.",
                        isOn: $liveMeetingSidecarEnabled,
                        help: "Opt in to the live meeting sidecar workspace.",
                        automationIdentifier: "transcripted.settings.beta.live-meeting-sidecar"
                    )

                    liveSidecarSetupStatus()
                }

                Divider()

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
