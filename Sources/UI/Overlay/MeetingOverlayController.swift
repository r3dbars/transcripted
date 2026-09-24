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
        /// Optional third, left-aligned button (Check Access on the system
        /// audio warning). Nil keeps the usual two-button prompt.
        var tertiaryTitle: String? = nil
        var tertiaryAccessibilityLabel: String? = nil
    }

    // MARK: - State

    private(set) var state: OverlayState = .idle {
        didSet {
            guard state != oldValue else { return }
            if case .error = state { return }
            snapshotFailedMeetingIDs()
        }
    }
    private var currentDuration: TimeInterval = 0
    private var currentMicLevel: Float = 0
    private var currentSystemLevel: Float = 0
    private var currentParticipants: [String] = []
    private var currentWarmupStatus: MeetingSessionController.ModelWarmupStatus = .ready
    private var currentPrompt: PromptDisplay?
    private var promptKind: PromptKind?
    private var audioRouteWarningOutcome: CaptureRouteStabilizationOutcome?
    private var systemAudioDegradationWarning: MeetingSystemAudioDegradationWarning?
    private var micOnlyNotice: MeetingMicOnlyNotice?
    // Audio inactivity drives its own per-second countdown Task
    // (schedulePromptCountdown). The combined warning subscription re-fires
    // on *any* of the four signals changing, so this mirror lets it tell
    // "the inactivity warning itself changed" apart from "some unrelated
    // signal changed while inactivity was already the winning prompt" —
    // only the former should restart the countdown.
    private var lastAppliedAudioInactivityWarning: MeetingAudioInactivityWarning?
    private var promptCountdownTask: Task<Void, Never>?
    private var promptSecondsRemaining = 0
    // Transcription progress for the "Transcribing meeting…" pill. Nil when
    // the pipeline has no number to show.
    private var currentTranscriptionProgress: Double?
    private var currentQueuedTranscriptionCount = 0
    // The transcript the "Saved to Markdown" pill opens. Cleared when a new
    // transcription starts, so Open never lands on the previous meeting; it
    // arrives once the saved file is restyled, which can be after the pill
    // appears (Open then just shows the Meetings page).
    private var savedTranscriptURL: URL?
    private var savedTranscriptTitle: String?
    // Which job's transcript the saved pill may take. The session's URL
    // lands after an async restyle and can be republished later (speaker
    // naming), so an earlier meeting's URL can arrive while a later one is
    // transcribing or already saved. Only accept a URL between this job's
    // `.transcriptSaved` and the next job's start, and never one already
    // seen for an earlier job (including one that arrived too late).
    private var isTranscriptionJobRunning = false
    private var acceptsSavedTranscript = false
    private var earlierJobTranscriptURLs: Set<URL> = []

    // Failed-meeting rows that existed before the current error, so the
    // error pill only offers Open for a failure that left a row behind (not
    // for an old, unrelated one). Refreshed on every non-error state.
    private var failedMeetingIDsBeforeError: Set<UUID> = []

    // MARK: - Panel & views

    private var panel: MeetingOverlayPanel?
    private var rootView: MeetingOverlayRootView?
    private var subscriptions: Set<AnyCancellable> = []
    private var autoHideTask: Task<Void, Never>?
    private var isShowingCancelConfirmation = false
    private var isRestingCondensed = false
    private var isPanelHovered = false
    private var restTask: Task<Void, Never>?
    private var lastRequestedPanelSize: NSSize?

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
    /// Opens the Meetings page, from the saved pill's or error pill's Open
    /// button. A transcript URL asks the page to expand that meeting.
    var onOpenMeetings: ((URL?) -> Void)?

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
        rootView.onCallAudioAction = { [weak self] in self?.handleCallAudioActionTapped() }
        rootView.onPanelHoverChanged = { [weak self] hovered in self?.handlePanelHoverChanged(hovered) }
        rootView.onStripMenuRequested = { [weak self] in self?.makeStripMenu() }
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
        snapshotFailedMeetingIDs(from: session)
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

        session.$displayStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                self?.applyDisplayStatus(status)
            }
            .store(in: &subscriptions)

        // Delivered on the next main-queue turn, so `lastSavedTitle` (set
        // right after the URL) is already current when this reads it.
        session.$lastSavedTranscriptURL
            .receive(on: DispatchQueue.main)
            .sink { [weak self] url in
                self?.applySavedTranscript(url: url)
            }
            .store(in: &subscriptions)

        // The error pill's Open depends on a failed-meeting row existing,
        // which can land just after the error state itself.
        session.$failedMeetings
            .map { Self.settledFailedMeetingIDs(in: $0) }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self, case .error = self.state else { return }
                self.pushToView()
            }
            .store(in: &subscriptions)

        session.$micOnlyNotice
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notice in
                self?.applyMicOnlyNotice(notice)
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

    }

    private func applyDisplayStatus(_ status: DisplayStatus) {
        // `percent(progress:)` already shows nothing for the idle, saved and
        // failed values (0 or 1), so no switch over every case is needed.
        let previousDetail = finishDetail
        currentTranscriptionProgress = status.progress
        currentQueuedTranscriptionCount = meetingSession?.queuedTranscriptionCount ?? 0

        switch status {
        case .gettingReady, .transcribing:
            if !isTranscriptionJobRunning {
                isTranscriptionJobRunning = true
                acceptsSavedTranscript = false
                if let savedTranscriptURL {
                    earlierJobTranscriptURLs.insert(savedTranscriptURL)
                }
                savedTranscriptURL = nil
                savedTranscriptTitle = nil
            }
        case .transcriptSaved:
            isTranscriptionJobRunning = false
            acceptsSavedTranscript = true
        case .failed:
            isTranscriptionJobRunning = false
        default:
            break
        }

        // Progress ticks often; only redraw when the text on the pill moves.
        if state == .transcribing, finishDetail != previousDetail {
            pushToView()
        }
    }

    private func applySavedTranscript(url: URL?) {
        guard let url, !earlierJobTranscriptURLs.contains(url) else { return }
        guard acceptsSavedTranscript else {
            // A late URL from a job that has already been replaced.
            earlierJobTranscriptURLs.insert(url)
            return
        }
        savedTranscriptURL = url
        savedTranscriptTitle = meetingSession?.lastSavedTitle
        if state == .saved {
            pushToView()
        }
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
            } else if state == .recording {
                pushToView()
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
    /// right after `.transcribing`, shown for `MeetingPillFinishPresentation.savedPillDwellSeconds`
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
        case .recording, .stoppingRecording:
            break
        default:
            micOnlyNotice = meetingSession?.micOnlyNotice
        }
        switch sessionState {
        case .idle:
            cancelRest()
            if state == .prompt {
                pushToView()
                break
            }
            promptKind = nil
            state = presentationState(session: sessionState, prompt: promptKind)
            hidePanel()
        case .loadingModels, .startingRecording:
            cancelRest()
            currentPrompt = nil
            promptKind = nil
            promptCountdownTask?.cancel()
            // A saved pill's dwell must not hide the next meeting's start.
            autoHideTask?.cancel()
            state = presentationState(session: sessionState, prompt: promptKind)
            showPanel()
        case .ready:
            cancelRest()
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
                scheduleAutoHide(after: MeetingPillFinishPresentation.savedPillDwellSeconds)
                break
            }
            if case .saved = state { break }
            if case .error = state { break }
            state = presentationState(session: sessionState, prompt: promptKind)
            hidePanel()
        case .recording, .stoppingRecording:
            if state != .recording {
                // Start from a clean hover state — enter events re-arm it.
                isPanelHovered = false
            }
            isRestingCondensed = false
            currentPrompt = nil
            promptKind = nil
            promptCountdownTask?.cancel()
            autoHideTask?.cancel()
            state = presentationState(session: sessionState, prompt: promptKind)
            showPanel()
            scheduleRestIfNeeded()
        case .transcribing:
            cancelRest()
            currentPrompt = nil
            promptKind = nil
            promptCountdownTask?.cancel()
            if state != .transcribing {
                autoHideTask?.cancel()
            }
            currentQueuedTranscriptionCount = meetingSession?.queuedTranscriptionCount ?? 0
            state = presentationState(session: sessionState, prompt: promptKind)
            showPanel()
        case .error:
            cancelRest()
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
        case .error:
            return MeetingOverlayTokens.errorHeight
        default:
            return MeetingOverlayTokens.panelHeight
        }
    }

    private func currentPanelWidth() -> CGFloat {
        switch state {
        case .recording where isVisuallyCondensed:
            return showsMicOnlyNote && micOnlyNotice == .callAudioOff
                ? MeetingOverlayTokens.condensedPillWidthWithMicOnlyCue
                : MeetingOverlayTokens.condensedPillWidth
        case .recording where showsMicOnlyNote:
            return MeetingOverlayTokens.recordingPanelWidthWithMicOnlyNote
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
        // The confirm sheet can outlive the recording. Stop or an unexpected
        // capture end may already be preserving audio — do not cancel then.
        guard case .recording = session.state else { return }

        Task { [weak session] in
            await session?.cancelRecording(reason: .discardButton)
        }
    }

    private func scheduleAutoHide(after seconds: Double) {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            // Someone reading the saved pill or reaching for Open keeps it
            // up. Checked here instead of trusting hover events, which can
            // be missed when the pill appears under the pointer.
            if case .saved = self.state, self.pointerIsOverPanel() {
                self.scheduleAutoHide(after: MeetingPillFinishPresentation.savedPillHoverOutDwellSeconds)
                return
            }
            self.hidePanel()
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
        switch state {
        case .saved:
            openMeetingsFromPill(transcriptURL: savedTranscriptURL)
            return
        case .error:
            openMeetingsFromPill(transcriptURL: nil)
            return
        default:
            break
        }
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

    private func openMeetingsFromPill(transcriptURL: URL?) {
        autoHideTask?.cancel()
        state = .idle
        hidePanel()
        pushToView()
        onOpenMeetings?(transcriptURL)
    }

    /// The pill's "Mic only" note, or Check Access on the system audio
    /// warning. Both send the user to turn call audio on.
    private func handleCallAudioActionTapped() {
        switch state {
        case .prompt:
            guard promptKind == .systemAudio else { return }
            meetingSession?.checkSystemAudioAccessFromWarning()
        case .recording:
            guard micOnlyNotice == .callAudioOff else { return }
            Task { @MainActor [weak self] in
                await self?.meetingSession?.turnOnCallAudioFromMicOnlyNotice()
            }
        default:
            break
        }
    }

    /// The note is a quiet label, not a prompt: it never blocks resting. It
    /// only wakes the pill when it changes to say call audio is now on, so
    /// the user sees the fix worked.
    private func applyMicOnlyNotice(_ notice: MeetingMicOnlyNotice?) {
        // Stop clears the session's note while the pill still shows through
        // teardown. Keep it until the pill leaves recording, so the pill
        // doesn't shrink and slide Stop under the cursor mid-stop.
        // `applySessionState` resyncs once the session moves on.
        if notice == nil, meetingSession?.state == .stoppingRecording { return }
        let previous = micOnlyNotice
        micOnlyNotice = notice
        if state == .recording,
           previous == .callAudioOff,
           notice == .callAudioOnForNextMeeting {
            bloomFromRest()
            scheduleRestIfNeeded()
        }
        pushToView()
    }

    /// The "Audio unverified" title owns the strip's middle when both apply.
    private var showsMicOnlyNote: Bool {
        micOnlyNotice != nil && systemAudioDegradationWarning?.cause != .unverified
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
            hasSystemAudioWarning: systemAudioDegradationWarning != nil
        )
    }

    private func scheduleRestIfNeeded() {
        restTask?.cancel()
        guard !isRestingCondensed,
              MeetingPillRestPolicy.canRest(
                isRecording: state == .recording,
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

    /// Wake the pill back to its full strip (prompts, hover, pin).
    private func bloomFromRest() {
        restTask?.cancel()
        restTask = nil
        isRestingCondensed = false
    }

    private func handlePanelHoverChanged(_ hovered: Bool) {
        guard hovered != isPanelHovered else { return }
        isPanelHovered = hovered
        // The saved pill has no rest/bloom; its auto-hide checks the
        // pointer itself.
        if case .saved = state { return }
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

        let pinItem = NSMenuItem(
            title: "Keep Controls Visible",
            action: #selector(handleMenuTogglePin),
            keyEquivalent: ""
        )
        pinItem.target = self
        pinItem.state = MeetingOverlayPillPreferences.keepControlsVisible() ? .on : .off
        menu.addItem(pinItem)

        // Overlay `.recording` also covers `.stoppingRecording` (keep the pill
        // up through teardown). Discard must require the session itself to
        // still be `.recording`, or the item no-ops after a stop starts.
        if case .recording = meetingSession?.state {
            menu.addItem(.separator())

            let discardItem = NSMenuItem(
                title: "Discard Recording…",
                action: #selector(handleMenuDiscard),
                keyEquivalent: ""
            )
            discardItem.target = self
            menu.addItem(discardItem)
        }

        return menu
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
        let offersCheckAccess = MeetingSystemAudioCheckAccessPolicy.offersCheckAccess(
            for: warning,
            status: TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem()
        )
        return PromptDisplay(
            title: MeetingSystemAudioDegradationCopy.title(for: warning),
            detail: MeetingSystemAudioDegradationCopy.detail(for: warning),
            countdownText: "",
            secondaryTitle: "Keep Recording",
            secondaryAccessibilityLabel: "Acknowledge system audio warning and keep recording",
            primaryTitle: "End & Transcribe",
            primaryAccessibilityLabel: "End and transcribe the meeting",
            tertiaryTitle: offersCheckAccess ? MeetingMicOnlyNoticeCopy.checkAccessTitle : nil,
            tertiaryAccessibilityLabel: offersCheckAccess ? MeetingMicOnlyNoticeCopy.checkAccessAccessibilityLabel : nil
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
        let shortcut = PhysicalDictationTriggerPreferences.displayString(
            for: PhysicalDictationTriggerPreferences.meetingBinding()
        )
        return PromptDisplay(
            title: "\(surface) wasn't recorded",
            detail: "About \(length). Click Record on the prompt or press \(shortcut) next time.",
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
            isCondensed: isVisuallyCondensed,
            systemAudioUnverified: systemAudioDegradationWarning?.cause == .unverified,
            finishDetail: finishDetail,
            hasFailedMeetingRowForError: hasFailedMeetingRowForCurrentError,
            micOnlyNotice: showsMicOnlyNote ? micOnlyNotice : nil
        )
    }

    private func snapshotFailedMeetingIDs(from session: MeetingSessionController? = nil) {
        let failedMeetings = (session ?? meetingSession)?.failedMeetings ?? []
        failedMeetingIDsBeforeError = Self.settledFailedMeetingIDs(in: failedMeetings)
    }

    /// Failed rows that aren't mid-retry. A retry keeps its row's id, so
    /// leaving retrying rows out lets a retry that fails again count as a
    /// new row for the error pill's Open.
    nonisolated private static func settledFailedMeetingIDs(in failedMeetings: [MeetingSessionController.FailedMeetingItem]) -> Set<UUID> {
        Set(failedMeetings.filter { !$0.isRetrying }.map(\.id))
    }

    private var hasFailedMeetingRowForCurrentError: Bool {
        guard let failedMeetings = meetingSession?.failedMeetings else { return false }
        return !Self.settledFailedMeetingIDs(in: failedMeetings).isSubset(of: failedMeetingIDsBeforeError)
    }

    /// Secondary text for the finish states: progress while transcribing,
    /// the meeting's name once saved.
    private var finishDetail: String {
        switch state {
        case .transcribing:
            return MeetingPillFinishPresentation.pillDetail(
                progress: currentTranscriptionProgress,
                queuedCount: currentQueuedTranscriptionCount
            )
        case .saved:
            return MeetingPillFinishPresentation.savedDetail(meetingTitle: savedTranscriptTitle)
        default:
            return ""
        }
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
