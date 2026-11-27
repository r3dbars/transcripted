import SwiftUI

/// The combined settings page. Runtime state and side effects stay in
/// `TranscriptedSettingsView`; this view only lays out bindings and injected
/// editor content.
///
/// Four visible groups hold the settings most people change: Dictation,
/// Meetings, Library and Privacy. Everything else sits in one disclosure,
/// Advanced, which remembers whether it was open. Nothing else on the page is
/// hidden. Permissions and the voice model move up top whenever they need
/// attention, so a missing permission is never one click down.
struct GeneralSettingsPage<
    DictationKeyEditor: View,
    MicrophoneEditor: View,
    AutoSendEditor: View,
    MeetingsKeyEditor: View,
    LibraryEditor: View,
    PrivacyEditor: View,
    PermissionsEditor: View,
    ModelEditor: View,
    Advanced: View
>: View {
    @Binding var dictationCleanupEnabled: Bool
    @Binding var autoDetectCallsEnabled: Bool

    /// A required permission is missing: Permissions shows first, not in Advanced.
    let showsPermissionsUpTop: Bool
    /// Model files are missing or downloading: the voice model shows first.
    let showsModelUpTop: Bool

    let dictationKeyEditor: () -> DictationKeyEditor
    let microphoneEditor: () -> MicrophoneEditor
    let autoSendEditor: () -> AutoSendEditor
    let meetingsKeyEditor: () -> MeetingsKeyEditor
    let libraryEditor: () -> LibraryEditor
    let privacyEditor: () -> PrivacyEditor
    let permissionsEditor: () -> PermissionsEditor
    let modelEditor: () -> ModelEditor
    let advanced: () -> Advanced

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title only: the window's titlebar is hidden, so this heading is
            // the only thing naming the page.
            SettingsPageIntro(title: "Settings")

            if showsPermissionsUpTop {
                SettingsGroup(title: "Permissions", identifier: "transcripted.settings.section.permissions") {
                    permissionsEditor()
                }
                .padding(.top, 8)
            }

            if showsModelUpTop {
                SettingsGroup(title: "Voice model", identifier: "transcripted.settings.section.transcription") {
                    modelEditor()
                }
                .padding(.top, 8)
            }

            SettingsGroup(title: "Dictation", identifier: "transcripted.settings.section.dictation") {
                dictationKeyEditor()

                // The section id stays the old one so smokes and anchors keep it.
                VStack(alignment: .leading, spacing: 0) {
                    microphoneEditor()
                    Divider()
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("transcripted.settings.section.bluetooth-microphone")

                GeneralToggleRow(
                    title: "Clean up pasted text",
                    isOn: $dictationCleanupEnabled,
                    help: dictationCleanupEnabled ? "Light cleanup before pasting." : "Paste the raw transcript.",
                    info: GeneralInfo(
                        title: "Clean up pasted text",
                        message: "Removes filler words, repeats and stray spaces before pasting."
                    ),
                    automationIdentifier: "transcripted.settings.general.cleanup-pasted-text"
                )

                VStack(alignment: .leading, spacing: 0) {
                    autoSendEditor()
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("transcripted.settings.section.send-after-dictation")
            }
            .padding(.top, 8)

            SettingsGroup(title: "Meetings", identifier: "transcripted.settings.section.meetings") {
                meetingsKeyEditor()

                GeneralToggleRow(
                    title: "Auto-detect calls",
                    isOn: $autoDetectCallsEnabled,
                    help: autoDetectCallsEnabled ? "Offer to record detected calls." : "Only calendar and app detection.",
                    info: GeneralInfo(
                        title: "Auto-detect calls",
                        message: "Offers to record when a call starts. Detection runs on this Mac."
                    ),
                    automationIdentifier: "transcripted.settings.general.auto-detect-calls"
                )

                MeetingTitlesSettingsRow(showsDivider: false)
            }
            .padding(.top, 16)

            libraryEditor()
                .padding(.top, 16)

            SettingsGroup(title: "Privacy", identifier: "transcripted.settings.section.privacy") {
                privacyEditor()
            }
            .padding(.top, 16)

            SettingsAdvancedDisclosure(
                summary: "Sounds, call recording, mic processing, voice model, corrections, login and Dock, permissions, updates and feedback."
            ) {
                advanced()
            }
            .padding(.top, 20)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.settings.page.general")
    }
}

/// What Settings › Advanced holds, grouped. Every row here used to sit on the
/// flat page; none of them changed what it does.
struct AdvancedSettingsSection<
    KeyboardShortcutsEditor: View,
    MicProcessingEditor: View,
    SpeakerEditor: View,
    ModelEditor: View,
    PermissionsEditor: View,
    AboutEditor: View,
    SupportFilesEditor: View
>: View {
    @Binding var uiSoundsEnabled: Bool
    @Binding var dictationMuffleEnabled: Bool
    @Binding var launchAtLoginEnabled: Bool
    let launchAtLoginStatus: String
    /// Inline line under the switch when it failed or macOS is waiting for
    /// approval in Login Items. Nil when launch at login is working.
    let launchAtLoginNotice: String?
    let onOpenLoginItems: () -> Void
    @Binding var showTranscriptedInDock: Bool

    let correctionsStatusLine: String
    /// Permissions and the voice model show here only while they're healthy;
    /// otherwise the page shows them at the top.
    let showsPermissions: Bool
    let showsModel: Bool

    let onTrackAction: (String) -> Void
    let onImportAudioFile: () -> Void
    let onEditCorrections: () -> Void
    let keyboardShortcutsEditor: () -> KeyboardShortcutsEditor
    let micProcessingEditor: () -> MicProcessingEditor
    let speakerEditor: () -> SpeakerEditor
    let modelEditor: () -> ModelEditor
    let permissionsEditor: () -> PermissionsEditor
    let aboutEditor: () -> AboutEditor
    let supportFilesEditor: () -> SupportFilesEditor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsGroup(title: "Dictation", identifier: "transcripted.settings.section.advanced-dictation") {
                GeneralToggleRow(
                    title: "Sounds",
                    isOn: $uiSoundsEnabled,
                    help: uiSoundsEnabled ? "Dictation sounds are on." : "No dictation sounds.",
                    info: GeneralInfo(
                        title: "Sounds",
                        message: "A click when dictation starts and stops, and a soft drop if it hears nothing."
                    ),
                    automationIdentifier: "transcripted.settings.general.dictation-sounds"
                )

                GeneralToggleRow(
                    title: "Muffle other audio",
                    isOn: $dictationMuffleEnabled,
                    help: dictationMuffleEnabled ? "Music sounds muffled while you talk." : "Other audio plays normally.",
                    info: GeneralInfo(
                        title: "Muffle other audio",
                        message: "Music and videos get quieter while you talk, then come back. Calls are left alone. Needs System Audio Recording."
                    ),
                    automationIdentifier: "transcripted.settings.general.dictation-muffle"
                )

                NotchIslandScreenSharingRow()

                keyboardShortcutsEditor()
            }

            SettingsGroup(title: "Meetings", identifier: "transcripted.settings.section.advanced-meetings") {
                MeetingMicMuteControlRow()

                LiveMeetingWordsRow()

                micProcessingEditor()

                VStack(alignment: .leading, spacing: 0) {
                    speakerEditor()
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("transcripted.settings.section.speakers")
            }
            .padding(.top, 8)

            if showsModel {
                SettingsGroup(title: "Transcription", identifier: "transcripted.settings.section.transcription") {
                    modelEditor()
                    transcriptionExtras
                }
                .padding(.top, 8)
            } else {
                SettingsGroup(title: "Transcription", identifier: "transcripted.settings.section.transcription-extras") {
                    transcriptionExtras
                }
                .padding(.top, 8)
            }

            SettingsGroup(title: "App", identifier: "transcripted.settings.section.app") {
                launchAtLoginRows

                GeneralToggleRow(
                    title: "Show in Dock",
                    isOn: $showTranscriptedInDock,
                    help: showTranscriptedInDock ? "Visible in the Dock." : "Menu bar only while idle.",
                    info: GeneralInfo(
                        title: "Show in Dock",
                        message: "Off keeps Transcripted in the menu bar while idle."
                    ),
                    automationIdentifier: "transcripted.settings.general.show-in-dock"
                )

                supportFilesEditor()
            }
            .padding(.top, 8)

            if showsPermissions {
                SettingsGroup(title: "Permissions", identifier: "transcripted.settings.section.permissions") {
                    permissionsEditor()
                }
                .padding(.top, 8)
            }

            aboutEditor()
                .padding(.top, 8)
        }
    }

    @ViewBuilder
    private var transcriptionExtras: some View {
        SettingsControlRow(
            title: "Corrections",
            info: GeneralInfo(
                title: "Corrections",
                message: "Your fixes for words it mishears, like \"okay ours → OKRs\". Used for new dictations and meetings."
            ),
            automationIdentifier: "transcripted.settings.general.corrections"
        ) {
            HStack(spacing: 8) {
                Text(correctionsStatusLine)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                SettingsInlineActionButton(title: "Edit…") {
                    onTrackAction("toggle_corrections")
                    onEditCorrections()
                }
            }
        }

        GeneralActionRow(
            title: HomeCaptureListCopy.ImportFileRow.title,
            value: HomeCaptureListCopy.ImportFileRow.value,
            systemImage: "waveform",
            help: HomeCaptureListCopy.ImportFileRow.help,
            automationIdentifier: HomeCaptureListCopy.ImportFileRow.automationIdentifier,
            showsDivider: false
        ) {
            onImportAudioFile()
        }
    }

    @ViewBuilder
    private var launchAtLoginRows: some View {
        GeneralToggleRow(
            title: "Launch at login",
            isOn: $launchAtLoginEnabled,
            help: launchAtLoginStatus,
            info: GeneralInfo(
                title: "Launch at login",
                message: "Opens Transcripted when you sign in, so shortcuts and call detection are ready."
            ),
            automationIdentifier: "transcripted.settings.general.launch-at-login",
            showsDivider: launchAtLoginNotice == nil
        )

        if let launchAtLoginNotice {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(LibraryTokens.attention)

                VStack(alignment: .leading, spacing: 4) {
                    Text(launchAtLoginNotice)
                        .foregroundStyle(LibraryTokens.ink2)
                        .fixedSize(horizontal: false, vertical: true)

                    Button("Open Login Items") {
                        onOpenLoginItems()
                    }
                    .buttonStyle(.transcriptedQuiet)
                    .controlSize(.small)
                    .accessibilityIdentifier("transcripted.settings.general.launch-at-login.open-login-items")
                }
            }
            .font(LibraryTokens.meta)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
            .overlay(alignment: .bottom) {
                Divider()
            }
        }
    }
}
