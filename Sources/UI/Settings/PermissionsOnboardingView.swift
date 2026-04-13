// PermissionsOnboardingView.swift
// First-run checklist for the permissions needed to start using Transcripted.

import SwiftUI
import AVFoundation
import ApplicationServices
import AppKit

extension FirstRunLocalModelState {
    init(_ state: ParakeetModelState) {
        switch state {
        case .notLoaded:
            self = .notLoaded
        case .downloading(let progress):
            self = .downloading(progress: progress)
        case .loading:
            self = .loading
        case .ready:
            self = .ready
        case .failed(let message):
            self = .failed(message)
        }
    }
}

struct PermissionsOnboardingView: View {
    private static let completionKey = "permissionsOnboardingCompleted"
    private static let forceKey = "forcePermissionsOnboarding"

    @ObservedObject private var parakeetEngine: ParakeetEngine
    let canStartDictation: Bool
    var onStartDictation: (() -> Void)?
    var onComplete: () -> Void

    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var crashReportingEnabled = CrashReportingPreferences.isEnabled()
    @State private var anonymousAnalyticsEnabled = AnalyticsPreferences.isEnabled()
    @State private var pollTimer: Timer?

    init(
        parakeetEngine: ParakeetEngine,
        canStartDictation: Bool = false,
        onStartDictation: (() -> Void)? = nil,
        onComplete: @escaping () -> Void
    ) {
        _parakeetEngine = ObservedObject(wrappedValue: parakeetEngine)
        self.canStartDictation = canStartDictation
        self.onStartDictation = onStartDictation
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingHeroCard()
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

                    LocalDictationModelCard(status: modelStatus)

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
                            detail: canStartDictation
                                ? "Use Start first dictation below and Transcripted will guide you into the first capture."
                                : "Click back into any text field, then use Dictation from the Transcripted menu."
                        )

                        QuickStartRow(
                            icon: "record.circle.fill",
                            title: "Meetings",
                            detail: screenRecordingGranted
                                ? "Meeting audio is ready too. Calendar prompts stay optional."
                                : MeetingRecordingStartGate.screenRecordingQuickStart
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
                Text(primaryAction.detail)
                    .font(.caption)
                    .foregroundStyle(MenuTokens.textSecondary)

                Button(primaryAction.title) {
                    handlePrimaryAction()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!primaryAction.isEnabled)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .frame(width: MenuTokens.onboardingWindowWidth, height: MenuTokens.onboardingWindowHeight)
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

    private var modelStatus: FirstRunModelCardState {
        FirstRunExperience.modelCard(for: FirstRunLocalModelState(parakeetEngine.modelDownloadState))
    }

    private var primaryAction: FirstRunPrimaryActionState {
        FirstRunExperience.primaryAction(
            hasRequiredPermissions: hasRequiredPermissions,
            hasPasteTarget: canStartDictation && onStartDictation != nil,
            modelState: FirstRunLocalModelState(parakeetEngine.modelDownloadState)
        )
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

    private func handlePrimaryAction() {
        guard primaryAction.isEnabled else { return }
        completeOnboarding(startFirstDictation: primaryAction.shouldStartDictation)
    }

    private func completeOnboarding(startFirstDictation: Bool = false) {
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
        if startFirstDictation, let onStartDictation {
            onStartDictation()
            return
        }
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
        if UserDefaults.standard.bool(forKey: forceKey) {
            return false
        }
        return UserDefaults.standard.bool(forKey: completionKey)
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completionKey)
    }
}

private struct LocalDictationModelCard: View {
    let status: FirstRunModelCardState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(iconColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(status.title)
                        .font(.subheadline.weight(.semibold))

                    Text(status.detail)
                        .font(.caption)
                        .foregroundStyle(MenuTokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Text(status.status)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(iconColor)
            }

            if let progress = status.progress, status.tone != .ready {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(iconColor)
            }

            VStack(alignment: .leading, spacing: 6) {
                ModelDisclosureLine(title: "Model", detail: TranscriptedModelInfo.speechToTextSummary)
                ModelDisclosureLine(title: "Languages", detail: TranscriptedModelInfo.speechToTextLanguageSummary)
                ModelDisclosureLine(title: "Setup network", detail: TranscriptedModelInfo.downloadHostSummary)

                if status.tone == .failed {
                    ModelDisclosureLine(title: "Why this error appears", detail: TranscriptedModelInfo.secureConnectionSummary)
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

    private var iconName: String {
        switch status.tone {
        case .ready:
            return "checkmark.circle.fill"
        case .working:
            return "arrow.down.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    private var iconColor: Color {
        switch status.tone {
        case .ready:
            return MenuTokens.statusGreen
        case .working:
            return Color.accentColor
        case .failed:
            return Color.orange
        }
    }
}

private struct ModelDisclosureLine: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(title):")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            Text(detail)
                .font(.caption)
                .foregroundStyle(MenuTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OnboardingHeroCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                AppIconPreview()

                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to Transcripted")
                        .font(.title2.weight(.semibold))

                    Text("We’ll get the core permissions ready here, then open the menu bar controls so you can start dictating right away.")
                        .font(.callout)
                        .foregroundStyle(MenuTokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                FeaturePill(icon: "menubar.rectangle", title: "Menu bar utility")
                FeaturePill(icon: "mic.fill", title: "Dictation first")
                FeaturePill(icon: "record.circle.fill", title: "Meetings later")
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(MenuTokens.textSecondary)
                    .frame(width: 16)

                Text("After setup, Transcripted lives in your menu bar. Use that icon to start dictation, record a meeting, open settings, or check for updates.")
                    .font(.caption)
                    .foregroundStyle(MenuTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(MenuTokens.pillBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(MenuTokens.pillBorder, lineWidth: 1)
                    )
            )
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(MenuTokens.cardBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(MenuTokens.cardBorder, lineWidth: 1)
                )
        )
    }
}

private struct AppIconPreview: View {
    private var iconImage: NSImage {
        if let icon = NSApplication.shared.applicationIconImage,
           icon.size.width > 0,
           icon.size.height > 0 {
            return icon
        }
        return NSImage(systemSymbolName: "waveform.and.mic", accessibilityDescription: "Transcripted") ?? NSImage()
    }

    var body: some View {
        Image(nsImage: iconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: 68, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
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

            Text(MeetingRecordingStartGate.optionalPermissionsFootnote)
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
            Text("Help improve Transcripted")
                .font(.subheadline.weight(.semibold))

            Text("These start on by default for this release, and you can turn either one off right now or later in Settings. Transcripted never sends transcript text, audio, meeting titles, speaker names, source app names, emails, file paths, or raw URLs.")
                .font(.caption)
                .foregroundStyle(MenuTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ObservabilityQuestionRow(
                icon: "bolt.shield.fill",
                question: "Share crash and error reports to help diagnose broken releases?",
                detail: crashFootnote,
                isOn: Binding(
                    get: { crashReportingEnabled },
                    set: { onCrashToggle($0) }
                ),
                toggleTitle: "Share crash and error reports",
                isAvailable: crashReportingAvailable
            )

            ObservabilityQuestionRow(
                icon: "chart.bar.xaxis",
                question: "Share anonymized usage stats to show what parts of Transcripted people actually use?",
                detail: analyticsFootnote,
                isOn: Binding(
                    get: { anonymousAnalyticsEnabled },
                    set: { onAnalyticsToggle($0) }
                ),
                toggleTitle: "Share anonymous usage stats",
                isAvailable: analyticsAvailable
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

    private var crashFootnote: String {
        if !crashReportingAvailable {
            return "This build does not have Sentry configured yet, so crash and error reports stay on this Mac only. You can still change this later from Settings."
        }

        return crashReportingEnabled
            ? "On by default. Transcripted will send scrubbed crash logs plus a small allowlist of reliability events to Sentry. You can turn this off now or later from Settings."
            : "Off. Crash and error details will stay on this Mac unless you turn this back on later."
    }

    private var analyticsFootnote: String {
        if !analyticsAvailable {
            return "This build does not have PostHog configured yet, so anonymous usage statistics stay off until a project key is added."
        }

        return anonymousAnalyticsEnabled
            ? "On by default. Transcripted will send only allowlisted, bucketed product events with an anonymous device ID to PostHog."
            : "Off. Transcripted will stop sending anonymous usage trends unless you turn this back on later."
    }
}

private struct ObservabilityQuestionRow: View {
    let icon: String
    let question: String
    let detail: String
    @Binding var isOn: Bool
    let toggleTitle: String
    let isAvailable: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(MenuTokens.pillBackground)
                        .frame(width: 34, height: 34)

                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(question)
                        .font(.subheadline.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(MenuTokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Toggle(toggleTitle, isOn: $isOn)
                .disabled(!isAvailable)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(MenuTokens.pillBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(MenuTokens.pillBorder, lineWidth: 1)
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
