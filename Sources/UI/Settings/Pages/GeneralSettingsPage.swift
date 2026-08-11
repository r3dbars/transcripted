import SwiftUI

/// The Settings > General page. Runtime state and side effects stay in
/// `TranscriptedSettingsView`; this view only renders the page from bindings
/// and injected editor content.
///
/// Rows are grouped by what they're about (Dictation, Meetings, App) instead
/// of by settings-page provenance, with everything infrequently touched
/// (permissions, mic processing, reporting, dock icon) tucked under one
/// "Advanced" disclosure at the bottom. Each disclosure holds one topic:
/// keyboard shortcuts, Bluetooth microphone, and send-after-dictation are
/// separate disclosures instead of one merged "shortcuts" editor, and
/// speaker matching lives with the other meeting behavior. Plain rows,
/// hairline separators, no card chrome — see `LibraryTokens`.
struct GeneralSettingsPage<
    ModelSettingsEditor: View,
    ShortcutSettingsEditor: View,
    BluetoothMicEditor: View,
    AutoSendEditor: View,
    SpeakerMatchingEditor: View,
    PermissionsEditor: View,
    MicProcessingEditor: View,
    ReportingEditor: View,
    CorrectionsEditor: View
>: View {
    @Binding var launchAtLoginEnabled: Bool
    let launchAtLoginStatus: String
    @Binding var showTranscriptedInDock: Bool
    @Binding var uiSoundsEnabled: Bool
    @Binding var dictationCleanupEnabled: Bool
    @Binding var dictationOverlayMode: DictationOverlayPresentationMode
    @Binding var autoDetectCallsEnabled: Bool

    let effectiveTranscriptionModelTitle: String
    let dictationShortcutsEnabled: Bool
    let bluetoothMicStatusLine: String
    let autoSendStatusLine: String
    let speakerMatchingStatusLine: String
    let permissionsStatusLine: String
    let privacyStatusLine: String
    let customDictionaryStatusLine: String
    @Binding var showModelSettings: Bool
    @Binding var showShortcutSettings: Bool
    @Binding var showBluetoothMicSettings: Bool
    @Binding var showAutoSendSettings: Bool
    @Binding var showSpeakerMatching: Bool
    @Binding var showAdvanced: Bool
    @Binding var showPermissions: Bool
    @Binding var showPrivacySettings: Bool
    @Binding var showCorrections: Bool

    let onTrackAction: (String) -> Void
    let onImportAudioFile: () -> Void
    let modelSettingsEditor: () -> ModelSettingsEditor
    let shortcutSettingsEditor: () -> ShortcutSettingsEditor
    let bluetoothMicEditor: () -> BluetoothMicEditor
    let autoSendEditor: () -> AutoSendEditor
    let speakerMatchingEditor: () -> SpeakerMatchingEditor
    let permissionsEditor: () -> PermissionsEditor
    let micProcessingEditor: () -> MicProcessingEditor
    let reportingEditor: () -> ReportingEditor
    let correctionsEditor: () -> CorrectionsEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Settings",
                summary: "Everything in one place — scroll to find it."
            )

            dictationGroup
            meetingsGroup
            appGroup
            advancedDisclosure
        }
        .accessibilityIdentifier("transcripted.settings.page.general")
    }

    // MARK: Dictation

    private var dictationGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            LibrarySectionLabel(text: "Dictation")

            VStack(alignment: .leading, spacing: 0) {
                GeneralToggleRow(
                    title: "Dictation sounds",
                    isOn: $uiSoundsEnabled,
                    help: uiSoundsEnabled
                        ? "Play sounds when dictation starts and finishes."
                        : "No dictation sounds.",
                    info: GeneralInfo(
                        title: "Dictation sounds",
                        message: "These short sounds tell you when dictation starts, finishes, or hears no speech. Turn them off if you want Transcripted to stay quiet."
                    ),
                    automationIdentifier: "transcripted.settings.general.dictation-sounds"
                )

                DictationOverlayModeRow(selection: $dictationOverlayMode)

                GeneralToggleRow(
                    title: "Clean up pasted text",
                    isOn: $dictationCleanupEnabled,
                    help: dictationCleanupEnabled
                        ? "Remove filler words, repeats, and spacing mistakes before pasting."
                        : "Paste the raw local transcript.",
                    info: GeneralInfo(
                        title: "Clean up pasted text",
                        message: "Transcripted lightly fixes filler words, repeated words, and spacing before it pastes your dictation. Turn this off when you want the raw transcript."
                    ),
                    automationIdentifier: "transcripted.settings.general.cleanup-pasted-text"
                )

                GeneralDisclosureRow(
                    title: "Keyboard shortcuts",
                    value: dictationShortcutsEnabled ? "On" : "Off",
                    isExpanded: $showShortcutSettings,
                    help: showShortcutSettings ? "Hide keyboard shortcut settings." : "Show keyboard shortcut settings.",
                    automationIdentifier: "transcripted.settings.general.disclosure.keyboard-shortcuts"
                ) {
                    onTrackAction("toggle_shortcut_settings")
                }

                if showShortcutSettings {
                    GeneralExpandedContent {
                        shortcutSettingsEditor()
                    }
                }

                GeneralDisclosureRow(
                    title: "Bluetooth microphone",
                    value: bluetoothMicStatusLine,
                    isExpanded: $showBluetoothMicSettings,
                    help: showBluetoothMicSettings ? "Hide Bluetooth microphone settings." : "Show Bluetooth microphone settings.",
                    automationIdentifier: "transcripted.settings.general.disclosure.bluetooth-microphone"
                ) {
                    onTrackAction("toggle_bluetooth_mic_settings")
                }

                if showBluetoothMicSettings {
                    GeneralExpandedContent {
                        bluetoothMicEditor()
                    }
                }

                GeneralDisclosureRow(
                    title: "Send after dictation",
                    value: autoSendStatusLine,
                    isExpanded: $showAutoSendSettings,
                    help: showAutoSendSettings ? "Hide send-after-dictation settings." : "Show send-after-dictation settings.",
                    automationIdentifier: "transcripted.settings.general.disclosure.send-after-dictation"
                ) {
                    onTrackAction("toggle_auto_send_settings")
                }

                if showAutoSendSettings {
                    GeneralExpandedContent {
                        autoSendEditor()
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
        }
    }

    // MARK: Meetings

    private var meetingsGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            LibrarySectionLabel(text: "Meetings")

            VStack(alignment: .leading, spacing: 0) {
                GeneralToggleRow(
                    title: "Auto-detect calls",
                    isOn: $autoDetectCallsEnabled,
                    help: autoDetectCallsEnabled
                        ? "Offer to record when a call starts, even without a calendar invite."
                        : "Only detect meetings from your calendar and conferencing apps.",
                    info: GeneralInfo(
                        title: "Auto-detect calls",
                        message: "When this is on, Transcripted notices when an app or browser starts using your microphone, when a conferencing app starts playing call audio (even if you joined muted), or when your camera turns on while a call app is active, and offers to record it. It only checks local device activity on your Mac; nothing about the audio or video ever leaves your device."
                    ),
                    automationIdentifier: "transcripted.settings.general.auto-detect-calls"
                )

                GeneralDisclosureRow(
                    title: "Speaker matching",
                    value: speakerMatchingStatusLine,
                    isExpanded: $showSpeakerMatching,
                    help: showSpeakerMatching ? "Hide speaker matching settings." : "Show speaker matching settings.",
                    automationIdentifier: "transcripted.settings.general.disclosure.speaker-matching"
                ) {
                    onTrackAction("toggle_speaker_matching_settings")
                }

                if showSpeakerMatching {
                    GeneralExpandedContent {
                        speakerMatchingEditor()
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
        }
    }

    // MARK: App

    private var appGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            LibrarySectionLabel(text: "App")

            VStack(alignment: .leading, spacing: 0) {
                GeneralToggleRow(
                    title: "Launch at login",
                    isOn: $launchAtLoginEnabled,
                    help: launchAtLoginStatus,
                    info: GeneralInfo(
                        title: "Launch at login",
                        message: "When this is on, macOS opens Transcripted after you sign in, so the menu bar app and shortcuts are ready without opening it yourself."
                    ),
                    automationIdentifier: "transcripted.settings.general.launch-at-login"
                )

                GeneralDisclosureRow(
                    title: "Transcription model",
                    value: effectiveTranscriptionModelTitle,
                    isExpanded: $showModelSettings,
                    help: showModelSettings ? "Hide transcription model settings." : "Show transcription model settings.",
                    automationIdentifier: "transcripted.settings.general.disclosure.transcription-model"
                ) {
                    onTrackAction("toggle_model_settings")
                }

                if showModelSettings {
                    GeneralExpandedContent {
                        modelSettingsEditor()
                    }
                }

                GeneralActionRow(
                    title: "Transcribe audio file",
                    value: "Choose",
                    systemImage: "waveform",
                    help: "Choose an audio file to transcribe.",
                    automationIdentifier: "transcripted.settings.general.transcribe-audio-file"
                ) {
                    onImportAudioFile()
                }

                GeneralDisclosureRow(
                    title: "Corrections",
                    value: customDictionaryStatusLine,
                    isExpanded: $showCorrections,
                    help: showCorrections ? "Hide correction settings." : "Show correction settings.",
                    automationIdentifier: "transcripted.settings.general.disclosure.corrections"
                ) {
                    onTrackAction("toggle_corrections")
                }

                if showCorrections {
                    GeneralExpandedContent {
                        correctionsEditor()
                    }
                }
            }
            .frame(maxWidth: 680, alignment: .leading)
        }
    }

    // MARK: Advanced

    private var advancedDisclosure: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeneralDisclosureRow(
                title: "Advanced",
                value: permissionsStatusLine,
                isExpanded: $showAdvanced,
                help: showAdvanced ? "Hide advanced settings." : "Show advanced settings.",
                automationIdentifier: "transcripted.settings.general.disclosure.advanced"
            ) {
                onTrackAction("toggle_advanced_settings")
            }

            if showAdvanced {
                GeneralExpandedContent {
                    VStack(alignment: .leading, spacing: 12) {
                        GeneralToggleRow(
                            title: "Show in Dock",
                            isOn: $showTranscriptedInDock,
                            help: showTranscriptedInDock
                                ? "Transcripted is visible in the Dock."
                                : "Transcripted only appears in the menu bar.",
                            info: GeneralInfo(
                                title: "Show in Dock",
                                message: "Turn this off if you want Transcripted to stay out of the Dock while idle. Settings and active recordings can still bring the app forward when needed."
                            ),
                            automationIdentifier: "transcripted.settings.general.show-in-dock"
                        )

                        VStack(alignment: .leading, spacing: 0) {
                            GeneralDisclosureRow(
                                title: "Permissions",
                                value: permissionsStatusLine,
                                isExpanded: $showPermissions,
                                help: showPermissions ? "Hide permission status." : "Show permission status.",
                                automationIdentifier: "transcripted.settings.general.disclosure.permissions"
                            ) {
                                onTrackAction("toggle_permission_settings")
                            }

                            if showPermissions {
                                GeneralExpandedContent {
                                    permissionsEditor()
                                }
                            }
                        }

                        micProcessingEditor()

                        VStack(alignment: .leading, spacing: 0) {
                            GeneralDisclosureRow(
                                title: "Privacy",
                                value: privacyStatusLine,
                                isExpanded: $showPrivacySettings,
                                help: showPrivacySettings ? "Hide privacy settings." : "Show privacy settings.",
                                automationIdentifier: "transcripted.settings.general.disclosure.privacy"
                            ) {
                                onTrackAction("toggle_privacy_settings")
                            }

                            if showPrivacySettings {
                                GeneralExpandedContent {
                                    reportingEditor()
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: 680, alignment: .leading)
    }
}
