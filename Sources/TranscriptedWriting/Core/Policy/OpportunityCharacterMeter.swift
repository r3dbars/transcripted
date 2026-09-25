import Foundation

/// Counts the characters a writer authored between ghosts so each outcome
/// event's `opportunityCharacters` is a slice of real writing volume.
///
/// The old value was the length of the bounded context at the moment a
/// ghost appeared. In a 2,000-character document that showed ten ghosts, the
/// same 2,000 characters were counted ten times, so "net time saved per
/// thousand characters" divided by ten times the writing that happened and
/// made Tilde look far less useful than it was. This meter counts a
/// character once: every typed grapheme and every accepted character adds to
/// the running total, and each shown ghost takes the total and resets it.
/// The characters typed after the last ghost of a segment stay unattributed
/// rather than being charged to a ghost that never came.
public struct OpportunityCharacterMeter: Equatable, Sendable {
    public private(set) var authoredSinceLastOpportunity: Int = 0

    public init() {}

    public mutating func noteTyped(characters: Int = 1) {
        authoredSinceLastOpportunity += max(0, characters)
    }

    public mutating func noteAccepted(characters: Int) {
        authoredSinceLastOpportunity += max(0, characters)
    }

    /// The count for the ghost being shown now. Never below one: the event
    /// schema requires a positive denominator, and a ghost shown with no
    /// authored character since the last one is still one opportunity.
    public mutating func takeForOpportunity() -> Int {
        defer { authoredSinceLastOpportunity = 0 }
        return max(1, authoredSinceLastOpportunity)
    }

    /// A new segment, field, or privacy exclusion: nothing carries over.
    public mutating func reset() {
        authoredSinceLastOpportunity = 0
    }
}
