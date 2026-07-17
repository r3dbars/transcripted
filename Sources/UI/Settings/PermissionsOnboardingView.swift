// PermissionsOnboardingView.swift
// First-run onboarding for Transcripted's local dictation and meeting capture.
//
// The flow is intentionally four steps: welcome → permissions → try dictation
// → ready. Every grant lives on the single permissions screen, the voice model
// prefetches in the background from the first screen, and the only hard gate
// is Microphone so meeting-only users are never trapped on optional grants.

import SwiftUI
import AppKit

extension Notification.Name {
    /// Posted by app-termination cleanup so onboarding can attribute an
    /// in-progress permission handoff before the process exits, since
    /// `onDisappear` never fires when the app quits without closing the
    /// onboarding window first.
    static let transcriptedOnboardingWillTerminate = Notification.Name("transcriptedOnboardingWillTerminate")
}

extension FirstRunLocalModelState {
    init(_ state: ParakeetModelState) {
        switch state {
        case .notLoaded:
            self = .notLoaded
        case .downloading(let progress):
            self = .downloading(progress: progress)
        case .cached:
            self = .cached
        case .loading:
            self = .loading
        case .ready:
            self = .ready
        case .failed(let message):
            self = .failed(message)
        }
    }
}

@MainActor
struct PermissionsOnboardingView: View {
    var onComplete: () -> Void
    var startModelPrefetch: @MainActor () -> Void
    var modelStateProvider: @MainActor () -> FirstRunLocalModelState

    static let preferredSize = NSSize(width: 960, height: 680)
    private static let defaultDictationShortcut = "Right Option"

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var currentStepIndex = 0
    @State private var navigationDirection: OnboardingNavigationDirection = .forward
    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var systemAudioGranted = false
    @State private var diagnosticsEnabled = CrashReportingPreferences.isEnabled() && AnalyticsPreferences.isEnabled()
    @State private var demoDictationText = ""
    @State private var modelState: FirstRunLocalModelState = .notLoaded
    @State private var copiedAgentItem: AgentCopyItem?
    @State private var claudeDesktopConnectPhase: OnboardingAgentConnectPhase = .idle
    @State private var copiedResetTask: Task<Void, Never>?
    @State private var pollTask: Task<Void, Never>?
    @State private var systemAudioProbeTask: Task<Void, Never>?
    @State private var flowStartedAt: CFAbsoluteTime?
    @State private var stepStartedAt: CFAbsoluteTime?
    @State private var didTrackCompletion = false
    @State private var didTrackAbandonment = false
    @State private var didStartModelPrefetch = false
    @State private var pendingSystemSettingsHandoff = false
    @State private var pendingSystemSettingsHandoffKind: TranscriptedPermissionKind?
    @State private var lastPermissionStatuses: [TranscriptedPermissionKind: String] = [:]
    @FocusState private var demoEditorFocused: Bool

    init(
        startModelPrefetch: @escaping @MainActor () -> Void = {},
        modelStateProvider: @escaping @MainActor () -> FirstRunLocalModelState = { .notLoaded },
        onComplete: @escaping () -> Void
    ) {
        self.startModelPrefetch = startModelPrefetch
        self.modelStateProvider = modelStateProvider
        self.onComplete = onComplete
    }

    private static let stepSequence: [OnboardingStepSpec] = [
        .init(kind: .welcome),
        .init(kind: .permissions),
        .init(kind: .tryDictation, canSkip: true),
        .init(kind: .ready),
    ]

    private var steps: [OnboardingStepSpec] { Self.stepSequence }

    private var currentStep: OnboardingStepSpec {
        steps[min(currentStepIndex, steps.count - 1)]
    }

    /// Microphone is the only hard gate. System Audio and Accessibility are
    /// strongly nudged in place, but meeting-only users must never be trapped
    /// behind grants they do not need yet.
    private var hasRequiredPermissions: Bool {
        FirstRunExperience.hasRequiredMeetingSetup(microphoneGranted: micGranted)
    }

    private var dictationReady: Bool {
        FirstRunExperience.hasRequiredDictationSetup(
            microphoneGranted: micGranted,
            accessibilityGranted: accessibilityGranted
        )
    }

    private var primaryButtonTitle: String {
        if currentStepIndex == 0 { return "Begin" }
        if currentStepIndex == steps.count - 1 { return "Open Transcripted" }
        return "Continue"
    }

    private var primaryButtonDisabled: Bool {
        (currentStep.kind == .permissions || currentStep.kind == .ready) && !hasRequiredPermissions
    }

    var body: some View {
        OnboardingWindowShell(
            current: currentStepIndex,
            total: steps.count,
            direction: navigationDirection,
            canGoBack: currentStepIndex > 0,
            canSkip: currentStep.canSkip,
            primaryTitle: primaryButtonTitle,
            primaryDisabled: primaryButtonDisabled,
            onBack: goBack,
            onSkip: goNext,
            onNext: goNextOrComplete
        ) {
            stepContent
                .id(currentStep.kind)
        }
        .frame(width: Self.preferredSize.width, height: Self.preferredSize.height)
        .background(OnboardingTheme.canvas)
        .onAppear {
            if flowStartedAt == nil {
                flowStartedAt = CFAbsoluteTimeGetCurrent()
            }
            if !didStartModelPrefetch {
                // Start caching the on-device voice model while the user reads
                // the first screens, so the first dictation is not blocked on a
                // large download.
                didStartModelPrefetch = true
                startModelPrefetch()
            }
            checkAllPermissions(trackChanges: false)
            revalidateSystemAudioIfAlreadyKnown()
            refreshModelState()
            trackCurrentStepViewed()
            startPolling()
        }
        .onChange(of: currentStepIndex) { _, _ in
            trackCurrentStepViewed()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            handleAppBecameActive()
        }
        .onReceive(NotificationCenter.default.publisher(for: .transcriptedOnboardingWillTerminate)) { _ in
            trackAbandonmentIfNeeded()
        }
        .onDisappear {
            stopPolling()
            trackAbandonmentIfNeeded()
            copiedResetTask?.cancel()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep.kind {
        case .welcome:
            CenterStage {
                Kicker("Transcripted")
                Headline(primary: "Speak. It's written.", emphasis: "Private, on this Mac.")
                Lede("Dictate into any app. Record meetings with both sides of the call. Everything becomes local Markdown you and your agent can search.", maxWidth: 560)
                HeroWaveCircle()
                    .padding(.top, 10)
                HStack(spacing: 14) {
                    PrivacyPill("On-device transcription")
                    PrivacyPill("Saved as Markdown")
                    PrivacyPill("No accounts, no cloud")
                }
                .padding(.top, 10)
            }
        case .permissions:
            CenterStage(spacing: 14) {
                Kicker("One-time setup")
                Headline(primary: "Allow three things.", emphasis: "Everything stays on this Mac.", size: 42)
                BodyCopy("Each one is a click. macOS will confirm with you directly, and you can change any of them later in System Settings.", maxWidth: 540)
                    .multilineTextAlignment(.center)
                permissionRows
                    .frame(width: 560)
                    .padding(.top, 6)
                ToggleCard(
                    title: "Share anonymous diagnostics",
                    detail: "Crash reports and feature counts. Never audio, transcripts, or anything you type or say.",
                    isOn: $diagnosticsEnabled,
                    compact: true,
                    automationIdentifier: "transcripted.onboarding.diagnostics.share"
                )
                .frame(width: 560)
                .onChange(of: diagnosticsEnabled) { _, newValue in
                    CrashReportingPreferences.setEnabled(newValue)
                    AnalyticsPreferences.setEnabled(newValue)
                }
                Text(readinessLine)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OnboardingTheme.muted)
                    .padding(.top, 2)
            }
        case .tryDictation:
            CenterStage {
                Kicker("Your turn")
                Headline(primary: "Try dictation right now.", size: 42)
                if dictationReady {
                    BodyCopy("Tap \(Self.defaultDictationShortcut) once, say anything, then tap it again. Transcripted pastes your words right here.", maxWidth: 540)
                        .multilineTextAlignment(.center)
                    DemoPasteTarget(text: $demoDictationText)
                        .focused($demoEditorFocused)
                        .padding(.top, 6)
                        .onAppear {
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                demoEditorFocused = true
                            }
                        }
                    HStack(spacing: 12) {
                        DictationPill(label: Self.defaultDictationShortcut)
                        ModelStatusCapsule(state: modelState)
                    }
                    .padding(.top, 6)
                    Text("Works in any app — Mail, docs, Slack, code. Change the shortcut anytime in Settings.")
                        .font(.system(size: 12))
                        .italic()
                        .foregroundStyle(OnboardingTheme.muted)
                } else {
                    BodyCopy("Dictation listens with the microphone and pastes with Accessibility. Finish those two and try it without leaving this window.", maxWidth: 540)
                        .multilineTextAlignment(.center)
                    tryDictationSetupRows
                        .frame(width: 560)
                        .padding(.top, 6)
                    Text("Or skip for now — you can dictate anytime with \(Self.defaultDictationShortcut) once setup is done.")
                        .font(.system(size: 12))
                        .italic()
                        .foregroundStyle(OnboardingTheme.muted)
                        .padding(.top, 4)
                }
            }
        case .ready:
            CenterStage(spacing: 16) {
                Kicker("You're set")
                Headline(primary: "Dictate. Record. Ask.", size: 48)
                Lede(readyStepLede, maxWidth: 560)
                ThreeActionsRecap()
                    .padding(.top, 10)
                AgentConnectStrip(
                    copiedItem: copiedAgentItem,
                    connectPhase: claudeDesktopConnectPhase,
                    onCopy: copyAgentItem,
                    onConnectClaudeDesktop: connectClaudeDesktop
                )
                .frame(width: 640)
                .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var permissionRows: some View {
        VStack(spacing: 12) {
            PermissionGrantRow(
                title: "Microphone",
                reason: "Hears you — dictation and your side of meetings.",
                icon: "mic.fill",
                granted: micGranted,
                requirementLabel: "Required",
                automationIdentifier: "transcripted.onboarding.permissions.microphone"
            ) {
                requestPermission(.microphone, required: true)
            }

            PermissionGrantRow(
                title: "System Audio",
                reason: "Hears everyone else on a call, so meeting transcripts have both sides.",
                icon: "speaker.wave.2.fill",
                granted: systemAudioGranted,
                requirementLabel: "For meetings",
                automationIdentifier: "transcripted.onboarding.permissions.system-audio"
            ) {
                requestPermission(.systemAudioRecording, required: false)
            }

            PermissionGrantRow(
                title: "Accessibility",
                reason: "Types for you — pastes dictation wherever your cursor is.",
                icon: "hand.raised.fill",
                granted: accessibilityGranted,
                requirementLabel: "For dictation",
                automationIdentifier: "transcripted.onboarding.permissions.accessibility"
            ) {
                requestPermission(.accessibility, required: false)
            }
        }
    }

    @ViewBuilder
    private var tryDictationSetupRows: some View {
        VStack(spacing: 12) {
            if !micGranted {
                PermissionGrantRow(
                    title: "Microphone",
                    reason: "Hears you — dictation and your side of meetings.",
                    icon: "mic.fill",
                    granted: micGranted,
                    requirementLabel: "Required",
                    automationIdentifier: "transcripted.onboarding.try.permissions.microphone"
                ) {
                    requestPermission(.microphone, required: true)
                }
            }
            if !accessibilityGranted {
                PermissionGrantRow(
                    title: "Accessibility",
                    reason: "Types for you — pastes dictation wherever your cursor is.",
                    icon: "hand.raised.fill",
                    granted: accessibilityGranted,
                    requirementLabel: "For dictation",
                    automationIdentifier: "transcripted.onboarding.try.permissions.accessibility"
                ) {
                    requestPermission(.accessibility, required: false)
                }
            }
        }
    }

    private var readinessLine: String {
        FirstRunExperience.setupReadinessLine(
            microphoneGranted: micGranted,
            systemAudioGranted: systemAudioGranted,
            accessibilityGranted: accessibilityGranted
        )
    }

    private var readyStepLede: String {
        if systemAudioGranted {
            return "That's the whole app. Transcripted notices when a call starts — calendar invite or not — and asks once before recording."
        }
        return "Transcripted notices when a call starts — calendar invite or not — and asks once. Allow System Audio from Settings before your first full meeting transcript."
    }

    private func goBack() {
        guard currentStepIndex > 0 else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
            navigationDirection = .backward
            currentStepIndex -= 1
        }
    }

    private func goNext() {
        guard currentStepIndex < steps.count - 1 else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.24)) {
            navigationDirection = .forward
            currentStepIndex += 1
        }
    }

    private func goNextOrComplete() {
        guard !primaryButtonDisabled else { return }
        trackPrimaryCTAClicked()
        if currentStepIndex == steps.count - 1 {
            completeOnboarding()
        } else {
            goNext()
        }
    }

    private func connectClaudeDesktop() {
        guard claudeDesktopConnectPhase != .connecting else { return }
        claudeDesktopConnectPhase = .connecting

        AnalyticsReporter.track(
            "onboarding_agent_cta_clicked",
            properties: [
                "agent_cta": "claude_desktop_connect",
                "step_id": currentStep.kind.analyticsID,
            ]
        )

        Task {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try ClaudeDesktopIntegrationInstaller.installForClaudeDesktop()
                }.value
                claudeDesktopConnectPhase = .connected
                ActivationTelemetry.trackAgentSetupCTA(
                    setupKind: .claudeDesktop,
                    agentTarget: .claudeDesktop,
                    surface: .onboarding,
                    result: .success
                )
            } catch {
                // Plain words on the first-run card instead of a raw NSError dump.
                // The button flips to "Try again" (the retry); the raw error still
                // goes to telemetry above, not onto the user's onboarding screen.
                claudeDesktopConnectPhase = .failed(AgentSetupFailureCopy.connect(agentName: "Claude Desktop"))
                ActivationTelemetry.trackAgentSetupCTA(
                    setupKind: .claudeDesktop,
                    agentTarget: .claudeDesktop,
                    surface: .onboarding,
                    result: .failed
                )
            }
        }
    }

    private func copyAgentItem(_ item: AgentCopyItem) {
        let value: String
        let agentCTA: String
        let promptKind: ActivationTelemetry.AgentPromptKind
        let setupKind: ActivationTelemetry.AgentSetupKind
        let agentTarget: ActivationTelemetry.AgentTarget
        switch item {
        case .localAgentPrompt:
            agentCTA = "local_agent_prompt"
            promptKind = .localAgentPrompt
            setupKind = .localPrompt
            agentTarget = .localAgent
            value = AgentConnectionGuide.starterPrompt(filename: nil)
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        ActivationTelemetry.trackAgentSetupCTA(
            setupKind: setupKind,
            agentTarget: agentTarget,
            surface: .onboarding
        )
        ActivationTelemetry.trackAgentPromptAction(
            promptKind: promptKind,
            actionKind: .copied,
            agentTarget: agentTarget,
            surface: .onboarding
        )
        AnalyticsReporter.track(
            "onboarding_agent_cta_clicked",
            properties: [
                "agent_cta": agentCTA,
                "step_id": currentStep.kind.analyticsID,
            ]
        )

        copiedAgentItem = item
        copiedResetTask?.cancel()
        copiedResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            copiedAgentItem = nil
        }
    }

    private func checkAllPermissions(trackChanges: Bool = false) {
        let previousStatuses = lastPermissionStatuses

        micGranted = TranscriptedPermissionAccess.isGranted(.microphone)
        accessibilityGranted = TranscriptedPermissionAccess.isGranted(.accessibility)
        systemAudioGranted = TranscriptedPermissionAccess.isGranted(.systemAudioRecording)

        let updatedStatuses = currentPermissionStatuses()
        if trackChanges && !previousStatuses.isEmpty {
            trackPermissionStatusChanges(from: previousStatuses, to: updatedStatuses)
        }
        lastPermissionStatuses = updatedStatuses
    }

    /// System audio has no passive status API, so its cached status can go
    /// stale between launches. Freshen it once per appearance, but only when a
    /// decision has already been made — probing an undetermined status would
    /// surface the macOS prompt before the user asked for it.
    private func revalidateSystemAudioIfAlreadyKnown() {
        guard TranscriptedPermissionAccess.systemAudioRecordingStatus() != .unknown else { return }
        probeSystemAudioPermission(trackChanges: false)
    }

    private func probeSystemAudioPermission(trackChanges: Bool) {
        guard systemAudioProbeTask == nil else { return }
        systemAudioProbeTask = Task { @MainActor in
            _ = await TranscriptedPermissionAccess.revalidateSystemAudioRecordingStatus()
            checkAllPermissions(trackChanges: trackChanges)
            systemAudioProbeTask = nil
        }
    }

    private func handleAppBecameActive() {
        let handoffKind = pendingSystemSettingsHandoffKind
        let hadHandoff = pendingSystemSettingsHandoff
        pendingSystemSettingsHandoff = false
        pendingSystemSettingsHandoffKind = nil
        checkAllPermissions(trackChanges: true)

        // Returning from a System Settings handoff is the one moment a user can
        // have flipped the System Audio toggle behind our back; re-probe it.
        // Never probe while the status is undetermined unless the handoff was
        // for System Audio itself, so no surprise macOS prompt appears.
        guard hadHandoff else { return }
        if handoffKind == .systemAudioRecording
            || TranscriptedPermissionAccess.systemAudioRecordingStatus() != .unknown {
            probeSystemAudioPermission(trackChanges: true)
        }
    }

    /// Cheap 1s status refresh so rows flip live while the user grants
    /// permissions. Microphone/Accessibility reads are free; System Audio is
    /// read from its cache here and only re-probed on click, appearance, or
    /// return from System Settings.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            // Foundation Timers run in .default mode and pause during menu
            // tracking, so onboarding could miss a permission flip while the
            // user has the System Settings menu open. A Task-driven loop keeps
            // polling regardless and dies cleanly when onDisappear cancels it.
            while !Task.isCancelled {
                checkAllPermissions(trackChanges: true)
                refreshModelState()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        systemAudioProbeTask?.cancel()
        systemAudioProbeTask = nil
    }

    private func refreshModelState() {
        let updated = modelStateProvider()
        guard updated != modelState else { return }
        let previous = modelState
        modelState = updated
        guard previous.shouldTrackAnalyticsTransition(to: updated) else { return }
        AnalyticsReporter.track(
            "onboarding_model_state_changed",
            properties: [
                "from_status": previous.analyticsStatus,
                "step_id": currentStep.kind.analyticsID,
                "to_status": updated.analyticsStatus,
            ]
        )
    }

    private func completeOnboarding() {
        guard hasRequiredPermissions else { return }
        stopPolling()
        trackCompletionIfNeeded()
        onComplete()
    }

    private func trackCompletionIfNeeded() {
        guard !didTrackCompletion else { return }
        didTrackCompletion = true

        AnalyticsReporter.track(
            "onboarding_completed",
            properties: FirstRunExperience.onboardingCompletionAnalyticsProperties(
                completionPath: .unified,
                systemAudioGranted: systemAudioGranted,
                calendarGranted: TranscriptedPermissionAccess.isGranted(.calendar),
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
            stage: currentStep.kind.analyticsID,
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
                "step_id": currentStep.kind.analyticsID,
            ]
        )

        // First System Audio ask: run the native capture probe so macOS shows
        // its own permission dialog right here, instead of bouncing the user
        // into System Settings. Once a decision exists, the regular
        // request-or-open-Settings path takes over for retries.
        if kind == .systemAudioRecording,
           TranscriptedPermissionAccess.systemAudioRecordingStatus() == .unknown {
            probeSystemAudioPermission(trackChanges: true)
            return
        }

        pendingSystemSettingsHandoff = true
        pendingSystemSettingsHandoffKind = kind
        TranscriptedPermissionAccess.openSettings(for: kind)
        checkAllPermissions(trackChanges: false)
    }

    private func trackCurrentStepViewed() {
        let now = CFAbsoluteTimeGetCurrent()
        stepStartedAt = now

        AnalyticsReporter.track(
            "onboarding_step_viewed",
            properties: [
                "flow_elapsed_bucket": flowElapsedBucket(now: now),
                "step_id": currentStep.kind.analyticsID,
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
                "step_id": currentStep.kind.analyticsID,
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
                    "step_id": currentStep.kind.analyticsID,
                    "to_status": updated,
                ]
            )
        }
    }

    private var primaryCTAAnalyticsID: String {
        if currentStepIndex == 0 { return "begin" }
        if currentStepIndex == steps.count - 1 { return "open_transcripted" }
        return "continue"
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
            .calendar: TranscriptedPermissionAccess.isGranted(.calendar) ? "granted" : "not_granted",
        ]
    }

    private func permissionStatus(for kind: TranscriptedPermissionKind) -> String {
        currentPermissionStatuses()[kind] ?? "unknown"
    }
}

private struct OnboardingStepSpec {
    let kind: OnboardingStepKind
    var canSkip = false
}

private enum OnboardingStepKind: Hashable {
    case welcome
    case permissions
    case tryDictation
    case ready

    var analyticsID: String {
        switch self {
        case .welcome:
            return "welcome"
        case .permissions:
            return "permissions"
        case .tryDictation:
            // Keeps funnel continuity with the previous flow's dictation test step.
            return "dictation_test"
        case .ready:
            return "done"
        }
    }
}

private enum AgentCopyItem: Hashable {
    case localAgentPrompt
}

private enum OnboardingAgentConnectPhase: Equatable {
    case idle
    case connecting
    case connected
    case failed(String)
}

private enum OnboardingNavigationDirection {
    case forward
    case backward

    var transition: AnyTransition {
        switch self {
        case .forward:
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        case .backward:
            return .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        }
    }
}

private enum OnboardingTheme {
    static let canvas = Color(red: 0.89, green: 0.87, blue: 0.84)
    static let window = Color(red: 0.98, green: 0.98, blue: 0.96)
    static let card = Color.white
    static let cardSoft = Color(red: 0.97, green: 0.96, blue: 0.93)
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.11)
    static let body = Color(red: 0.16, green: 0.16, blue: 0.15)
    static let muted = Color(red: 0.42, green: 0.42, blue: 0.41)
    static let border = Color.black.opacity(0.08)
    static let success = Color(red: 0.16, green: 0.78, blue: 0.25)
    static let recording = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)
    static let codex = Color(red: 0.06, green: 0.64, blue: 0.50)
}

private struct OnboardingWindowShell<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let current: Int
    let total: Int
    let direction: OnboardingNavigationDirection
    let canGoBack: Bool
    let canSkip: Bool
    let primaryTitle: String
    let primaryDisabled: Bool
    let onBack: () -> Void
    let onSkip: () -> Void
    let onNext: () -> Void
    let content: Content

    init(
        current: Int,
        total: Int,
        direction: OnboardingNavigationDirection,
        canGoBack: Bool,
        canSkip: Bool,
        primaryTitle: String,
        primaryDisabled: Bool,
        onBack: @escaping () -> Void,
        onSkip: @escaping () -> Void,
        onNext: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.current = current
        self.total = total
        self.direction = direction
        self.canGoBack = canGoBack
        self.canSkip = canSkip
        self.primaryTitle = primaryTitle
        self.primaryDisabled = primaryDisabled
        self.onBack = onBack
        self.onSkip = onSkip
        self.onNext = onNext
        self.content = content()
    }

    var body: some View {
        ZStack {
            OnboardingTheme.window

            VStack(spacing: 0) {
                // The real macOS close button sits in the transparent titlebar
                // on the left; only the step counter is drawn here.
                HStack(alignment: .center) {
                    Spacer()
                    ProgressCounter(current: current, total: total)
                }
                .padding(.horizontal, 16)
                .frame(height: 44)

                ZStack {
                    content
                        .transition(reduceMotion ? .opacity : direction.transition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                NavBar(
                    canGoBack: canGoBack,
                    canSkip: canSkip,
                    primaryTitle: primaryTitle,
                    primaryDisabled: primaryDisabled,
                    onBack: onBack,
                    onSkip: onSkip,
                    onNext: onNext
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.22), radius: 45, y: 24)
    }
}

private struct ProgressCounter: View {
    let current: Int
    let total: Int

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("\(String(format: "%02d", current + 1)) / \(String(format: "%02d", total))")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .kerning(2)
                .foregroundStyle(OnboardingTheme.muted)
            Rectangle()
                .fill(OnboardingTheme.ink)
                .frame(width: 28, height: 1)
        }
    }
}

private struct NavBar: View {
    let canGoBack: Bool
    let canSkip: Bool
    let primaryTitle: String
    let primaryDisabled: Bool
    let onBack: () -> Void
    let onSkip: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack {
            Button {
                onBack()
            } label: {
                Text("← Back")
                    .font(.system(size: 13))
                    .foregroundStyle(OnboardingTheme.muted)
                    .frame(minWidth: CGFloat(FirstRunOnboardingPolishContract.minimumHitTarget), minHeight: CGFloat(FirstRunOnboardingPolishContract.minimumHitTarget))
            }
            .buttonStyle(.plain)
            .opacity(canGoBack ? 1 : 0)
            .disabled(!canGoBack)
            .accessibilityIdentifier("transcripted.onboarding.nav.back")

            Spacer()

            if canSkip {
                Button("Skip for now") {
                    onSkip()
                }
                .font(.system(size: 13))
                .buttonStyle(.plain)
                .foregroundStyle(OnboardingTheme.muted)
                .frame(
                    minWidth: CGFloat(FirstRunOnboardingPolishContract.minimumHitTarget),
                    minHeight: CGFloat(FirstRunOnboardingPolishContract.minimumHitTarget)
                )
                .contentShape(Rectangle())
                .accessibilityIdentifier("transcripted.onboarding.nav.skip")
            }

            Button {
                onNext()
            } label: {
                HStack(spacing: 7) {
                    Text(primaryTitle)
                    Text("→")
                }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OnboardingTheme.window)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(minHeight: CGFloat(FirstRunOnboardingPolishContract.minimumHitTarget))
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(primaryDisabled ? OnboardingTheme.muted.opacity(0.45) : OnboardingTheme.ink)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(primaryDisabled)
            .accessibilityIdentifier("transcripted.onboarding.nav.primary")
        }
        .padding(.horizontal, 32)
        .frame(height: 78)
    }
}

private struct CenterStage<Content: View>: View {
    var spacing: CGFloat
    let content: Content

    init(spacing: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: spacing) {
                content
            }
            .frame(maxWidth: 800)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 60)
    }
}

private struct Kicker: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
            .kerning(2.2)
            .foregroundStyle(OnboardingTheme.muted)
    }
}

private struct Headline: View {
    let primary: String
    var emphasis: String?
    var size: CGFloat = 58
    var alignment: TextAlignment = .center
    // Cap the line measure so long headings wrap onto balanced lines instead of
    // running nearly edge-to-edge (CenterStage is 800pt) and leaving an orphan
    // word on the last line.
    var measure: CGFloat = 640

    var body: some View {
        VStack(alignment: alignment == .leading ? .leading : .center, spacing: 2) {
            Text(primary)
                .font(.system(size: size, weight: .semibold))
                .lineSpacing(1)
            if let emphasis {
                Text(emphasis)
                    .font(.custom("Georgia", size: size).italic())
            }
        }
        .foregroundStyle(OnboardingTheme.ink)
        .multilineTextAlignment(alignment)
        .lineLimit(nil)
        .minimumScaleFactor(0.92)
        .frame(maxWidth: measure, alignment: alignment == .leading ? .leading : .center)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Lede: View {
    let text: String
    var maxWidth: CGFloat = 540

    init(_ text: String, maxWidth: CGFloat = 540) {
        self.text = text
        self.maxWidth = maxWidth
    }

    var body: some View {
        Text(text)
            .font(.system(size: 17))
            .lineSpacing(3)
            .foregroundStyle(OnboardingTheme.body)
            .multilineTextAlignment(.center)
            .frame(maxWidth: maxWidth)
            .lineLimit(FirstRunOnboardingPolishContract.bodyCopyLineLimit)
            .minimumScaleFactor(0.94)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct BodyCopy: View {
    let text: String
    var maxWidth: CGFloat = 430

    init(_ text: String, maxWidth: CGFloat = 430) {
        self.text = text
        self.maxWidth = maxWidth
    }

    var body: some View {
        Text(text)
            .font(.system(size: 15))
            .lineSpacing(3)
            .foregroundStyle(OnboardingTheme.body)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .lineLimit(FirstRunOnboardingPolishContract.bodyCopyLineLimit)
            .minimumScaleFactor(0.94)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct HeroWaveCircle: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let count = 26

    var body: some View {
        TimelineView(.animation) { timeline in
            // Reduce Motion: freeze the wave at a fixed phase instead of looping.
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(OnboardingTheme.ink)
                    .frame(width: 200, height: 200)
                    .shadow(color: .black.opacity(0.22 + 0.04 * abs(sin(t * 1.4))), radius: 30, y: 20)

                HStack(alignment: .center, spacing: 2) {
                    ForEach(0..<count, id: \.self) { index in
                        RoundedRectangle(cornerRadius: 1.2, style: .continuous)
                            .fill(OnboardingTheme.window)
                            .frame(width: 2.4, height: barHeight(index: index, time: t))
                    }
                }
                .frame(height: 40)
            }
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        let center = Double(count - 1) / 2.0
        let norm = (Double(index) - center) / center
        let envelope = pow(max(0, cos(norm * .pi / 2.0)), 1.2)
        let wave = abs(sin(Double(index) * 0.82 + time * 2.0) + sin(Double(index) * 0.23 + time * 3.2) * 0.5)
        return CGFloat(max(3.0, wave * 18.0 * envelope + 3.0))
    }
}

private struct PrivacyPill: View {
    let label: String

    init(_ label: String) {
        self.label = label
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark")
                .font(.system(size: 11, weight: .bold))
            Text(label)
                .font(.system(size: 13, weight: .medium))
        }
        .foregroundStyle(OnboardingTheme.ink)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(Capsule().fill(OnboardingTheme.card))
        .overlay(Capsule().stroke(OnboardingTheme.border, lineWidth: 1))
        .shadow(color: .black.opacity(0.04), radius: 8, y: 4)
    }
}

private struct PermissionGrantRow: View {
    let title: String
    let reason: String
    let icon: String
    let granted: Bool
    var requirementLabel: String?
    let automationIdentifier: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(granted ? OnboardingTheme.success : OnboardingTheme.cardSoft)
                    .frame(width: 28, height: 28)
                Image(systemName: granted ? "checkmark" : icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(granted ? OnboardingTheme.ink : OnboardingTheme.muted)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                    if let requirementLabel, !granted {
                        Text(requirementLabel.uppercased())
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .kerning(1.1)
                            .foregroundStyle(OnboardingTheme.muted)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(OnboardingTheme.cardSoft))
                            .overlay(Capsule().stroke(OnboardingTheme.border, lineWidth: 1))
                    }
                }
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(granted ? OnboardingTheme.window.opacity(0.72) : OnboardingTheme.muted)
            }
            .foregroundStyle(granted ? OnboardingTheme.window : OnboardingTheme.ink)

            Spacer()

            Button(granted ? "On" : "Allow") {
                action()
            }
            .buttonStyle(InkButtonStyle(isSubtle: granted, compact: true, onInk: granted))
            .disabled(granted)
            .accessibilityIdentifier(automationIdentifier)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(minHeight: CGFloat(FirstRunOnboardingPolishContract.minimumHitTarget))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(granted ? OnboardingTheme.ink : OnboardingTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 10, y: 5)
        .animation(.easeInOut(duration: 0.2), value: granted)
    }
}

private struct InkButtonStyle: ButtonStyle {
    var isSubtle = false
    var compact = false
    /// When the button sits on an ink-filled surface, subtle labels need the
    /// light window tone to stay legible.
    var onInk = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 14, weight: .semibold))
            .foregroundStyle(isSubtle ? (onInk ? OnboardingTheme.window : OnboardingTheme.ink) : OnboardingTheme.window)
            .padding(.horizontal, compact ? 14 : 22)
            .padding(.vertical, compact ? 8 : 12)
            .frame(minWidth: CGFloat(compact ? FirstRunOnboardingPolishContract.minimumCompactButtonHeight : FirstRunOnboardingPolishContract.minimumHitTarget))
            .frame(minHeight: CGFloat(compact ? FirstRunOnboardingPolishContract.minimumCompactButtonHeight : FirstRunOnboardingPolishContract.minimumHitTarget))
            .background(
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .fill(isSubtle ? Color.clear : OnboardingTheme.ink)
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                    .stroke(isSubtle ? (onInk ? OnboardingTheme.window.opacity(0.35) : OnboardingTheme.border) : Color.clear, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct DictationPill: View {
    let label: String

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(OnboardingTheme.recording)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
            MiniWaveform(color: OnboardingTheme.ink, width: 54, height: 18)
        }
        .foregroundStyle(OnboardingTheme.ink)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Capsule().fill(OnboardingTheme.card))
        .overlay(Capsule().stroke(OnboardingTheme.border, lineWidth: 1))
    }
}

private struct ModelStatusCapsule: View {
    let state: FirstRunLocalModelState

    var body: some View {
        let status = FirstRunExperience.onboardingModelStatus(for: state)
        HStack(spacing: 8) {
            Circle()
                .fill(status.isReady ? OnboardingTheme.success : OnboardingTheme.muted.opacity(0.55))
                .frame(width: 7, height: 7)
            Text(status.text)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(OnboardingTheme.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Capsule().fill(OnboardingTheme.cardSoft))
        .overlay(Capsule().stroke(OnboardingTheme.border, lineWidth: 1))
        .accessibilityLabel(Text(status.text))
    }
}

private struct DemoPasteTarget: View {
    @Binding var text: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(OnboardingTheme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(OnboardingTheme.border, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.05), radius: 14, y: 8)

            TextEditor(text: $text)
                .font(.system(size: 18))
                .foregroundStyle(OnboardingTheme.ink)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your words will paste here.")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(OnboardingTheme.ink.opacity(0.42))
                    Text("Tap Right Option once, speak, then tap it again.")
                        .font(.system(size: 12))
                        .foregroundStyle(OnboardingTheme.muted)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .allowsHitTesting(false)
            }
        }
        .frame(width: 560, height: 150)
        .overlay(alignment: .bottomTrailing) {
            if !text.isEmpty {
                Button("Clear") {
                    text = ""
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OnboardingTheme.muted)
                .frame(
                    minWidth: CGFloat(FirstRunOnboardingPolishContract.minimumHitTarget),
                    minHeight: CGFloat(FirstRunOnboardingPolishContract.minimumHitTarget)
                )
                .contentShape(Rectangle())
                .accessibilityLabel("Clear dictation test text")
                .accessibilityIdentifier("transcripted.onboarding.dictation-test.clear")
            }
        }
    }
}

private struct MiniWaveform: View {
    let color: Color
    let width: CGFloat
    let height: CGFloat
    private let count = 16

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 1.6) {
                ForEach(0..<count, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 1, style: .continuous)
                        .fill(color)
                        .frame(width: 2, height: barHeight(index: index, time: t))
                }
            }
            .frame(width: width, height: height)
        }
    }

    private func barHeight(index: Int, time: TimeInterval) -> CGFloat {
        let center = Double(count - 1) / 2.0
        let norm = abs((Double(index) - center) / center)
        let envelope = 1.0 - norm * 0.55
        let wave = abs(sin(time * 4.0 + Double(index) * 0.58))
        return CGFloat(max(3.0, wave * 14.0 * envelope + 2.0))
    }
}

private struct ToggleCard: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var compact = false
    var automationIdentifier: String? = nil

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: compact ? 2 : 4) {
                Text(title)
                    .font(.system(size: compact ? 13 : 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: compact ? 11.5 : 12))
                    .lineSpacing(2)
                    .foregroundStyle(OnboardingTheme.muted)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .onboardingAutomationIdentifier(automationIdentifier)
                .frame(
                    minWidth: CGFloat(FirstRunOnboardingPolishContract.minimumHitTarget),
                    minHeight: CGFloat(FirstRunOnboardingPolishContract.minimumHitTarget)
                )
        }
        .padding(.horizontal, 20)
        .padding(.vertical, compact ? 8 : 16)
        .frame(minHeight: CGFloat(FirstRunOnboardingPolishContract.minimumHitTarget))
        .background(compact ? OnboardingTheme.cardSoft : OnboardingTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(compact ? 0.02 : 0.04), radius: compact ? 6 : 12, y: compact ? 3 : 6)
    }
}

private extension View {
    @ViewBuilder
    func onboardingAutomationIdentifier(_ identifier: String?) -> some View {
        if let identifier {
            accessibilityIdentifier(identifier)
        } else {
            self
        }
    }
}

private struct ThreeActionsRecap: View {
    var body: some View {
        HStack(spacing: 14) {
            ActionStepCard(
                number: "1",
                title: "Dictate",
                command: "Right Option",
                detail: "Tap once to talk, again to paste. Works in any app.",
                color: OnboardingTheme.codex,
                icon: "keyboard"
            )
            ActionStepCard(
                number: "2",
                title: "Record",
                command: "Auto-detected",
                detail: "Transcripted notices when a call starts and asks once. Or use the menu bar.",
                color: OnboardingTheme.recording,
                icon: "record.circle"
            )
            ActionStepCard(
                number: "3",
                title: "Ask",
                command: "Your agent",
                detail: "Every capture is local Markdown your agent can search.",
                color: OnboardingTheme.claude,
                icon: "magnifyingglass"
            )
        }
    }
}

private struct ActionStepCard: View {
    let number: String
    let label: String
    let command: String
    let detail: String
    let color: Color
    let icon: String

    init(number: String, title: String, command: String, detail: String, color: Color, icon: String) {
        self.number = number
        self.label = title
        self.command = command
        self.detail = detail
        self.color = color
        self.icon = icon
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(number)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(OnboardingTheme.window)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(color))
                Spacer()
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(color)
            }

            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .kerning(1.8)
                .foregroundStyle(OnboardingTheme.muted)

            Text(command)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(OnboardingTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.85)

            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(OnboardingTheme.body)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 200, height: 156, alignment: .leading)
        .background(OnboardingTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 1)
        )
        .shadow(color: color.opacity(0.12), radius: 18, y: 10)
    }
}

private struct AgentConnectStrip: View {
    let copiedItem: AgentCopyItem?
    let connectPhase: OnboardingAgentConnectPhase
    let onCopy: (AgentCopyItem) -> Void
    let onConnectClaudeDesktop: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            AgentConnectRow(
                glyph: "◆",
                color: OnboardingTheme.claude,
                title: "Claude Desktop",
                detail: claudeDesktopDetail,
                buttonTitle: claudeDesktopButtonTitle,
                automationIdentifier: "transcripted.onboarding.agent.connect-claude-desktop",
                action: onConnectClaudeDesktop
            )

            Divider()
                .overlay(OnboardingTheme.border)
                .padding(.horizontal, 18)

            AgentConnectRow(
                glyph: "●",
                color: OnboardingTheme.codex,
                title: "Claude Code, Codex, Cursor",
                detail: "Copy one prompt for local coding agents — or connect them later in Settings.",
                buttonTitle: copiedItem == .localAgentPrompt ? "Copied" : "Copy prompt",
                automationIdentifier: "transcripted.onboarding.agent.copy-local-agent-prompt"
            ) {
                onCopy(.localAgentPrompt)
            }
        }
        .background(OnboardingTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.04), radius: 12, y: 6)
        .overlay(alignment: .top) {
            Text("OPTIONAL — GIVE YOUR AGENT YOUR VOICE HISTORY")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .kerning(1.4)
                .foregroundStyle(OnboardingTheme.muted)
                .padding(.horizontal, 10)
                .background(OnboardingTheme.window)
                .offset(y: -7)
        }
    }

    private var claudeDesktopDetail: String {
        switch connectPhase {
        case .idle, .connecting:
            return "One click installs Transcripted's tools. Restart Claude Desktop to pick them up."
        case .connected:
            return "Connected. Restart Claude Desktop, then ask it about your latest meeting."
        case .failed(let message):
            return message
        }
    }

    private var claudeDesktopButtonTitle: String {
        switch connectPhase {
        case .idle:
            return "Connect"
        case .connecting:
            return "Connecting..."
        case .connected:
            return "Connected"
        case .failed:
            return "Try again"
        }
    }
}

private struct AgentConnectRow: View {
    let glyph: String
    let color: Color
    let title: String
    let detail: String
    let buttonTitle: String
    let automationIdentifier: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            AgentGlyph(glyph: glyph, color: color, size: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(OnboardingTheme.ink)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(OnboardingTheme.muted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button(buttonTitle) {
                action()
            }
            .buttonStyle(InkButtonStyle(compact: true))
            .accessibilityIdentifier(automationIdentifier)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .frame(minHeight: CGFloat(FirstRunOnboardingPolishContract.minimumHitTarget))
    }
}

private struct AgentGlyph: View {
    let glyph: String
    let color: Color
    var size: CGFloat = 36

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(color)
                .frame(width: size, height: size)
            Text(glyph)
                .font(.system(size: size * 0.48, weight: .bold))
                .foregroundStyle(.white)
        }
    }
}
