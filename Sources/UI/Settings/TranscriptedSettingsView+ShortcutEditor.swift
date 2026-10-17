// TranscriptedSettingsView+ShortcutEditor.swift
// General page: the keyboard shortcuts switch and the shortcut recorder
// (dictation key, optional Hands-Free, its behavior, meetings).

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
                    message: "One dictation key: hold it to talk, or tap it to keep listening, depending on Behavior. Off still lets you start from the app, and meeting controls keep working."
                ),
                automationIdentifier: "transcripted.settings.general.keyboard-shortcuts"
            )

            if dictationShortcutsEnabled {
                ShortcutKeyRow(
                    target: .dictation,
                    info: GeneralInfo(
                        title: "Dictation key",
                        message: "Hold this key to talk, or tap it to keep listening, depending on Behavior. Click it, then press the key you want. Modifier keys like Fn or Right Option work on their own."
                    ),
                    automationIdentifier: "transcripted.settings.general.dictation-key",
                    recorder: shortcutRecorder
                ) {
                    if let dictationTriggerSystemWarning {
                        dictationKeyWarning(dictationTriggerSystemWarning)
                    }
                }

                if PhysicalDictationTriggerPreferences.hasDistinctHandsFreeBinding() {
                    ShortcutKeyRow(
                        target: .dictationHandsFree,
                        info: GeneralInfo(
                            title: "Hands-Free",
                            message: "A second key that starts or stops dictation without holding. 1.1.69 bound this separately; it still works next to the hold key."
                        ),
                        automationIdentifier: "transcripted.settings.general.hands-free-key",
                        recorder: shortcutRecorder
                    )
                }

                DictationKeyBehaviorRow(behavior: persistedSettingsBinding(
                    $dictationKeyBehavior,
                    persist: { HotkeyPreferences.setDictationKeyBehavior($0) },
                    track: { trackSettingsAction("change_dictation_key_behavior_\($0.rawValue)", page: .general) }
                ))
            }

            ShortcutKeyRow(
                target: .meeting,
                info: GeneralInfo(
                    title: "Meetings",
                    message: "Starts or stops recording a meeting from anywhere."
                ),
                automationIdentifier: "transcripted.settings.general.meeting-shortcut",
                showsDivider: false,
                recorder: shortcutRecorder
            )
        }
        .onDisappear { shortcutRecorder.stopRecording() }
        .onChange(of: dictationShortcutsEnabled) { _, enabled in
            // The dictation row just hid; don't keep listening for its key.
            if !enabled,
               shortcutRecorder.recordingTarget == .dictation
                || shortcutRecorder.recordingTarget == .dictationHandsFree {
                shortcutRecorder.stopRecording()
            }
        }
    }

    /// Fn's macOS action fires along with dictation until it's set to Do
    /// Nothing; said right under the key it's about.
    private func dictationKeyWarning(_ warning: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text(warning)
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
    }
}
