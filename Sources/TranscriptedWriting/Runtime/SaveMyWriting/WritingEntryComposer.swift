#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

/// Groups the keyboard's Personal History events into Save my writing
/// entries (the phase 3 contract). An entry is one app's continuous writing:
/// a new one starts on an app switch, after 2 minutes idle, or on a segment
/// break the keyboard reports (a caret jump, Return, a shortcut: anything
/// that starts a new segment chain). A Backspace the keyboard tracked removes
/// its UTF-16 units from the open entry; an entry under 2 characters after trimming
/// isn't saved. A scrap (under 3 words, like "yeah I can") doesn't end at a
/// segment break when the same app's next segment starts within a minute:
/// it folds into that entry on its own line, so quick chat replies don't
/// each become an entry. Pure: the caller passes the clock. Not part of Tilde.
struct WritingEntryComposer {
    static let idleGapMilliseconds: Int64 = 120_000
    static let minimumCharacters = 2
    static let scrapWordLimit = 3
    static let scrapMergeGapMilliseconds: Int64 = 60_000

    /// A closed entry, ready for the day file.
    struct Entry: Equatable, Sendable {
        let entryID: String
        let capturedAtMilliseconds: Int64
        let appBundleIdentifier: String
        let historyIdentifier: String
        let consentIdentifier: String
        let text: String
        let wordCount: Int
        let characterCount: Int
        let acceptedWordCount: Int
    }

    private struct Piece {
        var text: String
        let accepted: Bool
    }

    private struct OpenEntry {
        let entryID: String
        let appBundleIdentifier: String
        let historyIdentifier: String
        let consentIdentifier: String
        var chainRoot: String
        let firstTimestampMilliseconds: Int64
        var lastActivityMilliseconds: Int64
        var pieces: [Piece] = []

        var text: String { pieces.map(\.text).joined() }

        mutating func append(_ text: String, accepted: Bool) {
            if let last = pieces.indices.last, pieces[last].accepted == accepted {
                pieces[last].text += text
            } else {
                pieces.append(Piece(text: text, accepted: accepted))
            }
        }

        /// Removes `count` UTF-16 units from the end, the unit the keyboard
        /// reports a Backspace in. Not `Character`s: a combining mark or a
        /// joiner typed on its own merges into the character before it once
        /// pieces are joined, and one `Character` would take both.
        mutating func deleteLast(_ count: Int) {
            var remaining = count
            while remaining > 0, let last = pieces.indices.last {
                var scalars = pieces[last].text.unicodeScalars
                while remaining > 0, let scalar = scalars.popLast() {
                    remaining -= scalar.utf16.count
                }
                pieces[last].text = String(scalars)
                if pieces[last].text.isEmpty { pieces.removeLast() }
            }
        }
    }

    private let makeEntryID: @Sendable (Int64) -> String
    private var open: OpenEntry?

    /// `makeEntryID` gets the first keystroke's time in milliseconds.
    init(makeEntryID: @escaping @Sendable (Int64) -> String) {
        self.makeEntryID = makeEntryID
    }

    var hasOpenEntry: Bool { open != nil }

    /// Takes one batch in keyboard order. `receivedAt` counts as activity
    /// for the entry the batch ends in: the keyboard sends a batch shortly
    /// after the last key in it, while an event's own timestamp is its first
    /// key. Returns the entries this batch closed.
    mutating func ingest(_ events: [PersonalHistoryEvent], receivedAt: Date) -> [Entry] {
        var closed: [Entry] = []
        var openTouched = false
        for event in events {
            if var entry = open, Self.continues(entry, with: event) || Self.foldsScrap(entry, into: event) {
                Self.startSegmentIfNeeded(&entry, for: event)
                Self.apply(event, to: &entry)
                entry.lastActivityMilliseconds = max(entry.lastActivityMilliseconds, event.timestampMilliseconds)
                open = entry
                openTouched = true
                continue
            }
            if let finished = closeOpen() { closed.append(finished) }
            openTouched = false
            // A deletion from a chain that isn't open has nothing to remove.
            guard event.source != .deletion else { continue }
            var entry = OpenEntry(
                entryID: makeEntryID(event.timestampMilliseconds),
                appBundleIdentifier: event.appBundleIdentifier,
                historyIdentifier: event.historyIdentifier,
                consentIdentifier: event.consentIdentifier,
                chainRoot: String(PersonalHistorySegmentChain.root(of: event.sessionIdentifier)),
                firstTimestampMilliseconds: event.timestampMilliseconds,
                lastActivityMilliseconds: event.timestampMilliseconds
            )
            Self.apply(event, to: &entry)
            open = entry
            openTouched = true
        }
        if openTouched, var entry = open {
            entry.lastActivityMilliseconds = max(entry.lastActivityMilliseconds, Self.milliseconds(receivedAt))
            open = entry
        }
        return closed
    }

    /// Closes the open entry once it has been idle for 2 minutes.
    mutating func closeIdle(now: Date) -> [Entry] {
        guard let entry = open,
              Self.milliseconds(now) - entry.lastActivityMilliseconds > Self.idleGapMilliseconds else { return [] }
        return closeOpen().map { [$0] } ?? []
    }

    /// Closes whatever is open, as at quit.
    mutating func closeAll() -> [Entry] {
        closeOpen().map { [$0] } ?? []
    }

    /// Drops the open entry unsaved: Save my writing went off, or delete all.
    mutating func discardOpenEntry() {
        open = nil
    }

    private mutating func closeOpen() -> Entry? {
        guard let entry = open else { return nil }
        open = nil
        let text = entry.pieces.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= Self.minimumCharacters else { return nil }
        return Entry(
            entryID: entry.entryID,
            capturedAtMilliseconds: entry.firstTimestampMilliseconds,
            appBundleIdentifier: entry.appBundleIdentifier,
            historyIdentifier: entry.historyIdentifier,
            consentIdentifier: entry.consentIdentifier,
            text: text,
            wordCount: Self.wordCount(text),
            characterCount: text.count,
            acceptedWordCount: entry.pieces.filter(\.accepted).reduce(0) { $0 + Self.wordCount($1.text) }
        )
    }

    private static func continues(_ entry: OpenEntry, with event: PersonalHistoryEvent) -> Bool {
        entry.appBundleIdentifier == event.appBundleIdentifier
            && entry.historyIdentifier == event.historyIdentifier
            && entry.consentIdentifier == event.consentIdentifier
            && PersonalHistorySegmentChain.root(of: event.sessionIdentifier) == entry.chainRoot
            && event.timestampMilliseconds - entry.lastActivityMilliseconds <= idleGapMilliseconds
    }

    /// The open entry is a scrap and `event` starts the same app's next
    /// segment within a minute. A deletion never starts a new segment.
    private static func foldsScrap(_ entry: OpenEntry, into event: PersonalHistoryEvent) -> Bool {
        event.source != .deletion
            && entry.appBundleIdentifier == event.appBundleIdentifier
            && entry.historyIdentifier == event.historyIdentifier
            && entry.consentIdentifier == event.consentIdentifier
            && event.timestampMilliseconds - entry.lastActivityMilliseconds <= scrapMergeGapMilliseconds
            && wordCount(entry.text) < scrapWordLimit
    }

    /// When `event` is from a new segment chain, puts the new segment on its
    /// own line and follows that chain from here on.
    private static func startSegmentIfNeeded(_ entry: inout OpenEntry, for event: PersonalHistoryEvent) {
        let root = String(PersonalHistorySegmentChain.root(of: event.sessionIdentifier))
        guard root != entry.chainRoot else { return }
        entry.chainRoot = root
        if !entry.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entry.append("\n", accepted: false)
        }
    }

    private static func apply(_ event: PersonalHistoryEvent, to entry: inout OpenEntry) {
        switch event.source {
        case .typed: entry.append(event.text, accepted: false)
        case .acceptedSuggestion: entry.append(event.text, accepted: true)
        case .deletion: entry.deleteLast(event.deletedCharacters ?? 0)
        }
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }
}
