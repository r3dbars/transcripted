import SwiftUI

/// The General portion of the combined settings page. Runtime state and side
/// effects stay in `TranscriptedSettingsView`; this view only renders layout
/// from bindings and injected editor content.
///
/// Card-based layout (2026-08 settings restyle): every setting is an
/// always-visible row inside a rounded card — no disclosures to hunt through.
/// Rows carry at most a few words; the explanation for each setting lives in
/// its ⓘ info popover. Sections: Dictation, Bluetooth microphone, Send after
/// dictation, Meetings, Speakers, Transcription, App, Permissions, Privacy.
struct GeneralSettingsPage<
    ShortcutEditor: View,
    BluetoothMicEditor: View,
    AutoSendEditor: View,
    SpeakerEditor: View,
    ModelEditor: View,
    MicProcessingEditor: View,
    PermissionsEditor: View,
    ReportingEditor: View
>: View {
    @Binding var launchAtLoginEnabled: Bool
    let launchAtLoginStatus: String
    @Binding var showTranscriptedInDock: Bool
    @Binding var uiSoundsEnabled: Bool
    @Binding var dictationCleanupEnabled: Bool
    @Binding var dictationOverlayMode: DictationOverlayPresentationMode
    @Binding var autoDetectCallsEnabled: Bool

    let correctionsStatusLine: String

    let onTrackAction: (String) -> Void
    let onImportAudioFile: () -> Void
    let onEditCorrections: () -> Void
    let shortcutEditor: () -> ShortcutEditor
    let bluetoothMicEditor: () -> BluetoothMicEditor
    let autoSendEditor: () -> AutoSendEditor
    let speakerEditor: () -> SpeakerEditor
    let modelEditor: () -> ModelEditor
    let micProcessingEditor: () -> MicProcessingEditor
    let permissionsEditor: () -> PermissionsEditor
    let reportingEditor: () -> ReportingEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsPageIntro(
                title: "Settings",
                summary: "Everything in one place — scroll to find it."
            )

            SettingsCardLabel(text: "Dictation")
                .padding(.top, 8)
            SettingsCard {
                GeneralToggleRow(
                    title: "Sounds",
                    isOn: $uiSoundsEnabled,
                    help: uiSoundsEnabled ? "Dictation sounds are on." : "No dictation sounds.",
                    info: GeneralInfo(
                        title: "Sounds",
                        message: "Short sounds when dictation starts, finishes, or hears no speech."
                    ),
                    automationIdentifier: "transcripted.settings.general.dictation-sounds"
                )

                DictationOverlayModeRow(selection: $dictationOverlayMode)

                GeneralToggleRow(
                    title: "Clean up pasted text",
                    isOn: $dictationCleanupEnabled,
                    help: dictationCleanupEnabled ? "Light cleanup before pasting." : "Paste the raw transcript.",
                    info: GeneralInfo(
                        title: "Clean up pasted text",
                        message: "Lightly fixes filler words, repeats, and spacing before pasting. Off pastes the raw transcript."
                    ),
                    automationIdentifier: "transcripted.settings.general.cleanup-pasted-text"
                )

                shortcutEditor()
            }
            .accessibilityIdentifier("transcripted.settings.section.dictation")

            SettingsCardLabel(text: "Bluetooth microphone")
                .padding(.top, 16)
            SettingsCard {
                bluetoothMicEditor()
            }
            .accessibilityIdentifier("transcripted.settings.section.bluetooth-microphone")

            SettingsCardLabel(text: "Send after dictation")
                .padding(.top, 16)
            SettingsCard {
                autoSendEditor()
            }
            .accessibilityIdentifier("transcripted.settings.section.send-after-dictation")

            SettingsCardLabel(text: "Meetings")
                .padding(.top, 16)
            SettingsCard {
                GeneralToggleRow(
                    title: "Auto-detect calls",
                    isOn: $autoDetectCallsEnabled,
                    help: autoDetectCallsEnabled ? "Offer to record detected calls." : "Only calendar and app detection.",
                    info: GeneralInfo(
                        title: "Auto-detect calls",
                        message: "Notices when a call starts — an app using your mic, call audio playing, or your camera turning on — and offers to record it. Detection is entirely local; nothing about the audio or video leaves this Mac."
                    ),
                    automationIdentifier: "transcripted.settings.general.auto-detect-calls"
                )

                micProcessingEditor()
            }
            .accessibilityIdentifier("transcripted.settings.section.meetings")

            SettingsCardLabel(text: "Speakers")
                .padding(.top, 16)
            SettingsCard {
                speakerEditor()
            }
            .accessibilityIdentifier("transcripted.settings.section.speakers")

            SettingsCardLabel(text: "Transcription")
                .padding(.top, 16)
            SettingsCard {
                modelEditor()

                SettingsControlRow(
                    title: "Corrections",
                    info: GeneralInfo(
                        title: "Corrections",
                        message: "Your fixes for words Transcripted mishears — \"okay ours → OKRs\". Applied to dictations and meeting transcripts."
                    ),
                    automationIdentifier: "transcripted.settings.general.corrections"
                ) {
                    HStack(spacing: 8) {
                        Text(correctionsStatusLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        SettingsInlineActionButton(title: "Edit…") {
                            onTrackAction("toggle_corrections")
                            onEditCorrections()
                        }
                    }
                }

                GeneralActionRow(
                    title: "Transcribe a file",
                    value: "Choose",
                    systemImage: "waveform",
                    help: "Pick an audio or video file. The transcript lands with your meetings.",
                    automationIdentifier: "transcripted.settings.general.transcribe-audio-file"
                ) {
                    onImportAudioFile()
                }
            }
            .accessibilityIdentifier("transcripted.settings.section.transcription")

            SettingsCardLabel(text: "App")
                .padding(.top, 16)
            SettingsCard {
                GeneralToggleRow(
                    title: "Launch at login",
                    isOn: $launchAtLoginEnabled,
                    help: launchAtLoginStatus,
                    info: GeneralInfo(
                        title: "Launch at login",
                        message: "Opens Transcripted after you sign in, so shortcuts and meeting detection are ready without opening it yourself."
                    ),
                    automationIdentifier: "transcripted.settings.general.launch-at-login"
                )

                GeneralToggleRow(
                    title: "Show in Dock",
                    isOn: $showTranscriptedInDock,
                    help: showTranscriptedInDock ? "Visible in the Dock." : "Menu bar only while idle.",
                    info: GeneralInfo(
                        title: "Show in Dock",
                        message: "Off keeps Transcripted menu-bar-only while idle. Settings and active recordings can still bring the app forward."
                    ),
                    automationIdentifier: "transcripted.settings.general.show-in-dock"
                )
            }
            .accessibilityIdentifier("transcripted.settings.section.app")

            SettingsCardLabel(text: "Permissions")
                .padding(.top, 16)
            SettingsCard {
                permissionsEditor()
            }
            .accessibilityIdentifier("transcripted.settings.section.permissions")

            SettingsCardLabel(text: "Privacy")
                .padding(.top, 16)
            SettingsCard {
                reportingEditor()
            }
            .accessibilityIdentifier("transcripted.settings.section.privacy")
        }
        .accessibilityIdentifier("transcripted.settings.page.general")
    }
}
