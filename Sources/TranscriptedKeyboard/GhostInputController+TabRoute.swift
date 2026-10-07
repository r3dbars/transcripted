import InputMethodKit

extension GhostInputController {
    enum PlainTabOutcome: Equatable {
        /// Swallowed while a chained request is still on its way.
        case held
        /// Accepted the next word of the visible ghost.
        case accepted
        /// Nothing to accept: the host gets the Tab.
        case passedToHost
    }

    /// What a plain Tab does. The hold is decided before the accept attempt,
    /// because that attempt cancels pending work and moves the schedule
    /// revision on, which would make a chained request look stale.
    static func routePlainTab(
        awaitingChainedGhost: () -> Bool,
        acceptWord: () -> Bool
    ) -> PlainTabOutcome {
        if awaitingChainedGhost() { return .held }
        return acceptWord() ? .accepted : .passedToHost
    }
}

/// The request a consumed accept chained, while it may still show a ghost.
/// In a calm-reveal (Electron) host the chained request first waits for the
/// host to commit the accepted text, so for that moment it has no pending
/// ticket yet; it still counts as on its way until its task starts.
struct ChainedTabHold {
    private(set) var chainedRevision: Int?
    private var taskNotStarted = false

    mutating func chained(revision: Int) {
        chainedRevision = revision
        taskNotStarted = true
    }

    /// Called when the chained schedule's task wakes, whether it goes on to
    /// read the field or bails. A stale task never clears a newer chain.
    mutating func taskStarted(revision: Int) {
        if revision == chainedRevision { taskNotStarted = false }
    }

    func isAwaitingGhost(scheduleRevision: Int, requestPending: Bool, ghostVisible: Bool) -> Bool {
        guard let chainedRevision, chainedRevision == scheduleRevision, !ghostVisible else { return false }
        return requestPending || taskNotStarted
    }
}
