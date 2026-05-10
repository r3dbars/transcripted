// PermissionsOnboardingView.swift
// First-run onboarding for Transcripted's local dictation and meeting capture.

import SwiftUI
import AppKit
import AVFoundation
import ApplicationServices

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

@MainActor
struct PermissionsOnboardingView: View {
    var onComplete: () -> Void

    static let preferredSize = NSSize(width: 960, height: 680)

    @State private var currentStepIndex = 0
    @State private var navigationDirection: OnboardingNavigationDirection = .forward
    @State private var micGranted = false
    @State private var accessibilityGranted = false
    @State private var screenRecordingGranted = false
    @State private var calendarGranted = false
    @State private var meetingPromptsEnabled = true
    @State private var diagnosticsEnabled = CrashReportingPreferences.isEnabled() && AnalyticsPreferences.isEnabled()
    @State private var demoDictationText = ""
    @State private var showDemoPasteHelp = false
    @State private var copiedAgentItem: AgentCopyItem?
    @State private var copiedResetTask: Task<Void, Never>?
    @State private var permissionRefreshTask: Task<Void, Never>?
    @FocusState private var demoEditorFocused: Bool

    init(onComplete: @escaping () -> Void) {
        self.onComplete = onComplete
    }

    private var currentStep: OnboardingStepSpec {
        Self.steps[currentStepIndex]
    }

    private var hasRequiredPermissions: Bool {
        micGranted && accessibilityGranted
    }

    private var primaryButtonTitle: String {
        if currentStepIndex == 0 { return "Begin" }
        if currentStepIndex == Self.steps.count - 1 { return "Open Transcripted" }
        return "Continue"
    }

    private var primaryButtonDisabled: Bool {
        (currentStep.kind == .permissions || currentStep.kind == .done) && !hasRequiredPermissions
    }

    private var calendarPermissionNote: String {
        if calendarGranted && !meetingPromptsEnabled {
            return "Calendar access stays allowed. Meeting prompts are paused."
        }

        if !meetingPromptsEnabled {
            return "Meeting prompts are paused. You can still allow calendar access now."
        }

        return "Read-only calendar access lets Transcripted suggest prompts. Events stay on your Mac."
    }

    private var handsFreeDictationShortcut: String {
        PhysicalDictationTriggerPreferences.displayString(
            for: PhysicalDictationTriggerPreferences.handsFreeBinding()
        )
    }

    var body: some View {
        OnboardingWindowShell(
            current: currentStepIndex,
            total: Self.steps.count,
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
        // This walkthrough uses a fixed light launch palette instead of adapting token-by-token.
        .preferredColorScheme(.light)
        .onAppear {
            checkAllPermissions()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            checkAllPermissions()
        }
        .onDisappear {
            stopPermissionRefresh()
            copiedResetTask?.cancel()
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep.kind {
        case .welcome:
            CenterStage {
                Kicker("Transcripted")
                Headline(primary: "Your voice becomes text.", emphasis: "Every meeting, remembered.")
                Lede("Talk to type in any app. Record every call. Ask your agent what happened.")
                HeroWaveCircle()
                    .padding(.top, 14)
            }
        case .privacy:
            CenterStage {
                Kicker("Before we start")
                Headline(primary: "Your voice.\nYour files.", emphasis: "Stays on your Mac.")
                Lede("No accounts. No sign-in. Nothing leaves your computer.", maxWidth: 500)
                HStack(spacing: 14) {
                    PrivacyPill("On-device transcription")
                    PrivacyPill("Stored as markdown")
                    PrivacyPill("No cloud, no sync")
                }
                .padding(.top, 18)
            }
        case .permissions:
            CenterStage {
                Kicker("Two to start")
                Headline(primary: "Two yeses now. Meetings can come later.", size: 42)
                BodyCopy("Microphone and Accessibility are required for dictation. System audio and Calendar are optional later.", maxWidth: 460)
                VStack(spacing: 12) {
                    PermissionGrantRow(
                        title: "Microphone",
                        reason: "So we can hear you.",
                        icon: "mic.fill",
                        granted: micGranted,
                        actionTitle: TranscriptedPermissionKind.microphone.onboardingActionTitle,
                        grantedTitle: TranscriptedPermissionKind.microphone.onboardingGrantedTitle
                    ) {
                        requestPermission(.microphone)
                    }
                    PermissionGrantRow(
                        title: "Accessibility",
                        reason: "So your shortcut works everywhere.",
                        icon: "hand.raised.fill",
                        granted: accessibilityGranted,
                        actionTitle: TranscriptedPermissionKind.accessibility.onboardingActionTitle,
                        grantedTitle: TranscriptedPermissionKind.accessibility.onboardingGrantedTitle
                    ) {
                        requestPermission(.accessibility)
                    }
                }
                .frame(width: OnboardingTheme.permissionStackWidth)
                .padding(.top, 8)
                Text(hasRequiredPermissions ? "You're ready to keep going." : "Allow both to continue.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(OnboardingTheme.muted)
                    .padding(.top, 4)
            }
        case .dictation:
            SplitStage {
                Kicker("Dictation")
                Headline(primary: "Talk to type.", emphasis: "In any app.", size: 42, alignment: .leading)
                BodyCopy("Press \(handsFreeDictationShortcut) once to start. Press it again to stop. Your words land where your cursor is.")
                BulletList(["Mail, docs, Slack, code, anywhere", "On-device. Fast.", "Never leaves your Mac"])
            } right: {
                DictationDemoCard()
            }
        case .shortcut:
            CenterStage {
                Kicker("Your turn")
                Headline(primary: "Try dictation\nright now.", size: 42)
                BodyCopy("Press \(handsFreeDictationShortcut), say a sentence, then press it again. Your words paste into the focused field - try here, or any other app.", maxWidth: 560)
                DemoPasteTarget(
                    text: $demoDictationText,
                    isFocused: $demoEditorFocused,
                    showHelp: showDemoPasteHelp,
                    shortcutDisplay: handsFreeDictationShortcut
                )
                    .padding(.top, 6)
                HStack(spacing: 12) {
                    DictationPill(label: handsFreeDictationShortcut)
                    Text("You can change it anytime in Settings.")
                        .font(.system(size: 12))
                        .italic()
                        .foregroundStyle(OnboardingTheme.muted)
                }
                .padding(.top, 6)
                .onAppear {
                    showDemoPasteHelp = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        demoEditorFocused = true
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                        guard currentStep.kind == .shortcut else { return }
                        showDemoPasteHelp = demoDictationText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    }
                }
                .onChange(of: demoDictationText) { _, newValue in
                    if !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        showDemoPasteHelp = false
                    }
                }
            }
        case .systemAudio:
            SplitStage {
                Kicker("Meeting transcripts")
                Headline(primary: "Record meetings.\nGet the transcript.", size: 42, alignment: .leading)
                BodyCopy("Transcripted needs two audio streams to write the whole conversation: your microphone for you, and system audio for everyone else.")
                BulletList(["macOS calls this Screen Recording", "Used only to hear meeting audio", "Everything stays on your Mac"])
                Button(screenRecordingGranted
                    ? TranscriptedPermissionKind.systemAudioRecording.onboardingGrantedTitle
                    : TranscriptedPermissionKind.systemAudioRecording.onboardingActionTitle
                ) {
                    requestPermission(.systemAudioRecording)
                }
                .buttonStyle(InkButtonStyle(isSubtle: screenRecordingGranted))
                .padding(.top, 12)
                Text("You can skip this now, but meeting transcripts need it to include the other side of the call.")
                    .font(.system(size: 12))
                    .foregroundStyle(OnboardingTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } right: {
                DualStreamVisual(systemReady: screenRecordingGranted)
            }
        case .meeting:
            SplitStage {
                Kicker("After the call")
                Headline(primary: "A transcript you can actually use.", size: 42, alignment: .leading)
                BodyCopy("Every recorded meeting becomes a local Markdown file with timestamps and speaker labels.")
                BulletList(["Find decisions later", "Copy exact quotes", "Give your agent the right context"])
            } right: {
                MeetingDemoCard()
            }
        case .calendar:
            SplitStage {
                Kicker("Calendar")
                Headline(primary: "Want meeting\nreminders?", size: 42, alignment: .leading)
                BodyCopy("Transcripted can look at your calendar and offer a quiet prompt when a call is about to start.")
                ToggleCard(
                    title: "Meeting reminders",
                    detail: "Use read-only calendar access to notice upcoming calls.",
                    isOn: $meetingPromptsEnabled
                )
                .frame(maxWidth: OnboardingTheme.calendarToggleMaxWidth)
                .padding(.top, 4)
                Button(calendarGranted
                    ? TranscriptedPermissionKind.calendar.onboardingGrantedTitle
                    : TranscriptedPermissionKind.calendar.onboardingActionTitle
                ) {
                    requestPermission(.calendar)
                }
                .buttonStyle(InkButtonStyle(isSubtle: calendarGranted || !meetingPromptsEnabled))
                .padding(.top, 6)
                Text(calendarPermissionNote)
                    .font(.system(size: 12))
                    .foregroundStyle(OnboardingTheme.muted)
            } right: {
                CalendarMock(connected: calendarGranted && meetingPromptsEnabled)
            }
        case .memory:
            CenterStage {
                Kicker("The payoff")
                Headline(primary: "Every word you've said,", emphasis: "searchable.", size: 52)
                Lede("Dictations and meetings flow into one place on your Mac. Your second brain, for your agent to reason over.", maxWidth: 560)
                MemoryFlowVisual()
                    .padding(.top, 16)
            }
        case .agentDemo:
            SplitStage {
                Kicker("Your agent")
                Headline(primary: "Ask about", emphasis: "last Tuesday.", size: 42, alignment: .leading)
                BodyCopy("Your agent gets a new skill: your voice history. Answers come back with citations from your own words.")
            } right: {
                AgentDemoCard()
            }
        case .connectAgent:
            ConnectAgentStage(
                copiedItem: copiedAgentItem,
                onCopy: copyAgentItem
            )
        case .diagnostics:
            CenterStage {
                Kicker("One last thing")
                Headline(primary: "Help us make it better?", size: 42)
                BodyCopy("Anonymous diagnostics help us find bugs and fix them fast.", maxWidth: OnboardingTheme.permissionStackWidth)
                ToggleCard(
                    title: "Share anonymous diagnostics",
                    detail: "Crash reports, feature counts, app version, and macOS version. Never audio, transcripts, or anything you type or say.",
                    isOn: $diagnosticsEnabled
                )
                .frame(width: OnboardingTheme.permissionStackWidth)
                .padding(.top, 10)
                .onChange(of: diagnosticsEnabled) { _, newValue in
                    CrashReportingPreferences.setEnabled(newValue)
                    AnalyticsPreferences.setEnabled(newValue)
                }
            }
        case .done:
            CenterStage {
                Kicker("You're set")
                Headline(primary: "Dictate. Record. Ask.", size: 52)
                Lede("Three actions to remember: use your voice anywhere, capture meetings, then ask your agent what happened.", maxWidth: 560)
                ThreeActionsRecap(dictationShortcut: handsFreeDictationShortcut)
                    .padding(.top, 22)
            }
        }
    }

    private func goBack() {
        guard currentStepIndex > 0 else { return }
        withAnimation(.easeInOut(duration: 0.24)) {
            navigationDirection = .backward
            currentStepIndex -= 1
        }
    }

    private func goNext() {
        guard currentStepIndex < Self.steps.count - 1 else { return }
        withAnimation(.easeInOut(duration: 0.24)) {
            navigationDirection = .forward
            currentStepIndex += 1
        }
    }

    private func goNextOrComplete() {
        guard !primaryButtonDisabled else { return }
        if currentStepIndex == Self.steps.count - 1 {
            completeOnboarding()
        } else {
            goNext()
        }
    }

    private func copyAgentItem(_ item: AgentCopyItem) {
        let value: String
        switch item {
        case .claudeDesktopSetup:
            value = """
            \(AgentConnectionGuide.mcpSetupText)

            \(AgentConnectionGuide.mcpConfigExample)
            """
        case .localAgentPrompt:
            value = AgentConnectionGuide.starterPrompt(filename: nil)
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)

        copiedAgentItem = item
        copiedResetTask?.cancel()
        copiedResetTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: MenuTokens.copyFeedbackDurationNanoseconds)
            guard !Task.isCancelled else { return }
            copiedAgentItem = nil
        }
    }

    private func checkAllPermissions() {
        micGranted = TranscriptedPermissionAccess.isGranted(.microphone)
        accessibilityGranted = TranscriptedPermissionAccess.isGranted(.accessibility)
        screenRecordingGranted = TranscriptedPermissionAccess.isGranted(.systemAudioRecording)
        calendarGranted = TranscriptedPermissionAccess.isGranted(.calendar)
    }

    private func requestPermission(_ kind: TranscriptedPermissionKind) {
        TranscriptedPermissionAccess.openSettings(for: kind)
        checkAllPermissions()
        startTemporaryPermissionRefresh(untilGranted: kind)
    }

    private func startTemporaryPermissionRefresh(untilGranted kind: TranscriptedPermissionKind) {
        permissionRefreshTask?.cancel()
        permissionRefreshTask = Task { @MainActor in
            for _ in 0..<16 {
                checkAllPermissions()
                if TranscriptedPermissionAccess.isGranted(kind) {
                    permissionRefreshTask = nil
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard !Task.isCancelled else { return }
            }
            checkAllPermissions()
            permissionRefreshTask = nil
        }
    }

    private func stopPermissionRefresh() {
        permissionRefreshTask?.cancel()
        permissionRefreshTask = nil
    }

    private func completeOnboarding() {
        guard hasRequiredPermissions else { return }
        stopPermissionRefresh()
        onComplete()
    }

    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: "permissionsOnboardingCompleted")
    }

    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: "permissionsOnboardingCompleted")
    }

    private static let steps: [OnboardingStepSpec] = [
        .init(kind: .welcome),
        .init(kind: .privacy),
        .init(kind: .permissions),
        .init(kind: .dictation),
        .init(kind: .shortcut),
        .init(kind: .systemAudio, canSkip: true),
        .init(kind: .meeting),
        .init(kind: .calendar, canSkip: true),
        .init(kind: .memory),
        .init(kind: .agentDemo),
        .init(kind: .connectAgent, canSkip: true),
        .init(kind: .diagnostics, canSkip: true),
        .init(kind: .done),
    ]
}

private struct OnboardingStepSpec {
    let kind: OnboardingStepKind
    var canSkip = false
}

private enum OnboardingStepKind: Hashable {
    case welcome
    case privacy
    case permissions
    case dictation
    case shortcut
    case systemAudio
    case meeting
    case calendar
    case memory
    case agentDemo
    case connectAgent
    case diagnostics
    case done
}

private enum AgentCopyItem: Hashable {
    case claudeDesktopSetup
    case localAgentPrompt
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

private struct OnboardingShadow {
    let opacity: Double
    let radius: CGFloat
    let y: CGFloat
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
    static let trafficClose = Color(red: 1.0, green: 0.37, blue: 0.34)
    static let trafficMinimize = Color(red: 1.0, green: 0.74, blue: 0.18)
    static let micStream = Color(red: 0.55, green: 0.65, blue: 1.0)
    static let systemStream = Color(red: 1.0, green: 0.70, blue: 0.55)
    static let calendarAccent = Color(red: 0.55, green: 0.90, blue: 0.76)

    static let radiusCompact: CGFloat = 8
    static let radiusButton: CGFloat = 10
    static let radiusCard: CGFloat = 12
    static let radiusLarge: CGFloat = 14

    static let padButtonH: CGFloat = 24
    static let padNavH: CGFloat = 32
    static let padContentH: CGFloat = 60
    static let padContentV: CGFloat = 28

    static let centerStageMaxWidth: CGFloat = 800
    static let ledeMaxWidth: CGFloat = 540
    static let bodyCopyMaxWidth: CGFloat = 430
    static let calendarToggleMaxWidth: CGFloat = 440
    static let permissionStackWidth: CGFloat = 480
    static let dictationDemoWidth: CGFloat = 360
    static let dictationDemoHeight: CGFloat = 170
    static let demoPasteWidth: CGFloat = 560
    static let demoPasteHeight: CGFloat = 150
    static let miniVisualWidth: CGFloat = 380
    static let calendarCardWidth: CGFloat = 340
    static let memoryFlowWidth: CGFloat = 720

    static let shadowShell = OnboardingShadow(opacity: 0.22, radius: 45, y: 24)
    static let shadowHeroBaseOpacity = 0.22
    static let shadowHeroPulseOpacity = 0.04
    static let shadowHeroPulseRadius: CGFloat = 30
    static let shadowHeroPulseY: CGFloat = 20
    static let shadowSoft = OnboardingShadow(opacity: 0.04, radius: 8, y: 4)
    static let shadowSoftRaised = OnboardingShadow(opacity: 0.04, radius: 10, y: 5)
    static let shadowCard = OnboardingShadow(opacity: 0.04, radius: 12, y: 6)
    static let shadowCardWide = OnboardingShadow(opacity: 0.04, radius: 14, y: 6)
    static let shadowInput = OnboardingShadow(opacity: 0.05, radius: 14, y: 8)
    static let shadowPanel = OnboardingShadow(opacity: 0.06, radius: 18, y: 10)
    static let shadowPanelWide = OnboardingShadow(opacity: 0.06, radius: 20, y: 10)
    static let shadowAccentCard = OnboardingShadow(opacity: 0.12, radius: 18, y: 10)
    static let shadowMedium = OnboardingShadow(opacity: 0.08, radius: 24, y: 12)
    static let shadowMediumTight = OnboardingShadow(opacity: 0.08, radius: 22, y: 12)
}

private extension View {
    func onboardingShadow(_ shadow: OnboardingShadow, color: Color = .black) -> some View {
        self.shadow(color: color.opacity(shadow.opacity), radius: shadow.radius, y: shadow.y)
    }
}

private struct OnboardingWindowShell<Content: View>: View {
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
                HStack(alignment: .center) {
                    TrafficLights()
                    Spacer()
                    ProgressCounter(current: current, total: total)
                }
                .padding(.horizontal, 16)
                .frame(height: 44)

                ZStack {
                    content
                        .transition(direction.transition)
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
        .clipShape(RoundedRectangle(cornerRadius: OnboardingTheme.radiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OnboardingTheme.radiusLarge, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 1)
        )
        .onboardingShadow(OnboardingTheme.shadowShell)
    }
}

private struct TrafficLights: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(OnboardingTheme.trafficClose)
            Circle().fill(OnboardingTheme.trafficMinimize)
            Circle().fill(OnboardingTheme.success)
        }
        .frame(width: 52, height: 12)
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
            }
            .buttonStyle(.plain)
            .opacity(canGoBack ? 1 : 0)
            .disabled(!canGoBack)

            Spacer()

            if canSkip {
                Button("Skip for now") {
                    onSkip()
                }
                .font(.system(size: 13))
                .buttonStyle(.plain)
                .foregroundStyle(OnboardingTheme.muted)
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
                .padding(.horizontal, OnboardingTheme.padButtonH)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: OnboardingTheme.radiusButton, style: .continuous)
                        .fill(primaryDisabled ? OnboardingTheme.muted.opacity(0.45) : OnboardingTheme.ink)
                )
            }
            .buttonStyle(.plain)
            .disabled(primaryDisabled)
        }
        .padding(.horizontal, OnboardingTheme.padNavH)
        .frame(height: 78)
    }
}

private struct CenterStage<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            VStack(spacing: 18) {
                content
            }
            .frame(maxWidth: OnboardingTheme.centerStageMaxWidth)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, OnboardingTheme.padContentH)
    }
}

private struct SplitStage<Left: View, Right: View>: View {
    let left: Left
    let right: Right

    init(@ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) {
        self.left = left()
        self.right = right()
    }

    var body: some View {
        HStack(spacing: 30) {
            VStack(alignment: .leading, spacing: 18) {
                left
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            ZStack {
                right
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, OnboardingTheme.padContentH)
        .padding(.vertical, OnboardingTheme.padContentV)
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
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct Lede: View {
    let text: String
    var maxWidth: CGFloat = OnboardingTheme.ledeMaxWidth

    init(_ text: String, maxWidth: CGFloat = OnboardingTheme.ledeMaxWidth) {
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
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct BodyCopy: View {
    let text: String
    var maxWidth: CGFloat = OnboardingTheme.bodyCopyMaxWidth

    init(_ text: String, maxWidth: CGFloat = OnboardingTheme.bodyCopyMaxWidth) {
        self.text = text
        self.maxWidth = maxWidth
    }

    var body: some View {
        Text(text)
            .font(.system(size: 15))
            .lineSpacing(3)
            .foregroundStyle(OnboardingTheme.body)
            .frame(maxWidth: maxWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct HeroWaveCircle: View {
    private let count = 26

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(OnboardingTheme.ink)
                    .frame(width: 200, height: 200)
                    .shadow(
                        color: .black.opacity(
                            OnboardingTheme.shadowHeroBaseOpacity
                                + OnboardingTheme.shadowHeroPulseOpacity * abs(sin(t * 1.4))
                        ),
                        radius: OnboardingTheme.shadowHeroPulseRadius,
                        y: OnboardingTheme.shadowHeroPulseY
                    )

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
        .onboardingShadow(OnboardingTheme.shadowSoft)
    }
}

private struct PermissionGrantRow: View {
    let title: String
    let reason: String
    let icon: String
    let granted: Bool
    let actionTitle: String
    let grantedTitle: String
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
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(OnboardingTheme.muted)
            }
            .foregroundStyle(granted ? OnboardingTheme.window : OnboardingTheme.ink)

            Spacer()

            Button(granted ? grantedTitle : actionTitle) {
                action()
            }
            .buttonStyle(InkButtonStyle(isSubtle: granted, compact: true))
            .disabled(granted)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: OnboardingTheme.radiusCard, style: .continuous)
                .fill(granted ? OnboardingTheme.ink : OnboardingTheme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: OnboardingTheme.radiusCard, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 1)
        )
        .onboardingShadow(OnboardingTheme.shadowSoftRaised)
        .animation(.easeInOut(duration: 0.2), value: granted)
    }
}

private struct InkButtonStyle: ButtonStyle {
    var isSubtle = false
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 14, weight: .semibold))
            .foregroundStyle(isSubtle ? OnboardingTheme.ink : OnboardingTheme.window)
            .padding(.horizontal, compact ? 14 : 22)
            .padding(.vertical, compact ? 8 : 12)
            .background(
                RoundedRectangle(cornerRadius: compact ? OnboardingTheme.radiusCompact : OnboardingTheme.radiusButton, style: .continuous)
                    .fill(isSubtle ? Color.clear : OnboardingTheme.ink)
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? OnboardingTheme.radiusCompact : OnboardingTheme.radiusButton, style: .continuous)
                    .stroke(isSubtle ? OnboardingTheme.border : Color.clear, lineWidth: 1)
            )
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct BulletList: View {
    let items: [String]

    init(_ items: [String]) {
        self.items = items
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 12) {
                    Circle()
                        .fill(OnboardingTheme.ink)
                        .frame(width: 4, height: 4)
                        .padding(.top, 8)
                    Text(item)
                        .font(.system(size: 13.5))
                        .foregroundStyle(OnboardingTheme.body)
                }
            }
        }
        .padding(.top, 8)
    }
}

private struct DictationDemoCard: View {
    private let phrase = "I think we should ship the pricing change before the board meeting."

    var body: some View {
        VStack(spacing: 18) {
            MiniWindow(title: "Mail - Reply") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(phrase)
                        .font(.system(size: 15))
                        .lineSpacing(4)
                        .foregroundStyle(OnboardingTheme.ink)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Rectangle()
                        .fill(OnboardingTheme.ink)
                        .frame(width: 2, height: 18)
                        .opacity(0.7)
                }
                .padding(18)
            }
            .frame(width: OnboardingTheme.dictationDemoWidth, height: OnboardingTheme.dictationDemoHeight)

            DictationPill(label: "Listening")
        }
    }
}

private struct MiniWindow<Content: View>: View {
    let title: String
    let content: Content

    init(title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(OnboardingTheme.border).frame(width: 7, height: 7)
                Circle().fill(OnboardingTheme.border).frame(width: 7, height: 7)
                Circle().fill(OnboardingTheme.border).frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(OnboardingTheme.muted.opacity(0.7))
                    .padding(.leading, 6)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .overlay(Rectangle().fill(OnboardingTheme.border).frame(height: 1), alignment: .bottom)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(OnboardingTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: OnboardingTheme.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OnboardingTheme.radiusCard, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 1)
        )
        .onboardingShadow(OnboardingTheme.shadowPanel)
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

private struct DemoPasteTarget: View {
    @Binding var text: String
    let isFocused: FocusState<Bool>.Binding
    let showHelp: Bool
    let shortcutDisplay: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: OnboardingTheme.radiusLarge, style: .continuous)
                .fill(OnboardingTheme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: OnboardingTheme.radiusLarge, style: .continuous)
                        .stroke(OnboardingTheme.border, lineWidth: 1)
                )
                .onboardingShadow(OnboardingTheme.shadowInput)

            TextEditor(text: $text)
                .font(.system(size: 18))
                .foregroundStyle(OnboardingTheme.ink)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .focused(isFocused)

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Your words will paste here.")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(OnboardingTheme.ink.opacity(0.42))
                    Text("Press \(shortcutDisplay) once, speak, then press it again.")
                        .font(.system(size: 12))
                        .foregroundStyle(OnboardingTheme.muted)
                    if showHelp {
                        Text("Nothing showing up? Click this field, or try dictating into any app.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(OnboardingTheme.codex)
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .allowsHitTesting(false)
            }
        }
        .frame(width: OnboardingTheme.demoPasteWidth, height: OnboardingTheme.demoPasteHeight)
        .overlay(alignment: .bottomTrailing) {
            if !text.isEmpty {
                Button("Clear") {
                    text = ""
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(OnboardingTheme.muted)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
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

private struct DualStreamVisual: View {
    let systemReady: Bool

    var body: some View {
        VStack(spacing: 22) {
            StreamCard(label: "You", subtitle: "Mic", color: OnboardingTheme.micStream, active: true)
            StreamCard(label: "Everyone else", subtitle: "System audio", color: OnboardingTheme.systemStream, active: systemReady)
            Text("-> local transcript with speaker labels")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .kerning(1.2)
                .textCase(.uppercase)
                .foregroundStyle(OnboardingTheme.muted)
        }
        .frame(width: OnboardingTheme.miniVisualWidth)
    }
}

private struct StreamCard: View {
    let label: String
    let subtitle: String
    let color: Color
    let active: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(color.opacity(active ? 1 : 0.25))
                    .frame(width: 32, height: 32)
                Text(String(label.prefix(1)))
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(OnboardingTheme.ink)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 13.5, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(OnboardingTheme.muted)
            }

            Spacer()
            MiniWaveform(color: OnboardingTheme.ink.opacity(active ? 0.85 : 0.25), width: 80, height: 22)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(OnboardingTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: OnboardingTheme.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OnboardingTheme.radiusCard, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 1)
        )
        .onboardingShadow(OnboardingTheme.shadowCardWide)
    }
}

private struct MeetingDemoCard: View {
    private let lines = [
        ("00:00", "You", "Thanks for making time today."),
        ("00:04", "Alex", "Happy to help. Let's get started."),
        ("00:08", "You", "Can you walk me through the rollout plan?"),
        ("00:13", "Alex", "Sure. We staged it in three regions.")
    ]

    var body: some View {
        MiniWindow(title: "Transcript.md") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(lines, id: \.0) { time, speaker, text in
                    HStack(alignment: .top, spacing: 10) {
                        Text(time)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(OnboardingTheme.muted)
                            .frame(width: 42, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(speaker)
                                .font(.system(size: 12, weight: .semibold))
                            Text(text)
                                .font(.system(size: 12))
                                .foregroundStyle(OnboardingTheme.body)
                        }
                    }
                }
            }
            .padding(18)
        }
        .frame(width: OnboardingTheme.miniVisualWidth, height: 250)
    }
}

private struct ToggleCard: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .lineSpacing(2)
                    .foregroundStyle(OnboardingTheme.muted)
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(OnboardingTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: OnboardingTheme.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OnboardingTheme.radiusCard, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 1)
        )
        .onboardingShadow(OnboardingTheme.shadowCard)
    }
}

private struct CalendarMock: View {
    let connected: Bool
    private let events = [
        ("10:00", "Design review", "45m", OnboardingTheme.micStream),
        ("11:30", "Team sync", "30m", OnboardingTheme.systemStream),
        ("02:00", "1:1 with Priya", "30m", OnboardingTheme.calendarAccent)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Today")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .kerning(1.8)
                .foregroundStyle(OnboardingTheme.muted)
                .textCase(.uppercase)

            VStack(spacing: 10) {
                ForEach(events, id: \.1) { time, name, duration, color in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(color)
                            .frame(width: 3, height: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(name)
                                .font(.system(size: 13, weight: .semibold))
                            Text("\(time) - \(duration)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(OnboardingTheme.muted)
                        }
                        Spacer()
                        if connected {
                            Text("prompt")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(OnboardingTheme.muted)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(connected ? OnboardingTheme.cardSoft : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: OnboardingTheme.radiusCompact, style: .continuous))
                    .opacity(connected ? 1 : 0.45)
                }
            }
        }
        .padding(20)
        .frame(width: OnboardingTheme.calendarCardWidth)
        .background(OnboardingTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: OnboardingTheme.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OnboardingTheme.radiusCard, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 1)
        )
        .onboardingShadow(OnboardingTheme.shadowMedium)
    }
}

private struct MemoryFlowVisual: View {
    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 10) {
                MemorySourceCard(
                    label: "Dictation",
                    title: "Voice notes",
                    detail: "Ship notes from today"
                )
                MemorySourceCard(
                    label: "Meeting",
                    title: "Transcript",
                    detail: "Alex: rollout in 3 regions"
                )
            }

            MemoryConnector(label: "saved")

            MemoryIndexCard()

            MemoryConnector(label: "ask")

            VStack(spacing: 10) {
                MemoryQuestionCard(text: "What did Alex decide?")
                MemoryQuestionCard(text: "Find the launch notes")
                MemoryQuestionCard(text: "Summarize last Tuesday")
            }
            .frame(width: 170)
        }
        .frame(width: OnboardingTheme.memoryFlowWidth, height: 210)
    }
}

private struct MemorySourceCard: View {
    let label: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .kerning(1.4)
                .foregroundStyle(OnboardingTheme.muted)
                .textCase(.uppercase)
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(OnboardingTheme.ink)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(OnboardingTheme.muted)
                .lineLimit(1)
        }
        .padding(14)
        .frame(width: 158, height: 84, alignment: .leading)
        .background(OnboardingTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: OnboardingTheme.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OnboardingTheme.radiusCard, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 1)
        )
        .onboardingShadow(OnboardingTheme.shadowCard)
    }
}

private struct MemoryConnector: View {
    let label: String

    var body: some View {
        VStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .kerning(1.2)
                .foregroundStyle(OnboardingTheme.muted)
                .textCase(.uppercase)
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addCurve(
                    to: CGPoint(x: size.width, y: size.height / 2),
                    control1: CGPoint(x: size.width * 0.34, y: 0),
                    control2: CGPoint(x: size.width * 0.66, y: size.height)
                )
                context.stroke(
                    path,
                    with: .color(OnboardingTheme.ink.opacity(0.28)),
                    style: StrokeStyle(lineWidth: 1.3, dash: [3, 4])
                )
            }
            .frame(width: 58, height: 34)
        }
        .frame(width: 64)
    }
}

private struct MemoryIndexCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("LOCAL MEMORY")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .kerning(1.4)
                        .foregroundStyle(OnboardingTheme.muted)
                    Text("on your Mac")
                        .font(.system(size: 11))
                        .foregroundStyle(OnboardingTheme.body)
                }
                Spacer()
                Circle()
                    .fill(OnboardingTheme.codex)
                    .frame(width: 10, height: 10)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(OnboardingTheme.muted)
                Text("search voice history")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(OnboardingTheme.ink)
                Spacer()
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(OnboardingTheme.cardSoft)
            .clipShape(RoundedRectangle(cornerRadius: OnboardingTheme.radiusCompact, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                MemoryTagRow(label: "decisions", value: "18")
                MemoryTagRow(label: "people", value: "42")
                MemoryTagRow(label: "dates", value: "all local")
            }
        }
        .padding(16)
        .frame(width: 210, height: 174)
        .background(OnboardingTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: OnboardingTheme.radiusLarge, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OnboardingTheme.radiusLarge, style: .continuous)
                .stroke(OnboardingTheme.ink.opacity(0.18), lineWidth: 1.3)
        )
        .onboardingShadow(OnboardingTheme.shadowMediumTight)
    }
}

private struct MemoryTagRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(OnboardingTheme.body)
            Spacer()
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(OnboardingTheme.muted)
        }
    }
}

private struct MemoryQuestionCard: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(OnboardingTheme.claude)
                .frame(width: 7, height: 7)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(OnboardingTheme.ink)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
        .background(OnboardingTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: OnboardingTheme.radiusButton, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OnboardingTheme.radiusButton, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 1)
        )
    }
}

private struct AgentDemoCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ChatBubble(role: "You", text: "What did Alex say last Tuesday?")
            ChatBubble(role: "Agent", text: "Alex wanted the rollout staged in three regions. Source: Design review transcript.", accent: OnboardingTheme.codex)
            HStack(spacing: 8) {
                Image(systemName: "quote.bubble")
                Text("Cited from your local transcript")
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(OnboardingTheme.muted)
        }
        .padding(18)
        .frame(width: OnboardingTheme.miniVisualWidth)
        .background(OnboardingTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: OnboardingTheme.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OnboardingTheme.radiusCard, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 1)
        )
        .onboardingShadow(OnboardingTheme.shadowPanelWide)
    }
}

private struct ChatBubble: View {
    let role: String
    let text: String
    var accent: Color = OnboardingTheme.ink

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(role)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .kerning(1.2)
                .foregroundStyle(OnboardingTheme.muted)
                .textCase(.uppercase)
            Text(text)
                .font(.system(size: 13))
                .lineSpacing(2)
                .foregroundStyle(OnboardingTheme.body)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: OnboardingTheme.radiusButton, style: .continuous))
    }
}

private struct ConnectAgentStage: View {
    let copiedItem: AgentCopyItem?
    let onCopy: (AgentCopyItem) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Kicker("Connect an agent")
                Headline(primary: "Give your agent a memory.", size: 42, alignment: .leading)

                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 260), spacing: 16, alignment: .top)],
                    alignment: .leading,
                    spacing: 16
                ) {
                    AgentOptionCard(
                        eyebrow: "Option 1 - Start here",
                        title: "Claude Desktop",
                        detail: "Copy the setup steps, then install Transcripted direct tools from Settings > Agent.",
                        glyph: "◆",
                        color: OnboardingTheme.claude,
                        buttonTitle: copiedItem == .claudeDesktopSetup ? "Copied" : "Copy steps"
                    ) {
                        onCopy(.claudeDesktopSetup)
                    }

                    AgentOptionCard(
                        eyebrow: "Option 2 - Other apps",
                        title: "Claude Code, Codex, OpenClaw",
                        detail: "Copy one prompt for local coding agents that can read your Transcripted Markdown folders.",
                        glyph: "●",
                        color: OnboardingTheme.codex,
                        buttonTitle: copiedItem == .localAgentPrompt ? "Copied" : "Copy prompt"
                    ) {
                        onCopy(.localAgentPrompt)
                    }
                }
                .padding(.top, 28)

                Text("Or skip. Everything still works without an agent.")
                    .font(.system(size: 12))
                    .italic()
                    .foregroundStyle(OnboardingTheme.muted)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 12)
            }
            .padding(.horizontal, OnboardingTheme.padContentH)
            .padding(.vertical, 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct AgentOptionCard: View {
    let eyebrow: String
    let title: String
    let detail: String
    let glyph: String
    let color: Color
    let buttonTitle: String
    var inverted = false
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(eyebrow.uppercased())
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .kerning(2)
                .foregroundStyle(inverted ? OnboardingTheme.window.opacity(0.62) : OnboardingTheme.muted)

            HStack(spacing: 12) {
                AgentGlyph(glyph: glyph, color: color)
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(detail)
                .font(.system(size: 13))
                .lineSpacing(3)
                .foregroundStyle(inverted ? OnboardingTheme.window.opacity(0.72) : OnboardingTheme.body)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button(buttonTitle) {
                action()
            }
            .buttonStyle(InkButtonStyle(isSubtle: inverted))
        }
        .foregroundStyle(inverted ? OnboardingTheme.window : OnboardingTheme.ink)
        .padding(22)
        .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
        .background(inverted ? OnboardingTheme.ink : OnboardingTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: OnboardingTheme.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OnboardingTheme.radiusCard, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 1)
        )
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

private struct ThreeActionsRecap: View {
    let dictationShortcut: String

    var body: some View {
        HStack(spacing: 14) {
            ActionStepCard(
                number: "1",
                label: "Dictate",
                command: dictationShortcut,
                detail: "Press once to talk. Press again to paste.",
                color: OnboardingTheme.codex,
                icon: "keyboard"
            )
            ActionStepCard(
                number: "2",
                label: "Record",
                command: "Option-M",
                detail: "Start or stop a meeting recording.",
                color: OnboardingTheme.recording,
                icon: "record.circle"
            )
            ActionStepCard(
                number: "3",
                label: "Ask",
                command: "Ask your agent",
                detail: "Use your saved voice memory as context.",
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

    init(number: String, label: String, command: String, detail: String, color: Color, icon: String) {
        self.number = number
        self.label = label
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

            Text(detail)
                .font(.system(size: 11.5))
                .foregroundStyle(OnboardingTheme.body)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(width: 190, height: 150, alignment: .leading)
        .background(OnboardingTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: OnboardingTheme.radiusCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OnboardingTheme.radiusCard, style: .continuous)
                .stroke(OnboardingTheme.border, lineWidth: 1)
        )
        .onboardingShadow(OnboardingTheme.shadowAccentCard, color: color)
    }
}
