import CoreGraphics

enum SpeakerPeopleSettingsPolishContract {
    static let minimumHitTarget: CGFloat = 40
    /// Glyph point size for the quiet inline play/pause control. The old
    /// 36pt filled accent circle is gone — playing state reads through the
    /// pause glyph, accent ink, and the sweep under the sample it belongs to.
    static let quietPlayGlyphPointSize: CGFloat = 14
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
    static let message = "Transcripted learns each voice as you record. After your first meeting, the people in it show up here, so you can name them. Once you’ve confirmed someone in a few meetings, Transcripted names them on its own."
    static let actionTitle = "Record a meeting"
    static let actionAutomationIdentifier = "transcripted.speakers.empty.start-meeting"
    static let noSearchMatches = "No speakers match your search."
}
