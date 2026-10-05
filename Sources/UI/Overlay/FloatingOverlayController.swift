// FloatingOverlayController.swift
// Dictation state machine, timers, and global Escape monitor. The Notch
// island draws every dictation; this controller pushes it plain snapshots.

import AppKit
import Combine
import TranscriptedCore

@MainActor
class FloatingOverlayController {
    struct LoadingPresentation {
        let title: String
        let detail: String
        let progress: Double
        let status: String?

        static let initial = LoadingPresentation(
            title: "Warming up",
            detail: "Dictation starts automatically as soon as the voice model is ready.",
            progress: 0.08,
            status: "Starting up"
        )
    }

    enum SessionMode {
        case dictation
    }

    enum OverlayState {
        case idle
        case starting     // Microphone start requested — cancellable before recording flips on
        case loading      // Voice model still loading — waiting for readiness
        case listening    // Recording dictation
        case drafting     // Processing dictation
        case success      // Finished successfully — brief confirmation before dismiss

        var isActiveDictationState: Bool {
            switch self {
            case .starting, .loading, .listening:
                return true
            case .idle, .drafting, .success:
                return false
            }
        }
    }

    /// How a drafting-state message should read: a real problem, or a calm
    /// "your text is safe on the clipboard" fallback that is not the user's fault.
    enum MessageTone {
        case error
        case notice
        /// The text was saved, just not pasted (the 15-minute cap). Good news,
        /// so no warning triangle and no shake.
        case saved
    }

    var listeningNotice = "" {
        didSet {
            guard listeningNotice != oldValue else { return }
            pushStateToIsland()
        }
    }

    // MARK: - State (plain vars with didSet — no @Published, no ObservableObject)

    var state: OverlayState = .idle {
        didSet {
            guard state != oldValue else { return }
            if state != .drafting { clearNotPasted() }
            updateEscapeCancelTracking()
            if state.isActiveDictationState {
                cancelPendingHideForActiveDictation()
            }
            pushStateToIsland()
        }
    }
    var isVisible = false
    var errorMessage: String = ""
    private var messageTone: MessageTone = .error
    /// True while the message on screen is only a passing note about a take
    /// that went fine (no speech heard, "press Return to send"), so a press
    /// waiting for the next take may start over it. Any other message stays.
    var messageCanGiveWayToNextStart = false
    private var errorActionTitle: String?
    private var errorActionHandler: (() -> Void)?
    /// A dictation that didn't paste: its words, shown in the island, and
    /// what the island's Paste button does. Kept apart from the actionable
    /// error handler so closing the notice leaves the text on the clipboard.
    private var notPastedText: String?
    private var notPastedPasteHandler: (() -> Void)?
    private var notPastedActionTitle = "Paste"
    private var notPastedHint: String?
    private var notPastedKeyMonitor: Any?
    static let notPastedDismissSeconds: Double = 15
    var loadingElapsedSeconds: Int = 0 {
        didSet { pushStateToIsland() }
    }
    var loadingPresentation: LoadingPresentation = .initial {
        didSet { pushStateToIsland() }
    }
    private var successTitle: String = "Pasted"
    /// Closure for Escape during active dictation overlay states.
    var onEscapeDuringSession: (() -> Void)?
    var onStopListening: (() -> Void)?
    var onActionableMessageDiscarded: (() -> Void)?
    /// Every Esc during an active session, before the discard decision.
    var onEscapeKeyDuringSession: (() -> Void)?

    // MARK: - Monitors

    private var escapeMonitor: Any?

    /// Epoch — invalidated on every showPanel(), checked in async _performHide()
    private var hideGeneration = SupersessionEpoch()

    /// Combine subscriptions for engine state → island updates
    private var subscriptions = Set<AnyCancellable>()

    deinit {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
        }
        errorDismissTask?.cancel()
        loadingTimerTask?.cancel()
        successDismissTask?.cancel()
        escapeConfirmResetTask?.cancel()
    }

    var sttRouter: STTRouter?

    /// Draws the session. The app always sets it; when it is nil (tests),
    /// the state machine still runs and nothing shows.
    weak var island: NotchIslandController? {
        didSet {
            island?.dictationActionHandler = { [weak self] action in
                self?.handleIslandAction(action)
            }
        }
    }
    /// The app the words go to, for the island's "Inserting into" line.
    private var islandSourceApp: NSRunningApplication?

    private var isIslandMode: Bool {
        island != nil
    }

    // MARK: - Setup

    func setup(sttRouter: STTRouter) {
        guard self.sttRouter == nil else {
            EventReporter.shared.capture(level: .warning, engine: "overlay", event: "setup_called_twice",
                message: "setup() called twice — ignoring")
            return
        }
        self.sttRouter = sttRouter
        LiveDictationCaptions.shared.attach(router: sttRouter)

        // Meter readings arrive on the main actor as they're published, with
        // no second hop, so the island never gets them in bunches.
        sttRouter.audioLevels.readings
            .sink { [weak self] reading in
                guard let self, self.isIslandMode else { return }
                self.island?.updateDictationLevel(DictationMeterPolicy.presentation(
                    isListening: self.state == .listening, sttIsRecording: sttRouter.isRecording, reading: reading
                ))
            }
            .store(in: &subscriptions)

        sttRouter.$isRecording
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.pushStateToIsland()
            }
            .store(in: &subscriptions)

    }

    // MARK: - State → Island Push

    private func pushStateToIsland() {
        guard let island else { return }
        guard isIslandMode, isVisible else {
            island.updateDictation(nil, targetApp: nil)
            return
        }
        island.updateDictation(islandContent(), targetApp: islandSourceApp)
    }

    private func islandContent() -> NotchIslandDictationContent? {
        let phase: NotchIslandDictationContent.Phase
        switch state {
        case .idle:
            return nil
        case .starting:
            phase = .starting
        case .loading:
            // Only a model download has a real number ("42% downloaded").
            let downloaded = loadingPresentation.status
                .flatMap { $0.hasSuffix("% downloaded") ? $0.split(separator: "%").first : nil }
                .flatMap { Double($0) }
                .map { $0 / 100 }
            phase = .loading(
                title: loadingPresentation.title,
                detail: loadingPresentation.detail,
                progress: downloaded
            )
        case .listening:
            phase = .listening
        case .drafting where errorMessage.isEmpty:
            phase = .writing
        case .drafting:
            let tone: NotchIslandDictationContent.Message.Tone
            switch messageTone {
            case .error:
                tone = messageCanGiveWayToNextStart ? .noSpeech : .error
            case .notice:
                tone = .notice
            case .saved:
                tone = .saved
            }
            phase = .message(.init(
                tone: tone,
                text: errorMessage,
                actionTitle: notPastedText != nil ? notPastedActionTitle : errorActionTitle,
                preview: notPastedText,
                dismissSeconds: notPastedText != nil ? Self.notPastedDismissSeconds : nil,
                hint: notPastedText != nil ? notPastedHint : nil
            ))
        case .success:
            phase = .success(title: successTitle)
        }
        return NotchIslandDictationContent(
            phase: phase,
            notice: listeningNotice,
            targetAppName: islandSourceApp?.localizedName
        )
    }

    private func handleIslandAction(_ action: NotchIslandAction) {
        switch action {
        case .dictationStop:
            guard state == .listening else { return }
            onStopListening?()
        case .dictationCancel:
            guard state.isActiveDictationState else { return }
            clearEscapeConfirmation()
            onEscapeDuringSession?()
        case .dictationMessageAction:
            if let paste = notPastedPasteHandler {
                paste()
                return
            }
            let handler = errorActionHandler
            clearActionableErrorWithoutHiding()
            handler?()
        case .dictationDismissMessage:
            dismissError()
        default:
            break
        }
    }

    // MARK: - Show/Hide

    /// Shows the session in the island. `anchorRect` is kept for callers;
    /// the island picks its own place.
    func showPanel(near sourceApp: NSRunningApplication?, anchorRect: NSRect? = nil) {
        // Invalidate any pending async _performHide() from a previous session's animation
        hideGeneration.invalidate()

        // Cancel stale timers from a previous session
        errorDismissTask?.cancel()
        errorDismissTask = nil
        loadingTimerTask?.cancel()
        loadingTimerTask = nil
        successDismissTask?.cancel()
        successDismissTask = nil

        islandSourceApp = sourceApp
        isVisible = true
        pushStateToIsland()
        installEscapeMonitor()
    }

    /// The island sizes itself; kept so callers that used to shrink the old
    /// panel after loading don't need to change.
    func resizePanelToCompact() {}

    func showStartingState(near sourceApp: NSRunningApplication?, anchorRect: NSRect? = nil) {
        errorDismissTask?.cancel()
        errorDismissTask = nil
        loadingTimerTask?.cancel()
        loadingTimerTask = nil
        successDismissTask?.cancel()
        successDismissTask = nil
        errorMessage = ""
        messageTone = .error
        discardActionableMessageIfNeeded()
        listeningNotice = ""
        state = .starting
        if !isVisible {
            showPanel(near: sourceApp, anchorRect: anchorRect)
        }
    }

    private func cancelPendingHideForActiveDictation() {
        hideGeneration.invalidate()
        successDismissTask?.cancel()
        successDismissTask = nil
    }

    /// The earliest show on a key press, before the start's checks run.
    func showIslandStartingStateIfSelected(near sourceApp: NSRunningApplication?) {
        guard isIslandMode, !state.isActiveDictationState else { return }
        showStartingState(near: sourceApp)
    }

    // MARK: - Hide

    func hideWithConfirmAnimation(completion: (() -> Void)? = nil) {
        completion?()
        _performHide()
    }

    func hideWithCancelAnimation() {
        _performHide()
    }

    // MARK: - Error & Loading

    private var errorDismissTask: Task<Void, Never>?
    private var loadingTimerTask: Task<Void, Never>?
    private var successDismissTask: Task<Void, Never>?

    func showLoadingState(
        near sourceApp: NSRunningApplication? = nil,
        presentation: LoadingPresentation? = nil,
        anchorRect: NSRect? = nil
    ) {
        errorDismissTask?.cancel()
        errorMessage = ""
        messageTone = .error
        discardActionableMessageIfNeeded()
        if let presentation {
            loadingPresentation = presentation
        }
        let enteringLoading = state != .loading
        if enteringLoading {
            loadingElapsedSeconds = 0
        }
        state = .loading
        if !isVisible {
            showPanel(near: sourceApp, anchorRect: anchorRect)
        }
        if enteringLoading || loadingTimerTask == nil {
            loadingTimerTask?.cancel()
            loadingTimerTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    guard let self = self, !Task.isCancelled, self.state == .loading else { break }
                    self.loadingElapsedSeconds += 1
                }
            }
        }
    }

    func showError(
        _ message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        showMessage(message, tone: .error, actionTitle: actionTitle, action: action)
    }

    /// Calm variant of showError for "your text is on the clipboard" fallbacks:
    /// clipboard icon instead of a warning triangle, a longer dwell so the
    /// ⌘V instruction stays readable, and a clean fade instead of the shake.
    func showClipboardNotice(_ message: String) {
        showMessage(message, tone: .notice)
    }

    /// A dictation that didn't paste (no text box, or focus moved). The
    /// island shows the words, a Paste button, and a ring that runs down to
    /// the close; pressing ⌘V elsewhere steps it aside. Without an island
    /// (tests) it falls back to the plain clipboard notice.
    /// `unconfirmed` is for a paste that may well have landed (the target
    /// read the clipboard too late to prove it): the island says "Maybe
    /// pasted" so the Paste button doesn't read as the fix and double it.
    func showNotPastedNotice(
        _ text: String,
        fallbackMessage: String,
        unconfirmed: Bool = false,
        paste: @escaping () -> Void
    ) {
        guard isIslandMode else {
            showClipboardNotice(fallbackMessage)
            return
        }
        showMessage(unconfirmed ? "Maybe pasted" : "Not pasted", tone: .notice, notPasted: NotPastedNotice(
            text: text,
            actionTitle: "Paste",
            hint: unconfirmed ? "If the words aren\u{2019}t there, paste them again." : nil,
            watchesForManualPaste: true,
            action: paste
        ))
    }

    /// Paste-back didn't run because the clipboard held something it couldn't
    /// set aside, so the words were never put on it. The island shows them
    /// with a Copy button (the one step that replaces what's on the
    /// clipboard, only when asked). Without an island it shows the error.
    func showClipboardBusyNotice(_ text: String, fallbackMessage: String, copy: @escaping () -> Void) {
        guard isIslandMode else {
            showError(fallbackMessage)
            return
        }
        showMessage("Not pasted", tone: .notice, notPasted: NotPastedNotice(
            text: text,
            actionTitle: "Copy",
            hint: "Your clipboard holds something too big to set aside.",
            watchesForManualPaste: false,
            action: copy
        ))
    }

    private struct NotPastedNotice {
        let text: String
        let actionTitle: String
        let hint: String?
        let watchesForManualPaste: Bool
        let action: () -> Void
    }

    private func clearNotPasted() {
        notPastedText = nil
        notPastedPasteHandler = nil
        notPastedActionTitle = "Paste"
        notPastedHint = nil
        if let notPastedKeyMonitor {
            NSEvent.removeMonitor(notPastedKeyMonitor)
            self.notPastedKeyMonitor = nil
        }
    }

    /// Watches for the user's own ⌘V in another app while the words are
    /// still on the clipboard. Seeing the keypress proves nothing about where
    /// the words went, so the notice just steps aside. It never turns into
    /// "Pasted".
    private func watchForManualPaste(of text: String) {
        notPastedKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command, event.charactersIgnoringModifiers?.lowercased() == "v" else { return }
            Task { @MainActor [weak self] in
                guard let self, self.notPastedText == text, self.state == .drafting,
                      NSPasteboard.general.string(forType: .string) == text else { return }
                self.dismissError()
            }
        }
    }

    /// Calm "it's saved" message, with an optional action such as Paste It.
    func showSavedNotice(
        _ message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        showMessage(message, tone: .saved, actionTitle: actionTitle, action: action)
    }

    private func showMessage(
        _ message: String,
        tone: MessageTone,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil,
        notPasted: NotPastedNotice? = nil
    ) {
        errorDismissTask?.cancel()
        clearNotPasted()
        if let notPasted {
            notPastedText = notPasted.text
            notPastedPasteHandler = notPasted.action
            notPastedActionTitle = notPasted.actionTitle
            notPastedHint = notPasted.hint
            if notPasted.watchesForManualPaste {
                watchForManualPaste(of: notPasted.text)
            }
        }
        loadingTimerTask?.cancel()
        loadingTimerTask = nil
        discardActionableMessageIfNeeded()
        errorMessage = message
        messageTone = tone
        messageCanGiveWayToNextStart = false
        errorActionTitle = actionTitle
        errorActionHandler = action
        state = .drafting
        if !isVisible {
            showPanel(near: nil)
        }
        pushStateToIsland()  // Force update for error message
        if notPasted != nil {
            // Runs down with the island's ring, and holds while hovered.
            errorDismissTask = Task { @MainActor [weak self] in
                var remaining = Self.notPastedDismissSeconds
                while remaining > 0 {
                    do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                    guard let self else { return }
                    if !self.isMouseOverPanel { remaining -= 0.1 }
                }
                guard let self, !self.errorMessage.isEmpty else { return }
                self.dismissError()
            }
            return
        }
        guard actionTitle == nil else { return }
        let dismissDelay = TranscriptedConstants.messageDismissDelay(
            base: tone != .error
                ? TranscriptedConstants.clipboardNoticeDismissDelay
                : TranscriptedConstants.errorDismissDelay,
            characterCount: message.count
        )
        errorDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: dismissDelay)
                // Hovering the island holds the message so it can be read, up
                // to a cap, in case the pointer just sits there.
                var heldNanoseconds: UInt64 = 0
                while self?.isMouseOverPanel == true, heldNanoseconds < Self.messageHoverHoldLimit {
                    try await Task.sleep(nanoseconds: 300_000_000)
                    heldNanoseconds += 300_000_000
                }
            } catch { return }
            guard let self = self, !self.errorMessage.isEmpty else { return }
            self.dismissError()
        }
    }

    private static let messageHoverHoldLimit: UInt64 = 30_000_000_000  // 30 s

    private var isMouseOverPanel: Bool {
        isVisible && island?.isPointerOverIsland == true
    }

    func dismissError() {
        guard state == .drafting, !errorMessage.isEmpty else { return }
        clearNotPasted()
        errorDismissTask?.cancel()
        errorDismissTask = nil
        errorMessage = ""
        discardActionableMessageIfNeeded()
        // Only real problems shake on the way out.
        if messageTone == .error {
            hideWithCancelAnimation()
        } else {
            hideWithConfirmAnimation()
        }
    }

    private func discardActionableMessageIfNeeded() {
        let hadAction = errorActionHandler != nil
        errorActionTitle = nil
        errorActionHandler = nil
        if hadAction {
            onActionableMessageDiscarded?()
        }
    }

    private func clearActionableErrorWithoutHiding() {
        guard state == .drafting, !errorMessage.isEmpty else { return }
        clearNotPasted()
        errorDismissTask?.cancel()
        errorDismissTask = nil
        errorMessage = ""
        errorActionTitle = nil
        errorActionHandler = nil
        pushStateToIsland()
    }

    /// Fast dismiss for empty dictation audio — brief flash then clean fade (no shake).
    func showNoSpeechAndDismiss(
        trigger: String = "unknown",
        reason: DictationEmptyTranscriptionReason = .noSpeech,
        shortcutMode: DictationShortcutMode? = nil,
        silentMicName: String? = nil
    ) {
        errorDismissTask?.cancel()
        clearNotPasted()
        errorMessage = DictationNoSpeechPresentationPolicy.message(
            trigger: trigger,
            reason: reason,
            shortcutMode: shortcutMode,
            silentMicName: silentMicName
        )
        messageTone = .error
        messageCanGiveWayToNextStart = true
        discardActionableMessageIfNeeded()
        state = .drafting
        if !isVisible {
            showPanel(near: nil)
        }
        pushStateToIsland()
        // A muted mic needs reading and acting on, so it stays up as long
        // as other messages of its length; plain "no speech" is a flash.
        let dismissDelay = silentMicName == nil
            ? TranscriptedConstants.noSpeechDismissDelay
            : TranscriptedConstants.messageDismissDelay(
                base: TranscriptedConstants.errorDismissDelay,
                characterCount: errorMessage.count
            )
        errorDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: dismissDelay)
            } catch { return }
            guard let self = self else { return }
            self.errorMessage = ""
            self.hideWithConfirmAnimation()
        }
    }

    func showSuccessAndDismiss(title: String = "Pasted", completion: (() -> Void)? = nil) {
        errorDismissTask?.cancel()
        clearNotPasted()
        loadingTimerTask?.cancel()
        successDismissTask?.cancel()
        errorMessage = ""
        messageTone = .error
        discardActionableMessageIfNeeded()
        successTitle = title
        if isIslandMode {
            island?.noteDictationInserted(title: title)
        }
        state = .success
        if !isVisible {
            showPanel(near: nil)
        }
        pushStateToIsland()
        successDismissTask = Task { @MainActor [weak self] in
            do {
                // Let the "Pasted" confirmation stay readable before it eases out
                // instead of flashing past in under half a second.
                try await Task.sleep(nanoseconds: 800_000_000)
            } catch { return }
            guard let self else { return }
            self.hideWithConfirmAnimation(completion: completion)
        }
    }

    // MARK: - Internal Hide

    private func _performHide() {
        guard isVisible else { return }
        removeEscapeMonitor()

        isVisible = false
        errorDismissTask?.cancel()
        errorDismissTask = nil
        loadingTimerTask?.cancel()
        loadingTimerTask = nil
        successDismissTask?.cancel()
        successDismissTask = nil
        state = .idle
        errorMessage = ""
        messageTone = .error
        discardActionableMessageIfNeeded()
        listeningNotice = ""
        loadingPresentation = .initial
        islandSourceApp = nil
        pushStateToIsland()
    }

    // MARK: - System Wake Recovery & Periodic AG Refresh

    func handleSystemWake() {
        // No NSHostingView to recreate. AppKit views survive sleep/wake without corruption.
        // Reset state to idle as a safety measure.
        guard !isVisible else { return }
        state = .idle
    }

    // MARK: - Global Escape Monitor

    private func installEscapeMonitor() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Key repeat from a held Esc must not count as the confirming press.
            guard event.keyCode == 53, !event.isARepeat else { return }
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                guard self.state == .starting || self.state == .loading || self.state == .listening || self.state == .drafting else { return }
                if self.state == .drafting, !self.errorMessage.isEmpty {
                    self.dismissError()
                    return
                }
                self.handleEscapeDuringSession()
            }
        }
    }

    /// When the mic first started recording in this session; nil before that.
    /// Uptime, not wall clock, so a clock change can't make a long take look short.
    private var listeningStartedAt: TimeInterval?
    /// A first Esc on a long take that is waiting for a second press.
    private var escapeFirstPressAt: TimeInterval?
    private var escapeConfirmResetTask: Task<Void, Never>?

    private static func escapeClockNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func updateEscapeCancelTracking() {
        switch state {
        case .listening:
            if listeningStartedAt == nil {
                listeningStartedAt = Self.escapeClockNow()
            }
        case .idle, .starting, .success:
            listeningStartedAt = nil
            clearEscapeConfirmation()
        case .loading, .drafting:
            // Stopping is an explicit "keep": a prompt from before the stop
            // must not let the next Esc throw the take away while it
            // transcribes. A new Esc here asks again.
            clearEscapeConfirmation()
        }
    }

    /// A retained recording being readmitted for another transcription pass.
    /// It already holds real audio, so Esc must ask before discarding it even
    /// though the overlay only just returned to listening.
    func markRetainedRecordingForEscape() {
        listeningStartedAt = Self.escapeClockNow() - DictationEscapeCancelPolicy.instantCancelLimitSeconds
    }

    private func handleEscapeDuringSession() {
        onEscapeKeyDuringSession?()
        let now = Self.escapeClockNow()
        let decision = DictationEscapeCancelPolicy.decision(
            capturedSeconds: listeningStartedAt.map { now - $0 },
            secondsSinceFirstPress: escapeFirstPressAt.map { now - $0 }
        )
        switch decision {
        case .cancel:
            clearEscapeConfirmation()
            onEscapeDuringSession?()
        case .askToConfirm:
            escapeFirstPressAt = now
            listeningNotice = DictationEscapeCancelPolicy.confirmNotice
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [
                    .announcement: DictationEscapeCancelPolicy.confirmNotice,
                    .priority: NSAccessibilityPriorityLevel.high.rawValue,
                ]
            )
            escapeConfirmResetTask?.cancel()
            escapeConfirmResetTask = Task { @MainActor [weak self] in
                try? await Task.sleep(
                    nanoseconds: UInt64(DictationEscapeCancelPolicy.confirmWindowSeconds * 1_000_000_000)
                )
                guard !Task.isCancelled, let self else { return }
                self.clearEscapeConfirmation()
            }
        }
    }

    private func clearEscapeConfirmation() {
        escapeFirstPressAt = nil
        escapeConfirmResetTask?.cancel()
        escapeConfirmResetTask = nil
        if listeningNotice == DictationEscapeCancelPolicy.confirmNotice {
            listeningNotice = ""
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeMonitor {
            NSEvent.removeMonitor(monitor)
            escapeMonitor = nil
        }
    }
}
