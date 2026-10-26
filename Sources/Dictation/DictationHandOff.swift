import Foundation

/// A hand-off take: dictation that listens for another feature (today Write for Me's voice) and hands
/// the words back to it instead of pasting them. It never starts over the person's own dictation and
/// never stops it, and it's quiet: no dictation analytics (start, cancel or completion), no session-cap
/// events or log lines, no "Saved to Markdown" notice. The words are still saved to Dictations. Pure, so
/// tests pin it.
enum DictationHandOffPolicy {
    /// History records the words as saved without a paste.
    static let delivery: DictationDelivery = .savedWithoutPaste

    /// Only when nothing is dictating: a hand-off never takes over a take that's running or finishing.
    static func mayStart(isDictating: Bool) -> Bool {
        !isDictating
    }

    /// Whether the take `sessionID` is the hand-off one, so its words go back instead of being pasted.
    /// However it was stopped (the hand-off itself, the dictation key, the session cap), they go back.
    static func handsOff(sessionID: UUID, handOffSessionID: UUID?) -> Bool {
        handOffSessionID == sessionID
    }

    /// The dictation island stays hidden only while a hand-off take is starting (the card is its listening
    /// UI). Every other start shows it, whatever an earlier hand-off left behind.
    static func overlayIsQuiet(startingHandOff: Bool) -> Bool {
        startingHandOff
    }

    /// After a hand-off start: still hidden only if the take really started. A refused start (dictation
    /// busy, model not ready, a meeting) never leaves the island hidden for the next normal take.
    static func overlayIsQuiet(afterHandOffStarted started: Bool) -> Bool {
        started
    }

    /// The hand-off take to remember when a start is asked for. A hand-off start, or one while a take is still
    /// running or finishing, keeps it (that take's words must still go back to its card). Any other start
    /// forgets it, so the person's next take is never mistaken for an old hand-off, even in the counting
    /// that runs before the new take has its own session.
    static func handOffSession(onStartRequest current: UUID?, startingHandOff: Bool, isDictating: Bool) -> UUID? {
        startingHandOff || isDictating ? current : nil
    }

    /// Dictation's own analytics (`dictation_start_requested`, `dictation_started`, `dictation_cancelled`,
    /// `dictation_start_failed`) are for the person's dictation only, never a hand-off take.
    static func sendsAnalytics(isStartingHandOff: Bool, sessionID: UUID, handOffSessionID: UUID?) -> Bool {
        !isStartingHandOff && !handsOff(sessionID: sessionID, handOffSessionID: handOffSessionID)
    }

    /// The words of the hand-off take still waiting for the feature that started it: the take ended
    /// before it asked (the dictation key or the session cap stopped it, or nothing was heard). Each
    /// take's words are claimed once.
    static func canClaim(unclaimedSessionID: UUID?, handOffSessionID: UUID?) -> Bool {
        unclaimedSessionID != nil && unclaimedSessionID == handOffSessionID
    }

    /// Throwing a hand-off take away is only for one still recording. Once it's finishing, cancelling would
    /// also drop a press the person queued meanwhile, so it finishes and its words go unused.
    static func mayCancel(currentSessionID: UUID, handOffSessionID: UUID?, isDictating: Bool, isFinishing: Bool) -> Bool {
        !isFinishing && mayStop(currentSessionID: currentSessionID, handOffSessionID: handOffSessionID, isDictating: isDictating)
    }

    /// The feature that started a hand-off may stop it, and only it: never the person's own dictation.
    static func mayStop(currentSessionID: UUID, handOffSessionID: UUID?, isDictating: Bool) -> Bool {
        isDictating && handsOff(sessionID: currentSessionID, handOffSessionID: handOffSessionID)
    }
}

/// Finishing a transcribed hand-off take. The steps are all it does; there's no telemetry step.
@MainActor
enum DictationHandOffFinisher {
    struct Steps {
        /// Gives the words to the feature that asked for them.
        var deliver: (String) -> Void
        /// Saves them to Dictations. True when saved.
        var save: () async -> Bool
        /// The take is still the current one (not cancelled, no newer take started).
        var canPublish: () -> Bool
        /// Puts the dictation pill or island away without a notice.
        var hideOverlay: () -> Void
        /// Marks the take finished.
        var endSession: () -> Void
    }

    static func finish(text: String, steps: Steps) async {
        steps.deliver(text)
        _ = await steps.save()
        guard steps.canPublish() else { return }
        steps.hideOverlay()
        steps.endSession()
    }
}
