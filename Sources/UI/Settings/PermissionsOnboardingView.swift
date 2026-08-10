// PermissionsOnboardingView.swift
// First-run onboarding for Transcripted's local dictation and meeting capture.
//
// Three quiet steps, one path, no branching: welcome, permissions, done.
// Visual language matches the quiet-library main window (see LibraryTokens)
// instead of the old skeuomorphic 14-step walkthrough.

import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted by app-termination cleanup so onboarding can attribute an
    /// in-progress permission handoff before the process exits, since
    /// `onDisappear` never fires when the app quits without closing the
    /// onboarding window first.
    static let transcriptedOnboardingWillTerminate = Notification.Name("transcriptedOnboardingWillTerminate")
}

@MainActor
struct PermissionsOnboardingView: View {
    var onComplete: () -> Void

    static let preferredSize = NSSize(width: 640, height: 560)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentStepIndex = 0
    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var systemAudioGranted = false
    @State private var calendarGranted = false
    @State private var permissionRevalidationTask: Task<Void, Never>?
    @State private var flowStartedAt: CFAbsoluteTime?
    @State private var stepStartedAt: CFAbsoluteTime?
    @State private var didTrackCompletion = false
    @State private var didTrackAbandonment = false
    @State private var pendingSystemSettingsHandoff = false
    @State private var lastPermissionStatuses: [TranscriptedPermissionKind: String] = [:]

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }

    private static let steps: [OnboardingStepKind] = [.welcome, .permissions, .done]

    private var currentStep: OnboardingStepKind {
        Self.steps[min(currentStepIndex, Self.steps.count - 1)]
    }

    private var hasRequiredPermissions: Bool {
        FirstRunExperience.hasRequiredMeetingSetup(microphoneGranted: micGranted)
    }

    private var primaryButtonTitle: String {
        switch currentStep {
        case .welcome:
            return "Set Up"
        case .permissions:
            return "Continue"
        case .done:
            return "Open Transcripted"
        }
    }

    private var primaryButtonDisabled: Bool {
        (currentStep == .permissions || currentStep == .done) && !hasRequiredPermissions
    }

    var body: some View {
        OnboardingWindowShell(
            canGoBack: currentStepIndex > 0,
            primaryTitle: primaryButtonTitle,
            primaryDisabled: primaryButtonDisabled,
            onBack: goBack,
            onNext: goNextOrComplete
        ) {
            stepContent
                .id(currentStep)
        }
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .background(LibraryTokens.contentBackground)
        .onAppear {
            if flowStartedAt == nil {
                flowStartedAt = CFAbsoluteTimeGetCurrent()
            }
            checkAllPermissions(trackChanges: false)
            trackCurrentStepViewed()
        }
        .onChange(of: currentStepIndex) { _, _ in
            trackCurrentStepViewed()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            pendingSystemSettingsHandoff = false
            checkAllPermissions(trackChanges: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptedPermissionsDidChange)) { _ in
            checkAllPermissions(trackChanges: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptedOnboardingWillTerminate)) { _ in
            trackAbandonmentIfNeeded()
        }
        .onDisappear {
            stopPermissionRevalidation()
            trackAbandonmentIfNeeded()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .welcome:
            WelcomeStage()
        case .permissions:
            PermissionsStage(
                micGranted: micGranted,
                accessibilityGranted: accessibilityGranted,
                systemAudioGranted: systemAudioGranted,
                calendarGranted: calendarGranted,
                onRequest: { kind in requestPermission(kind, required: kind == .microphone) }
            )
        case .done:
            DoneStage(
                dictationShortcutDisplay: Self.dictationShortcutDisplay,
                meetingShortcutDisplay: Self.meetingShortcutDisplay
            )
        }
    }

    // Nil when the user has dictation shortcuts turned off (e.g. a forced
    // rerun after choosing that in Settings) — advertising a binding the
    // capture engine won't honor would be a lie; the Done screen hides the
    // row instead of flipping the user's preference back on.
    private static var dictationShortcutDisplay: String? {
        guard HotkeyPreferences.dictationShortcutsEnabled() else { return nil }
        return PhysicalDictationTriggerPreferences.displayString(
            for: PhysicalDictationTriggerPreferences.handsFreeBinding()
        )
    }

    private static var meetingShortcutDisplay: String {
        PhysicalDictationTriggerPreferences.displayString(
            for: PhysicalDictationTriggerPreferences.meetingBinding()
        )
    }

    private func goBack() {
        guard currentStepIndex > 0 else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            currentStepIndex -= 1
        }
    }

    private func goNext() {
        guard currentStepIndex < Self.steps.count - 1 else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            currentStepIndex += 1
        }
    }

    private func goNextOrComplete() {
        guard !primaryButtonDisabled else { return }
        trackPrimaryCTAClicked()
        if currentStepIndex == Self.steps.count - 1 {
            completeOnboarding()
        } else {
            goNext()
        }
    }

    private func checkAllPermissions(trackChanges: Bool) {
        let previousStatuses = lastPermissionStatuses

        micGranted = TranscriptedPermissionAccess.isGranted(.microphone)
        accessibilityGranted = TranscriptedPermissionAccess.isGranted(.accessibility)
        systemAudioGranted = TranscriptedPermissionAccess.isGranted(.systemAudioRecording)
        calendarGranted = TranscriptedPermissionAccess.isGranted(.calendar)
        revalidateSystemAudioPermissionForStatusSurfaces()

        let updatedStatuses = currentPermissionStatuses()
        if trackChanges && !previousStatuses.isEmpty {
            trackPermissionStatusChanges(from: previousStatuses, to: updatedStatuses)
        }
        lastPermissionStatuses = updatedStatuses
    }

    private func revalidateSystemAudioPermissionForStatusSurfaces() {
        SystemAudioPermissionRevalidator.revalidateForStatusSurfaces(
            task: $permissionRevalidationTask
        ) {
            systemAudioGranted = TranscriptedPermissionAccess.isGranted(.systemAudioRecording)
        }
    }

    private func stopPermissionRevalidation() {
        permissionRevalidationTask?.cancel()
        permissionRevalidationTask = nil
    }

    private func completeOnboarding() {
        guard hasRequiredPermissions else { return }
        stopPermissionRevalidation()
        trackCompletionIfNeeded()
        onComplete()
    }

    private func trackCompletionIfNeeded() {
        guard !didTrackCompletion else { return }
        didTrackCompletion = true

        AnalyticsReporter.track(
            "onboarding_completed",
            properties: FirstRunExperience.onboardingCompletionAnalyticsProperties(
                completionPath: .meetings,
                systemAudioGranted: systemAudioGranted,
                calendarGranted: calendarGranted,
                meetingPromptsEnabled: true,
                firstDictationSaved: PermissionsOnboardingPreferences.hasTrackedFirstDictationSaved(),
                anonymousUsageEnabled: AnalyticsPreferences.isEnabled(),
                crashReportingEnabled: CrashReportingPreferences.isEnabled(),
                elapsedSeconds: flowStartedAt.map { CFAbsoluteTimeGetCurrent() - $0 }
            )
        )
    }

    private func trackAbandonmentIfNeeded() {
        guard !didTrackCompletion, !didTrackAbandonment, flowStartedAt != nil else { return }
        didTrackAbandonment = true
        let now = CFAbsoluteTimeGetCurrent()
        ActivationTelemetry.trackWorkflowAbandoned(
            workflowKind: .onboarding,
            stage: currentStep.analyticsID,
            reasonKind: OnboardingAbandonmentReasonPolicy.reason(
                pendingSystemSettingsHandoff: pendingSystemSettingsHandoff
            ),
            surface: .onboarding,
            elapsedBucket: flowElapsedBucket(now: now),
            priorReadyState: hasRequiredPermissions ? "ready" : "not_ready"
        )
    }

    private func requestPermission(_ kind: TranscriptedPermissionKind, required: Bool) {
        AnalyticsReporter.track(
            "onboarding_permission_cta_clicked",
            properties: [
                "permission_kind": kind.analyticsValue,
                "prior_status": permissionStatus(for: kind),
                "required": required ? "true" : "false",
                "step_id": currentStep.analyticsID,
            ]
        )

        pendingSystemSettingsHandoff = true
        Task { @MainActor in
            _ = await TranscriptedPermissionAccess.requestAccessOrOpenSettings(for: kind)
            checkAllPermissions(trackChanges: false)
        }
    }

    private func trackCurrentStepViewed() {
        let now = CFAbsoluteTimeGetCurrent()
        stepStartedAt = now

        AnalyticsReporter.track(
            "onboarding_step_viewed",
            properties: [
                "flow_elapsed_bucket": flowElapsedBucket(now: now),
                "step_id": currentStep.analyticsID,
                "step_index": String(currentStepIndex),
            ]
        )
    }

    private func trackPrimaryCTAClicked() {
        let now = CFAbsoluteTimeGetCurrent()
        AnalyticsReporter.track(
            "onboarding_primary_cta_clicked",
            properties: [
                "cta": primaryCTAAnalyticsID,
                "cta_type": "primary",
                "flow_elapsed_bucket": flowElapsedBucket(now: now),
                "step_elapsed_bucket": stepElapsedBucket(now: now),
                "step_id": currentStep.analyticsID,
            ]
        )
    }

    private func trackPermissionStatusChanges(
        from previousStatuses: [TranscriptedPermissionKind: String],
        to updatedStatuses: [TranscriptedPermissionKind: String]
    ) {
        for kind in TranscriptedPermissionKind.allCases {
            guard let previous = previousStatuses[kind],
                  let updated = updatedStatuses[kind],
                  previous != updated else {
                continue
            }

            AnalyticsReporter.track(
                "onboarding_permission_status_changed",
                properties: [
                    "from_status": previous,
                    "permission_kind": kind.analyticsValue,
                    "step_id": currentStep.analyticsID,
                    "to_status": updated,
                ]
            )
        }
    }

    private var primaryCTAAnalyticsID: String {
        switch currentStep {
        case .welcome:
            return "set_up"
        case .permissions:
            return "continue"
        case .done:
            return "open_transcripted"
        }
    }

    private func flowElapsedBucket(now: CFAbsoluteTime) -> String {
        AnalyticsReporter.durationBucket(seconds: now - (flowStartedAt ?? now))
    }

    private func stepElapsedBucket(now: CFAbsoluteTime) -> String {
        AnalyticsReporter.durationBucket(seconds: now - (stepStartedAt ?? now))
    }

    private func currentPermissionStatuses() -> [TranscriptedPermissionKind: String] {
        [
            .microphone: micGranted ? "granted" : "not_granted",
            .accessibility: accessibilityGranted ? "granted" : "not_granted",
            .systemAudioRecording: systemAudioGranted ? "granted" : "not_granted",
            .calendar: calendarGranted ? "granted" : "not_granted",
        ]
    }

    private func permissionStatus(for kind: TranscriptedPermissionKind) -> String {
        currentPermissionStatuses()[kind] ?? "unknown"
    }
}

private enum OnboardingStepKind: Hashable {
    case welcome
    case permissions
    case done

    var analyticsID: String {
        switch self {
        case .welcome:
            return "welcome"
        case .permissions:
            return "permissions"
        case .done:
            return "done"
        }
    }
}

// MARK: - Window shell

private struct OnboardingWindowShell<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let canGoBack: Bool
    let primaryTitle: String
    let primaryDisabled: Bool
    let onBack: () -> Void
    let onNext: () -> Void
    let content: Content

    init(
        canGoBack: Bool,
        primaryTitle: String,
        primaryDisabled: Bool,
        onBack: @escaping () -> Void,
        onNext: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.canGoBack = canGoBack
        self.primaryTitle = primaryTitle
        self.primaryDisabled = primaryDisabled
        self.onBack = onBack
        self.onNext = onNext
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                content
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            NavBar(
                canGoBack: canGoBack,
                primaryTitle: primaryTitle,
                primaryDisabled: primaryDisabled,
                onBack: onBack,
                onNext: onNext
            )
        }
        .background(LibraryTokens.contentBackground)
    }
}

private struct NavBar: View {
    let canGoBack: Bool
    let primaryTitle: String
    let primaryDisabled: Bool
    let onBack: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack {
            Button {
                onBack()
            } label: {
                Text("Back")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                    .frame(minWidth: LibraryTokens.minimumHitTarget, minHeight: LibraryTokens.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(canGoBack ? 1 : 0)
            .disabled(!canGoBack)
            .accessibilityIdentifier("transcripted.onboarding.nav.back")

            Spacer()

            Button {
                onNext()
            } label: {
                Text(primaryTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 22)
                    .frame(minHeight: LibraryTokens.minimumHitTarget)
                    .background(
                        RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                            .fill(primaryDisabled ? LibraryTokens.ink3 : LibraryTokens.accent)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(primaryDisabled)
            .accessibilityIdentifier("transcripted.onboarding.nav.primary")
        }
        .padding(.horizontal, 32)
        .frame(height: 76)
        .overlay(Rectangle().fill(LibraryTokens.hairline).frame(height: 1), alignment: .top)
    }
}

// MARK: - Welcome

private struct WelcomeStage: View {
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

                Text("Audio and transcripts stay on this Mac. Nothing is uploaded.")
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

private struct PermissionsStage: View {
    let micGranted: Bool
    let accessibilityGranted: Bool
    let systemAudioGranted: Bool
    let calendarGranted: Bool
    let onRequest: (TranscriptedPermissionKind) -> Void

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
                    summary: "Needed to hear you, for dictation and your side of meetings.",
                    icon: "mic.fill",
                    granted: micGranted,
                    isRequired: true,
                    automationIdentifier: "transcripted.onboarding.permissions.microphone"
                ) { onRequest(.microphone) }

                divider

                QuietPermissionRow(
                    title: "Paste-back",
                    summary: "Pastes dictation into the app you're using. Without it, dictations copy to the clipboard instead.",
                    icon: "hand.raised.fill",
                    granted: accessibilityGranted,
                    isRequired: false,
                    automationIdentifier: "transcripted.onboarding.permissions.accessibility"
                ) { onRequest(.accessibility) }

                divider

                QuietPermissionRow(
                    title: "System Audio",
                    summary: "Captures the other side of the call, so meeting transcripts include everyone.",
                    icon: "speaker.wave.2.fill",
                    granted: systemAudioGranted,
                    isRequired: false,
                    automationIdentifier: "transcripted.onboarding.permissions.system-audio"
                ) { onRequest(.systemAudioRecording) }

                divider

                QuietPermissionRow(
                    title: "Calendar",
                    summary: "Reminds you a few minutes before scheduled meetings.",
                    icon: "calendar",
                    granted: calendarGranted,
                    isRequired: false,
                    automationIdentifier: "transcripted.onboarding.permissions.calendar"
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

private struct QuietPermissionRow: View {
    let title: String
    let summary: String
    let icon: String
    let granted: Bool
    let isRequired: Bool
    let automationIdentifier: String
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

            Button(granted ? "Granted" : "Grant") {
                action()
            }
            .buttonStyle(QuietPermissionButtonStyle(isSubtle: granted))
            .disabled(granted)
            .accessibilityIdentifier(automationIdentifier)
        }
        .padding(.vertical, 13)
        .frame(minHeight: LibraryTokens.minimumHitTarget)
    }
}

private struct QuietPermissionButtonStyle: ButtonStyle {
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

private struct DoneStage: View {
    let dictationShortcutDisplay: String?
    let meetingShortcutDisplay: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 20) {
                Text("You're set.")
                    .font(LibraryTokens.title)
                    .foregroundStyle(.primary)
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
                            detail: "Tap to start, tap again to stop and paste."
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
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 48)
    }
}

private struct ShortcutRow: View {
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
