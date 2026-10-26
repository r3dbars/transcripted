import Foundation

// Transcripted phase 3 (docs/writing-plan.md, decision 10): Backspace
// tracking for Save my writing. Not part of Tilde.
//
// Tilde breaks the writing segment on every Backspace, so its learning never
// sees a deletion. The keyboard still breaks the segment there, so the
// personal predictor and the encrypted log get exactly Tilde's segments. What
// is new: when the Backspace removes a character the keyboard itself just sent,
// it also reports a text-free count, and the next segment's identifier stays
// in the same chain (`PersonalHistorySegmentChain`), so the app can drop the
// character from the entry it is composing.

extension PersonalHistoryEvent {
    /// A text-free deletion of `deletedCharacters` UTF-16 units from the end
    /// of `sessionIdentifier`'s chain. Travels as version 2.
    public init?(
        deletionID id: String,
        timestampMilliseconds: Int64,
        historyIdentifier: String,
        consentIdentifier: String? = nil,
        sessionIdentifier: String,
        appBundleIdentifier: String,
        deletedCharacters: Int
    ) {
        guard Self.validIdentifier(id),
              timestampMilliseconds > 0,
              Self.validIdentifier(historyIdentifier),
              let consentIdentifier = consentIdentifier ?? Optional(historyIdentifier),
              Self.validIdentifier(consentIdentifier),
              Self.validIdentifier(sessionIdentifier),
              Self.validBundleIdentifier(appBundleIdentifier),
              (1...Self.maximumDeletedCharacters).contains(deletedCharacters) else {
            return nil
        }
        self.v = Self.deletionVersion
        self.id = id
        self.timestampMilliseconds = timestampMilliseconds
        self.historyIdentifier = historyIdentifier
        self.consentIdentifier = consentIdentifier
        self.sessionIdentifier = sessionIdentifier
        self.appBundleIdentifier = appBundleIdentifier
        self.source = .deletion
        self.text = ""
        self.deletedCharacters = deletedCharacters
    }

    /// Every event version this build reads. A history batch with any other
    /// version is answered `unsupported` (`GhostBrainRequest`).
    public static let supportedVersions: Set<Int> = [version, deletionVersion]

    /// Typed and accepted text is version 1, a deletion version 2.
    public var hasCurrentVersion: Bool {
        v == (source == .deletion ? Self.deletionVersion : Self.version)
    }

    /// Two queued deletions in one segment become one count, the way queued
    /// typed text coalesces. `nil` when either isn't a deletion, the segments
    /// differ, or the sum is past the bound.
    public func coalescingDeletion(with next: Self) -> Self? {
        guard source == .deletion,
              next.source == .deletion,
              historyIdentifier == next.historyIdentifier,
              consentIdentifier == next.consentIdentifier,
              sessionIdentifier == next.sessionIdentifier,
              appBundleIdentifier == next.appBundleIdentifier,
              let count = deletedCharacters,
              let nextCount = next.deletedCharacters else { return nil }
        return Self(
            deletionID: id,
            timestampMilliseconds: timestampMilliseconds,
            historyIdentifier: historyIdentifier,
            consentIdentifier: consentIdentifier,
            sessionIdentifier: sessionIdentifier,
            appBundleIdentifier: appBundleIdentifier,
            deletedCharacters: count + nextCount
        )
    }
}

/// Segment identifiers that say which writing they continue. A chain starts
/// at a random root (a UUID, as Tilde's segment identifiers always were). A
/// tracked Backspace moves to `<root>_<n>`: a new segment for the predictor,
/// the same chain for Save my writing. UUID strings never contain `_`.
public enum PersonalHistorySegmentChain {
    private static let separator: Character = "_"

    public static func root(of segment: String) -> Substring {
        segment.split(separator: separator, maxSplits: 1, omittingEmptySubsequences: false).first
            ?? Substring(segment)
    }

    public static func continuation(of segment: String) -> String {
        let root = root(of: segment)
        let generation = segment.dropFirst(root.count + 1)
        return "\(root)\(separator)\((Int(generation) ?? 0) + 1)"
    }

    public static func sameChain(_ first: String, _ second: String) -> Bool {
        root(of: first) == root(of: second)
    }
}

/// What the keyboard itself sent in the current segment chain and still
/// believes is in the field, so a Backspace right after it can be reported.
/// Memory only, bounded like one event's text. A Backspace past what it holds
/// breaks the segment, exactly as every Backspace did in Tilde.
public struct PersonalHistoryDeletionTracker: Equatable, Sendable {
    public static let maximumTrackedCharacters = PersonalHistoryEvent.maximumTextCharacters

    public struct Backspace: Equatable, Sendable {
        /// How far the caret moves back, in UTF-16 units: one character as
        /// the keyboard inserted it. The deletion event reports this count,
        /// and the app removes the same number of units.
        public let utf16Length: Int
        /// The segment had text since its last rotation, so the predictor
        /// must see a new segment from here, as Tilde's always did.
        public let rotatesSegment: Bool
    }

    private var tracked: [Character] = []
    private var segmentHasText = false

    public init() {}

    public var hasTrackedText: Bool { !tracked.isEmpty }

    public mutating func inserted(_ text: String) {
        guard !text.isEmpty else { return }
        tracked.append(contentsOf: text)
        if tracked.count > Self.maximumTrackedCharacters {
            tracked.removeFirst(tracked.count - Self.maximumTrackedCharacters)
        }
        segmentHasText = true
    }

    /// One Backspace at the caret the keyboard's own text ends at. `nil` when
    /// none of that text is left.
    public mutating func backspace() -> Backspace? {
        guard let last = tracked.popLast() else { return nil }
        let rotates = segmentHasText
        segmentHasText = false
        return Backspace(utf16Length: String(last).utf16.count, rotatesSegment: rotates)
    }

    public mutating func reset() {
        tracked.removeAll(keepingCapacity: true)
        segmentHasText = false
    }
}

/// Transcripted: whether a key lands at the end of the keyboard's own text,
/// so it continues the segment chain, from the caret the host reports. Not
/// every host moves that caret as text goes in: Ghostty reports `{0, 0}`
/// whenever nothing is selected, and Chromium fields can report the caret
/// from before the last few keys. Requiring the caret to land exactly where
/// the last key's text ended broke the chain on every key there, and the
/// app saved each character on its own line. So a caret anywhere from the
/// one the host reported for the previous key up to where the keyboard's
/// text ends continues the chain: a host that's frozen or behind never
/// reports past that end, and a host that keeps up reports just that end.
/// So does a caret where that end was within the last few keys, for a host
/// that's behind across a Backspace (its carets go back down there). A
/// selection starting at such a caret (Chrome's omnibox selects its inline
/// completion after the caret) continues it too. Anything else is a caret
/// jump and breaks the chain. The cost: in a host that keeps up, a click
/// back up to `recentEndLimit` characters into the keyboard's own text just
/// typed isn't seen as a jump. Not part of Tilde.
public struct PersonalHistoryCaretContinuity: Equatable, Sendable {
    public enum Decision: Equatable, Sendable {
        /// The key continues the current chain.
        case continues
        /// The key starts a new chain.
        case breaks
        /// The host reports no caret; the key isn't captured.
        case unusable
    }

    /// How many keys a host may be behind across a Backspace.
    public static let recentEndLimit = 3

    private struct Chain: Equatable, Sendable {
        let bundle: String
        /// Where the keyboard's own text ends, as the host would report it
        /// if it kept up.
        var end: Int
        /// The caret the host reported for the previous key.
        var lastReported: Int
        /// Where the keyboard's text ended before each of the last few keys.
        var recentEnds: [Int]

        mutating func moveEnd(to newEnd: Int) {
            recentEnds.append(end)
            if recentEnds.count > PersonalHistoryCaretContinuity.recentEndLimit {
                recentEnds.removeFirst(recentEnds.count - PersonalHistoryCaretContinuity.recentEndLimit)
            }
            end = newEnd
        }
    }

    private var chain: Chain?

    public init() {}

    public var isTracking: Bool { chain != nil }

    /// A key about to insert `utf16Length` UTF-16 units with the host's
    /// caret at `selection`. Moves the chain past that text unless the host
    /// reports no caret.
    public mutating func insertion(bundle: String, selection: NSRange, utf16Length: Int) -> Decision {
        guard selection.location != NSNotFound, selection.location >= 0 else {
            chain = nil
            return .unusable
        }
        let caret = selection.location
        let decision: Decision
        if let current = chain, continues(current, bundle: bundle, caret: caret) {
            decision = .continues
        } else {
            decision = chain == nil && selection.length == 0 ? .continues : .breaks
        }
        if decision == .continues, var current = chain {
            current.moveEnd(to: current.end + max(0, utf16Length))
            current.lastReported = min(caret, current.end)
            chain = current
        } else {
            chain = Chain(bundle: bundle, end: caret + max(0, utf16Length), lastReported: caret, recentEnds: [caret])
        }
        return decision
    }

    /// Whether a Backspace with the host's caret at `selection` lands at the
    /// end of the keyboard's own text (no selection).
    public func isAtOwnTextEnd(bundle: String, selection: NSRange) -> Bool {
        guard let chain, selection.location != NSNotFound, selection.length == 0 else { return false }
        return continues(chain, bundle: bundle, caret: selection.location)
    }

    /// A Backspace at the end of the keyboard's text removed `utf16Length`
    /// units of it, with the host's caret at `caret`.
    public mutating func backspaced(utf16Length: Int, caret: Int) {
        guard var current = chain else { return }
        current.moveEnd(to: max(0, current.end - utf16Length))
        current.lastReported = min(caret, current.end)
        chain = current
    }

    public mutating func reset() {
        chain = nil
    }

    private func continues(_ chain: Chain, bundle: String, caret: Int) -> Bool {
        guard chain.bundle == bundle else { return false }
        return (chain.lastReported...chain.end).contains(caret) || chain.recentEnds.contains(caret)
    }
}
