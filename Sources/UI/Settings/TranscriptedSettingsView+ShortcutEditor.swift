// TranscriptedSettingsView+ShortcutEditor.swift
// General page: the keyboard shortcuts switch, the shortcut recorder, and
// Tap to keep listening for the Push to Talk key.

import SwiftUI

extension TranscriptedSettingsView {
    var generalShortcutSettingsEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            GeneralToggleRow(
                title: "Keyboard shortcuts",
                isOn: persistedSettingsBinding(
                    $dictationShortcutsEnabled,
                    persist: { HotkeyPreferences.setDictationShortcutsEnabled($0) },
                    track: { trackSettingsToggle("dictation_shortcuts", enabled: $0, page: .general) }
                ),
                help: dictationShortcutsEnabled ? "Shortcut keys can start dictation." : "Start dictation from the app only.",
                info: GeneralInfo(
                    title: "Keyboard shortcuts",
                    message: "Push-to-talk and hands-free keys can start dictation. Off still lets you start from the app, and meeting controls keep working."
                ),
                automationIdentifier: "transcripted.settings.general.keyboard-shortcuts"
            )

            HotkeyRecorderContainer(dictationShortcutsEnabled: dictationShortcutsEnabled)
                .frame(height: HotkeyRecorderContainer.preferredHeight)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            if dictationShortcutsEnabled {
                GeneralToggleRow(
                    title: "Tap to keep listening",
                    isOn: persistedSettingsBinding(
                        $pushToTalkTapKeepsListening,
                        persist: { HotkeyPreferences.setPushToTalkTapKeepsListening($0) },
                        track: { trackSettingsToggle("push_to_talk_tap_keeps_listening", enabled: $0, page: .general) }
                    ),
                    help: pushToTalkTapKeepsListening
                        ? "Hold Push to Talk to record, or tap it to keep going until you tap again."
                        : "Push to Talk records only while you hold it.",
                    info: GeneralInfo(
                        title: "Tap to keep listening",
                        message: "One key does both. Hold the Push to Talk key and it records until you let go. Tap it quickly and it keeps listening hands-free, then tap it again to paste. Off, a tap does nothing and only holding records."
                    ),
                    automationIdentifier: "transcripted.settings.general.push-to-talk-tap",
                    showsDivider: false
                )
            }

            if dictationShortcutsEnabled, let dictationTriggerSystemWarning {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(dictationTriggerSystemWarning)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Button("Open Keyboard Settings") {
                            trackSettingsAction("open_keyboard_settings", page: .general)
                            PhysicalDictationTriggerPreferences.openKeyboardSettings()
                        }
                        .buttonStyle(.link)
                        .accessibilityIdentifier("transcripted.settings.general.keyboard-shortcuts.open-keyboard-settings")
                    }
                }
                .font(.caption)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
    }
}
