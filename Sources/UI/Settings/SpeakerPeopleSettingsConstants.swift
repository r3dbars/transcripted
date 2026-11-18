import CoreGraphics

enum SpeakerPeopleSettingsPolishContract {
    static let minimumHitTarget: CGFloat = 40
    static let compactIconVisibleDiameter: CGFloat = 28
}

// MARK: - Empty state copy

/// Foundation-pure copy for the Speakers surface's empty states. Kept as
/// constants so the teaching first-run copy can be pinned by fast tests and can
/// never regress to bare gray placeholder text. Plain words, no exclamation
/// marks, per the repo voice convention.
enum SpeakerPeopleEmptyState {
    static let symbolName = "person.2"
    static let title = "No speakers yet"
    static let message = "People from your meetings show up here."
    static let actionTitle = "Record a meeting"
    static let actionAutomationIdentifier = "transcripted.speakers.empty.start-meeting"
    static let noSearchMatches = "No one matches your search."
}
