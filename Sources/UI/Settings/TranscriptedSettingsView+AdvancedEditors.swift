// TranscriptedSettingsView+AdvancedEditors.swift
// Settings › Advanced: wires the rows that sit in the one disclosure, and
// decides when the voice model needs to move up top.

import SwiftUI

extension TranscriptedSettingsView {
    /// Everything that isn't one of the 15 everyday rows, in one disclosure.
    func generalAdvancedSection(showsPermissions: Bool, showsModel: Bool) -> some View {
        AdvancedSettingsSection(
            uiSoundsEnabled: persistedSettingsBinding(
                $uiSoundsEnabled,
                persist: { UISoundPreferences.setEnabled($0) },
                track: { trackSettingsToggle("dictation_sounds", enabled: $0, page: .general) }
            ),
            dictationMuffleEnabled: persistedSettingsBinding(
                $dictationMuffleEnabled,
                persist: { DictationMufflePreferences.setEnabled($0) },
                track: { trackSettingsToggle("dictation_muffle", enabled: $0, page: .general) },
                sideEffect: { Self.dictationMuffleSettingChanged($0) }
            ),
            launchAtLoginEnabled: Binding(
                get: { launchAtLogin.isEnabled },
                set: { updateLaunchAtLogin($0) }
            ),
            launchAtLoginStatus: launchAtLogin.statusDescription,
            launchAtLoginNotice: LaunchAtLoginNoticePolicy.notice(
                needsApproval: launchAtLogin.needsApproval,
                failureMessage: launchAtLoginFailureMessage
            ),
            onOpenLoginItems: {
                trackSettingsAction("open_login_items", page: .general)
                LaunchAtLoginController.openLoginItemsSettings()
            },
            showTranscriptedInDock: persistedSettingsBinding(
                $showTranscriptedInDock,
                persist: { DockVisibilityPreferences.setVisible($0) },
                track: { trackSettingsToggle("show_in_dock", enabled: $0, page: .general) }
            ),
            correctionsStatusLine: customDictionaryStatusLine,
            showsPermissions: showsPermissions,
            showsModel: showsModel,
            onTrackAction: { actionID in
                trackSettingsAction(actionID, page: .general)
            },
            onImportAudioFile: {
                trackSettingsAction("import_recording", page: .general)
                actions.importAudioFile()
            },
            onEditCorrections: { showCorrectionsSheet = true },
            keyboardShortcutsEditor: { generalKeyboardShortcutsAdvancedEditor },
            micProcessingEditor: {
                VStack(alignment: .leading, spacing: 0) {
                    // With the Mac mic recorder on, the one Microphone choice
                    // covers meetings too, including the macOS input.
                    if microphoneSettingsRows.showsMeetingMacInputToggle {
                        MeetingMicrophoneSettingRow(usesSystemInput: persistedSettingsBinding(
                            $useSystemMeetingMicrophone,
                            persist: { MeetingMicrophonePreferences.setUsesSystemInput($0) }
                        ))
                    }
                    generalMicProcessingEditor
                    Divider()
                }
            },
            speakerEditor: { generalSpeakerMatchingEditor },
            modelEditor: { generalModelSettingsEditor },
            permissionsEditor: { generalPermissionsEditor },
            aboutEditor: { aboutPage },
            supportFilesEditor: {
                SupportFilesSettingsRow(folder: appStateFolder.deletingLastPathComponent())
            }
        )
    }

    /// Model files missing, failed or downloading: the voice model moves to
    /// the top of the page instead of waiting inside Advanced.
    var generalModelNeedsAttention: Bool {
        let state = sttRouter.modelDownloadState
        let modelCard = FirstRunExperience.modelCard(
            for: state,
            model: effectiveTranscriptionModel,
            isLocallyInstalled: isLocalModelInstalled(effectiveTranscriptionModel)
        )
        return FirstRunExperience.modelNeedsAttention(state, card: modelCard)
    }
}
