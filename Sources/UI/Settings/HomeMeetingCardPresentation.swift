import Foundation

/// The first lines of a saved meeting, read once per card so a closed card
/// can show who said what without opening it.
struct HomeMeetingCardSnippet: Equatable, Sendable {
    /// The opening transcript lines, at most `HomeMeetingCardPresentation.closedLineLimit`.
    let lines: [HomeMeetingTranscriptLine]
    /// Every transcript line in the file.
    let totalLineCount: Int
    /// Named voices in order of first appearance ("You", "Priya"). Unnamed
    /// "Speaker 2" voices are left out; the issue line asks for them instead.
    let participants: [String]
    /// Plain text when the file has no speaker lines (old or hand-edited
    /// transcripts), else nil.
    let fallbackText: String?
}

/// Foundation-only rules for the Meetings card (`QuietMeetingCard`), so fast
/// tests read the same values the view lays out from.
enum HomeMeetingCardPresentation {
    /// A closed card shows this many transcript lines, like the four lines of
    /// a Dictations card.
    static let closedLineLimit = 4
    /// Each line of a closed card wraps to at most this many rows.
    static let closedLineWrapLimit = 2
    /// An opened card shows this many lines before "Show all N lines".
    static let openedLineLimit = 60
    /// A line this long probably wraps past two rows on a closed card.
    static let longLineCharacterCount = 140
    /// Names in the bar before "+N".
    static let participantLimit = 3

    static func snippet(from content: HomeMeetingPreviewContent) -> HomeMeetingCardSnippet {
        let lines = content.transcriptLines
        var seen = Set<String>()
        var participants: [String] = []
        for line in lines {
            let name = line.speaker.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !isUnnamedVoice(name), seen.insert(name).inserted else { continue }
            participants.append(name)
        }
        let fallback = content.fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        return HomeMeetingCardSnippet(
            lines: Array(lines.prefix(closedLineLimit)),
            totalLineCount: lines.count,
            participants: participants,
            fallbackText: lines.isEmpty && !fallback.isEmpty ? String(fallback.prefix(600)) : nil
        )
    }

    /// "Speaker", "Speaker 2", "Unknown": a voice nobody has named yet.
    static func isUnnamedVoice(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if lowered == "unknown" || lowered == "speaker" { return true }
        guard lowered.hasPrefix("speaker ") else { return false }
        return lowered.dropFirst("speaker ".count).allSatisfy(\.isNumber)
    }

    /// "You, Priya" or "You, Priya, Leo +2".
    static func participantsText(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(participantLimit).joined(separator: ", ")
        let rest = names.count - participantLimit
        return rest > 0 ? "\(shown) +\(rest)" : shown
    }

    /// "<1 min", "32 min", "1 hr", "1 hr 5 min"; nil without both ends.
    static func durationText(start: Date?, end: Date?) -> String? {
        guard let start, let end, end > start else { return nil }
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
        if minutes < 1 { return "<1 min" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    /// The bar's meta: start time · length · people. No date (the day header
    /// says it) and no model name.
    static func metaItems(time: String, start: Date?, end: Date?, participants: [String]) -> [String] {
        [time, durationText(start: start, end: end), participantsText(participants)].compactMap { $0 }
    }

    /// Show more appears when the card hides something: more lines than a
    /// closed card shows, or a line likely cut at two rows.
    static func hasMore(_ snippet: HomeMeetingCardSnippet) -> Bool {
        if snippet.totalLineCount > closedLineLimit { return true }
        if let fallback = snippet.fallbackText { return fallback.count > longLineCharacterCount * 2 }
        return snippet.lines.contains { $0.text.count > longLineCharacterCount }
    }

    /// "Show all 214 lines" under an opened card that holds back the rest.
    static func showAllTitle(totalLineCount: Int) -> String? {
        totalLineCount > openedLineLimit ? "Show all \(totalLineCount) lines" : nil
    }
}
