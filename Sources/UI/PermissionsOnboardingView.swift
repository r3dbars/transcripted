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
                    ForEach(TranscriptedPermissionKind.allCases) { kind in
                        PermissionSetupCard(
                            kind: kind,
                            granted: isGranted(kind),
                            action: { TranscriptedPermissionAccess.openSettings(for: kind) }
                        )
                    }

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
            startPolling()
        }
        .onDisappear {
            stopPolling()
        }
    }

    private var hasRequiredPermissions: Bool {
        micGranted && accessibilityGranted
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
        onComplete()
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
