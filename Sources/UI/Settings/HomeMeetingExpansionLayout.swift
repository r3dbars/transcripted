import Foundation

/// One action on an opened Meetings card (`QuietMeetingExpansion`).
enum HomeMeetingExpansionAction: Equatable, CaseIterable {
    case copy
    case revealInFinder
    case more
}

/// Where an opened Meetings card puts its actions, and what a click on its
/// header does. Foundation-only so the fast tests read the same values the
/// view lays out from.
enum HomeMeetingExpansionLayout {
    /// What a click on the card's header (title and time) does.
    enum HeaderClick: Equatable {
        case nothing
        case collapse
    }

    /// Actions in the header row, top right.
    static let headerActions: [HomeMeetingExpansionAction] = []

    /// Actions in the bar under the transcript.
    static let footerActions: [HomeMeetingExpansionAction] = [.copy, .revealInFinder, .more]

    static let headerClick: HeaderClick = .nothing
}
