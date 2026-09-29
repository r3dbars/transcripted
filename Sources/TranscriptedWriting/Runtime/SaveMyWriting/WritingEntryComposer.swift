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
/// each become an entry. Box fragments (one character, or a few digits with
/// no letters, like a card or OTP box) don't count toward the 3 words, so a
/// card typed over four boxes stays one entry the scrubber can see whole. Every closed entry goes through
/// `WritingSecretScrubber` before it's returned; an entry that was nothing
/// but a secret isn't returned at all.
///
/// Personal History (the encrypted log and the next-word predictor) gets the
/// keyboard's events only through here, once their entry has closed:
/// `takeClearedHistory()`. An entry the scrubber redacts anything from, as
/// saved or as typed before Backspace, gives Personal History nothing. Pure:
/// the caller passes the clock. Not part of Tilde.
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
        /// The typed and accepted events as the keyboard sent them, for
        /// Personal History. Never deletions: Personal History doesn't take them.
        var historyEvents: [PersonalHistoryEvent] = []

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

    /// The last few lines each app's previous entries ended with, kept in
    /// memory only, so the scrubber can see the command a password answers:
    /// in a terminal, `sudo apt update` ends its entry at Return and the
    /// password starts the next one. Per app, so a Slack reply in between
    /// doesn't lose the Terminal context.
    private struct RecentLines {
        let lastActivityMilliseconds: Int64
        let lines: [String]
    }

    private struct ContextKey: Hashable {
        let appBundleIdentifier: String
        let historyIdentifier: String
    }

    static let contextLineLimit = 6
    /// How long a previous entry counts as context: sudo waits 5 minutes
    /// for its password.
    static let contextWindowMilliseconds: Int64 = 300_000
    private static let contextAppLimit = 16

    private let makeEntryID: @Sendable (Int64) -> String
    private var open: OpenEntry?
    private var recent: [ContextKey: RecentLines] = [:]
    private var clearedHistory: [PersonalHistoryEvent] = []

    /// `makeEntryID` gets the first keystroke's time in milliseconds.
    init(makeEntryID: @escaping @Sendable (Int64) -> String) {
        self.makeEntryID = makeEntryID
    }

    var hasOpenEntry: Bool { open != nil }

    /// The typed and accepted events of every entry closed since the last
    /// call, in keyboard order, and forgets them. Never deletions. Entries
    /// too short to save still count; an entry that held a secret adds
    /// nothing.
    mutating func takeClearedHistory() -> [PersonalHistoryEvent] {
        defer { clearedHistory.removeAll() }
        return clearedHistory
    }

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
    /// Personal History gets none of it either.
    mutating func discardOpenEntry() {
        open = nil
        recent.removeAll()
        clearedHistory.removeAll()
    }

    private mutating func closeOpen() -> Entry? {
        guard let entry = open else { return nil }
        open = nil
        let typed = entry.pieces.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let context = precedingLines(for: entry)
        remember(
            RecentLines(
                lastActivityMilliseconds: entry.lastActivityMilliseconds,
                lines: Array((context + typed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
                    .suffix(Self.contextLineLimit))
            ),
            for: Self.contextKey(entry)
        )
        let scrubbed = WritingSecretScrubber.scrub(
            typed,
            appBundleIdentifier: entry.appBundleIdentifier,
            precedingLines: context
        )
        if !Self.holdsSecret(entry, typed: typed, scrubbed: scrubbed, context: context) {
            clearedHistory += entry.historyEvents
        }
        guard typed.count >= Self.minimumCharacters, !scrubbed.isOnlyRedactions else { return nil }
        let text = scrubbed.clean.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count >= Self.minimumCharacters else { return nil }
        let wordCount = Self.wordCount(text)
        return Entry(
            entryID: entry.entryID,
            capturedAtMilliseconds: entry.firstTimestampMilliseconds,
            appBundleIdentifier: entry.appBundleIdentifier,
            historyIdentifier: entry.historyIdentifier,
            consentIdentifier: entry.consentIdentifier,
            text: text,
            wordCount: wordCount,
            characterCount: text.count,
            acceptedWordCount: min(
                wordCount,
                entry.pieces.filter(\.accepted).reduce(0) { $0 + Self.wordCount($1.text) }
            )
        )
    }

    /// Whether the scrubber redacts anything from the entry as saved, or from
    /// it as the keyboard sent it. The sent text matters when Backspace took
    /// a secret back out: the saved entry no longer has it, but Personal
    /// History would store every event, the deleted text included. The
    /// scrubber changes text only to redact, so any change counts.
    private static func holdsSecret(
        _ entry: OpenEntry,
        typed: String,
        scrubbed: WritingSecretScrubber.Result,
        context: [String]
    ) -> Bool {
        guard scrubbed.clean == typed else { return true }
        let sent = sentText(entry.historyEvents)
        guard sent != typed else { return false }
        return WritingSecretScrubber.scrub(
            sent,
            appBundleIdentifier: entry.appBundleIdentifier,
            precedingLines: context
        ).clean != sent
    }

    /// The events' text the way Personal History keeps it: one line per
    /// keyboard segment, and each Backspace there starts a new segment.
    private static func sentText(_ events: [PersonalHistoryEvent]) -> String {
        var text = ""
        var session: String?
        for event in events {
            if let session, session != event.sessionIdentifier, !text.isEmpty { text += "\n" }
            session = event.sessionIdentifier
            text += event.text
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The previous entry's tail when it was the same app and history and
    /// ended within the idle gap of this entry's first keystroke.
    private func precedingLines(for entry: OpenEntry) -> [String] {
        guard let recent = recent[Self.contextKey(entry)],
              entry.firstTimestampMilliseconds - recent.lastActivityMilliseconds <= Self.contextWindowMilliseconds else {
            return []
        }
        return recent.lines
    }

    private mutating func remember(_ lines: RecentLines, for key: ContextKey) {
        recent[key] = lines
        guard recent.count > Self.contextAppLimit,
              let oldest = recent.min(by: { $0.value.lastActivityMilliseconds < $1.value.lastActivityMilliseconds }) else {
            return
        }
        recent[oldest.key] = nil
    }

    private static func contextKey(_ entry: OpenEntry) -> ContextKey {
        ContextKey(appBundleIdentifier: entry.appBundleIdentifier, historyIdentifier: entry.historyIdentifier)
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
            && scrapWordCount(entry.text) < scrapWordLimit
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
        case .typed:
            entry.append(event.text, accepted: false)
            entry.historyEvents.append(event)
        case .acceptedSuggestion:
            entry.append(event.text, accepted: true)
            entry.historyEvents.append(event)
        case .deletion: entry.deleteLast(event.deletedCharacters ?? 0)
        }
    }

    /// Words toward the scrap limit: box fragments (one character, or up to
    /// 5 characters with no letters: `4111`, `12/28`, `4`) don't count.
    private static func scrapWordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).filter { word in
            !(word.count == 1 || (word.count <= 5 && !word.contains(where: \.isLetter)))
        }.count
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }

    private static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000).rounded(.down))
    }
}
