import SwiftUI

extension TranscriptedSettingsView {
    var shortcutsPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Shortcuts",
                summary: "Keyboard triggers and send-after-paste rules."
            )

            SettingsSection(
                title: "Keys",
                detail: "Set push-to-talk, hands-free, paste-last-dictation, and meeting shortcuts."
            ) {
                SettingsToggleRow(
                    title: "Enable dictation shortcuts",
                    detail: dictationShortcutsEnabled
                        ? "Push-to-talk and hands-free keys can start dictation."
                        : "Off. You can still start dictation from the app, and meeting controls still work.",
                    isOn: Binding(
                        get: { dictationShortcutsEnabled },
                        set: { newValue in
                            dictationShortcutsEnabled = newValue
                            trackSettingsToggle("dictation_shortcuts", enabled: newValue, page: .shortcuts)
                            HotkeyPreferences.setDictationShortcutsEnabled(newValue)
                        }
                    )
                )

                HotkeyRecorderContainer(dictationShortcutsEnabled: dictationShortcutsEnabled)
                    .frame(height: HotkeyRecorderContainer.preferredHeight)

                if dictationShortcutsEnabled, let dictationTriggerSystemWarning {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)

                        Text(dictationTriggerSystemWarning)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption)
                }
            }

            SettingsSection(
                title: "Send After Paste",
                detail: "Press Enter only in the apps you choose."
            ) {
                SettingsToggleRow(
                    title: "Send after dictation",
                    detail: autoEnterEnabled
                        ? "Transcripted sends \(autoEnterKey.title) after it pastes, only in selected apps."
                        : "Off. Dictation only pastes text.",
                    isOn: Binding(
                        get: { autoEnterEnabled },
                        set: { newValue in
                            autoEnterEnabled = newValue
                            trackSettingsToggle("auto_send", enabled: newValue, page: .shortcuts)
                            DictationAutoSendPreferences.setEnabled(newValue)
                        }
                    )
                )

                Picker("Send key", selection: Binding(
                    get: { autoEnterKey },
                    set: { newValue in
                        autoEnterKey = newValue
                        trackSettingsAction("change_auto_send_key", page: .shortcuts)
                        DictationAutoSendPreferences.setSendKey(newValue)
                    }
                )) {
                    ForEach(DictationAutoSendKey.allCases) { key in
                        Text(key.title).tag(key)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!autoEnterEnabled)

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Allowed Apps")
                            .font(.subheadline.weight(.semibold))

                        Spacer()

                        SettingsInlineActionButton(title: "Refresh") {
                            trackSettingsAction("refresh_auto_send_apps", page: .shortcuts)
                            refreshAutoEnterAppCandidates()
                        }

                        SettingsInlineActionButton(title: "Add App...", symbolName: "plus") {
                            trackSettingsAction("add_auto_send_app", page: .shortcuts)
                            chooseAutoEnterApp()
                        }
                    }

                    if autoEnterAllowedBundleIDs.isEmpty {
                        Text("Add an app before Transcripted can send.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(sortedAutoEnterAllowedBundleIDs, id: \.self) { bundleID in
                            AutoEnterAllowedAppRow(
                                title: autoEnterDisplayName(for: bundleID),
                                bundleID: bundleID
                            ) {
                                setAutoEnterApp(bundleID, isAllowed: false)
                            }
                        }
                    }
                }
                .disabled(!autoEnterEnabled)

                if !autoEnterAppCandidates.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Running Apps")
                            .font(.subheadline.weight(.semibold))

                        ForEach(autoEnterAppCandidates) { app in
                            SettingsToggleRow(
                                title: app.name,
                                detail: app.bundleID,
                                isOn: Binding(
                                    get: { autoEnterAllowedBundleIDs.contains(app.bundleID) },
                                    set: { isAllowed in
                                        setAutoEnterApp(app.bundleID, isAllowed: isAllowed)
                                    }
                                ),
                                help: "Allow Transcripted to send \(autoEnterKey.title) after pasting into \(app.name)."
                            )
                        }
                    }
                    .disabled(!autoEnterEnabled)
                }
            }
        }
    }
}
