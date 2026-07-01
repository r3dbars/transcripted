import SwiftUI

extension TranscriptedSettingsView {
    var privacyPage: some View {
        VStack(alignment: .leading, spacing: 24) {
            SettingsPageIntro(
                title: "Privacy",
                summary: "Permissions and optional reporting."
            )

            SettingsSection(
                title: "Permissions",
                detail: "Needed for capture, paste-back, and meeting prompts."
            ) {
                ForEach(TranscriptedPermissionKind.allCases) { kind in
                    PermissionStatusRow(kind: kind, granted: permissionStates[kind] ?? false) {
                        trackPermissionCTA(kind)
                        Task { @MainActor in
                            await TranscriptedPermissionAccess.requestAccessOrOpenSettings(for: kind)
                            refreshPermissions()
                        }
                    }
                }
            }

            SettingsSection(
                title: "Meeting Audio",
                detail: "How Transcripted handles your microphone during meetings."
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    Picker("Meeting mic processing", selection: Binding(
                        get: { meetingMicProcessingMode },
                        set: { newValue in
                            meetingMicProcessingMode = newValue
                            trackSettingsToggle("meeting_mic_processing_\(newValue.rawValue)", enabled: true, page: .privacy)
                            MicrophoneProcessingPreferences.setMode(newValue)
                        }
                    )) {
                        ForEach(MicrophoneProcessingMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("transcripted.settings.privacy.meeting-mic-processing")

                    Text(meetingMicProcessingMode.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                SettingsToggleRow(
                    title: "Identify multiple people on this Mac",
                    detail: splitLocalSpeakersEnabled
                        ? "On. After shared-room meetings, Transcripted asks you to name the people captured by your mic."
                        : "Off. The local mic stays as You, which is simpler when you are the only person near this Mac.",
                    isOn: Binding(
                        get: { splitLocalSpeakersEnabled },
                        set: { newValue in
                            splitLocalSpeakersEnabled = newValue
                            trackSettingsToggle("local_speaker_split", enabled: newValue, page: .privacy)
                            LocalSpeakerPreferences.setEnabled(newValue)
                        }
                    )
                )

                Text("Changes here apply from the next recording.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            SettingsSection(
                title: "Reporting",
                detail: "Optional. Scrubbed before anything leaves this Mac."
            ) {
                SettingsToggleRow(
                    title: "Send crash and error reports",
                    detail: crashReportingFootnote,
                    isOn: Binding(
                        get: { crashReportingEnabled },
                        set: { newValue in
                            crashReportingEnabled = newValue
                            trackSettingsToggle("crash_reporting", enabled: newValue, page: .privacy)
                            CrashReportingPreferences.setEnabled(newValue)
                            sentryTestStatus = nil
                            diagnosticsActionStatus = nil
                        }
                    )
                )
                    .disabled(!CrashReporter.isAvailable)

                SettingsToggleRow(
                    title: "Send anonymous usage stats",
                    detail: analyticsFootnote,
                    isOn: Binding(
                        get: { anonymousAnalyticsEnabled },
                        set: { newValue in
                            anonymousAnalyticsEnabled = newValue
                            if newValue {
                                AnalyticsPreferences.setEnabled(true)
                                trackSettingsToggle("anonymous_analytics", enabled: true, page: .privacy)
                            } else {
                                trackSettingsToggle("anonymous_analytics", enabled: false, page: .privacy)
                                AnalyticsPreferences.setEnabled(false)
                            }
                            diagnosticsActionStatus = nil
                        }
                    )
                )
                    .disabled(!AnalyticsReporter.isAvailable)

                HStack {
                    SettingsInlineActionButton(title: "Send Test Sentry Event", tone: .warning) {
                        trackSettingsAction("send_test_sentry_event", page: .privacy)
                        sendTestSentryEvent()
                    }
                    .disabled(!CrashReporter.isAvailable || !crashReportingEnabled)

                    if let sentryTestStatus {
                        Text(sentryTestStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Text("Never sent: transcript text, audio, names, emails, file paths, raw URLs, or meeting titles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
