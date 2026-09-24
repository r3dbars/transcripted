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
    /// Watched so the Done screen can say the voice model is still
    /// downloading instead of "You're set." while it isn't.
    @ObservedObject var sttRouter: STTRouter

    static let preferredSize = NSSize(width: 640, height: 560)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentStepIndex: Int
    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var systemAudioGranted = false
    @State private var systemAudioState: TranscriptedPermissionAccess.SystemAudioPermissionState = .unknown
    @State private var systemAudioProbeResult: TranscriptedPermissionAccess.SystemAudioPermissionProbeResult?
    @State private var systemAudioRequestTask: Task<Void, Never>?
    @State private var calendarGranted = false
    // macOS never asks twice. After a Don't Allow the row says so and its
    // button opens System Settings instead of reading "Grant".
    @State private var micBlocked = false
    @State private var calendarBlocked = false
    @State private var flowStartedAt: CFAbsoluteTime?
    @State private var stepStartedAt: CFAbsoluteTime?
    @State private var didTrackCompletion = false
    @State private var didTrackAbandonment = false
    @State private var pendingSystemSettingsHandoff = false
    @State private var lastPermissionStatuses: [TranscriptedPermissionKind: String] = [:]
    // After a Don't Allow on the microphone, setup used to be a dead end even
    // though importing files needs no mic. Skipping only reaches Done; it
    // doesn't change what the app can record.
    @State private var skippedMicrophone = false

    init(sttRouter: STTRouter, onComplete: @escaping () -> Void) {
        _sttRouter = ObservedObject(wrappedValue: sttRouter)
        self.onComplete = onComplete
        _currentStepIndex = State(initialValue: PermissionsOnboardingPreferences.resumeStepIndex())
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
            // "Open Transcripted" read like a second app launch; this just
            // closes setup and shows the menu bar.
            return "Done"
        }
    }

    private var canFinishSetup: Bool {
        hasRequiredPermissions || skippedMicrophone
    }

    private var primaryButtonDisabled: Bool {
        switch currentStep {
        case .welcome:
            return false
        case .permissions:
            return !hasRequiredPermissions
        case .done:
            return !canFinishSetup
        }
    }

    /// Offered only once macOS won't ask for the microphone again.
    private var secondaryButtonTitle: String? {
        guard currentStep == .permissions, micBlocked, !micGranted else { return nil }
        return "Skip for now"
    }

    var body: some View {
        OnboardingWindowShell(
            canGoBack: currentStepIndex > 0,
            primaryTitle: primaryButtonTitle,
            primaryDisabled: primaryButtonDisabled,
            secondaryTitle: secondaryButtonTitle,
            onBack: goBack,
            onNext: goNextOrComplete,
            onSecondary: skipMicrophone
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
        .onChange(of: currentStepIndex) { _, newIndex in
            PermissionsOnboardingPreferences.recordStepReached(newIndex)
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
                systemAudioPresentation: TranscriptedPermissionKind.systemAudioOnboardingPresentation(
                    state: systemAudioState,
                    result: systemAudioProbeResult,
                    isChecking: systemAudioRequestTask != nil
                ),
                systemAudioChecking: systemAudioRequestTask != nil,
                calendarGranted: calendarGranted,
                micBlocked: micBlocked,
                calendarBlocked: calendarBlocked,
                onSystemAudioSettings: {
                    pendingSystemSettingsHandoff = true
                    TranscriptedPermissionAccess.openSystemAudioRecordingSettings()
                },
                onRequest: { kind in requestPermission(kind, required: kind == .microphone) }
            )
        case .done:
            DoneStage(
                modelPresentation: FirstRunExperience.onboardingDoneModelPresentation(
                    for: sttRouter.modelDownloadState,
                    model: sttRouter.selectedModel,
                    isLocallyInstalled: Self.isLocalModelInstalled(sttRouter.selectedModel)
                ),
                microphoneMissing: !micGranted,
                onOpenMicrophoneSettings: {
                    pendingSystemSettingsHandoff = true
                    TranscriptedPermissionAccess.openSettings(for: .microphone)
                },
                dictationShortcutDisplay: Self.dictationShortcutDisplay,
                meetingShortcutDisplay: Self.meetingShortcutDisplay,
                shortcutsNeedAccessibility: !accessibilityGranted,
                willOpenAtLogin: LaunchAtLoginPreferences.shouldApplyDefaultEnable(
                    hasExplicitChoice: LaunchAtLoginPreferences.hasExplicitChoice(),
                    hasAppliedDefault: LaunchAtLoginPreferences.hasAppliedDefaultEnable(),
                    onboardingCompleted: true
                )
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

    private static func isLocalModelInstalled(_ model: TranscriptionModelChoice) -> Bool {
        guard let variant = model.parakeetVariant, variant.isLocalInstallOnly else { return true }
        return ModelCacheInventory.activeParakeetModelDirectory(variant: variant) != nil
    }

    private static var meetingShortcutDisplay: String {
        PhysicalDictationTriggerPreferences.displayString(
            for: PhysicalDictationTriggerPreferences.meetingBinding()
        )
    }

    private func goBack() {
        guard currentStepIndex > 0 else { return }
        stopPermissionRevalidation()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            currentStepIndex -= 1
        }
    }

    private func goNext() {
        guard currentStepIndex < Self.steps.count - 1 else { return }
        stopPermissionRevalidation()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            currentStepIndex += 1
        }
    }

    private func skipMicrophone() {
        guard currentStep == .permissions, !micGranted else { return }
        AnalyticsReporter.track(
            "onboarding_primary_cta_clicked",
            properties: [
                "cta": "skip_microphone",
                "cta_type": "secondary",
                "flow_elapsed_bucket": flowElapsedBucket(now: CFAbsoluteTimeGetCurrent()),
                "step_elapsed_bucket": stepElapsedBucket(now: CFAbsoluteTimeGetCurrent()),
                "step_id": currentStep.analyticsID,
            ]
        )
        skippedMicrophone = true
        goNext()
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
        // macOS's recorded answer is a cheap, prompt-free read. It catches a
        // Don't Allow or a reset in System Settings that the cache can't see.
        TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem()
        systemAudioGranted = TranscriptedPermissionAccess.isGranted(.systemAudioRecording)
        systemAudioState = TranscriptedPermissionAccess.systemAudioRecordingStatus()
        calendarGranted = TranscriptedPermissionAccess.isGranted(.calendar)
        micBlocked = TranscriptedPermissionAccess.microphoneAccessBlocked()
        calendarBlocked = TranscriptedPermissionAccess.calendarAccessBlocked()
        // A live audio check still belongs to the explicit button, never
        // window activation or polling.

        let updatedStatuses = currentPermissionStatuses()
        if trackChanges && !previousStatuses.isEmpty {
            trackPermissionStatusChanges(from: previousStatuses, to: updatedStatuses)
        }
        lastPermissionStatuses = updatedStatuses
    }

    private func stopPermissionRevalidation() {
        systemAudioRequestTask?.cancel()
        systemAudioRequestTask = nil
    }

    private func completeOnboarding() {
        guard canFinishSetup else { return }
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
        guard kind != .systemAudioRecording || systemAudioRequestTask == nil else { return }
        AnalyticsReporter.track(
            "onboarding_permission_cta_clicked",
            properties: [
                "permission_kind": kind.analyticsValue,
                "prior_status": permissionStatus(for: kind),
                "required": required ? "true" : "false",
                "step_id": currentStep.analyticsID,
            ]
        )

        if kind == .systemAudioRecording {
            systemAudioRequestTask = Task { @MainActor in
                let decision = await TranscriptedPermissionAccess.systemAudioRecordingAccessDecision(forceRefresh: true)
                guard !Task.isCancelled else { return }
                systemAudioProbeResult = decision.probeResult
                systemAudioState = decision.state
                systemAudioGranted = decision.state.isGranted
                systemAudioRequestTask = nil
            }
            return
        }

        pendingSystemSettingsHandoff = true
        Task { @MainActor in
            _ = await TranscriptedPermissionAccess.requestAccessOrOpenSettings(
                for: kind,
                firstAccessibilityAskShowsPromptOnly: true
            )
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
    let secondaryTitle: String?
    let onBack: () -> Void
    let onNext: () -> Void
    let onSecondary: () -> Void
    let content: Content

    init(
        canGoBack: Bool,
        primaryTitle: String,
        primaryDisabled: Bool,
        secondaryTitle: String?,
        onBack: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onSecondary: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.canGoBack = canGoBack
        self.primaryTitle = primaryTitle
        self.primaryDisabled = primaryDisabled
        self.secondaryTitle = secondaryTitle
        self.onBack = onBack
        self.onNext = onNext
        self.onSecondary = onSecondary
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
                secondaryTitle: secondaryTitle,
                onBack: onBack,
                onNext: onNext,
                onSecondary: onSecondary
            )
        }
        .background(LibraryTokens.contentBackground)
    }
}

private struct NavBar: View {
    let canGoBack: Bool
    let primaryTitle: String
    let primaryDisabled: Bool
    let secondaryTitle: String?
    let onBack: () -> Void
    let onNext: () -> Void
    let onSecondary: () -> Void

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

            if let secondaryTitle {
                Button {
                    onSecondary()
                } label: {
                    Text(secondaryTitle)
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink2)
                        .padding(.horizontal, 12)
                        .frame(minHeight: LibraryTokens.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("transcripted.onboarding.nav.secondary")
            }

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

private struct PermissionsStage: View {
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

private struct QuietPermissionRow: View {
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
    let modelPresentation: OnboardingDoneModelPresentation
    /// Setup was skipped after a Don't Allow on the microphone.
    let microphoneMissing: Bool
    let onOpenMicrophoneSettings: () -> Void
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
