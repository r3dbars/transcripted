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
