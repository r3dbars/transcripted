// PermissionsOnboardingView.swift
// First-run onboarding for getting users to their first useful Transcripted capture.

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

    @ObservedObject private var sttRouter: STTRouter
    let canStartDictation: Bool
    var onStartDictation: (() -> Void)?
    var onStopDictation: (() -> Void)?
    var onStartMeetingDryRun: (() async -> Bool)?
    var onStopMeetingDryRun: (() async -> Bool)?
    var onOpenAgentSettings: (() -> Void)?
    var onComplete: () -> Void

    @State private var currentStep: FirstRunOnboardingStep = .hero
    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var systemRecordingGranted = false
    @State private var calendarGranted = false
    @State private var firstSavedDictation: SavedDictationEntry?
    @State private var firstDictationIssue: String?
    @State private var isFirstDictationRunning = false
    @State private var crashReportingEnabled = CrashReportingPreferences.isEnabled()
    @State private var anonymousAnalyticsEnabled = AnalyticsPreferences.isEnabled()
    @State private var copiedFirstDictation = false
    @State private var copiedAgentPrompt = false
    @State private var isInstallingClaude = false
    @State private var claudeInstallMessage: String?
    @State private var isMeetingDryRunStarting = false
    @State private var isMeetingDryRunRunning = false
    @State private var meetingDryRunCompleted = false
    @State private var meetingDryRunIssue: String?
    @State private var pollTimer: Timer?
    @State private var previousPermissionStatuses: [TranscriptedPermissionKind: Bool] = [:]
    @State private var trackedSteps: Set<FirstRunOnboardingStep> = []
    @State private var trackedShown = false
    @State private var lastTrackedModelState: String?

    init(
        sttRouter: STTRouter,
        canStartDictation: Bool = false,
        onStartDictation: (() -> Void)? = nil,
        onStopDictation: (() -> Void)? = nil,
        onStartMeetingDryRun: (() async -> Bool)? = nil,
        onStopMeetingDryRun: (() async -> Bool)? = nil,
        onOpenAgentSettings: (() -> Void)? = nil,
        onComplete: @escaping () -> Void
    ) {
        _sttRouter = ObservedObject(wrappedValue: sttRouter)
        self.canStartDictation = canStartDictation
        self.onStartDictation = onStartDictation
        self.onStopDictation = onStopDictation
        self.onStartMeetingDryRun = onStartMeetingDryRun
        self.onStopMeetingDryRun = onStopMeetingDryRun
        self.onOpenAgentSettings = onOpenAgentSettings
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OnboardingHeader(
                steps: FirstRunExperience.onboardingSteps(),
                currentStep: currentStep
            )
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 14)

            Divider()
                .overlay(MenuTokens.cardBorder)

            ScrollView {
                currentScreen
                    .padding(.horizontal, 22)
                    .padding(.vertical, 18)
            }

            Divider()
                .overlay(MenuTokens.cardBorder)

            OnboardingFooter(
                action: currentAction,
                canGoBack: FirstRunExperience.previousStep(before: currentStep) != nil,
                onBack: goBack,
                onSecondary: handleSecondaryAction,
                onPrimary: handlePrimaryAction
            )
            .padding(.horizontal, 22)
            .padding(.vertical, 16)
        }
        .frame(
            minWidth: MenuTokens.onboardingWindowWidth,
            idealWidth: 680,
            maxWidth: .infinity,
            minHeight: 700,
            idealHeight: MenuTokens.onboardingWindowHeight,
            maxHeight: .infinity
        )
        .background(MenuTokens.cardBackground)
        .preferredColorScheme(.dark)
        .onAppear {
            checkAllPermissions(trackChanges: false)
            crashReportingEnabled = CrashReportingPreferences.isEnabled()
            anonymousAnalyticsEnabled = AnalyticsPreferences.isEnabled()
            startPolling()
            trackShownIfNeeded()
            trackStepIfNeeded(currentStep)
            trackModelStateIfChanged()
        }
        .onDisappear {
            stopMeetingDryRunIfNeeded()
            stopPolling()
        }
        .onChange(of: currentStep) { _, step in
            trackStepIfNeeded(step)
        }
        .onChange(of: modelStateAnalyticsValue) { _, _ in
            trackModelStateIfChanged()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dictationTranscriptDidSave)) { _ in
            handleDictationSaved()
        }
        .onReceive(NotificationCenter.default.publisher(for: .dictationNoSpeechDetected)) { _ in
            handleNoSpeech()
        }
    }

    @ViewBuilder
    private var currentScreen: some View {
        switch currentStep {
        case .hero:
            HeroStepView()
        case .value:
            ValueStepView()
        case .dictationSetup:
            DictationSetupStepView(
                micGranted: micGranted,
                accessibilityGranted: accessibilityGranted,
                modelStatus: modelStatus,
                onPermissionAction: requestPermission
            )
        case .testDictation:
            TestDictationStepView(
                isRunning: isFirstDictationRunning,
                issue: firstDictationIssue,
                onStart: startFirstDictation,
                onStop: stopFirstDictation
            )
        case .dictationResult:
            FirstDictationResultStepView(
                entry: firstSavedDictation,
                copied: copiedFirstDictation,
                onCopy: copyFirstDictation,
                onOpenFolder: openFirstDictationFolder,
                onRetry: startFirstDictation
            )
        case .meetingsIntro:
            MeetingsIntroStepView()
        case .meetingSetup:
            MeetingSetupStepView(
                micGranted: micGranted,
                systemRecordingGranted: systemRecordingGranted,
                calendarGranted: calendarGranted,
                isDryRunStarting: isMeetingDryRunStarting,
                isDryRunRunning: isMeetingDryRunRunning,
                dryRunCompleted: meetingDryRunCompleted,
                dryRunIssue: meetingDryRunIssue,
                onPermissionAction: requestPermission,
                onDryRun: startMeetingDryRun,
                onStopDryRun: stopMeetingDryRun
            )
        case .agentPayoff:
            AgentPayoffStepView(
                copiedAgentPrompt: copiedAgentPrompt,
                isInstallingClaude: isInstallingClaude,
                installMessage: claudeInstallMessage,
                crashReportingEnabled: $crashReportingEnabled,
                anonymousAnalyticsEnabled: $anonymousAnalyticsEnabled,
                crashReportingAvailable: CrashReporter.isAvailable,
                analyticsAvailable: AnalyticsReporter.isAvailable,
                onInstallClaude: installClaude,
                onCopyAgentPrompt: copyAgentPrompt,
                onOpenAgentSettings: openAgentSettings,
                onCrashToggle: updateCrashReportingPreference,
                onAnalyticsToggle: updateAnalyticsPreference
            )
        }
    }

    private var hasRequiredDictationSetup: Bool {
        FirstRunExperience.hasRequiredDictationSetup(
            microphoneGranted: micGranted,
            accessibilityGranted: accessibilityGranted
        )
    }

    private var currentAction: FirstRunOnboardingActionState {
        if currentStep == .testDictation, isFirstDictationRunning {
            return FirstRunOnboardingActionState(
                primaryTitle: "Stop and Save",
                secondaryTitle: nil,
                detail: "Stop when you finish the sentence. Transcripted will transcribe and save the result.",
                isPrimaryEnabled: true
            )
        }

        if currentStep == .testDictation, firstDictationIssue != nil {
            return FirstRunOnboardingActionState(
                primaryTitle: "Try Again",
                secondaryTitle: "Continue anyway",
                detail: "Try again for the best setup check, or keep going and start dictation later from the menu.",
                isPrimaryEnabled: true
            )
        }

        if currentStep == .meetingSetup, isMeetingDryRunStarting {
            return FirstRunOnboardingActionState(
                primaryTitle: "Starting...",
                secondaryTitle: nil,
                detail: "Starting a short recording test.",
                isPrimaryEnabled: false
            )
        }

        if currentStep == .meetingSetup, isMeetingDryRunRunning {
            return FirstRunOnboardingActionState(
                primaryTitle: "Stop Dry Run",
                secondaryTitle: nil,
                detail: "Stop the dry run when you see recording is active. Test audio will be discarded.",
                isPrimaryEnabled: true
            )
        }

        if currentStep == .meetingSetup, meetingDryRunCompleted {
            return FirstRunOnboardingActionState(
                primaryTitle: "Continue",
                secondaryTitle: "Skip for now",
                detail: "Meeting recording is ready. The test audio was discarded.",
                isPrimaryEnabled: true
            )
        }

        return FirstRunExperience.onboardingAction(
            for: currentStep,
            microphoneGranted: micGranted,
            accessibilityGranted: accessibilityGranted,
            hasFirstDictation: firstSavedDictation != nil
        )
    }

    private var modelStatus: FirstRunModelCardState {
        FirstRunExperience.modelCard(
            for: FirstRunLocalModelState(sttRouter.modelDownloadState),
            model: sttRouter.selectedModel
        )
    }

    private var modelStateAnalyticsValue: String {
        switch sttRouter.modelDownloadState {
        case .notLoaded:
            return "not_loaded"
        case .downloading(let progress):
            return "downloading_\(Int(progress * 100))"
        case .loading:
            return "loading"
        case .ready:
            return "ready"
        case .failed:
            return "failed"
        }
    }

    private func handlePrimaryAction() {
        trackPrimaryCTA(currentAction.primaryTitle)

        switch currentStep {
        case .hero, .value:
            moveToNextStep()
        case .dictationSetup:
            guard hasRequiredDictationSetup else { return }
            moveToNextStep()
        case .testDictation:
            if isFirstDictationRunning {
                stopFirstDictation()
            } else {
                startFirstDictation()
            }
        case .dictationResult:
            if firstSavedDictation == nil {
                startFirstDictation()
            } else {
                move(to: .meetingsIntro)
            }
        case .meetingsIntro:
            move(to: .meetingSetup)
        case .meetingSetup:
            if isMeetingDryRunRunning {
                stopMeetingDryRun()
                return
            }
            guard !isMeetingDryRunStarting else { return }
            move(to: .agentPayoff)
        case .agentPayoff:
            completeOnboarding()
        }
    }

    private func handleSecondaryAction() {
        guard let title = currentAction.secondaryTitle else { return }
        trackPrimaryCTA(title)

        switch currentStep {
        case .testDictation:
            move(to: .meetingsIntro)
        case .meetingsIntro, .meetingSetup:
            move(to: .agentPayoff)
        default:
            break
        }
    }

    private func goBack() {
        guard let previous = FirstRunExperience.previousStep(before: currentStep) else { return }
        move(to: previous)
    }

    private func moveToNextStep() {
        guard let next = FirstRunExperience.nextStep(after: currentStep) else { return }
        move(to: next)
    }

    private func move(to step: FirstRunOnboardingStep) {
        currentStep = step
    }

    private func requestPermission(_ kind: TranscriptedPermissionKind) {
        AnalyticsReporter.track(
            "onboarding_permission_cta_clicked",
            properties: [
                "permission_kind": kind.analyticsValue,
                "prior_status": permissionStatusValue(kind),
                "required": kind.isRequiredOnFirstLaunch ? "true" : "false",
                "step_id": currentStep.analyticsValue,
            ]
        )
        TranscriptedPermissionAccess.openSettings(for: kind)
    }

    private func startFirstDictation() {
        guard hasRequiredDictationSetup else {
            move(to: .dictationSetup)
            return
        }

        firstDictationIssue = nil
        isFirstDictationRunning = true
        AnalyticsReporter.track(
            "onboarding_first_dictation_started",
            properties: [
                "model_state": modelStateAnalyticsValue,
                "step_id": currentStep.analyticsValue,
            ]
        )

        guard let onStartDictation else {
            isFirstDictationRunning = false
            firstDictationIssue = "Dictation could not start from onboarding. Open Transcripted and try Start Dictation."
            EventReporter.shared.capture(
                level: .error,
                engine: "onboarding",
                event: "first_dictation_start_failed",
                message: "Onboarding first dictation callback was not wired",
                context: ["step_id": currentStep.analyticsValue]
            )
            return
        }

        onStartDictation()
    }

    private func stopFirstDictation() {
        AnalyticsReporter.track(
            "onboarding_first_dictation_stop_clicked",
            properties: [
                "step_id": currentStep.analyticsValue,
            ]
        )

        guard let onStopDictation else {
            firstDictationIssue = "Dictation is running, but onboarding could not stop it. Use the floating control to stop."
            EventReporter.shared.capture(
                level: .error,
                engine: "onboarding",
                event: "first_dictation_stop_failed",
                message: "Onboarding first dictation stop callback was not wired",
                context: ["step_id": currentStep.analyticsValue]
            )
            return
        }

        onStopDictation()
    }

    private func startMeetingDryRun() {
        guard !isMeetingDryRunStarting, !isMeetingDryRunRunning else { return }
        meetingDryRunIssue = nil
        meetingDryRunCompleted = false
        isMeetingDryRunStarting = true

        AnalyticsReporter.track(
            "onboarding_meeting_dry_run_clicked",
            properties: [
                "meeting_recording_ready": systemRecordingGranted ? "true" : "false",
                "step_id": currentStep.analyticsValue,
            ]
        )

        guard let onStartMeetingDryRun else {
            isMeetingDryRunStarting = false
            meetingDryRunIssue = "Meeting recording could not start from onboarding. You can still start meetings later from the menu."
            return
        }

        Task { @MainActor in
            let started = await onStartMeetingDryRun()
            isMeetingDryRunStarting = false
            isMeetingDryRunRunning = started
            if !started {
                meetingDryRunIssue = "Meeting recording could not start. Check Microphone and System Audio Recording, then try again."
            }
        }
    }

    private func stopMeetingDryRun() {
        guard isMeetingDryRunStarting || isMeetingDryRunRunning else { return }
        meetingDryRunIssue = nil

        guard let onStopMeetingDryRun else {
            isMeetingDryRunStarting = false
            isMeetingDryRunRunning = false
            meetingDryRunIssue = "Meeting recording is running, but onboarding could not stop it. Use the meeting overlay stop button."
            return
        }

        Task { @MainActor in
            let stopped = await onStopMeetingDryRun()
            isMeetingDryRunStarting = false
            isMeetingDryRunRunning = false
            meetingDryRunCompleted = stopped
            if !stopped {
                meetingDryRunIssue = "Meeting recording had already stopped. You can continue or run the dry run again."
            }
        }
    }

    private func stopMeetingDryRunIfNeeded() {
        guard isMeetingDryRunStarting || isMeetingDryRunRunning else { return }
        guard let onStopMeetingDryRun else { return }
        Task { @MainActor in
            _ = await onStopMeetingDryRun()
        }
    }

    private func copyFirstDictation() {
        guard let text = firstSavedDictation?.text else { return }
        copyText(text)
        copiedFirstDictation = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copiedFirstDictation = false
        }
    }

    private func openFirstDictationFolder() {
        guard let url = firstSavedDictation?.url else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func installClaude() {
        guard !isInstallingClaude else { return }
        isInstallingClaude = true
        claudeInstallMessage = nil
        AnalyticsReporter.track(
            "onboarding_agent_cta_clicked",
            properties: [
                "agent_cta": "install_claude",
                "step_id": currentStep.analyticsValue,
            ]
        )

        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try ClaudeDesktopIntegrationInstaller.installForClaudeDesktop()
                }.value
                claudeInstallMessage = "Ready. Restart Claude Desktop."
            } catch {
                claudeInstallMessage = error.localizedDescription
            }
            isInstallingClaude = false
        }
    }

    private func copyAgentPrompt() {
        copyText(AgentConnectionGuide.starterPrompt(filename: nil))
        copiedAgentPrompt = true
        AnalyticsReporter.track(
            "onboarding_agent_cta_clicked",
            properties: [
                "agent_cta": "copy_for_agent",
                "step_id": currentStep.analyticsValue,
            ]
        )
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copiedAgentPrompt = false
        }
    }

    private func openAgentSettings() {
        AnalyticsReporter.track(
            "onboarding_agent_cta_clicked",
            properties: [
                "agent_cta": "open_agent_settings",
                "step_id": currentStep.analyticsValue,
            ]
        )
        onOpenAgentSettings?()
    }

    private func updateCrashReportingPreference(_ enabled: Bool) {
        crashReportingEnabled = enabled
        CrashReportingPreferences.setEnabled(enabled)
        AnalyticsReporter.track(
            "onboarding_reporting_toggle_changed",
            properties: [
                "available": CrashReporter.isAvailable ? "true" : "false",
                "enabled": enabled ? "true" : "false",
                "reporting_kind": "crash",
                "step_id": currentStep.analyticsValue,
            ]
        )
    }

    private func updateAnalyticsPreference(_ enabled: Bool) {
        if anonymousAnalyticsEnabled {
            AnalyticsReporter.track(
                "onboarding_reporting_toggle_changed",
                properties: [
                    "available": AnalyticsReporter.isAvailable ? "true" : "false",
                    "enabled": enabled ? "true" : "false",
                    "reporting_kind": "analytics",
                    "step_id": currentStep.analyticsValue,
                ]
            )
        }
        anonymousAnalyticsEnabled = enabled
        AnalyticsPreferences.setEnabled(enabled)
        if enabled {
            AnalyticsReporter.track(
                "onboarding_reporting_toggle_changed",
                properties: [
                    "available": AnalyticsReporter.isAvailable ? "true" : "false",
                    "enabled": "true",
                    "reporting_kind": "analytics",
                    "step_id": currentStep.analyticsValue,
                ]
            )
        }
    }

    private func completeOnboarding() {
        stopPolling()
        AnalyticsReporter.track(
            "onboarding_completed",
            properties: [
                "anonymous_usage_enabled": anonymousAnalyticsEnabled ? "true" : "false",
                "calendar_status": calendarGranted ? "ready" : "pending",
                "completion_path": "guided",
                "crash_reporting_enabled": crashReportingEnabled ? "true" : "false",
                "first_dictation_saved": firstSavedDictation == nil ? "false" : "true",
                "meeting_recording_ready": systemRecordingGranted ? "true" : "false",
                "model_state": modelStateAnalyticsValue,
                "step_id": currentStep.analyticsValue,
            ]
        )
        onComplete()
    }

    private func handleDictationSaved() {
        guard isFirstDictationRunning || currentStep == .testDictation else { return }
        firstSavedDictation = DictationTranscriptStore.latestSavedDictation()
        isFirstDictationRunning = false
        firstDictationIssue = nil
        NSApp.activate(ignoringOtherApps: true)

        if let firstSavedDictation {
            AnalyticsReporter.track(
                "onboarding_first_dictation_saved",
                properties: [
                    "delivery": firstSavedDictation.delivery.rawValue,
                    "step_id": currentStep.analyticsValue,
                    "word_count_bucket": AnalyticsReporter.wordCountBucket(
                        firstSavedDictation.text.split(whereSeparator: \.isWhitespace).count
                    ),
                ]
            )
        }
        move(to: .dictationResult)
    }

    private func handleNoSpeech() {
        guard currentStep == .testDictation || isFirstDictationRunning else { return }
        isFirstDictationRunning = false
        firstDictationIssue = "No speech detected. Try one clear sentence, like: remind me to review the pricing call."
        NSApp.activate(ignoringOtherApps: true)
        AnalyticsReporter.track(
            "onboarding_first_dictation_empty",
            properties: [
                "step_id": currentStep.analyticsValue,
            ]
        )
    }

    private func checkAllPermissions(trackChanges: Bool = true) {
        let statuses: [TranscriptedPermissionKind: Bool] = [
            .microphone: TranscriptedPermissionAccess.isGranted(.microphone),
            .accessibility: TranscriptedPermissionAccess.isGranted(.accessibility),
            .systemAudioRecording: TranscriptedPermissionAccess.isGranted(.systemAudioRecording),
            .calendar: TranscriptedPermissionAccess.isGranted(.calendar),
        ]

        micGranted = statuses[.microphone] ?? false
        accessibilityGranted = statuses[.accessibility] ?? false
        systemRecordingGranted = statuses[.systemAudioRecording] ?? false
        calendarGranted = statuses[.calendar] ?? false

        if trackChanges, !previousPermissionStatuses.isEmpty {
            for kind in TranscriptedPermissionKind.allCases {
                let old = previousPermissionStatuses[kind] ?? false
                let new = statuses[kind] ?? false
                guard old != new else { continue }
                AnalyticsReporter.track(
                    "onboarding_permission_status_changed",
                    properties: [
                        "from_status": old ? "ready" : "pending",
                        "permission_kind": kind.analyticsValue,
                        "step_id": currentStep.analyticsValue,
                        "to_status": new ? "ready" : "pending",
                    ]
                )
            }
        }

        previousPermissionStatuses = statuses
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

    private func trackShownIfNeeded() {
        guard !trackedShown else { return }
        trackedShown = true
        AnalyticsReporter.track(
            "onboarding_shown",
            properties: [
                "analytics_available": AnalyticsReporter.isAvailable ? "true" : "false",
                "crash_reporting_available": CrashReporter.isAvailable ? "true" : "false",
                "entrypoint": "first_launch",
                "has_target": canStartDictation ? "true" : "false",
                "meeting_recording_ready": systemRecordingGranted ? "true" : "false",
                "mic_status": micGranted ? "ready" : "pending",
                "model_state": modelStateAnalyticsValue,
                "pasteback_status": accessibilityGranted ? "ready" : "pending",
            ]
        )
    }

    private func trackStepIfNeeded(_ step: FirstRunOnboardingStep) {
        guard !trackedSteps.contains(step) else { return }
        trackedSteps.insert(step)
        AnalyticsReporter.track(
            "onboarding_step_viewed",
            properties: [
                "model_state": modelStateAnalyticsValue,
                "step_id": step.analyticsValue,
                "step_index": "\(step.rawValue + 1)",
            ]
        )
    }

    private func trackModelStateIfChanged() {
        let newState = modelStateAnalyticsValue
        guard lastTrackedModelState != newState else { return }
        let oldState = lastTrackedModelState
        lastTrackedModelState = newState
        AnalyticsReporter.track(
            "onboarding_model_state_changed",
            properties: [
                "from_status": oldState ?? "unknown",
                "step_id": currentStep.analyticsValue,
                "to_status": newState,
            ]
        )
    }

    private func trackPrimaryCTA(_ title: String) {
        AnalyticsReporter.track(
            "onboarding_primary_cta_clicked",
            properties: [
                "cta": title.analyticsSlug,
                "model_state": modelStateAnalyticsValue,
                "step_id": currentStep.analyticsValue,
            ]
        )
    }

    private func permissionStatusValue(_ kind: TranscriptedPermissionKind) -> String {
        switch kind {
        case .microphone:
            return micGranted ? "ready" : "pending"
        case .accessibility:
            return accessibilityGranted ? "ready" : "pending"
        case .systemAudioRecording:
            return systemRecordingGranted ? "ready" : "pending"
        case .calendar:
            return calendarGranted ? "ready" : "pending"
        }
    }

    private func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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

private struct OnboardingHeader: View {
    let steps: [FirstRunOnboardingStep]
    let currentStep: FirstRunOnboardingStep

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                AppIconPreview(size: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Transcripted")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(MenuTokens.textPrimary)

                    Text("Step \(currentStep.rawValue + 1) of \(steps.count): \(currentStep.progressTitle)")
                        .font(.footnote)
                        .foregroundStyle(MenuTokens.textSecondary)
                }

                Spacer()
            }

            HStack(spacing: 6) {
                ForEach(steps) { step in
                    ProgressStepPill(
                        title: step.progressTitle,
                        isCurrent: step == currentStep,
                        isComplete: step.rawValue < currentStep.rawValue
                    )
                }
            }
        }
    }
}

private struct ProgressStepPill: View {
    let title: String
    let isCurrent: Bool
    let isComplete: Bool

    var body: some View {
        HStack(spacing: 4) {
            if isComplete {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
            }
            Text(isCurrent ? title : "")
                .font(.system(size: 11, weight: .semibold))
                .lineLimit(1)
        }
        .foregroundStyle(isCurrent || isComplete ? MenuTokens.textPrimary : MenuTokens.textMuted)
        .frame(minWidth: isCurrent ? 104 : 18, minHeight: 22)
        .padding(.horizontal, isCurrent ? 8 : 2)
        .background(
            Capsule()
                .fill(isCurrent ? Color.accentColor.opacity(0.35) : MenuTokens.pillBackground)
                .overlay(
                    Capsule()
                        .stroke(isCurrent ? Color.accentColor.opacity(0.65) : MenuTokens.pillBorder, lineWidth: 1)
                )
        )
    }
}

private struct OnboardingFooter: View {
    let action: FirstRunOnboardingActionState
    let canGoBack: Bool
    let onBack: () -> Void
    let onSecondary: () -> Void
    let onPrimary: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Button {
                onBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            .disabled(!canGoBack)

            Text(action.detail)
                .font(.footnote)
                .foregroundStyle(MenuTokens.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 10)

            if let secondaryTitle = action.secondaryTitle {
                Button(secondaryTitle) {
                    onSecondary()
                }
                .buttonStyle(.bordered)
            }

            Button(action.primaryTitle) {
                onPrimary()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!action.isPrimaryEnabled)
        }
    }
}

private struct HeroStepView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 14) {
                AppIconPreview(size: 78)

                Text(FirstRunOnboardingStep.hero.screenTitle)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(MenuTokens.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(FirstRunOnboardingCopy.heroDetail)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(MenuTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            OnboardingCard {
                HStack(spacing: 14) {
                    FlowSymbol(name: "mic.fill", title: "Speak")
                    FlowArrow()
                    FlowSymbol(name: "doc.text.fill", title: "Markdown")
                    FlowArrow()
                    FlowSymbol(name: "sparkles", title: "Agent")
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct ValueStepView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScreenTitle(
                title: FirstRunOnboardingStep.value.screenTitle,
                detail: "Transcripted gives you two ways to turn spoken work into notes you can actually use."
            )

            HStack(spacing: 14) {
                ValueCard(
                    icon: "mic.fill",
                    title: "Dictation",
                    detail: "Dictate instead of type."
                )

                ValueCard(
                    icon: "record.circle.fill",
                    title: "Meetings",
                    detail: "Record conversations into notes."
                )
            }

            OnboardingCallout(
                icon: "folder.fill",
                title: "Local Markdown",
                detail: FirstRunOnboardingCopy.valueFooter
            )
        }
    }
}

private struct DictationSetupStepView: View {
    let micGranted: Bool
    let accessibilityGranted: Bool
    let modelStatus: FirstRunModelCardState
    let onPermissionAction: (TranscriptedPermissionKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScreenTitle(
                title: FirstRunOnboardingStep.dictationSetup.screenTitle,
                detail: "Dictation needs two things: permission to listen and permission to paste your words back where you were typing."
            )

            SetupRow(
                icon: "mic.fill",
                title: "Microphone",
                detail: "Lets Transcripted listen when you start dictation.",
                status: micGranted ? "Ready" : "Required",
                tone: micGranted ? .ready : .needed,
                buttonTitle: micGranted ? nil : TranscriptedPermissionKind.microphone.actionButtonTitle
            ) {
                onPermissionAction(.microphone)
            }

            SetupRow(
                icon: "text.cursor",
                title: "Paste-back",
                detail: "Lets Transcripted paste the dictation into the app you were using.",
                status: accessibilityGranted ? "Ready" : "Required",
                tone: accessibilityGranted ? .ready : .needed,
                buttonTitle: accessibilityGranted ? nil : TranscriptedPermissionKind.accessibility.actionButtonTitle
            ) {
                onPermissionAction(.accessibility)
            }

            LocalModelSetupRow(status: modelStatus)
        }
    }
}

private struct TestDictationStepView: View {
    let isRunning: Bool
    let issue: String?
    let onStart: () -> Void
    let onStop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScreenTitle(
                title: FirstRunOnboardingStep.testDictation.screenTitle,
                detail: "Let's make sure the whole loop works before moving on."
            )

            OnboardingCard {
                VStack(alignment: .leading, spacing: 14) {
                    Label(FirstRunOnboardingCopy.dictationPrompt, systemImage: "waveform")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(MenuTokens.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Start dictation, say the sentence, then click Stop and Save here.")
                        .font(.callout)
                        .foregroundStyle(MenuTokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if isRunning {
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Listening or preparing...")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(MenuTokens.textSecondary)
                        }
                    }

                    if let issue {
                        OnboardingCallout(
                            icon: "exclamationmark.triangle.fill",
                            title: "Try again",
                            detail: issue,
                            tone: .warning
                        )
                    }

                    Button {
                        isRunning ? onStop() : onStart()
                    } label: {
                        Label(isRunning ? "Stop and Save" : "Start Dictation", systemImage: isRunning ? "stop.fill" : "mic.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
        }
    }
}

private struct FirstDictationResultStepView: View {
    let entry: SavedDictationEntry?
    let copied: Bool
    let onCopy: () -> Void
    let onOpenFolder: () -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScreenTitle(
                title: FirstRunOnboardingStep.dictationResult.screenTitle,
                detail: "This is the core loop: dictate instead of type, and keep a saved Markdown copy."
            )

            if let entry {
                OnboardingCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Transcript preview")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(MenuTokens.textPrimary)

                        Text(entry.text)
                            .font(.body)
                            .foregroundStyle(MenuTokens.textPrimary)
                            .lineLimit(6)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(MenuTokens.pillBackground)
                            )

                        HStack(spacing: 10) {
                            Label(FirstRunOnboardingCopy.savedAsMarkdown, systemImage: "doc.text.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(MenuTokens.textPrimary)

                            Spacer()

                            Text(entry.url.lastPathComponent)
                                .font(.footnote.monospaced())
                                .foregroundStyle(MenuTokens.textSecondary)
                                .lineLimit(1)
                        }
                    }
                }

                OnboardingCallout(
                    icon: "sparkles",
                    title: "For your agent",
                    detail: FirstRunOnboardingCopy.agentDictationNote
                )

                HStack(spacing: 10) {
                    Button {
                        onCopy()
                    } label: {
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        onOpenFolder()
                    } label: {
                        Label("Open Folder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }
            } else {
                OnboardingCallout(
                    icon: "exclamationmark.triangle.fill",
                    title: "No dictation saved yet",
                    detail: "Try one clear sentence so Transcripted can show you the saved Markdown result.",
                    tone: .warning
                )

                Button {
                    onRetry()
                } label: {
                    Label("Try Again", systemImage: "mic.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct MeetingsIntroStepView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScreenTitle(
                title: FirstRunOnboardingStep.meetingsIntro.screenTitle,
                detail: "Once dictation works, the same idea expands to meetings."
            )

            OnboardingCard {
                HStack(spacing: 14) {
                    FlowSymbol(name: "person.2.wave.2.fill", title: "Conversation")
                    FlowArrow()
                    FlowSymbol(name: "waveform", title: "Recording")
                    FlowArrow()
                    FlowSymbol(name: "doc.text.fill", title: "Notes")
                }
                .frame(maxWidth: .infinity)
            }

            OnboardingCallout(
                icon: "record.circle.fill",
                title: "Meetings become notes",
                detail: FirstRunOnboardingCopy.meetingsDetail
            )
        }
    }
}

private struct MeetingSetupStepView: View {
    let micGranted: Bool
    let systemRecordingGranted: Bool
    let calendarGranted: Bool
    let isDryRunStarting: Bool
    let isDryRunRunning: Bool
    let dryRunCompleted: Bool
    let dryRunIssue: String?
    let onPermissionAction: (TranscriptedPermissionKind) -> Void
    let onDryRun: () -> Void
    let onStopDryRun: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ScreenTitle(
                title: FirstRunOnboardingStep.meetingSetup.screenTitle,
                detail: "Meeting recording needs your microphone plus System Audio Recording for the other side of calls."
            )

            SetupRow(
                icon: "mic.fill",
                title: "Microphone",
                detail: "Already used for your side of meetings.",
                status: micGranted ? "Ready" : "Required",
                tone: micGranted ? .ready : .needed,
                buttonTitle: micGranted ? nil : TranscriptedPermissionKind.microphone.actionButtonTitle
            ) {
                onPermissionAction(.microphone)
            }

            SetupRow(
                icon: "speaker.wave.2.fill",
                title: "System Audio Recording",
                detail: "Captures the other side of Zoom, Meet, videos, and calls.",
                status: systemRecordingGranted ? "Ready" : "Needed for meetings",
                tone: systemRecordingGranted ? .ready : .needed,
                buttonTitle: systemRecordingGranted ? nil : TranscriptedPermissionKind.systemAudioRecording.actionButtonTitle
            ) {
                onPermissionAction(.systemAudioRecording)
            }

            SetupRow(
                icon: "calendar",
                title: "Calendar",
                detail: "Optional. Helps Transcripted spot meetings and offer a record prompt.",
                status: calendarGranted ? "Ready" : "Optional",
                tone: calendarGranted ? .ready : .neutral,
                buttonTitle: calendarGranted ? nil : TranscriptedPermissionKind.calendar.actionButtonTitle
            ) {
                onPermissionAction(.calendar)
            }

            OnboardingCard {
                HStack(spacing: 12) {
                    Image(systemName: dryRunCompleted ? "checkmark.circle.fill" : "record.circle")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(dryRunCompleted ? MenuTokens.statusGreen : Color.accentColor)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(dryRunCompleted ? "Dry run worked" : "Run a quick dry run")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(MenuTokens.textPrimary)

                        Text(dryRunDetail)
                            .font(.footnote)
                            .foregroundStyle(MenuTokens.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer()

                    Button {
                        isDryRunRunning ? onStopDryRun() : onDryRun()
                    } label: {
                        Label(dryRunButtonTitle, systemImage: dryRunButtonIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isDryRunStarting)
                }
            }

            if let dryRunIssue {
                OnboardingCallout(
                    icon: "exclamationmark.triangle.fill",
                    title: "Dry run needs another try",
                    detail: dryRunIssue,
                    tone: .warning
                )
            }
        }
    }

    private var dryRunDetail: String {
        if isDryRunStarting {
            return "Starting a short recording test..."
        }
        if isDryRunRunning {
            return "Recording test is running. Stop it here when you're ready. Test audio will be discarded."
        }
        if dryRunCompleted {
            return "Meeting capture started and stopped correctly. The test audio was discarded."
        }
        return "Start a short meeting recording test, then stop it here. Transcripted discards this test audio."
    }

    private var dryRunButtonTitle: String {
        if isDryRunStarting {
            return "Starting..."
        }
        return isDryRunRunning ? "Stop Dry Run" : "Run Dry Run"
    }

    private var dryRunButtonIcon: String {
        if isDryRunStarting {
            return "clock"
        }
        return isDryRunRunning ? "stop.fill" : "play.fill"
    }
}

private struct AgentPayoffStepView: View {
    let copiedAgentPrompt: Bool
    let isInstallingClaude: Bool
    let installMessage: String?
    @Binding var crashReportingEnabled: Bool
    @Binding var anonymousAnalyticsEnabled: Bool
    let crashReportingAvailable: Bool
    let analyticsAvailable: Bool
    let onInstallClaude: () -> Void
    let onCopyAgentPrompt: () -> Void
    let onOpenAgentSettings: () -> Void
    let onCrashToggle: (Bool) -> Void
    let onAnalyticsToggle: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ScreenTitle(
                title: FirstRunOnboardingStep.agentPayoff.screenTitle,
                detail: FirstRunOnboardingCopy.agentDetail
            )

            OnboardingCard {
                HStack(spacing: 14) {
                    FlowSymbol(name: "folder.fill", title: "Markdown")
                    FlowArrow()
                    FlowSymbol(name: "magnifyingglass", title: "Search")
                    FlowArrow()
                    FlowSymbol(name: "sparkles", title: "Agent")
                }
                .frame(maxWidth: .infinity)
            }

            VStack(alignment: .leading, spacing: 8) {
                AgentPromptPill(text: "Search my meetings")
                AgentPromptPill(text: "What am I working on?")
                AgentPromptPill(text: "Summarize today")
            }

            HStack(spacing: 10) {
                Button {
                    onInstallClaude()
                } label: {
                    Label(isInstallingClaude ? "Installing..." : "Install in Claude", systemImage: isInstallingClaude ? "hourglass" : "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isInstallingClaude)

                Button {
                    onCopyAgentPrompt()
                } label: {
                    Label(copiedAgentPrompt ? "Copied" : "Copy for Agent", systemImage: copiedAgentPrompt ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Button {
                    onOpenAgentSettings()
                } label: {
                    Label("Agent Settings", systemImage: "gearshape")
                }
                .buttonStyle(.bordered)
            }

            if let installMessage {
                Text(installMessage)
                    .font(.footnote)
                    .foregroundStyle(installMessage.hasPrefix("Ready") ? MenuTokens.statusGreen : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ReportingConsentCard(
                crashReportingEnabled: $crashReportingEnabled,
                anonymousAnalyticsEnabled: $anonymousAnalyticsEnabled,
                crashReportingAvailable: crashReportingAvailable,
                analyticsAvailable: analyticsAvailable,
                onCrashToggle: onCrashToggle,
                onAnalyticsToggle: onAnalyticsToggle
            )
        }
    }
}

private struct ReportingConsentCard: View {
    @Binding var crashReportingEnabled: Bool
    @Binding var anonymousAnalyticsEnabled: Bool
    let crashReportingAvailable: Bool
    let analyticsAvailable: Bool
    let onCrashToggle: (Bool) -> Void
    let onAnalyticsToggle: (Bool) -> Void

    var body: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Help improve Transcripted", systemImage: "bolt.shield.fill")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(MenuTokens.textPrimary)

                Text("Privacy-safe diagnostics help catch setup problems. Transcripted never sends transcript text, audio, meeting titles, speaker names, source app names, emails, file paths, or raw URLs.")
                    .font(.footnote)
                    .foregroundStyle(MenuTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                ToggleRow(
                    title: "Crash and error reports",
                    detail: crashReportingAvailable ? "Scrubbed reliability events only." : "Unavailable in this build.",
                    isOn: Binding(get: { crashReportingEnabled }, set: { onCrashToggle($0) }),
                    isEnabled: crashReportingAvailable
                )

                ToggleRow(
                    title: "Anonymous usage stats",
                    detail: analyticsAvailable ? "Allowlisted product events only." : "Unavailable until PostHog is configured.",
                    isOn: Binding(get: { anonymousAnalyticsEnabled }, set: { onAnalyticsToggle($0) }),
                    isEnabled: analyticsAvailable
                )
            }
        }
    }
}

private struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    let isEnabled: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(MenuTokens.textPrimary)

                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(MenuTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Toggle("", isOn: $isOn)
                .labelsHidden()
                .disabled(!isEnabled)
                .accessibilityLabel(title)
                .help(detail)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(MenuTokens.pillBackground)
        )
    }
}

private struct ScreenTitle: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(MenuTokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Text(detail)
                .font(.title3.weight(.medium))
                .foregroundStyle(MenuTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct ValueCard: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.accentColor)

                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(MenuTokens.textPrimary)

                Text(detail)
                    .font(.callout)
                    .foregroundStyle(MenuTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
        }
    }
}

private enum SetupTone {
    case ready
    case needed
    case working
    case warning
    case neutral

    var color: Color {
        switch self {
        case .ready:
            return MenuTokens.statusGreen
        case .needed, .warning:
            return Color.orange
        case .working:
            return Color.accentColor
        case .neutral:
            return MenuTokens.textSecondary
        }
    }
}

private struct SetupRow: View {
    let icon: String
    let title: String
    let detail: String
    let status: String
    let tone: SetupTone
    let buttonTitle: String?
    let action: () -> Void

    var body: some View {
        OnboardingCard {
            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(MenuTokens.pillBackground)
                        .frame(width: 42, height: 42)

                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(MenuTokens.textPrimary)
                }

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(MenuTokens.textPrimary)

                        StatusBadge(title: status, tone: tone)
                    }

                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(MenuTokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                if let buttonTitle {
                    Button(buttonTitle) {
                        action()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

private struct LocalModelSetupRow: View {
    let status: FirstRunModelCardState

    var body: some View {
        OnboardingCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(MenuTokens.pillBackground)
                            .frame(width: 42, height: 42)

                        Image(systemName: iconName)
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(iconColor)
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text("Local model")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(MenuTokens.textPrimary)

                            StatusBadge(title: status.status, tone: tone)
                        }

                        Text(status.detail)
                            .font(.callout)
                            .foregroundStyle(MenuTokens.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let progress = status.progress, status.tone != .ready {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(iconColor)
                }
            }
        }
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

    private var tone: SetupTone {
        switch status.tone {
        case .ready:
            return .ready
        case .working:
            return .working
        case .failed:
            return .warning
        }
    }

    private var iconColor: Color {
        tone.color
    }
}

private struct StatusBadge: View {
    let title: String
    let tone: SetupTone

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tone.color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(tone == .ready ? MenuTokens.savedBackground : MenuTokens.pillBackground)
                    .overlay(
                        Capsule()
                            .stroke(tone == .ready ? MenuTokens.savedBorder : MenuTokens.pillBorder, lineWidth: 1)
                    )
            )
    }
}

private enum CalloutTone {
    case normal
    case warning
}

private struct OnboardingCallout: View {
    let icon: String
    let title: String
    let detail: String
    var tone: CalloutTone = .normal

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tone == .warning ? Color.orange : Color.accentColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(MenuTokens.textPrimary)

                Text(detail)
                    .font(.callout)
                    .foregroundStyle(MenuTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tone == .warning ? Color.orange.opacity(0.12) : MenuTokens.pillBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(tone == .warning ? Color.orange.opacity(0.28) : MenuTokens.pillBorder, lineWidth: 1)
                )
        )
    }
}

private struct OnboardingCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MenuTokens.pillBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(MenuTokens.pillBorder, lineWidth: 1)
                    )
            )
    }
}

private struct FlowSymbol: View {
    let name: String
    let title: String

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MenuTokens.pillBackground)
                    .frame(width: 76, height: 58)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(MenuTokens.pillBorder, lineWidth: 1)
                    )

                Image(systemName: name)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            Text(title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(MenuTokens.textSecondary)
        }
    }
}

private struct FlowArrow: View {
    var body: some View {
        Image(systemName: "arrow.right")
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(MenuTokens.textSecondary)
            .frame(width: 28)
    }
}

private struct AgentPromptPill: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text(text)
                .font(.callout.weight(.semibold))
                .foregroundStyle(MenuTokens.textPrimary)

            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(MenuTokens.pillBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(MenuTokens.pillBorder, lineWidth: 1)
                )
        )
    }
}

private struct AppIconPreview: View {
    let size: CGFloat

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
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: min(16, size * 0.22), style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
    }
}

private extension TranscriptedPermissionKind {
    var analyticsValue: String {
        switch self {
        case .microphone:
            return "microphone"
        case .accessibility:
            return "pasteback"
        case .systemAudioRecording:
            return "system_recording"
        case .calendar:
            return "calendar"
        }
    }
}

private extension FirstRunOnboardingStep {
    var analyticsValue: String {
        switch self {
        case .hero:
            return "hero"
        case .value:
            return "value"
        case .dictationSetup:
            return "dictation_setup"
        case .testDictation:
            return "test_dictation"
        case .dictationResult:
            return "dictation_result"
        case .meetingsIntro:
            return "meetings_intro"
        case .meetingSetup:
            return "meeting_setup"
        case .agentPayoff:
            return "agent_payoff"
        }
    }
}

private extension String {
    var analyticsSlug: String {
        lowercased()
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
            .filter { $0.isLetter || $0.isNumber || $0 == "_" }
    }
}
