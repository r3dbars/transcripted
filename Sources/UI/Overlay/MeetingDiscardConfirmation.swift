// MeetingDiscardConfirmation.swift
// "Discard this recording?" asked on the island itself, in place of the
// modal alert that pulled Transcripted to the front mid-call. Exactly as
// safe: discarding still takes two deliberate clicks, and Escape, a timeout
// or anything going wrong keeps the recording. The discard itself is the
// same code path as before (MeetingSessionStateMachine.discardRecordingIfConfirmed).

import AppKit

/// The rules, Foundation-pure and clock-injected so the tests can run them.
struct MeetingDiscardConfirmPolicy: Equatable {
    /// How long the question waits before it gives up and keeps the recording.
    /// Hovering the island holds it.
    static let timeoutSeconds: Double = 10
    /// A Discard press this soon after the question appeared is ignored, so a
    /// double-click on the first Discard can't answer the second.
    static let armDelaySeconds: Double = 0.5

    enum Event: Equatable {
        /// The right-click "Discard recording…" or the auto-record note's Discard.
        case request(recordingID: UUID, now: TimeInterval)
        /// The red Discard in the question.
        case confirm(recordingID: UUID, now: TimeInterval)
        /// Keep, Escape, or the timeout.
        case keep
        /// The question's own timer ran out for this recording.
        case timedOut(recordingID: UUID)
    }

    enum Effect: Equatable {
        case none
        /// Put the question on the island.
        case ask
        /// Take the question away; the recording keeps going.
        case keep
        /// Run the discard for this recording.
        case discard(UUID)
    }

    struct Pending: Equatable {
        var recordingID: UUID
        var askedAt: TimeInterval
    }

    private(set) var pending: Pending?

    func isAsking(about recordingID: UUID?) -> Bool {
        recordingID != nil && pending?.recordingID == recordingID
    }

    mutating func handle(_ event: Event) -> Effect {
        switch event {
        case .request(let id, let now):
            // Asking again doesn't restart anything or skip a step.
            guard pending?.recordingID != id else { return .none }
            pending = Pending(recordingID: id, askedAt: now)
            return .ask
        case .confirm(let id, let now):
            guard let pending, pending.recordingID == id else { return .none }
            guard now - pending.askedAt >= Self.armDelaySeconds else { return .none }
            self.pending = nil
            return .discard(id)
        case .keep:
            guard pending != nil else { return .none }
            pending = nil
            return .keep
        case .timedOut(let id):
            guard pending?.recordingID == id else { return .none }
            pending = nil
            return .keep
        }
    }
}

enum MeetingDiscardConfirmCopy {
    static let title = "Discard this recording?"
    static let detail = "The audio is deleted and no transcript is saved."
    static let discardTitle = "Discard"
    static let keepTitle = "Keep"
    /// The right-click menu item that asks.
    static let menuTitle = "Discard recording…"

    /// Discard is red and sits at the far left, away from where the first
    /// Discard was; Keep is the white primary on the right and carries the
    /// ring, because keeping is what happens when time runs out.
    static func prompt(recordingID: UUID, secondsLeft: Double) -> NotchIslandMeetingContent.Prompt {
        NotchIslandMeetingContent.Prompt(
            title: title,
            detail: detail,
            countdown: "",
            primaryTitle: keepTitle,
            secondaryTitle: "",
            tertiaryTitle: discardTitle,
            identity: .discardConfirm(recordingID),
            primaryAccessibilityLabel: "Keep recording",
            tertiaryAccessibilityLabel: "Discard this recording and its audio",
            primaryRole: .primary,
            tertiaryRole: .destructive,
            countdownRing: NotchIslandCountdownRing(
                button: .primary,
                secondsLeft: secondsLeft,
                totalSeconds: MeetingDiscardConfirmPolicy.timeoutSeconds,
                holdsWhileHovered: true
            )
        )
    }
}

/// Runs the policy on the main actor: the timeout (held while the pointer is
/// on the island) and Escape. Owned by `MeetingOverlayController`.
@MainActor
final class MeetingDiscardConfirmation {
    private(set) var policy = MeetingDiscardConfirmPolicy()
    private(set) var secondsLeft = MeetingDiscardConfirmPolicy.timeoutSeconds
    private var timeoutTask: Task<Void, Never>?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    /// Asks the controller to redraw the island.
    var onChange: (() -> Void)?
    /// Whether the pointer rests on the island (holds the timeout).
    var isPointerOverIsland: () -> Bool = { false }

    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    func isAsking(about recordingID: UUID?) -> Bool { policy.isAsking(about: recordingID) }

    /// Puts the question up. Asking again starts it over (after one redraw
    /// without it, so a drop-down someone closed opens again), which only
    /// ever makes the next Discard wait longer.
    @discardableResult
    func ask(recordingID: UUID) -> Bool {
        if policy.isAsking(about: recordingID) { keep() }
        guard policy.handle(.request(recordingID: recordingID, now: Self.now())) == .ask else { return false }
        secondsLeft = MeetingDiscardConfirmPolicy.timeoutSeconds
        startTimeout(for: recordingID)
        installEscape()
        onChange?()
        return true
    }

    /// The red Discard. True only when this press may discard.
    func confirm(recordingID: UUID) -> Bool {
        guard policy.handle(.confirm(recordingID: recordingID, now: Self.now())) == .discard(recordingID) else { return false }
        tearDown()
        onChange?()
        return true
    }

    func keep() {
        guard policy.handle(.keep) == .keep else { return }
        tearDown()
        onChange?()
    }

    private func startTimeout(for recordingID: UUID) {
        timeoutTask?.cancel()
        timeoutTask = Task { @MainActor [weak self] in
            while let self, self.secondsLeft > 0 {
                do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return }
                if !self.isPointerOverIsland() { self.secondsLeft -= 0.1 }
            }
            guard let self, !Task.isCancelled else { return }
            if self.policy.handle(.timedOut(recordingID: recordingID)) == .keep {
                self.tearDown()
                self.onChange?()
            }
        }
    }

    /// Escape keeps the recording, whichever app is in front. The island
    /// never takes the keyboard, so it listens without stealing focus.
    private func installEscape() {
        guard globalKeyMonitor == nil else { return }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor [weak self] in self?.keep() }
        }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor [weak self] in self?.keep() }
            }
            return event
        }
    }

    private func tearDown() {
        timeoutTask?.cancel()
        timeoutTask = nil
        secondsLeft = MeetingDiscardConfirmPolicy.timeoutSeconds
        if let globalKeyMonitor { NSEvent.removeMonitor(globalKeyMonitor) }
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        globalKeyMonitor = nil
        localKeyMonitor = nil
    }
}
