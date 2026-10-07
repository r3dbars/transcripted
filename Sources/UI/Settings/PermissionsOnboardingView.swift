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

    private var navigation: OnboardingNavigation {
        OnboardingNavigation(
            step: OnboardingNavigation.step(at: currentStepIndex),
            microphoneGranted: micGranted,
            microphoneBlocked: micBlocked,
            skippedMicrophone: skippedMicrophone
        )
    }

    private var currentStep: OnboardingStepKind {
        navigation.step
    }

    private var hasRequiredPermissions: Bool {
        navigation.hasRequiredPermissions
    }

    private var primaryButtonTitle: String {
        navigation.primaryTitle
    }

    private var canFinishSetup: Bool {
        navigation.canFinishSetup
    }

    private var primaryButtonDisabled: Bool {
        navigation.primaryDisabled
    }

    private var secondaryButtonTitle: String? {
        navigation.secondaryTitle
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
                RetentionTelemetry.observeOnboarding(previouslyCompleted:
                    UserDefaults.standard.bool(forKey: PermissionsOnboardingPreferences.completionKey))
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
                functionKeyWarning: Self.functionKeyWarning,
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
            for: PhysicalDictationTriggerPreferences.pushToTalkBinding()
        )
    }

    /// If someone picked Fn as the dictation key, on a Mac where the macOS Fn
    /// setting was never changed it also opens emoji or switches input. Say
    /// so here, so the menu bar's warning isn't the first people hear of it.
    private static var functionKeyWarning: String? {
        guard HotkeyPreferences.dictationShortcutsEnabled() else { return nil }
        return PhysicalDictationTriggerPreferences.functionKeyConflictWarning(
            for: PhysicalDictationTriggerPreferences.pushToTalkBinding()
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
        guard currentStepIndex < OnboardingNavigation.steps.count - 1 else { return }
        stopPermissionRevalidation()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            currentStepIndex += 1
        }
    }
    private func skipMicrophone() {
        guard navigation.canSkipMicrophone else { return }
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
        if currentStepIndex == OnboardingNavigation.steps.count - 1 {
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
        RetentionTelemetry.completeOnboarding()
        AnalyticsReporter.track(
            "onboarding_completed",
            properties: FirstRunExperience.onboardingCompletionAnalyticsProperties(
                completionPath: .meetings,
                microphoneGranted: micGranted,
                microphoneSkipped: skippedMicrophone,
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
