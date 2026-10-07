// MeetingOverlayController.swift
// Owns the meeting's overlay state machine and pushes snapshots to the
// Notch island, which draws it.

import AppKit
import Combine
import TranscriptedCore

// MARK: - Controller

/// Subscribes to `MeetingSessionController` @Published state and pushes
/// `NotchIslandMeetingContent` snapshots to the Notch island.
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
    private var currentWarmupStatus: MeetingSessionController.ModelWarmupStatus = .ready
    var currentPrompt: PromptDisplay?
    /// Mirrors `MeetingSessionController.asksAboutCallAudioWhileRecording`.
    /// The session owns the ask and ties it to the start that raised it, so a
    /// start that fails before recording never leaves one for the next meeting.
    private var islandCallAudioAskPending = false
    var promptKind: PromptKind?
    var audioRouteWarningOutcome: CaptureRouteStabilizationOutcome?
    var systemAudioDegradationWarning: MeetingSystemAudioDegradationWarning?
    var micOnlyNotice: MeetingMicOnlyNotice?
    // Audio inactivity drives its own per-second countdown Task
    // (schedulePromptCountdown). The combined warning subscription re-fires
    // on *any* of the four signals changing, so this mirror lets it tell
    // "the inactivity warning itself changed" apart from "some unrelated
    // signal changed while inactivity was already the winning prompt" —
    // only the former should restart the countdown.
    var lastAppliedAudioInactivityWarning: MeetingAudioInactivityWarning?
    var promptCountdownTask: Task<Void, Never>?
    var promptSecondsRemaining = 0
    // Transcription progress for the "Transcribing meeting…" pill. Nil when
    // the pipeline has no number to show.
    private var currentTranscriptionProgress: Double?
    private var currentQueuedTranscriptionCount = 0
    // The transcript the "Saved to Markdown" pill opens. Cleared when a new
    // transcription starts, so Open never lands on the previous meeting; it
    // arrives once the saved file is restyled, which can be after the pill
    // appears (Open then just shows the Meetings page).
    var savedTranscriptURL: URL?
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

    // MARK: - Subscriptions & tasks

    private var isSetUp = false
    private var subscriptions: Set<AnyCancellable> = []
    var autoHideTask: Task<Void, Never>?
    /// Hides a "call audio is back" notice after a few seconds. Kept apart
    /// from `autoHideTask`, which hides the whole panel after a save.
    var systemAudioAutoHideTask: Task<Void, Never>?
    var systemAudioAutoHideWarning: MeetingSystemAudioDegradationWarning?
    var isShowingCancelConfirmation = false

    // The precedence lattice for these kinds lives in the pure
    // `MeetingPromptPriority.resolve` — kept in its own Foundation-pure file
    // (with the shared `MeetingWarningPromptKind` enum) so the root fast-test
    // runner can exercise it without pulling in this controller's AppKit/
    // MeetingSessionController dependencies.
    typealias PromptKind = MeetingWarningPromptKind

    // Kept for the countdown-refresh pass, which rebuilds the display each tick.
    var missedCallPrompt: MeetingPromptUnrecordedCall?
    private static let missedCallNudgeTimeoutSeconds = 30

    deinit {
        autoHideTask?.cancel()
        promptCountdownTask?.cancel()
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

    /// Draws the meeting. States, prompts and timers stay here.
    weak var island: NotchIslandController? {
        didSet {
            island?.meetingActionHandler = { [weak self] action in self?.handleIslandAction(action) }
            island?.meetingMenuProvider = { [weak self] in self?.makeStripMenu() }
        }
    }
    /// Whether the island is carrying the meeting.
    private var islandShown = false

    // MARK: - Setup

    /// Wire subscriptions; the island stays hidden until state becomes
    /// non-idle. Safe to call once at app launch; re-calls are ignored.
    func setup(meetingSession: MeetingSessionController) {
        guard !isSetUp else { return }
        isSetUp = true
        self.meetingSession = meetingSession
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

    /// The call prompt dismisses before its Record callback returns. Keep a
    /// visible, non-interactive status up while the app checks
    /// permissions, models, and the audio route so Record never looks ignored.
    func showDetectedMeetingStartInProgress() {
        autoHideTask?.cancel()
        promptCountdownTask?.cancel()
        currentPrompt = nil
        promptKind = nil
        currentWarmupStatus = .init(
            title: "Starting…",
            subtitle: "Checking your mic and call audio",
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
        promptSecondsRemaining = Self.missedCallNudgeTimeoutSeconds
        currentPrompt = missedCallPromptDisplay(call: call)
        state = .prompt
        showPanel()
        pushToView()
        schedulePromptCountdown()
        return true
    }

    // MARK: - Subscriptions

    func wireSubscriptions(to session: MeetingSessionController) {
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

        session.audioLevels.$micLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] level in
                self?.currentMicLevel = level
                self?.pushAudioLevelsToView()
            }
            .store(in: &subscriptions)

        session.audioLevels.$systemLevel
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

        session.$asksAboutCallAudioWhileRecording
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] asks in
                self?.applyCallAudioAsk(asks)
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
    func presentationState(
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
            if state == .prompt {
                pushToView()
                break
            }
            promptKind = nil
            state = presentationState(session: sessionState, prompt: promptKind)
            hidePanel()
        case .loadingModels, .startingRecording:
            currentPrompt = nil
            promptKind = nil
            promptCountdownTask?.cancel()
            // A saved pill's dwell must not hide the next meeting's start.
            autoHideTask?.cancel()
            state = presentationState(session: sessionState, prompt: promptKind)
            showPanel()
        case .ready:
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
            // A discarded accidental start saved nothing, so it must not
            // flash "Saved". It just goes away, like a cancel.
            if case .transcribing = state,
               meetingSession?.lastTerminalTranscriptionOutcome != .discarded {
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
            currentPrompt = nil
            promptKind = nil
            promptCountdownTask?.cancel()
            autoHideTask?.cancel()
            state = presentationState(session: sessionState, prompt: promptKind)
            showPanel()
        case .transcribing:
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
            currentPrompt = nil
            promptKind = nil
            promptCountdownTask?.cancel()
            autoHideTask?.cancel()
            state = presentationState(session: sessionState, prompt: promptKind)
            showPanel()
        }
        pushToView()
    }

    // MARK: - Island show/hide

    func showPanel() {
        guard island != nil else { return }
        islandShown = true
    }

    func hidePanel() {
        guard islandShown else { return }
        islandShown = false
        island?.updateMeeting(nil)
    }

    /// The note is a quiet label, not a prompt.
    private func applyMicOnlyNotice(_ notice: MeetingMicOnlyNotice?) {
        // Stop clears the session's note while the pill still shows through
        // teardown. Keep it until the pill leaves recording, so the pill
        // doesn't shrink and slide Stop under the cursor mid-stop.
        // `applySessionState` resyncs once the session moves on.
        if notice == nil, meetingSession?.state == .stoppingRecording { return }
        micOnlyNotice = notice
        pushToView()
    }

    /// The "Can't confirm call audio" title owns the strip's middle when both apply.
    private var showsMicOnlyNote: Bool {
        micOnlyNotice != nil && systemAudioDegradationWarning?.cause != .unverified
    }

    func pointerIsOverPanel() -> Bool {
        islandShown && island?.isPointerOverIsland == true
    }

    func dismissPrompt() {
        promptCountdownTask?.cancel()
        missedCallPrompt = nil
        promptKind = nil
        currentPrompt = nil
        state = .idle
        hidePanel()
    }

    // MARK: - Notch island

    private func islandContent() -> NotchIslandMeetingContent {
        let sessionState = meetingSession?.state
        let phase: NotchIslandMeetingContent.Phase
        switch state {
        case .idle:
            phase = .none
        case .prompt:
            // Warning prompts arrive mid-recording; the missed-call nudge
            // arrives with nothing recording.
            switch sessionState {
            case .recording?, .stoppingRecording?:
                phase = .recording
            default:
                phase = .none
            }
        case .preparing where currentWarmupStatus.progress >= 1:
            // Models are ready; the mic and call audio are what's starting.
            phase = .preparing(title: "Starting…", detail: "Checking your mic and call audio")
        case .preparing:
            phase = .preparing(
                title: currentWarmupStatus.title,
                detail: currentWarmupStatus.subtitle.isEmpty ? currentWarmupStatus.detail : currentWarmupStatus.subtitle
            )
        case .recording:
            phase = .recording
        case .transcribing:
            phase = .transcribing(
                progress: MeetingPillFinishPresentation.percent(progress: currentTranscriptionProgress).map { Double($0) / 100 },
                detail: finishDetail
            )
        case .saved:
            phase = .saved(title: savedTranscriptTitle)
        case .error(let message):
            let copy = MeetingFailureCopy.make(forMessage: message, shortErrorMessage: message, isRetryable: true)
            phase = .error(
                title: copy.title,
                message: copy.detail,
                canOpen: MeetingPillFinishPresentation.errorOffersOpenMeetings(
                    failureKind: MeetingFailureKind.classify(message: message),
                    hasFailedMeetingRowForError: hasFailedMeetingRowForCurrentError
                ),
                grantsSystemAudio: meetingSession?.systemAudioPermissionRecoveryNeeded == true
            )
        }
        let prompt = currentPrompt.map {
            NotchIslandMeetingContent.Prompt(
                title: $0.title,
                detail: $0.detail,
                countdown: $0.countdownText,
                primaryTitle: $0.primaryTitle,
                secondaryTitle: $0.secondaryTitle,
                tertiaryTitle: $0.tertiaryTitle
            )
        }
        var callAudioNote: NotchIslandMeetingContent.CallAudioNote?
        switch showsMicOnlyNote ? micOnlyNotice : nil {
        case .callAudioOff?:
            callAudioNote = .off
        case .callAudioOnForNextMeeting?:
            callAudioNote = .onForNextMeeting
        case nil:
            callAudioNote = nil
        }
        return NotchIslandMeetingContent(
            phase: phase,
            prompt: state == .prompt ? prompt : nil,
            duration: currentDuration,
            callAudioNote: callAudioNote,
            systemAudioUnverified: systemAudioDegradationWarning?.cause == .unverified,
            asksAboutCallAudio: islandCallAudioAskPending
        )
    }

    /// The session raised or dropped the "can't hear the other side" ask.
    /// It asks while the recording that started mic only runs; every meeting
    /// asks again.
    private func applyCallAudioAsk(_ asks: Bool) {
        guard asks != islandCallAudioAskPending else { return }
        islandCallAudioAskPending = asks
        pushToView()
    }

    private func handleIslandAction(_ action: NotchIslandAction) {
        switch action {
        case .meetingCallAudioDismiss:
            islandCallAudioAskPending = false
            meetingSession?.dismissCallAudioAsk()
            pushToView()
        case .meetingStop, .meetingDismissError:
            handleCloseTapped()
        case .meetingPrimary, .meetingOpen:
            handlePrimaryActionTapped()
        case .meetingSecondary:
            handleSecondaryActionTapped()
        case .meetingTertiary:
            handleCallAudioActionTapped()
        case .meetingCallAudio:
            // The "Mic only" chip, which can show under a warning prompt too.
            islandCallAudioAskPending = false
            meetingSession?.dismissCallAudioAsk()
            guard micOnlyNotice == .callAudioOff else {
                pushToView()
                return
            }
            Task { @MainActor [weak self] in
                await self?.meetingSession?.turnOnCallAudioFromMicOnlyNotice()
            }
        default:
            break
        }
    }

    // MARK: - View push

    func pushToView() {
        guard islandShown else { return }
        island?.updateMeeting(islandContent())
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
        guard islandShown else { return }
        island?.updateMeetingLevels(mic: currentMicLevel, system: currentSystemLevel)
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
