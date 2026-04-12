// PermissionsOnboardingView.swift
// First-run checklist for the permissions needed to start using Transcripted.

import SwiftUI
import AVFoundation
import ApplicationServices

struct PermissionsOnboardingView: View {
    var onComplete: () -> Void

    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var crashReportingEnabled = CrashReportingPreferences.isEnabled()
    @State private var anonymousAnalyticsEnabled = AnalyticsPreferences.isEnabled()
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Welcome to Transcripted")
                    .font(.title3.weight(.semibold))

                Text("Turn on two quick permissions and you can start dictating into any app right away. Meeting audio and meeting prompts can wait until you need them.")
                    .font(.callout)
                    .foregroundStyle(MenuTokens.textSecondary)

                HStack(spacing: 8) {
                    FeaturePill(icon: "mic.fill", title: "Dictation first")
                    FeaturePill(icon: "record.circle.fill", title: "Meetings later")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()
                .overlay(MenuTokens.cardBorder)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(requiredPermissions) { kind in
                        PermissionSetupCard(
                            kind: kind,
                            granted: isGranted(kind),
                            action: { TranscriptedPermissionAccess.openSettings(for: kind) }
                        )
                    }

                    OptionalPermissionsCard(
                        optionalPermissions: optionalPermissions,
                        isGranted: isGranted
                    )

                    ObservabilityConsentCard(
                        crashReportingEnabled: $crashReportingEnabled,
                        anonymousAnalyticsEnabled: $anonymousAnalyticsEnabled,
                        crashReportingAvailable: CrashReporter.isAvailable,
                        analyticsAvailable: AnalyticsReporter.isAvailable,
                        onCrashToggle: updateCrashReportingPreference,
                        onAnalyticsToggle: updateAnalyticsPreference
                    )

                    VStack(alignment: .leading, spacing: 10) {
                        Text("What happens next")
                            .font(.subheadline.weight(.semibold))

                        QuickStartRow(
                            icon: "mic.fill",
                            title: "Dictation",
                            detail: "Use the Dictation button or your shortcut to speak into any app."
                        )

                        QuickStartRow(
                            icon: "record.circle.fill",
                            title: "Meetings",
                            detail: screenRecordingGranted
                                ? "Meeting audio is ready too. Calendar prompts stay optional."
                                : "You can enable Screen Recording later when you want call audio from Zoom, Meet, or other apps."
                        )
                    }
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(MenuTokens.cardBackground)
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(MenuTokens.cardBorder, lineWidth: 1)
                            )
                    )
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            }

            Divider()
                .overlay(MenuTokens.cardBorder)

            VStack(alignment: .leading, spacing: 10) {
                Text(footerMessage)
                    .font(.caption)
                    .foregroundStyle(MenuTokens.textSecondary)

                Button(continueButtonTitle) {
                    completeOnboarding()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasRequiredPermissions)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: MenuTokens.panelWidth, height: MenuTokens.panelHeight)
        .background(MenuTokens.cardBackground)
        .onAppear {
            checkAllPermissions()
            crashReportingEnabled = CrashReportingPreferences.isEnabled()
            anonymousAnalyticsEnabled = AnalyticsPreferences.isEnabled()
            startPolling()
        }
        .onDisappear {
            stopPolling()
        }
    }

    private var hasRequiredPermissions: Bool {
        micGranted && accessibilityGranted
    }

    private var requiredPermissions: [TranscriptedPermissionKind] {
        TranscriptedPermissionKind.allCases.filter(\.isRequiredOnFirstLaunch)
    }

    private var optionalPermissions: [TranscriptedPermissionKind] {
        TranscriptedPermissionKind.allCases.filter { !$0.isRequiredOnFirstLaunch }
    }

    private var continueButtonTitle: String {
        screenRecordingGranted ? "Continue to Transcripted" : "Continue without meeting audio"
    }

    private var footerMessage: String {
        if hasRequiredPermissions {
            return screenRecordingGranted
                ? "Everything is ready. You can start dictating or record meetings from the menu."
                : "Dictation is ready now. You can add meeting audio later from Settings."
        }

        return "Allow microphone and accessibility first. Those are the two pieces Transcripted needs to start dictating into other apps."
    }

    private func isGranted(_ kind: TranscriptedPermissionKind) -> Bool {
        switch kind {
        case .microphone:
            return micGranted
        case .accessibility:
            return accessibilityGranted
        case .screenRecording:
            return screenRecordingGranted
        case .calendar:
            return TranscriptedPermissionAccess.isGranted(.calendar)
        }
    }

    private func checkAllPermissions() {
        micGranted = TranscriptedPermissionAccess.isGranted(.microphone)
        accessibilityGranted = TranscriptedPermissionAccess.isGranted(.accessibility)
        screenRecordingGranted = TranscriptedPermissionAccess.isGranted(.screenRecording)
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in
                checkAllPermissions()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func completeOnboarding() {
        guard hasRequiredPermissions else { return }
        stopPolling()
        AnalyticsReporter.track(
            "onboarding_completed",
            properties: [
                "anonymous_usage_enabled": anonymousAnalyticsEnabled ? "true" : "false",
                "crash_reporting_enabled": crashReportingEnabled ? "true" : "false",
                "screen_recording_enabled": screenRecordingGranted ? "true" : "false",
            ]
        )
        onComplete()
    }

    private func updateCrashReportingPreference(_ enabled: Bool) {
        crashReportingEnabled = enabled
        CrashReportingPreferences.setEnabled(enabled)
    }

    private func updateAnalyticsPreference(_ enabled: Bool) {
        anonymousAnalyticsEnabled = enabled
        AnalyticsPreferences.setEnabled(enabled)
    }

    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: "permissionsOnboardingCompleted")
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: "permissionsOnboardingCompleted")
    }
}

private struct FeaturePill: View {
    let icon: String
    let title: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption.weight(.semibold))
            Text(title)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(MenuTokens.pillBackground)
                .overlay(
                    Capsule().stroke(MenuTokens.pillBorder, lineWidth: 1)
                )
        )
    }
}

private struct PermissionSetupCard: View {
    let kind: TranscriptedPermissionKind
    let granted: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(MenuTokens.pillBackground)
                        .frame(width: 34, height: 34)

                    Image(systemName: kind.icon)
                        .font(.system(size: 14, weight: .semibold))
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text(kind.title)
                            .font(.subheadline.weight(.semibold))

                        RequirementBadge(title: kind.isRequiredOnFirstLaunch ? "Required" : "Optional")
                    }

                    Text(kind.summary)
                        .font(.caption)
                        .foregroundStyle(MenuTokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                StatusBadge(granted: granted)
            }

            if !granted {
                Button(kind.onboardingActionTitle, action: action)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(MenuTokens.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(MenuTokens.cardBorder, lineWidth: 1)
                )
        )
    }
}

private struct OptionalPermissionsCard: View {
    let optionalPermissions: [TranscriptedPermissionKind]
    let isGranted: (TranscriptedPermissionKind) -> Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Optional later")
                .font(.subheadline.weight(.semibold))

            Text("You can start dictating without these. Add them later from Settings when you want richer meeting capture.")
                .font(.caption)
                .foregroundStyle(MenuTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(optionalPermissions) { kind in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: kind.icon)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(MenuTokens.textMuted)
                        .frame(width: 16, height: 16)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(kind.title)
                                .font(.caption.weight(.semibold))

                            Text(isGranted(kind) ? "Ready" : "Later")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(isGranted(kind) ? MenuTokens.statusGreen : MenuTokens.textMuted)
                        }

                        Text(kind.summary)
                            .font(.caption)
                            .foregroundStyle(MenuTokens.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(MenuTokens.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(MenuTokens.cardBorder, lineWidth: 1)
                )
        )
    }
}

private struct ObservabilityConsentCard: View {
    @Binding var crashReportingEnabled: Bool
    @Binding var anonymousAnalyticsEnabled: Bool
    let crashReportingAvailable: Bool
    let analyticsAvailable: Bool
    let onCrashToggle: (Bool) -> Void
    let onAnalyticsToggle: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Optional diagnostics")
                .font(.subheadline.weight(.semibold))

            Text("Both options are optional, and you can change either one later in Settings. Transcripted never sends transcript text, audio, meeting titles, speaker names, source app names, emails, file paths, or raw URLs.")
                .font(.caption)
                .foregroundStyle(MenuTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(
                "Share crash and error reports",
                isOn: Binding(
                    get: { crashReportingEnabled },
                    set: onCrashToggle
                )
            )
            .disabled(!crashReportingAvailable)

            Toggle(
                "Share anonymous usage statistics",
                isOn: Binding(
                    get: { anonymousAnalyticsEnabled },
                    set: onAnalyticsToggle
                )
            )
            .disabled(!analyticsAvailable)

            Text(crashFootnote)
                .font(.caption)
                .foregroundStyle(MenuTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(analyticsFootnote)
                .font(.caption)
                .foregroundStyle(MenuTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(MenuTokens.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(MenuTokens.cardBorder, lineWidth: 1)
                )
        )
    }

    private var crashFootnote: String {
        if !crashReportingAvailable {
            return "This build does not have Sentry configured yet, so crash and error reports stay on this Mac only. You can still change this later from Settings."
        }

        return crashReportingEnabled
            ? "On by default. You can turn this off now or later from Settings."
            : "Off. You can change this later from Settings if you want to help improve Transcripted."
    }

    private var analyticsFootnote: String {
        if !analyticsAvailable {
            return "This build does not have PostHog configured yet, so anonymous usage statistics stay off until a project key is added."
        }

        return anonymousAnalyticsEnabled
            ? "On. Transcripted will send only allowlisted, bucketed product events with an anonymous device ID."
            : "Off by default. Turn this on only if you want to share anonymous usage trends."
    }
}

private struct RequirementBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(MenuTokens.textMuted)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule()
                    .fill(MenuTokens.pillBackground)
                    .overlay(
                        Capsule().stroke(MenuTokens.pillBorder, lineWidth: 1)
                    )
            )
    }
}

private struct StatusBadge: View {
    let granted: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.caption.weight(.semibold))
            Text(granted ? "Ready" : "Pending")
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(granted ? MenuTokens.statusGreen : MenuTokens.textMuted)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(MenuTokens.pillBackground)
                .overlay(
                    Capsule().stroke(MenuTokens.pillBorder, lineWidth: 1)
                )
        )
    }
}

private struct QuickStartRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MenuTokens.textSecondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(MenuTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
