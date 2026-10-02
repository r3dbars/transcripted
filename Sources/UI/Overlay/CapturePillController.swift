import AppKit

/// When an unanswered call prompt closes by itself. The clock stops while
/// the pointer is over the island or while the prompt waits behind a
/// dictation, and picks up where it left off. Waiting off screen is capped
/// (`offScreenHoldLimit` per prompt): a dictation error that waits for a
/// click, or a model download, must not keep a stale prompt around forever,
/// so once the cap runs out the prompt expires unanswered as it always did.
/// Plain values in and out so the fast tests can drive it with their own clock.
struct CallPromptTimeoutClock: Equatable {
    /// How long, in total, one prompt may wait behind a dictation.
    static let offScreenHoldLimit: TimeInterval = 120

    enum Step: Equatable {
        /// Nothing to change.
        case keepGoing
        /// Stop the running timeout and countdown. With `expiresIn`, the
        /// prompt still expires unanswered after that long unless the clock
        /// runs again first (it is waiting off screen); nil holds it open.
        case hold(expiresIn: TimeInterval?)
        /// (Re)start the timeout and countdown for this long.
        case run(seconds: TimeInterval)
    }

    private(set) var deadline: Date?
    /// How much was left when the clock stopped; nil while it runs.
    private(set) var heldRemaining: TimeInterval?
    private var hovered = false
    private var offScreen = false
    /// What is left of this prompt's off-screen allowance, and when its
    /// current off-screen stretch began.
    private var offScreenAllowance = CallPromptTimeoutClock.offScreenHoldLimit
    private var offScreenSince: Date?

    var isHeld: Bool { heldRemaining != nil }

    /// A new prompt gets the full timeout and a fresh off-screen allowance,
    /// but stays held if it is already waiting off screen (a newer prompt
    /// replacing one behind a dictation).
    mutating func start(timeout: TimeInterval, now: Date) -> Step {
        // Hover is reported only when it changes; a new prompt starts
        // unhovered, as the old pill did.
        hovered = false
        heldRemaining = nil
        offScreenAllowance = Self.offScreenHoldLimit
        offScreenSince = offScreen ? now : nil
        let seconds = max(1, timeout)
        deadline = now.addingTimeInterval(seconds)
        let step = settle(now: now)
        return step == .keepGoing ? .run(seconds: seconds) : step
    }

    mutating func setHovered(_ hovered: Bool, now: Date) -> Step {
        guard deadline != nil, hovered != self.hovered else { return .keepGoing }
        self.hovered = hovered
        return settle(now: now)
    }

    mutating func setOnScreen(_ onScreen: Bool, now: Date) -> Step {
        guard deadline != nil, onScreen == offScreen else { return .keepGoing }
        offScreen = !onScreen
        if offScreen {
            offScreenSince = now
        } else if let since = offScreenSince {
            offScreenAllowance -= max(0, now.timeIntervalSince(since))
            offScreenSince = nil
        }
        return settle(now: now)
    }

    /// The prompt was answered, expired, or taken down.
    mutating func stop() {
        self = CallPromptTimeoutClock()
    }

    private mutating func settle(now: Date) -> Step {
        if hovered || offScreen {
            if heldRemaining == nil, let deadline {
                heldRemaining = max(1, deadline.timeIntervalSince(now))
            }
            guard heldRemaining != nil else { return .keepGoing }
            // Hovering someone is reading it, so no cap; off screen, the
            // allowance left (measured from when this stretch began).
            guard offScreen else { return .hold(expiresIn: nil) }
            let spent = offScreenSince.map { max(0, now.timeIntervalSince($0)) } ?? 0
            return .hold(expiresIn: max(0, offScreenAllowance - spent))
        }
        guard let remaining = heldRemaining else { return .keepGoing }
        heldRemaining = nil
        deadline = now.addingTimeInterval(remaining)
        return .run(seconds: remaining)
    }
}

@available(macOS 14.0, *)
@MainActor
final class CapturePillController {
    private var representedCandidate: MeetingPromptDetector.Candidate?
    private var dismissTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?
    /// When the unanswered prompt closes by itself; it holds while the
    /// island is hovered or the prompt waits behind a dictation.
    private var timeoutClock = CallPromptTimeoutClock()

    var onRecord: ((MeetingPromptDetector.Candidate) -> Void)?
    var onDismiss: ((MeetingPromptDetector.Candidate) -> Void)?
    var onRemind: ((MeetingPromptDetector.Candidate) -> Void)?
    var onExpired: ((MeetingPromptDetector.Candidate) -> Void)?

    /// The notch island asks; without one (never, in the app) nothing is
    /// presented.
    weak var island: NotchIslandCallPromptPresenting? {
        didSet {
            island?.callActionHandler = { [weak self] action in
                switch action {
                case .callRecord: self?.record()
                case .callDismiss: self?.dismiss(notify: true)
                case .callRemind: self?.remind()
                default: break
                }
            }
            island?.callHoverHandler = { [weak self] hovered in
                guard let self, self.representedCandidate != nil else { return }
                self.apply(self.timeoutClock.setHovered(hovered, now: Date()))
            }
            island?.callVisibilityHandler = { [weak self] onScreen in
                guard let self, self.representedCandidate != nil else { return }
                self.apply(self.timeoutClock.setOnScreen(onScreen, now: Date()))
            }
        }
    }

    /// The island's ring around Not now stops while the pointer is over the
    /// island; the timeout behind it stops too, so the prompt never closes
    /// while someone is reading it, or while it waits behind a dictation
    /// where no one can see it.
    private func apply(_ step: CallPromptTimeoutClock.Step) {
        switch step {
        case .keepGoing:
            break
        case .hold(let expiresIn):
            dismissTask?.cancel()
            dismissTask = nil
            countdownTask?.cancel()
            countdownTask = nil
            if let expiresIn {
                // Waiting off screen: it still expires unanswered once the
                // off-screen allowance runs out.
                scheduleDismiss(timeout: expiresIn)
            }
        case .run(let seconds):
            scheduleDismiss(timeout: seconds)
            scheduleCountdown(seconds: max(1, Int(ceil(seconds))))
        }
    }

    deinit {
        dismissTask?.cancel()
        countdownTask?.cancel()
    }

    /// `detailOverride` replaces the candidate's detail line, for something
    /// the user needs to know before tapping Record (call audio is off).
    @discardableResult
    func present(
        candidate: MeetingPromptDetector.Candidate,
        timeout: TimeInterval = 30,
        detailOverride: String? = nil
    ) -> Bool {
        guard let island else { return false }

        representedCandidate = candidate
        let timeoutSeconds = max(1, Int(ceil(timeout)))
        // Start the clock first: showing the prompt reports whether it
        // is on screen, which may hold it straight away.
        apply(timeoutClock.start(timeout: timeout, now: Date()))
        island.updateCallPrompt(NotchIslandCallPromptContent(
            title: candidate.suggestedTranscriptTitle ?? candidate.title,
            detail: detailOverride ?? candidate.detail,
            secondsLeft: timeoutSeconds
        ))
        return true
    }

    func dismiss(notify: Bool) {
        dismissTask?.cancel()
        dismissTask = nil
        countdownTask?.cancel()
        countdownTask = nil

        timeoutClock.stop()
        let candidate = representedCandidate
        representedCandidate = nil
        island?.updateCallPrompt(nil)

        if notify, let candidate {
            onDismiss?(candidate)
        }
    }

    private func record() {
        guard let candidate = representedCandidate else { return }
        dismiss(notify: false)
        onRecord?(candidate)
    }

    private func remind() {
        guard let candidate = representedCandidate else { return }
        dismiss(notify: false)
        onRemind?(candidate)
    }

    private func scheduleDismiss(timeout: TimeInterval) {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor [weak self] in
            let nanoseconds = UInt64(max(1, timeout) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            guard let self, let candidate = self.representedCandidate else { return }
            self.dismiss(notify: false)
            self.onExpired?(candidate)
        }
    }

    private func scheduleCountdown(seconds: Int) {
        countdownTask?.cancel()
        countdownTask = Task { @MainActor [weak self] in
            var secondsRemaining = max(1, seconds)
            self?.island?.updateCallPromptSeconds(secondsRemaining)

            while secondsRemaining > 1 {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                secondsRemaining -= 1
                self?.island?.updateCallPromptSeconds(secondsRemaining)
            }
        }
    }
}
