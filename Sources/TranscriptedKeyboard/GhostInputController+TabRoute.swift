import InputMethodKit

extension GhostInputController {
    enum PlainTabRoute: Equatable {
        /// Try to accept the next word of the visible ghost.
        case acceptWord
        /// Swallow the Tab and leave the chained request running.
        case holdForChainedGhost
    }

    /// What a plain Tab does. Decided before the accept attempt, because
    /// that attempt cancels pending work and moves the schedule revision on,
    /// which would make a chained request look stale.
    static func plainTabRoute(ghostVisible: Bool, awaitingChainedGhost: Bool) -> PlainTabRoute {
        awaitingChainedGhost && !ghostVisible ? .holdForChainedGhost : .acceptWord
    }
}
