// PermissionsOnboardingView.swift
// First-run setup for Transcripted's local dictation and meeting capture.
//
// One ask per screen (microphone, paste access, optional call audio), two
// real dictations in between, the promise, then Done lands on Today. Steps
// and buttons come from `OnboardingNavigation`; the screens are in
// PermissionsOnboardingStages.swift, PermissionsOnboardingPractice.swift and
// PermissionsOnboardingShell.swift.

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
    /// Watched so the practice and Done screens can say the voice model is
    /// still downloading, and so practice sees a take start and end.
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
    // macOS never asks twice. After a Don't Allow the step says so and its
    // button opens System Settings instead.
    @State private var micBlocked = false
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
    // A first take saved earlier in this setup (before a relaunch) counts.
    @State private var tryItDone = PermissionsOnboardingPreferences.hasTrackedFirstDictationSaved()
    @State private var tryHandsFreeDone = false
    @State private var didTrackTakeStartForStep: OnboardingStepKind?

    init(sttRouter: STTRouter, onComplete: @escaping () -> Void) {
        _sttRouter = ObservedObject(wrappedValue: sttRouter)
        self.onComplete = onComplete
        _currentStepIndex = State(initialValue: PermissionsOnboardingPreferences.resumeStepIndex())
    }

    private var systemAudioPresentation: TranscriptedPermissionKind.SystemAudioOnboardingPresentation {
        TranscriptedPermissionKind.systemAudioOnboardingPresentation(
            state: systemAudioState,
            result: systemAudioProbeResult,
            isChecking: systemAudioRequestTask != nil
        )
    }

    private var navigation: OnboardingNavigation {
        OnboardingNavigation(
            step: OnboardingNavigation.step(at: currentStepIndex),
            microphoneGranted: micGranted,
            microphoneBlocked: micBlocked,
            skippedMicrophone: skippedMicrophone,
            accessibilityGranted: accessibilityGranted,
            dictationKeyEnabled: HotkeyPreferences.dictationShortcutsEnabled(),
            keyBehavior: HotkeyPreferences.dictationKeyBehavior(),
            tryItDone: tryItDone,
            tryHandsFreeDone: tryHandsFreeDone,
            systemAudioVerified: systemAudioPresentation.isVerified,
            systemAudioChecking: systemAudioRequestTask != nil,
            systemAudioActionTitle: systemAudioPresentation.actionTitle
        )
    }

    private var currentStep: OnboardingStepKind {
        navigation.step
    }

    private var hasRequiredPermissions: Bool {
        navigation.hasRequiredPermissions
    }

    var body: some View {
        OnboardingWindowShell(
            canGoBack: navigation.previousStep != nil,
            primaryTitle: navigation.primaryTitle,
            primaryDisabled: navigation.primaryDisabled,
            secondaryTitle: navigation.secondaryTitle,
            onBack: goBack,
            onNext: performPrimaryAction,
            onSecondary: performSecondaryAction
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
            handleLifecycle(.appBecameActive)
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptedPermissionsDidChange)) { _ in
            handleLifecycle(.permissionsChanged)
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptedOnboardingWillTerminate)) { _ in
            handleLifecycle(.appWillTerminate)
        }
        .onDisappear {
            handleLifecycle(.windowDisappeared)
        }
    }

    private func handleLifecycle(_ event: OnboardingPermissionLifecyclePolicy.Event) {
        let effects = OnboardingPermissionLifecyclePolicy.effects(for: event)
        if effects.contains(.clearSystemSettingsHandoff) {
            pendingSystemSettingsHandoff = false
        }
        if effects.contains(.cancelSystemAudioCheck) {
            stopPermissionRevalidation()
        }
        if effects.contains(.refreshPermissions) {
            checkAllPermissions(trackChanges: true)
        }
        if effects.contains(.trackAbandonment) {
            trackAbandonmentIfNeeded()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .welcome:
            OnboardingWelcomeStage()
        case .microphone:
            OnboardingMicrophoneStage(
                progressLabel: navigation.progressLabel,
                granted: micGranted,
                blocked: micBlocked
            )
        case .accessibility:
            OnboardingAccessibilityStage(
                progressLabel: navigation.progressLabel,
                granted: accessibilityGranted
            )
        case .tryIt, .tryHandsFree:
            OnboardingPracticeStage(
                kind: currentStep == .tryIt ? .first : .handsFree,
                progressLabel: navigation.progressLabel,
                sttRouter: sttRouter,
                accessibilityGranted: accessibilityGranted,
                keyEnabled: HotkeyPreferences.dictationShortcutsEnabled(),
                keyDisplay: Self.dictationShortcutDisplay ?? "your dictation key",
                keyBehavior: HotkeyPreferences.dictationKeyBehavior(),
                isDone: currentStep == .tryIt ? tryItDone : tryHandsFreeDone,
                onTakeStarted: trackPracticeTakeStarted,
                onHeardNothing: trackPracticeTakeEmpty,
                onTakeSaved: markPracticeTakeSaved
            )
        case .systemAudio:
            OnboardingSystemAudioStage(
                progressLabel: navigation.progressLabel,
                note: OnboardingSystemAudioStage.note(
                    actionTitle: systemAudioPresentation.actionTitle,
                    state: systemAudioState,
                    isVerified: systemAudioPresentation.isVerified
                ),
                isVerified: systemAudioPresentation.isVerified,
                onSystemAudioSettings: {
                    pendingSystemSettingsHandoff = true
                    TranscriptedPermissionAccess.openSystemAudioRecordingSettings()
                }
            )
        case .promise:
            OnboardingPromiseStage()
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
                onAllowPasteAccess: { requestPermission(.accessibility, required: false) },
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

    // MARK: - Moving between steps

    private func move(to step: OnboardingStepKind) {
        stopPermissionRevalidation()
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            currentStepIndex = OnboardingNavigation.index(of: step)
        }
    }

    private func goBack() {
        guard let previous = navigation.previousStep else { return }
        move(to: previous)
    }

    private func goNext() {
        guard let next = navigation.nextStep else { return }
        move(to: next)
    }

    private func performPrimaryAction() {
        guard !navigation.primaryDisabled else { return }
        trackPrimaryCTAClicked()
        switch navigation.primaryAction {
        case .advance:
            goNext()
        case .requestMicrophone:
            requestPermission(.microphone, required: true)
        case .requestAccessibility:
            requestPermission(.accessibility, required: false)
        case .requestSystemAudio:
            requestPermission(.systemAudioRecording, required: false)
        case .finish:
            completeOnboarding()
        }
    }

    private func performSecondaryAction() {
        guard let action = navigation.secondaryAction else { return }
        switch action {
        case .skipMicrophone:
            skipMicrophone()
        case .skip:
            trackSecondaryCTAClicked("skip")
            goNext()
        }
    }

    private func skipMicrophone() {
        guard navigation.canSkipMicrophone else { return }
        trackSecondaryCTAClicked("skip_microphone")
        skippedMicrophone = true
        move(to: .done)
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
        guard navigation.canFinishSetup else { return }
        stopPermissionRevalidation()
        trackCompletionIfNeeded()
        onComplete()
    }

    // MARK: - Practice

    private func markPracticeTakeSaved() {
        switch currentStep {
        case .tryIt: tryItDone = true
        case .tryHandsFree: tryHandsFreeDone = true
        default: break
        }
    }

    /// Reuses the funnel's take-started event, once per practice screen.
    private func trackPracticeTakeStarted() {
        guard didTrackTakeStartForStep != currentStep else { return }
        didTrackTakeStartForStep = currentStep
        AnalyticsReporter.track(
            "onboarding_first_dictation_started",
            properties: [
                "model_state": sttRouter.modelDownloadState.diagnosticName,
                "step_id": currentStep.analyticsID,
            ]
        )
    }

    private func trackPracticeTakeEmpty() {
        AnalyticsReporter.track(
            "onboarding_first_dictation_empty",
            properties: ["step_id": currentStep.analyticsID]
        )
    }

    // MARK: - Analytics

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
                guard let result = OnboardingPermissionLifecyclePolicy.systemAudioCheckResult(
                    decision,
                    checkWasCancelled: Task.isCancelled
                ) else { return }
                systemAudioProbeResult = result.probeResult
                systemAudioState = result.state
                systemAudioGranted = result.isGranted
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

    private func trackSecondaryCTAClicked(_ cta: String) {
        let now = CFAbsoluteTimeGetCurrent()
        AnalyticsReporter.track(
            "onboarding_primary_cta_clicked",
            properties: [
                "cta": cta,
                "cta_type": "secondary",
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

    /// Series-stable ids: "set_up" on welcome, "allow" for a permission ask,
    /// "continue" to move on, and "open_transcripted" for Done (its old title).
    private var primaryCTAAnalyticsID: String {
        if currentStep == .welcome { return "set_up" }
        switch navigation.primaryAction {
        case .advance:
            return "continue"
        case .requestMicrophone, .requestAccessibility, .requestSystemAudio:
            return "allow"
        case .finish:
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
