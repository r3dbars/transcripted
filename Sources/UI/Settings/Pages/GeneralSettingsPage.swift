import SwiftUI

/// The Settings > General page. Runtime state and side effects stay in
/// `TranscriptedSettingsView`; this view only renders the page from bindings
/// and injected editor content.
struct GeneralSettingsPage<
    ModelSettingsEditor: View,
    ShortcutSettingsEditor: View,
    PrivacySettingsEditor: View,
    CorrectionsEditor: View
>: View {
    @Binding var launchAtLoginEnabled: Bool
    let launchAtLoginStatus: String
    @Binding var showTranscriptedInDock: Bool
    @Binding var uiSoundsEnabled: Bool
    @Binding var dictationCleanupEnabled: Bool
    @Binding var dictationOverlayMode: DictationOverlayPresentationMode
    @Binding var confirmQuitDuringMeetingEnabled: Bool
    @Binding var autoDetectCallsEnabled: Bool
    @Binding var missedCallNudgeEnabled: Bool

    let effectiveTranscriptionModelTitle: String
    let dictationShortcutsEnabled: Bool
    let privacyStatusLine: String
    let customDictionaryStatusLine: String
    @Binding var showModelSettings: Bool
    @Binding var showShortcutSettings: Bool
    @Binding var showPrivacySettings: Bool
    @Binding var showCorrections: Bool

    let onTrackAction: (String) -> Void
    let onImportAudioFile: () -> Void
    let modelSettingsEditor: () -> ModelSettingsEditor
    let shortcutSettingsEditor: () -> ShortcutSettingsEditor
    let privacySettingsEditor: () -> PrivacySettingsEditor
    let correctionsEditor: () -> CorrectionsEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GeneralSettingsHeader()

            GeneralSettingsGroup {
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

                DictationOverlayModeRow(selection: $dictationOverlayMode)

                GeneralToggleRow(
                    title: "Confirm meeting quits",
                    isOn: $confirmQuitDuringMeetingEnabled,
                    help: confirmQuitDuringMeetingEnabled
                        ? "Ask before stopping a live meeting."
                        : "Quit immediately and save recoverable audio.",
                    info: GeneralInfo(
                        title: "Confirm meeting quits",
                        message: "When this is on, Transcripted asks before quitting during a live meeting so you do not stop a recording by accident."
                    ),
                    automationIdentifier: "transcripted.settings.general.confirm-meeting-quits"
                )

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

                GeneralToggleRow(
                    title: "Missed-call reminders",
                    isOn: $missedCallNudgeEnabled,
                    help: missedCallNudgeEnabled
                        ? "Mention when a long call ends without a recording."
                        : "Stay quiet when calls end without a recording.",
                    info: GeneralInfo(
                        title: "Missed-call reminders",
                        message: "When a detected call lasts ten minutes or more and ends without a Transcripted recording, a small reminder appears so you know the meeting was not captured. It never shows after you decline a recording prompt, and it appears at most a few times a day."
                    ),
                    automationIdentifier: "transcripted.settings.general.missed-call-reminders"
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                GeneralSectionHeading(
                    title: "System",
                    info: GeneralInfo(
                        title: "System",
                        message: "Model, shortcut, and privacy settings now live here so the sidebar stays simpler."
                    )
                )

                GeneralSettingsGroup {
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
                            privacySettingsEditor()
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                GeneralSectionHeading(
                    title: "Tools",
                    info: GeneralInfo(
                        title: "Tools",
                        message: "These are occasional actions: transcribe an existing audio file, or teach Transcripted corrections for words it hears wrong."
                    )
                )

                GeneralSettingsGroup {
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
            }
        }
    }
}
