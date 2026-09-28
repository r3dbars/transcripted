import Foundation

// MARK: - Meeting list filtering

/// Foundation-pure matching for the Home meetings filter box.
///
/// The Home meetings list filter matches the user's query against each
/// meeting's metadata (title, a derived date string, and named speakers) so
/// filtering stays cheap and never reads transcript bodies off disk. The
/// decision lives here so it can be fast-tested; `HomeMeetingSearchIndex` and
/// `TranscriptedSettingsView` call in.
enum HomeMeetingListFilter {
    /// Returns true when every whitespace-separated token in `query` appears in
    /// at least one of `fields` (case- and diacritic-insensitive). An empty or
    /// whitespace-only query matches everything.
    static func matches(query: String, in fields: [String]) -> Bool {
        matches(tokens: tokens(in: query), haystack: haystack(for: fields))
    }

    /// The query split into the whitespace-separated tokens `matches` ANDs.
    static func tokens(in query: String) -> [String] {
        query
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    /// The single string `matches` searches for a set of fields. Callers that
    /// match one row against many queries (the Home search index) build it
    /// once per row.
    static func haystack(for fields: [String]) -> String {
        fields.joined(separator: "\n")
    }

    /// `matches(query:in:)` with the tokens and haystack prepared up front.
    /// No tokens matches everything.
    static func matches(tokens: [String], haystack: String) -> Bool {
        tokens.allSatisfy { token in
            haystack.range(
                of: token,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }

    /// Everything a saved meeting row can be found by: title, date words, and
    /// the named speakers. Metadata only, never the transcript body.
    static func searchFields(for meeting: RecentMeetingItem) -> [String] {
        [meeting.title, dateSearchText(for: meeting.date)] + meeting.speakerNames
    }

    /// Searchable date tokens for a meeting so users can filter by typing a
    /// month name, weekday, year, or numeric date fragment. Returns a single
    /// space-joined string suitable for inclusion in the field list.
    static func dateSearchText(for date: Date, calendar: Calendar = .current) -> String {
        var pieces: [String] = []
        pieces.append(HomeDaySectionLabel.label(for: calendar.startOfDay(for: date), calendar: calendar))
        pieces.append(mediumFormatter.string(from: date))
        pieces.append(numericFormatter.string(from: date))
        return pieces.joined(separator: " ")
    }

    private static let mediumFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    private static let numericFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .short
        f.timeStyle = .none
        return f
    }()
}

// MARK: - In-transcript find

/// A single occurrence of the find query inside one searched line.
///
/// `range` is expressed in UTF-16 offsets (NSString semantics) so the match can
/// be rebuilt into an `AttributedString` highlight without re-scanning.
struct TranscriptFindMatch: Equatable {
    let lineIndex: Int
    let range: Range<Int>
}

/// Foundation-pure occurrence finder for the in-transcript find bar.
///
/// Given the transcript's already-parsed line texts and a query, returns every
/// case- and diacritic-insensitive occurrence in reading order. The view layer
/// uses the result for highlighting, next/prev navigation, and the match
/// counter. Kept out of SwiftUI so it can be fast-tested.
enum TranscriptFinder {
    static func matches(in lines: [String], query: String) -> [TranscriptFindMatch] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var results: [TranscriptFindMatch] = []
        for (index, line) in lines.enumerated() {
            let ns = line as NSString
            var searchStart = 0
            while searchStart < ns.length {
                let scope = NSRange(location: searchStart, length: ns.length - searchStart)
                let found = ns.range(
                    of: trimmed,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: scope
                )
                guard found.location != NSNotFound else { break }
                results.append(
                    TranscriptFindMatch(
                        lineIndex: index,
                        range: found.location..<(found.location + found.length)
                    )
                )
                searchStart = found.location + max(found.length, 1)
            }
        }
        return results
    }
}
