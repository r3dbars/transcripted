// TranscriptedSettingsView+ShortcutEditor.swift
// Settings: the dictation key and its behavior (Dictation), the Meetings key
// (Meetings), and the keyboard shortcuts switch (Advanced while on).

import SwiftUI

extension TranscriptedSettingsView {
    /// The "Keyboard shortcuts" switch. Dictation shows it in place of the
    /// key rows while shortcuts are off, so turning them back on is where
    /// you'd look; while they're on it lives in Advanced.
    private var keyboardShortcutsToggle: some View {
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
                message: "Off turns off the dictation key. The Meetings key keeps working."
            ),
            automationIdentifier: "transcripted.settings.general.keyboard-shortcuts"
        )
    }

    /// Dictation key and Behavior, the first rows of Settings › Dictation.
    var generalDictationKeyEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            if dictationShortcutsEnabled {
                ShortcutKeyRow(
                    target: .dictation,
                    info: GeneralInfo(
                        title: "Dictation key",
                        message: "Click it, then press the key you want. Fn or Right Option work on their own."
                    ),
                    automationIdentifier: "transcripted.settings.general.dictation-key",
                    recorder: shortcutRecorder
                ) {
                    if showsDictationKeyMovedNotice {
                        dictationKeyMovedNotice
                    }
                    if let dictationTriggerSystemWarning {
                        dictationKeyWarning(dictationTriggerSystemWarning)
                    }
                }

                DictationKeyBehaviorRow(behavior: persistedSettingsBinding(
                    $dictationKeyBehavior,
                    persist: { HotkeyPreferences.setDictationKeyBehavior($0) },
                    track: { trackSettingsAction("change_dictation_key_behavior_\($0.rawValue)", page: .general) }
                ))
            } else {
                keyboardShortcutsToggle
            }
        }
        .onDisappear { shortcutRecorder.stopRecording() }
        .onChange(of: dictationShortcutsEnabled) { _, enabled in
            // The dictation row just hid; don't keep listening for its key.
            if !enabled, shortcutRecorder.recordingTarget == .dictation {
                shortcutRecorder.stopRecording()
            }
        }
    }

    /// The Meetings key, first row of Settings › Meetings.
    var generalMeetingsKeyEditor: some View {
        ShortcutKeyRow(
            target: .meeting,
            info: GeneralInfo(
                title: "Meetings key",
                message: "Starts or stops recording a meeting from anywhere."
            ),
            automationIdentifier: "transcripted.settings.general.meeting-shortcut",
            recorder: shortcutRecorder
        )
    }

    /// Advanced › Dictation keeps the switch while shortcuts are on.
    @ViewBuilder
    var generalKeyboardShortcutsAdvancedEditor: some View {
        if dictationShortcutsEnabled {
            keyboardShortcutsToggle
        }
    }

    /// One-time after upgrading from before 1.1.70, when the one dictation
    /// key became Right Option. OK persists the dismissal.
    private var dictationKeyMovedNotice: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(DictationShortcutUpgrade.movedToRightOptionNotice)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(DictationShortcutUpgrade.movedToRightOptionNoticeIdentifier)
            Spacer(minLength: 0)
            Button("Dismiss") {
                DictationShortcutUpgrade.dismissMovedToRightOptionNotice()
                showsDictationKeyMovedNotice = false
            }
            .buttonStyle(.transcriptedQuiet)
            .controlSize(.small)
            .accessibilityIdentifier(DictationShortcutUpgrade.movedToRightOptionNoticeDismissIdentifier)
        }
        .font(.caption)
        .padding(.bottom, 6)
    }

    /// Fn's macOS action fires along with dictation until it's set to Do
    /// Nothing; said right under the key it's about.
    private func dictationKeyWarning(_ warning: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(LibraryTokens.attention)

            VStack(alignment: .leading, spacing: 4) {
                Text(warning)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button("Open Keyboard Settings") {
                    trackSettingsAction("open_keyboard_settings", page: .general)
                    PhysicalDictationTriggerPreferences.openKeyboardSettings()
                }
                .buttonStyle(.transcriptedQuiet)
                .controlSize(.small)
                .accessibilityIdentifier("transcripted.settings.general.keyboard-shortcuts.open-keyboard-settings")
            }
        }
        .font(.caption)
    }
}
