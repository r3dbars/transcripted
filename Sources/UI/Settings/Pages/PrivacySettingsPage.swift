import SwiftUI

/// The Settings > Privacy page. Extracted from `TranscriptedSettingsView`
/// (codebase audit 2026-07-08 wave 2, spec W2-A).
///
/// `meetingMicProcessingMode`, `splitLocalSpeakersEnabled`,
/// `crashReportingEnabled`, `anonymousAnalyticsEnabled`, `sentryTestStatus`,
/// `diagnosticsActionStatus`, and `permissionStates` are also read by the
/// parent's embedded General > Privacy disclosure editor and by
/// notification-driven refresh handlers, so they stay `@State` on the parent
/// and are threaded through here as bindings/values per the split's rule 2.
struct PrivacySettingsPage: View {
    @Binding var meetingMicProcessingMode: MicrophoneProcessingMode
    @Binding var splitLocalSpeakersEnabled: Bool
    @Binding var crashReportingEnabled: Bool
    @Binding var anonymousAnalyticsEnabled: Bool
    @Binding var sentryTestStatus: String?
    let permissionStates: PermissionSnapshot
    let onDiagnosticsStatusesCleared: () -> Void
    let onTrackPermissionCTA: (TranscriptedPermissionKind) -> Void
    let onRefreshPermissions: () -> Void
    let onTrackSettingsToggle: (String, Bool, TranscriptedSettingsPage?) -> Void
    let onTrackSettingsAction: (String, TranscriptedSettingsPage?) -> Void
    let onSendTestSentryEvent: () -> Void

    var body: some View {
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
                        onTrackPermissionCTA(kind)
                        Task { @MainActor in
                            await TranscriptedPermissionAccess.requestAccessOrOpenSettings(for: kind)
                            onRefreshPermissions()
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
                            onTrackSettingsToggle("meeting_mic_processing_\(newValue.rawValue)", true, .privacy)
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
                            onTrackSettingsToggle("local_speaker_split", newValue, .privacy)
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
                            onTrackSettingsToggle("crash_reporting", newValue, .privacy)
                            CrashReportingPreferences.setEnabled(newValue)
                            CrashReporter.applySessionTrackingPreference()
                            sentryTestStatus = nil
                            onDiagnosticsStatusesCleared()
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
                                onTrackSettingsToggle("anonymous_analytics", true, .privacy)
                            } else {
                                onTrackSettingsToggle("anonymous_analytics", false, .privacy)
                                AnalyticsPreferences.setEnabled(false)
                            }
                            onDiagnosticsStatusesCleared()
                        }
                    )
                )
                    .disabled(!AnalyticsReporter.isAvailable)

                HStack {
                    SettingsInlineActionButton(title: "Send Test Sentry Event", tone: .warning) {
                        onTrackSettingsAction("send_test_sentry_event", .privacy)
                        onSendTestSentryEvent()
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

    private var crashReportingFootnote: String {
        if CrashReporter.isAvailable {
            return crashReportingEnabled
                ? "On. Sends scrubbed crash and error data to Sentry."
                : "Off. Crash and error details stay on this Mac."
        }
        return "Sentry is not configured in this build. Reports stay local."
    }

    private var analyticsFootnote: String {
        if AnalyticsReporter.isAvailable {
            return anonymousAnalyticsEnabled
                ? "On. Sends only allowlisted anonymous product events."
                : "Off. No anonymous usage stats leave this Mac."
        }
        return "PostHog is not configured in this build. Usage stats stay off."
    }
}
