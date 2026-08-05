// MeetingOverlayController.swift
// Owns the non-activating meeting overlay panel lifecycle and state updates.
// Views are kept in separate files and receive explicit update calls from here.

import AppKit
import Combine
import TranscriptedCore

// MARK: - Controller

/// Owns the `MeetingOverlayPanel`, subscribes to `MeetingSessionController`
/// @Published state, and pushes updates to `MeetingOverlayRootView`.
///
/// Also forwards the ⌥M hotkey intent (toggle meeting recording) through its
/// `toggleFromHotkey()` method — wired by the `TranscriptedAppDelegate` onto
/// `ContextCaptureEngine.onMeetingToggle`.
@available(macOS 14.0, *)
@MainActor
final class MeetingOverlayController: NSObject {

    enum OverlayState: Equatable {
        case idle
        case prompt
        case preparing
        case recording
        case transcribing
        case saved
        case error(String)
    }

    struct PromptDisplay: Equatable {
        let title: String
        let detail: String
        let countdownText: String
        let secondaryTitle: String
        let secondaryAccessibilityLabel: String
        let primaryTitle: String
        let primaryAccessibilityLabel: String
    }

    // MARK: - State

    private(set) var state: OverlayState = .idle
    private var currentDuration: TimeInterval = 0
    private var currentMicLevel: Float = 0
    private var currentSystemLevel: Float = 0
    private var currentParticipants: [String] = []
    private var currentWarmupStatus: MeetingSessionController.ModelWarmupStatus = .ready
    private var currentPrompt: PromptDisplay?
    private var promptKind: PromptKind?
    private var audioRouteWarningOutcome: CaptureRouteStabilizationOutcome?
    private var systemAudioDegradationWarning: MeetingSystemAudioDegradationWarning?
    // Audio inactivity drives its own per-second countdown Task
    // (schedulePromptCountdown). The combined warning subscription re-fires
    // on *any* of the four signals changing, so this mirror lets it tell
    // "the inactivity warning itself changed" apart from "some unrelated
    // signal changed while inactivity was already the winning prompt" —
    // only the former should restart the countdown.
    private var lastAppliedAudioInactivityWarning: MeetingAudioInactivityWarning?
    private var promptCountdownTask: Task<Void, Never>?
    private var promptSecondsRemaining = 0

    // MARK: - Panel & views

    private var panel: MeetingOverlayPanel?
    private var rootView: MeetingOverlayRootView?
    private var subscriptions: Set<AnyCancellable> = []
    private var autoHideTask: Task<Void, Never>?
    private var isShowingCancelConfirmation = false
    private var isRestingCondensed = false
    private var isPanelHovered = false
    private var restTask: Task<Void, Never>?
    private var isTranscriptExpanded = false
    private var lastRequestedPanelSize: NSSize?
    private var drawerResizeBaseHeight: CGFloat?
    private var activeDrawerHeightOverride: CGFloat?
    private var latestTranscriptFinals: [LiveMeetingTranscriptEntry] = []
    private var latestTranscriptPartials: [LiveMeetingTranscriptSource: LiveMeetingTranscriptEntry] = [:]
    private var latestTranscriptPhase: LiveMeetingTranscriptFeedPhase = .idle
    private var transcriptPushPending = false

    // The precedence lattice for these kinds lives in the pure
    // `MeetingPromptPriority.resolve` — kept in its own Foundation-pure file
    // (with the shared `MeetingWarningPromptKind` enum) so the root fast-test
    // runner can exercise it without pulling in this controller's AppKit/
    // MeetingSessionController dependencies.
    typealias PromptKind = MeetingWarningPromptKind

    // Kept for the countdown-refresh pass, which rebuilds the display each tick.
    private var missedCallPrompt: MeetingPromptUnrecordedCall?

    deinit {
        autoHideTask?.cancel()
        promptCountdownTask?.cancel()
        restTask?.cancel()
    }

    // MARK: - Dependencies

    /// The session controller the overlay reflects and forwards hotkey events to.
    /// Set once by `TranscriptedAppDelegate` during app launch.
    weak var meetingSession: MeetingSessionController?
    /// How the missed-call nudge resolved (acknowledged / disabled / expired).
    /// "Disabled" means the user tapped "Don't show again" — the wiring in
    /// `TranscriptedApp` persists the opt-out.
    var onMissedCallNudgeResolved: ((MissedCallNudgeOutcome) -> Void)?

    // MARK: - Setup

    /// Create the panel, wire subscriptions, and keep it hidden until state
    /// becomes non-idle. Safe to call once at app launch; re-calls are ignored.
    func setup(meetingSession: MeetingSessionController) {
        guard panel == nil else { return }
        self.meetingSession = meetingSession

        let frame = NSRect(
            x: 0, y: 0,
            width: MeetingOverlayTokens.panelWidth,
            height: MeetingOverlayTokens.panelHeight
        )

        let panel = MeetingOverlayPanel(
            contentRect: frame,
            styleMask: [],
            backing: .buffered,
            defer: true
        )

        let rootView = MeetingOverlayRootView(frame: panel.contentView?.bounds ?? frame)
        rootView.autoresizingMask = [.width, .height]
        rootView.onSecondaryAction = { [weak self] in self?.handleSecondaryActionTapped() }
        rootView.onPrimaryAction = { [weak self] in self?.handlePrimaryActionTapped() }
        rootView.onLiveViewAction = { [weak self] in self?.handleLiveViewTapped() }
        rootView.onPanelHoverChanged = { [weak self] hovered in self?.handlePanelHoverChanged(hovered) }
        rootView.onStripMenuRequested = { [weak self] in self?.makeStripMenu() }
        rootView.onCopyTranscriptAction = { [weak self] in self?.handleCopyTranscriptTapped() }
        rootView.onDrawerResizeBegan = { [weak self] in self?.handleDrawerResizeBegan() }
        rootView.onDrawerResizeChanged = { [weak self] delta in self?.handleDrawerResizeChanged(delta) }
        rootView.onDrawerResizeEnded = { [weak self] in self?.handleDrawerResizeEnded() }
        panel.contentView?.addSubview(rootView)

        self.panel = panel
        self.rootView = rootView

        wireSubscriptions(to: meetingSession)
    }

    // MARK: - Hotkey entry point

    /// Called from `ContextCaptureEngine.onMeetingToggle` when ⌥M fires.
    /// Toggles recording start/stop based on current session state.
    func toggleFromHotkey() {
        guard let session = meetingSession else { return }
        Task { [weak session] in
            guard let session else { return }
            switch session.state {
            case .idle, .ready, .transcribing, .error:
                await session.startRecording(trigger: .hotkey)
            case .loadingModels, .startingRecording, .stoppingRecording:
                // Still loading, or a start/stop is already in flight —
                // ignore to avoid double-starts/double-stops.
                break
            case .recording:
                await session.stopRecording(reason: .hotkeyToggle)
            }
        }
    }

    /// The capture pill dismisses before its Record callback returns. Keep a
    /// visible, non-interactive status panel up while the app checks
    /// permissions, models, and the audio route so Record never looks ignored.
    func showDetectedMeetingStartInProgress() {
        autoHideTask?.cancel()
        promptCountdownTask?.cancel()
        currentPrompt = nil
        promptKind = nil
        currentWarmupStatus = .init(
            title: "Starting meeting…",
            subtitle: "Checking permissions and audio",
            detail: "",
            progress: 0.12,
            dictationStatus: "Ready",
            meetingsStatus: "Starting"
        )
        state = .preparing
        showPanel()
        pushToView()
    }

    /// Post-call awareness nudge: a detected call just ended without a
    /// recording. Same non-activating prompt panel; no candidate, no detector
    /// backoff — resolution is reported through `onMissedCallNudgeResolved`.
    @discardableResult
    func presentMissedCallNudge(_ call: MeetingPromptUnrecordedCall) -> Bool {
        guard let session = meetingSession else { return false }

        let presentationSnapshot = MeetingPromptPresentationSnapshot(
            sessionState: MeetingPromptSessionPromptState(session.state),
            overlayState: MeetingPromptOverlayPromptState(state)
        )
        guard MeetingPromptPresentationGate.allowsDetectedMeetingPrompt(presentationSnapshot) else {
            return false
        }

        autoHideTask?.cancel()
        promptCountdownTask?.cancel()

        missedCallPrompt = call
        promptKind = .missedCall
        promptSecondsRemaining = MeetingOverlayTokens.missedCallNudgeTimeoutSeconds
        currentPrompt = missedCallPromptDisplay(call: call)
        state = .prompt
        showPanel()
        pushToView()
        schedulePromptCountdown()
        return true
    }

    // MARK: - Subscriptions

    private func wireSubscriptions(to session: MeetingSessionController) {
        session.$state
            .receive(on: DispatchQueue.main)
            .sink { [weak self] sessionState in
                self?.applySessionState(sessionState)
            }
            .store(in: &subscriptions)

        session.$recordingDuration
            .map { Int($0) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] wholeSecond in
                guard let self else { return }
                // The strip timer renders whole seconds (mm:ss). Collapse the
                // 5Hz capture duration publisher before the full view push so
                // recording does not rebuild attributed titles/layouts five
                // times for the same visible label.
                self.currentDuration = TimeInterval(wholeSecond)
                self.pushToView()
            }
            .store(in: &subscriptions)

        session.$audioLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.currentMicLevel = level
                self?.pushAudioLevelsToView()
            }
            .store(in: &subscriptions)

        session.$systemLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.currentSystemLevel = level
                self?.pushAudioLevelsToView()
            }
            .store(in: &subscriptions)

        session.$warmupStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.currentWarmupStatus = status
                self?.pushToView()
            }
            .store(in: &subscriptions)

        // The four warning-driven prompts are read together and resolved as
        // one unit: their precedence lattice (audioInactivity > systemAudio >
        // {audioRoute, micBoost}, the latter pair mutually sticky) needs to
        // see all four latest values at once to pick a winner — the old
        // per-signal .sink handlers re-derived that ordering by hand across
        // four apply*/clear* pairs, which is exactly what
        // MeetingPromptPriority.resolve now encodes in one place.
        Publishers.CombineLatest4(
            session.$audioInactivityWarning,
            session.$systemAudioDegradationWarning,
            session.$isMicBoostPromptVisible,
            session.$audioRouteWarning
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] inactivity, systemAudio, micBoostVisible, route in
            self?.applyWarningPrompt(
                inactivity: inactivity,
                systemAudio: systemAudio,
                micBoostVisible: micBoostVisible,
                route: route
            )
        }
        .store(in: &subscriptions)

        let feed = session.liveTranscriptFeed
        feed.$finalEntries
            .combineLatest(feed.$partialEntries, feed.$phase)
            // Live ASR emits at word rate for the whole meeting, and each
            // visible push rebuilds the drawer's attributed transcript and
            // relayouts the text view. Throttling with `latest: true` caps
            // that at ~5Hz while guaranteeing the newest finals/partials and
            // phase still land after the last emission in a window.
            .throttle(for: .milliseconds(200), scheduler: DispatchQueue.main, latest: true)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] finals, partials, phase in
                self?.latestTranscriptFinals = finals
                self?.latestTranscriptPartials = partials
                self?.latestTranscriptPhase = phase
                self?.pushTranscriptToView()
            }
            .store(in: &subscriptions)
    }

    private func pushTranscriptToView() {
        // Word-rate updates arrive for the whole meeting; building the
        // attributed string and re-laying-out the text view is only worth
        // doing while the drawer can actually be seen. Hidden updates mark
        // the view dirty and get flushed once on reveal.
        guard isTranscriptExpanded, state == .recording else {
            transcriptPushPending = true
            return
        }
        transcriptPushPending = false

        let hasEntries = !latestTranscriptFinals.isEmpty || !latestTranscriptPartials.isEmpty
        rootView?.updateLiveTranscript(
            finals: latestTranscriptFinals,
            partials: latestTranscriptPartials,
            statusText: MeetingLiveViewAffordancePolicy.drawerStatus(
                phase: latestTranscriptPhase,
                hasEntries: hasEntries
            ),
            hasEntries: hasEntries
        )
    }

    private func flushPendingTranscriptIfNeeded() {
        guard transcriptPushPending else { return }
        pushTranscriptToView()
    }

    /// Single entry point for all four warning-driven prompts. Fires whenever
    /// any of them changes (see the CombineLatest4 subscription in
    /// `wireSubscriptions`), recomputes the winning kind via
    /// `MeetingPromptPriority.resolve`, and renders it — replacing the old
    /// four apply*/clear* method pairs that re-derived the same precedence
    /// by hand.
    private func applyWarningPrompt(
        inactivity: MeetingAudioInactivityWarning?,
        systemAudio: MeetingSystemAudioDegradationWarning?,
        micBoostVisible: Bool,
        route: CaptureRouteStabilizationOutcome?
    ) {
        systemAudioDegradationWarning = systemAudio
        audioRouteWarningOutcome = route

        // A live system-audio warning keeps the pill fully expanded even
        // while a higher-priority prompt (audio inactivity) is the one
        // actually shown — isVisuallyCondensed/scheduleRestIfNeeded key off
        // this raw signal, not the resolved prompt kind.
        if systemAudio != nil {
            bloomFromRest()
        }

        let resolvedKind = MeetingPromptPriority.resolve(
            inactivity: inactivity,
            systemAudio: systemAudio,
            routeActive: route != nil,
            micBoostVisible: micBoostVisible,
            current: promptKind,
            isRecording: meetingSession?.state == .recording
        )

        guard let resolvedKind else {
            lastAppliedAudioInactivityWarning = nil
            if isWarningDrivenPromptKind(promptKind) {
                clearWarningPrompt()
            }
            return
        }

        if resolvedKind == .audioInactivity, promptKind == .audioInactivity,
           inactivity == lastAppliedAudioInactivityWarning {
            // Already showing this exact inactivity warning and some
            // unrelated signal is what changed. Its per-second countdown
            // Task is still ticking down — don't restart it under a fresh
            // value.
            return
        }

        guard let display = promptDisplay(
            for: resolvedKind,
            inactivity: inactivity,
            systemAudio: systemAudio,
            route: route
        ) else {
            // Resolver and display builder disagreed about which raw signal
            // backs `resolvedKind` — shouldn't happen; leave the previous
            // prompt state untouched rather than show a blank prompt.
            return
        }

        autoHideTask?.cancel()
        promptCountdownTask?.cancel()
        promptKind = resolvedKind
        promptSecondsRemaining = display.countdownSeconds
        currentPrompt = display.prompt
        if resolvedKind == .audioInactivity {
            lastAppliedAudioInactivityWarning = inactivity
        }
        bloomFromRest()
        state = presentationState(session: meetingSession?.state ?? .idle, prompt: promptKind)
        showPanel()
        pushToView()
        if display.schedulesCountdown {
            schedulePromptCountdown()
        }
    }

    /// Builds the display copy for the resolved warning-prompt kind, plus
    /// whether it starts a countdown (only audio inactivity does — its
    /// countdown can auto-stop the recording; the others never expire on
    /// their own).
    private func promptDisplay(
        for kind: PromptKind,
        inactivity: MeetingAudioInactivityWarning?,
        systemAudio: MeetingSystemAudioDegradationWarning?,
        route: CaptureRouteStabilizationOutcome?
    ) -> (prompt: PromptDisplay, countdownSeconds: Int, schedulesCountdown: Bool)? {
        switch kind {
        case .systemAudio:
            guard let systemAudio else { return nil }
            return (systemAudioWarningPromptDisplay(warning: systemAudio), 0, false)
        case .audioInactivity:
            guard let inactivity else { return nil }
            let seconds = inactivity.automaticStopAllowed ? max(1, inactivity.countdownSeconds) : 0
            return (
                audioInactivityPromptDisplay(warning: inactivity, countdownSeconds: seconds),
                seconds,
                inactivity.automaticStopAllowed
            )
        case .audioRoute:
            guard let route else { return nil }
            return (audioRouteWarningPromptDisplay(outcome: route), 0, false)
        case .micBoost:
            // No schedulePromptCountdown(): expiry must never auto-enable VPIO.
            return (micBoostPromptDisplay(), 0, false)
        case .missedCall:
            return nil
        }
    }

    private func isWarningDrivenPromptKind(_ kind: PromptKind?) -> Bool {
        switch kind {
        case .systemAudio, .audioInactivity, .audioRoute, .micBoost:
            return true
        case .missedCall, .none:
            return false
        }
    }

    /// Common "nothing left to show" path once the resolver returns nil for
    /// a previously-active warning prompt.
    private func clearWarningPrompt() {
        promptCountdownTask?.cancel()
        promptKind = nil
        currentPrompt = nil

        if meetingSession?.state == .recording {
            state = presentationState(session: .recording, prompt: nil)
            showPanel()
            pushToView()
            flushPendingTranscriptIfNeeded()
            scheduleRestIfNeeded()
        } else {
            state = .idle
            hidePanel()
        }
    }

    /// Pure derivation of the overlay's presentation state from the session
    /// state plus the currently-resolved prompt kind (whichever of the four
    /// warning prompts `MeetingPromptPriority` resolved to, or the
    /// missed-call nudge — both funnel through `promptKind`).
    ///
    /// Not total, though: `.saved` is a transient display (session `.ready`
    /// right after `.transcribing`, shown for `scheduleAutoHide`'s 1.5s
    /// before falling back to idle) that depends on the *previous* overlay
    /// state, not just the current session state — genuinely not derivable
    /// from `(session, prompt)` alone. `applySessionState` below keeps that
    /// one case as an explicit imperative branch instead of forcing it
    /// through this function.
    private func presentationState(
        session: MeetingSessionController.State,
        prompt: PromptKind?
    ) -> OverlayState {
        if prompt != nil {
            return .prompt
        }
        switch session {
        case .idle, .ready:
            return .idle
        // .startingRecording groups with .loadingModels, not .recording:
        // before the 2026-08 state collapse, `state` during the mic-engage
        // window was whatever it was before the start began (.ready in the
        // common case, mapped to `.idle` here) — it never showed the
        // recording pill until capture actually confirmed. Showing the pill
        // here would be new, premature behavior, and could visibly claim
        // "recording" a moment before the mic has actually engaged.
        case .loadingModels, .startingRecording:
            return .preparing
        // .stoppingRecording keeps showing the recording pill: before the
        // 2026-08 state collapse, `state` stayed .recording for the entire
        // stop/cancel/termination teardown window, so the overlay never saw
        // anything else here either.
        case .recording, .stoppingRecording:
            return .recording
        case .transcribing:
            return .transcribing
        case .error(let message):
            return .error(message)
        }
    }

    private func applySessionState(_ sessionState: MeetingSessionController.State) {
        switch sessionState {
        case .idle:
            cancelRest()
            isTranscriptExpanded = false
            if state == .prompt {
                pushToView()
                break
            }
            promptKind = nil
            state = presentationState(session: sessionState, prompt: promptKind)
            hidePanel()
        case .loadingModels, .startingRecording:
            cancelRest()
            isTranscriptExpanded = false
            currentPrompt = nil
            promptKind = nil
            promptCountdownTask?.cancel()
            state = presentationState(session: sessionState, prompt: promptKind)
            showPanel()
        case .ready:
            cancelRest()
            isTranscriptExpanded = false
            if state == .prompt {
                pushToView()
                break
            }
            // Ready but not recording — hide unless we're already showing a
            // terminal state (saved/error); the auto-hide task handles those.
            // `.saved` can't be derived from (session, prompt) alone — it
            // only exists because the *previous* overlay state was
            // `.transcribing` — so it stays an explicit branch here instead
            // of going through `presentationState`.
            if case .transcribing = state {
                state = .saved
                showPanel()
                scheduleAutoHide(after: 1.5)
                break
            }
            if case .saved = state { break }
            if case .error = state { break }
            state = presentationState(session: sessionState, prompt: promptKind)
            hidePanel()
        case .recording, .stoppingRecording:
            if state != .recording {
                // New recording: restore the user's last drawer choice so a
                // transcript they kept open last meeting opens itself, and
                // start from a clean hover state — enter events re-arm it.
                isTranscriptExpanded = MeetingLiveTranscriptPreferences.isDrawerOpenPreferred()
                isPanelHovered = false
            }
            isRestingCondensed = false
            currentPrompt = nil
            promptKind = nil
            promptCountdownTask?.cancel()
            autoHideTask?.cancel()
            state = presentationState(session: sessionState, prompt: promptKind)
            showPanel()
            flushPendingTranscriptIfNeeded()
            scheduleRestIfNeeded()
        case .transcribing:
            cancelRest()
            isTranscriptExpanded = false
            currentPrompt = nil
            promptKind = nil
            promptCountdownTask?.cancel()
            state = presentationState(session: sessionState, prompt: promptKind)
            showPanel()
        case .error:
            cancelRest()
            isTranscriptExpanded = false
            currentPrompt = nil
            promptKind = nil
            promptCountdownTask?.cancel()
            autoHideTask?.cancel()
            state = presentationState(session: sessionState, prompt: promptKind)
            showPanel()
        }
        pushToView()
    }

    // MARK: - Panel show/hide

    private func showPanel() {
        guard let panel = panel else { return }
        if panel.isVisible { return }

        let desiredHeight = currentPanelHeight()
        let desiredWidth = currentPanelWidth()

        // Position at top-center of the screen containing the mouse.
        let mousePos = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mousePos, $0.frame, false) })
            ?? NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            let origin = NSPoint(
                x: visibleFrame.midX - desiredWidth / 2,
                y: visibleFrame.maxY - desiredHeight - 12
            )
            panel.setFrameOrigin(origin)
        }
        panel.setContentSize(NSSize(
            width: desiredWidth,
            height: desiredHeight
        ))
        lastRequestedPanelSize = NSSize(width: desiredWidth, height: desiredHeight)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = AccessibilityDisplayPolicy.motionDuration(0.18)
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }
    }

    /// Target height for the panel based on the current `isExpanded` flag.
    /// Kept as a helper so show/animate paths agree on the value.
    private func currentPanelHeight() -> CGFloat {
        switch state {
        case .preparing:
            return MeetingOverlayTokens.warmupHeight
        case .prompt:
            return MeetingOverlayTokens.promptHeight
        case .recording where isVisuallyCondensed:
            return MeetingOverlayTokens.condensedPillHeight
        case .recording where isTranscriptExpanded:
            return MeetingOverlayTokens.panelHeight + currentDrawerHeight()
        case .error:
            return MeetingOverlayTokens.errorHeight
        default:
            return MeetingOverlayTokens.panelHeight
        }
    }

    // The transcript drawer reuses the recording pill's width on purpose:
    // expansion is a pure downward slide, so the header strip never moves
    // and text never re-wraps mid-animation.
    private func currentPanelWidth() -> CGFloat {
        switch state {
        case .recording where isVisuallyCondensed:
            return MeetingOverlayTokens.condensedPillWidth
        case .recording where isTranscriptExpanded:
            return MeetingOverlayTokens.expandedRecordingPanelWidth
        case .recording:
            return MeetingOverlayTokens.recordingPanelWidth
        default:
            return MeetingOverlayTokens.panelWidth
        }
    }

    private func hidePanel() {
        guard let panel = panel, panel.isVisible else { return }
        lastRequestedPanelSize = nil
        // A panel hidden under the cursor never delivers mouseExited; a
        // stale hover flag would silently block resting next recording.
        isPanelHovered = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = AccessibilityDisplayPolicy.motionDuration(0.14)
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
    }

    /// Discard lives behind the pill's context menu (with this confirmation)
    /// rather than as a permanent button: deleting a recording is a rare,
    /// deliberate act and must never sit one mis-click from Stop.
    private func handleDiscardRequested() {
        guard !isShowingCancelConfirmation else { return }
        guard let session = meetingSession else { return }
        guard case .recording = session.state else { return }

        isShowingCancelConfirmation = true
        defer {
            isShowingCancelConfirmation = false
        }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard this meeting recording?"
        alert.informativeText = "This will stop the meeting recording and delete the captured audio. No transcript will be saved."
        alert.addButton(withTitle: "Keep Recording")
        alert.addButton(withTitle: "Discard Recording")
        alert.buttons.last?.hasDestructiveAction = true

        let response = alert.runModal()
        guard response == .alertSecondButtonReturn else { return }

        Task { [weak session] in
            await session?.cancelRecording(reason: .discardButton)
        }
    }

    private func scheduleAutoHide(after seconds: Double) {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hidePanel()
        }
    }

    private func handleCloseTapped() {
        if case .error = state {
            state = .idle
            hidePanel()
            pushToView()
            return
        }
        guard let session = meetingSession else { hidePanel(); return }
        Task { [weak session] in
            guard let session else { return }
            if case .recording = session.state {
                await session.stopRecording(reason: .overlayStopButton)
            }
        }
    }

    private func handleSecondaryActionTapped() {
        switch state {
        case .prompt:
            switch promptKind {
            case .systemAudio:
                meetingSession?.acknowledgeSystemAudioDegradationWarning()
            case .audioInactivity:
                meetingSession?.dismissAudioInactivityWarning()
            case .micBoost:
                meetingSession?.declineMicBoostPrompt()
            case .audioRoute:
                meetingSession?.dismissAudioRouteWarning()
            case .missedCall:
                // "Don't show again" — the wiring persists the opt-out.
                onMissedCallNudgeResolved?(.disabled)
                dismissPrompt()
            case .none:
                dismissPrompt()
            }
        case .recording:
            handleCloseTapped()
        default:
            hidePanel()
        }
    }

    private func handlePrimaryActionTapped() {
        guard case .prompt = state else { return }
        promptCountdownTask?.cancel()

        switch promptKind {
        case .systemAudio:
            Task { @MainActor [weak self] in
                guard let session = self?.meetingSession else { return }
                await session.stopRecording(reason: .systemAudioWarning)
            }
        case .audioInactivity:
            Task { @MainActor [weak self] in
                guard let session = self?.meetingSession else { return }
                await session.endRecordingFromAudioInactivityPrompt(automatic: false)
            }
        case .audioRoute:
            Task { @MainActor [weak self] in
                guard let session = self?.meetingSession else { return }
                await session.stopRecording(reason: .audioRouteWarning)
            }
        case .micBoost:
            // Session clears the published flag, which the combined warning
            // subscription picks up and resolves back down to .recording (or
            // to whichever prompt was suppressed behind this one).
            meetingSession?.acceptMicBoostPrompt()
        case .missedCall:
            onMissedCallNudgeResolved?(.acknowledged)
            dismissPrompt()
        case .none:
            break
        }
    }

    /// Point-of-use live transcript action.
    private func handleLiveViewTapped() {
        guard state == .recording else { return }

        isTranscriptExpanded.toggle()
        MeetingLiveTranscriptPreferences.setDrawerOpenPreferred(isTranscriptExpanded)
        trackLiveTranscriptDrawerAction(
            actionKind: isTranscriptExpanded ? "open" : "close",
            trigger: "overlay_button"
        )
        if isTranscriptExpanded {
            bloomFromRest()
            flushPendingTranscriptIfNeeded()
        } else {
            scheduleRestIfNeeded()
        }
        pushToView()
    }

    private func trackLiveTranscriptDrawerAction(
        actionKind: String,
        trigger: String,
        result: String = "success"
    ) {
        AnalyticsReporter.track(
            "meeting_live_transcript_drawer_actioned",
            properties: [
                "action_kind": actionKind,
                "result": result,
                "surface": "meeting_overlay",
                "trigger": trigger,
            ]
        )
    }

    // MARK: - Rest / wake

    /// True when the pill should currently render as the compact capsule.
    /// Hovering wakes the pill (clears the resting state) rather than
    /// temporarily overriding rendering, so hover-out never resizes anything
    /// directly — only the countdown does. That asymmetry is what makes the
    /// interaction immune to spurious enter/exit events during animations.
    private var isVisuallyCondensed: Bool {
        return MeetingPillRestPolicy.isCondensedRendered(
            isResting: isRestingCondensed,
            isRecording: state == .recording,
            isTranscriptVisible: isTranscriptExpanded,
            hasSystemAudioWarning: systemAudioDegradationWarning != nil
        )
    }

    private func scheduleRestIfNeeded() {
        restTask?.cancel()
        guard systemAudioDegradationWarning == nil,
              !isRestingCondensed,
              MeetingPillRestPolicy.canRest(
                isRecording: state == .recording,
                isTranscriptVisible: isTranscriptExpanded,
                keepControlsVisible: MeetingOverlayPillPreferences.keepControlsVisible(),
                isHovered: isPanelHovered,
                hasSystemAudioWarning: systemAudioDegradationWarning != nil
              ) else { return }

        restTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(MeetingPillRestPolicy.restDelaySeconds * 1_000_000_000)
            )
            guard !Task.isCancelled, let self else { return }
            guard MeetingPillRestPolicy.canRest(
                isRecording: self.state == .recording,
                isTranscriptVisible: self.isTranscriptExpanded,
                keepControlsVisible: MeetingOverlayPillPreferences.keepControlsVisible(),
                isHovered: self.isPanelHovered,
                hasSystemAudioWarning: self.systemAudioDegradationWarning != nil
            ) else { return }
            // Belt and braces against a lost exit/enter pair: never rest
            // while the pointer is physically over the panel, even if the
            // hover flag went stale.
            guard !self.pointerIsOverPanel() else {
                self.scheduleRestIfNeeded()
                return
            }
            self.isRestingCondensed = true
            self.pushToView()
        }
    }

    private func pointerIsOverPanel() -> Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
    }

    /// Leaving the recording flow entirely: stop the countdown and forget
    /// the resting state.
    private func cancelRest() {
        restTask?.cancel()
        restTask = nil
        isRestingCondensed = false
    }

    /// Wake the pill back to its full strip (prompts, drawer opens, pin).
    private func bloomFromRest() {
        restTask?.cancel()
        restTask = nil
        isRestingCondensed = false
    }

    private func handlePanelHoverChanged(_ hovered: Bool) {
        guard hovered != isPanelHovered else { return }
        isPanelHovered = hovered
        if hovered {
            restTask?.cancel()
            if isRestingCondensed {
                // Wake: hovering restores the full pill, which then stays
                // until the next quiet stretch passes — no peek-and-snap.
                isRestingCondensed = false
                pushToView()
            }
        } else {
            scheduleRestIfNeeded()
        }
    }

    // MARK: - Pill context menu

    private func makeStripMenu() -> NSMenu? {
        guard state == .recording else { return nil }

        // An open menu is attention: pause the rest countdown so the pill
        // cannot shrink underneath it. The next hover-out reschedules.
        restTask?.cancel()

        let menu = NSMenu()

        let toggleItem = NSMenuItem(
            title: MeetingLiveViewAffordancePolicy.transcriptToggleMenuTitle(
                isTranscriptVisible: isTranscriptExpanded
            ),
            action: #selector(handleMenuToggleTranscript),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let pinItem = NSMenuItem(
            title: MeetingLiveViewAffordancePolicy.keepControlsVisibleMenuTitle,
            action: #selector(handleMenuTogglePin),
            keyEquivalent: ""
        )
        pinItem.target = self
        pinItem.state = MeetingOverlayPillPreferences.keepControlsVisible() ? .on : .off
        menu.addItem(pinItem)

        menu.addItem(.separator())

        let discardItem = NSMenuItem(
            title: MeetingLiveViewAffordancePolicy.discardRecordingMenuTitle,
            action: #selector(handleMenuDiscard),
            keyEquivalent: ""
        )
        discardItem.target = self
        menu.addItem(discardItem)

        return menu
    }

    @objc private func handleMenuToggleTranscript() {
        handleLiveViewTapped()
    }

    @objc private func handleMenuTogglePin() {
        let pinned = !MeetingOverlayPillPreferences.keepControlsVisible()
        MeetingOverlayPillPreferences.setKeepControlsVisible(pinned)
        if pinned {
            bloomFromRest()
        } else {
            scheduleRestIfNeeded()
        }
        pushToView()
    }

    @objc private func handleMenuDiscard() {
        handleDiscardRequested()
    }

    private func currentDrawerHeight() -> CGFloat {
        activeDrawerHeightOverride ?? CGFloat(MeetingLiveTranscriptPreferences.preferredDrawerHeight())
    }

    private func handleDrawerResizeBegan() {
        guard state == .recording, isTranscriptExpanded else { return }
        let height = currentDrawerHeight()
        drawerResizeBaseHeight = height
        activeDrawerHeightOverride = height
    }

    private func handleDrawerResizeChanged(_ delta: CGFloat) {
        guard let base = drawerResizeBaseHeight, let panel, panel.isVisible else { return }
        var height = CGFloat(MeetingLiveTranscriptPreferences.clampedDrawerHeight(Double(base + delta)))

        var frame = panel.frame
        let top = frame.origin.y + frame.height
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            height = min(height, top - visible.minY - 8 - MeetingOverlayTokens.panelHeight)
        }

        activeDrawerHeightOverride = height
        let total = MeetingOverlayTokens.panelHeight + height
        frame.origin.y = top - total
        frame.size.height = total
        // Direct, unanimated frame tracking while the user drags; the size
        // memo keeps duration ticks from animating back mid-drag.
        panel.setFrame(frame, display: true)
        lastRequestedPanelSize = frame.size
    }

    private func handleDrawerResizeEnded() {
        if let height = activeDrawerHeightOverride {
            MeetingLiveTranscriptPreferences.setPreferredDrawerHeight(Double(height))
        }
        drawerResizeBaseHeight = nil
        activeDrawerHeightOverride = nil
    }

    private func handleCopyTranscriptTapped() {
        let text = makeTranscriptPlainText()
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        rootView?.flashTranscriptCopyFeedback()
    }

    private func makeTranscriptPlainText() -> String {
        LiveTranscriptPlainTextRenderer.makeTranscriptPlainText(
            finals: latestTranscriptFinals,
            partials: latestTranscriptPartials
        )
    }

    private func dismissPrompt() {
        promptCountdownTask?.cancel()
        missedCallPrompt = nil
        promptKind = nil
        currentPrompt = nil
        state = .idle
        hidePanel()
    }

    private func schedulePromptCountdown() {
        promptCountdownTask?.cancel()
        promptCountdownTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while self.promptSecondsRemaining > 0 {
                self.refreshPromptCountdownDisplay()
                self.pushToView()

                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.promptSecondsRemaining -= 1
            }

            self.handlePromptCountdownExpired()
        }
    }

    private func refreshPromptCountdownDisplay() {
        switch promptKind {
        case .systemAudio:
            if let warning = systemAudioDegradationWarning {
                currentPrompt = systemAudioWarningPromptDisplay(warning: warning)
            }
        case .audioInactivity:
            let warning = meetingSession?.audioInactivityWarning
                ?? MeetingAudioInactivityWarning(
                    inactiveDuration: 5 * 60,
                    countdownSeconds: max(1, promptSecondsRemaining)
                )
            currentPrompt = audioInactivityPromptDisplay(
                warning: warning,
                countdownSeconds: promptSecondsRemaining
            )
        case .micBoost:
            currentPrompt = micBoostPromptDisplay()
        case .audioRoute:
            if let outcome = audioRouteWarningOutcome {
                currentPrompt = audioRouteWarningPromptDisplay(outcome: outcome)
            }
        case .missedCall:
            if let call = missedCallPrompt {
                currentPrompt = missedCallPromptDisplay(call: call)
            }
        case .none:
            break
        }
    }

    private func handlePromptCountdownExpired() {
        switch promptKind {
        case .systemAudio:
            return
        case .micBoost:
            // Defensive no-op: a countdown is never scheduled for this kind,
            // and expiry must never auto-enable VPIO.
            return
        case .audioRoute:
            return
        case .audioInactivity:
            guard meetingSession?.audioInactivityWarning?.automaticStopAllowed != false else {
                return
            }
            Task { @MainActor [weak self] in
                guard let session = self?.meetingSession else { return }
                await session.endRecordingFromAudioInactivityPrompt(automatic: true)
            }
        case .missedCall:
            onMissedCallNudgeResolved?(.expired)
            dismissPrompt()
        case .none:
            dismissPrompt()
        }
    }

    private func systemAudioWarningPromptDisplay(
        warning: MeetingSystemAudioDegradationWarning
    ) -> PromptDisplay {
        PromptDisplay(
            title: MeetingSystemAudioDegradationCopy.title(for: warning),
            detail: MeetingSystemAudioDegradationCopy.detail(for: warning),
            countdownText: "",
            secondaryTitle: "Keep Recording",
            secondaryAccessibilityLabel: "Acknowledge system audio warning and keep recording",
            primaryTitle: "End & Transcribe",
            primaryAccessibilityLabel: "End and transcribe the meeting"
        )
    }
    private func audioInactivityPromptDisplay(
        warning: MeetingAudioInactivityWarning,
        countdownSeconds: Int
    ) -> PromptDisplay {
        if warning.kind == .degradedRoute {
            return PromptDisplay(
                title: "Audio route changed",
                detail: "Mic or system audio looks muted. Transcripted is still recording.",
                countdownText: "",
                secondaryTitle: "Keep Recording",
                secondaryAccessibilityLabel: "Keep recording",
                primaryTitle: "End & Transcribe",
                primaryAccessibilityLabel: "End and transcribe meeting"
            )
        }

        return PromptDisplay(
            title: "No audio detected",
            detail: "No mic or system audio for \(formatInactiveDuration(warning.inactiveDuration)).",
            countdownText: "Ends in \(max(0, countdownSeconds))s",
            secondaryTitle: "Keep Recording",
            secondaryAccessibilityLabel: "Keep recording",
            primaryTitle: "End & Transcribe",
            primaryAccessibilityLabel: "End and transcribe meeting"
        )
    }

    private func audioRouteWarningPromptDisplay(
        outcome: CaptureRouteStabilizationOutcome
    ) -> PromptDisplay {
        let detail: String
        switch outcome {
        case .switchedToBuiltIn:
            detail = "Using the built-in mic while keeping Bluetooth output."
        case .builtInUnavailable, .switchFailed:
            detail = "Choose a built-in mic in System Settings, or keep recording."
        case .notNeeded:
            detail = "Transcripted is still recording."
        }

        return PromptDisplay(
            title: "Bluetooth mic is unstable",
            detail: detail,
            countdownText: "",
            secondaryTitle: "Keep Recording",
            secondaryAccessibilityLabel: "Keep recording with the current audio input",
            primaryTitle: "End & Transcribe",
            primaryAccessibilityLabel: "End and transcribe meeting"
        )
    }

    // The prompt panel renders `detail` as a single truncating line (~336pt
    // at 11pt medium; fixed MeetingOverlayTokens.promptHeight). The ducking
    // trade-off disclosure must be the detail on its own and fit untruncated
    // — the user has to see the cost before consenting to VPIO — so the
    // cause lives in the title instead.
    private func micBoostPromptDisplay() -> PromptDisplay {
        PromptDisplay(
            title: "Mic is very quiet — another app's call",
            detail: "Boosting may make other apps' audio slightly quieter.",
            countdownText: "",
            secondaryTitle: "Not now",
            secondaryAccessibilityLabel: "Keep software mic boost",
            primaryTitle: "Boost Mic",
            primaryAccessibilityLabel: "Boost microphone with Apple voice processing"
        )
    }

    // Awareness, not blame: name the call surface and length, then point at the
    // two ways to capture next time. The panel renders `detail` as one
    // truncating line, so the copy stays short.
    private func missedCallPromptDisplay(call: MeetingPromptUnrecordedCall) -> PromptDisplay {
        let surface = call.provider == .googleMeet
            ? "That browser call"
            : "That \(call.provider.displayName) call"
        let length = formatInactiveDuration(call.duration)
        return PromptDisplay(
            title: "\(surface) wasn't recorded",
            detail: "About \(length). Tap Record on the prompt or press Option-M next time.",
            countdownText: "",
            secondaryTitle: "Don't show again",
            secondaryAccessibilityLabel: "Disable missed-call reminders",
            primaryTitle: "Got It",
            primaryAccessibilityLabel: "Dismiss missed-call reminder"
        )
    }

    private func formatInactiveDuration(_ duration: TimeInterval) -> String {
        MeetingDurationFormatter.formatInactiveDuration(duration)
    }

    // MARK: - View push

    private func pushToView() {
        resizePanelIfNeeded()
        rootView?.update(
            state: state,
            duration: currentDuration,
            micLevel: currentMicLevel,
            systemLevel: currentSystemLevel,
            participants: currentParticipants,
            warmupStatus: currentWarmupStatus,
            prompt: currentPrompt,
            systemAudioWarning: systemAudioDegradationWarning,
            isCondensed: isVisuallyCondensed,
            liveView: MeetingLiveViewAffordancePolicy.affordance(
                isRecording: state == .recording,
                isTranscriptVisible: isTranscriptExpanded
            ),
            isTranscriptExpanded: isTranscriptExpanded
        )
    }

    private func pushAudioLevelsToView() {
        rootView?.updateAudioLevels(
            micLevel: currentMicLevel,
            systemLevel: currentSystemLevel
        )
    }

    private func resizePanelIfNeeded() {
        guard let panel, panel.isVisible else {
            lastRequestedPanelSize = nil
            return
        }
        let desired = NSSize(width: currentPanelWidth(), height: currentPanelHeight())

        // Compare against the last *requested* size, not the live frame: the
        // per-second duration tick lands mid-animation, and re-targeting the
        // same size against an intermediate frame restarts the animation and
        // makes the resize stutter.
        if let last = lastRequestedPanelSize,
           abs(last.width - desired.width) < 0.5,
           abs(last.height - desired.height) < 0.5 {
            return
        }
        lastRequestedPanelSize = desired

        // Keep the top edge and horizontal center fixed; both are invariant
        // across our resizes, so reading them mid-animation is safe.
        let frame = panel.frame
        let top = frame.origin.y + frame.height
        var target = NSRect(
            x: frame.midX - desired.width / 2,
            y: top - desired.height,
            width: desired.width,
            height: desired.height
        )

        // Never grow past the bottom or sides of the screen the panel is on.
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            target.origin.y = max(target.origin.y, visible.minY + 8)
            target.origin.x = min(
                max(target.origin.x, visible.minX + 8),
                visible.maxX - target.width - 8
            )
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = AccessibilityDisplayPolicy.motionDuration(0.20)
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }
    }
}

@available(macOS 14.0, *)
private extension MeetingPromptOverlayPromptState {
    init(_ state: MeetingOverlayController.OverlayState) {
        switch state {
        case .idle:
            self = .idle
        case .prompt:
            self = .prompt
        case .preparing:
            self = .preparing
        case .recording:
            self = .recording
        case .transcribing:
            self = .transcribing
        case .saved:
            self = .saved
        case .error:
            self = .error
        }
    }
}
