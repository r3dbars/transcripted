import SwiftUI
import AppKit

// MARK: - Welcome

struct WelcomeStage: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 16) {
                Image(systemName: "waveform")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(LibraryTokens.accent)

                Text("Transcripted")
                    .font(LibraryTokens.title)
                    .foregroundStyle(.primary)

                Text("Dictation and meeting transcripts, saved as Markdown on your Mac.")
                    .font(LibraryTokens.body)
                    .foregroundStyle(LibraryTokens.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)

                Text("Audio and transcripts never leave this Mac. Anonymous usage stats and crash reports help us fix bugs; turn them off in Settings.")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 48)
    }
}

// MARK: - Permissions

struct PermissionsStage: View {
    let micGranted: Bool
    let accessibilityGranted: Bool
    let systemAudioPresentation: TranscriptedPermissionKind.SystemAudioOnboardingPresentation
    let systemAudioChecking: Bool
    let calendarGranted: Bool
    let micBlocked: Bool
    let calendarBlocked: Bool
    let onSystemAudioSettings: () -> Void
    let onRequest: (TranscriptedPermissionKind) -> Void

    private static let blockedNote = " macOS won't ask again, so turn it on in System Settings."

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Permissions")
                    .font(LibraryTokens.title)
                    .foregroundStyle(.primary)
                Text("Microphone is required. Everything else is optional and can wait.")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
            }
            .padding(.top, 44)

            VStack(spacing: 0) {
                QuietPermissionRow(
                    title: "Microphone",
                    summary: "Needed to hear you, for dictation and your side of meetings."
                        + (micBlocked ? Self.blockedNote : ""),
                    icon: "mic.fill",
                    granted: micGranted,
                    isRequired: true,
                    automationIdentifier: "transcripted.onboarding.permissions.microphone",
                    actionTitle: micBlocked ? "Open Settings" : nil
                ) { onRequest(.microphone) }

                divider

                QuietPermissionRow(
                    title: "Keyboard shortcuts and paste-back",
                    summary: "Needed for the shortcuts and for pasting into other apps. Without it, start from the menu bar and dictations copy to the clipboard.",
                    icon: "hand.raised.fill",
                    granted: accessibilityGranted,
                    isRequired: false,
                    automationIdentifier: "transcripted.onboarding.permissions.accessibility"
                ) { onRequest(.accessibility) }

                divider

                QuietPermissionRow(
                    title: "System Audio",
                    summary: systemAudioPresentation.summary,
                    icon: "speaker.wave.2.fill",
                    granted: systemAudioPresentation.isVerified,
                    isRequired: false,
                    automationIdentifier: "transcripted.onboarding.permissions.system-audio",
                    actionTitle: systemAudioPresentation.actionTitle,
                    isChecking: systemAudioChecking,
                    settingsAction: onSystemAudioSettings
                ) { onRequest(.systemAudioRecording) }

                divider

                QuietPermissionRow(
                    title: "Calendar",
                    summary: "Reminds you to record a few minutes before scheduled meetings."
                        + (calendarBlocked ? Self.blockedNote : ""),
                    icon: "calendar",
                    granted: calendarGranted,
                    isRequired: false,
                    automationIdentifier: "transcripted.onboarding.permissions.calendar",
                    actionTitle: calendarBlocked ? "Open Settings" : nil
                ) { onRequest(.calendar) }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 48)
    }

    private var divider: some View {
        Rectangle().fill(LibraryTokens.hairline).frame(height: 1)
    }
}

struct QuietPermissionRow: View {
    let title: String
    let summary: String
    let icon: String
    let granted: Bool
    let isRequired: Bool
    let automationIdentifier: String
    var actionTitle: String? = nil
    var isChecking = false
    var settingsAction: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(granted ? LibraryTokens.accent : LibraryTokens.ink2)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(LibraryTokens.rowTitle)
                        .foregroundStyle(.primary)
                    if isRequired && !granted {
                        Text("REQUIRED")
                            .font(LibraryTokens.label)
                            .tracking(LibraryTokens.labelTracking)
                            .foregroundStyle(LibraryTokens.attention)
                    }
                }
                Text(summary)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            VStack(spacing: 4) {
                Button(actionTitle ?? (granted ? "Granted" : "Grant")) {
                    action()
                }
                .buttonStyle(QuietPermissionButtonStyle(isSubtle: granted))
                .disabled(granted || isChecking)
                .accessibilityIdentifier(automationIdentifier)
                if let settingsAction, !granted, !isChecking {
                    Button("Settings", action: settingsAction)
                        .buttonStyle(.plain)
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink2)
                        .accessibilityIdentifier(automationIdentifier + ".settings")
                }
            }
        }
        .padding(.vertical, 13)
        .frame(minHeight: LibraryTokens.minimumHitTarget)
    }
}

struct QuietPermissionButtonStyle: ButtonStyle {
    var isSubtle = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isSubtle ? LibraryTokens.ink3 : LibraryTokens.accent)
            .padding(.horizontal, 14)
            .frame(minWidth: 88, minHeight: LibraryTokens.minimumHitTarget)
            .background(
                RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                    .fill(isSubtle ? Color.clear : LibraryTokens.raisedFill)
            )
            .contentShape(RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

// MARK: - Done

struct DoneStage: View {
    let modelPresentation: OnboardingDoneModelPresentation
    /// Setup was skipped after a Don't Allow on the microphone.
    let microphoneMissing: Bool
    let onOpenMicrophoneSettings: () -> Void
    let functionKeyWarning: String?
    let dictationShortcutDisplay: String?
    let meetingShortcutDisplay: String
    /// Every global shortcut rides an event tap that needs Accessibility, so
    /// listing them to someone who skipped it would promise keys that do nothing.
    let shortcutsNeedAccessibility: Bool
    /// Finishing setup registers the login item once; say so before macOS
    /// shows its "Login Item added" notice.
    let willOpenAtLogin: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 20) {
                Text(microphoneMissing ? "Almost set." : modelPresentation.headline)
                    .font(LibraryTokens.title)
                    .foregroundStyle(.primary)

                if microphoneMissing {
                    microphoneMissingNotice
                } else if shortcutsNeedAccessibility {
                    Text("Shortcuts start working once Accessibility is on. Until then, start dictation and meetings from the menu bar.")
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink2)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    shortcutList
                    if let functionKeyWarning {
                        functionKeyNotice(functionKeyWarning)
                    }
                }

                if modelPresentation.statusLine != nil {
                    modelStatus
                }

                if willOpenAtLogin {
                    Text("Opens at login so it can catch your meetings. Change it in Settings.")
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 48)
    }

    private var microphoneMissingNotice: some View {
        VStack(spacing: 8) {
            Text("Dictation and meetings need the microphone. Until it's on, you can still transcribe audio and video files with + on the Meetings page.")
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Microphone Settings", action: onOpenMicrophoneSettings)
                .buttonStyle(QuietPermissionButtonStyle())
                .accessibilityIdentifier("transcripted.onboarding.done.open-microphone-settings")
        }
    }

    private func functionKeyNotice(_ warning: String) -> some View {
        VStack(spacing: 6) {
            Text(warning)
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Keyboard Settings") {
                PhysicalDictationTriggerPreferences.openKeyboardSettings()
            }
            .buttonStyle(.plain)
            .font(LibraryTokens.meta)
            .foregroundStyle(LibraryTokens.accent)
            .accessibilityIdentifier("transcripted.onboarding.done.open-keyboard-settings")
        }
    }

    private var modelStatus: some View {
        VStack(spacing: 6) {
            if let statusLine = modelPresentation.statusLine {
                HStack(spacing: 6) {
                    if modelPresentation.isFailed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(LibraryTokens.attention)
                    }
                    Text(statusLine)
                        .font(LibraryTokens.rowTitle)
                        .foregroundStyle(.primary)
                }
            }

            if let progress = modelPresentation.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(LibraryTokens.accent)
                    .frame(maxWidth: 260)
                    .accessibilityIdentifier("transcripted.onboarding.done.model-progress")
            }

            if let detail = modelPresentation.detail {
                Text(detail)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 400)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transcripted.onboarding.done.model-status")
    }

    @ViewBuilder
    private var shortcutList: some View {
        Text(dictationShortcutDisplay == nil
            ? "One shortcut to remember."
            : "Two shortcuts to remember.")
            .font(LibraryTokens.meta)
            .foregroundStyle(LibraryTokens.ink2)

        VStack(spacing: 0) {
            if let dictationShortcutDisplay {
                ShortcutRow(
                    label: "Dictate",
                    shortcut: dictationShortcutDisplay,
                    detail: HotkeyPreferences.dictationKeyBehavior().summary
                )
                Rectangle().fill(LibraryTokens.hairline).frame(height: 1)
            }
            ShortcutRow(
                label: "Record a meeting",
                shortcut: meetingShortcutDisplay,
                detail: "Start or stop from anywhere."
            )
        }
        .frame(maxWidth: 400)
        .padding(.top, 6)
    }
}

struct ShortcutRow: View {
    let label: String
    let shortcut: String
    let detail: String

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(LibraryTokens.rowTitle)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink3)
            }
            Spacer(minLength: 12)
            Text(shortcut)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(LibraryTokens.accent)
        }
        .padding(.vertical, 13)
        .frame(minHeight: LibraryTokens.minimumHitTarget)
    }
}
