import Foundation
import Testing
@testable import TranscriptedWritingCore
@testable import TranscriptedWritingRuntime

@Suite("Save my writing entry composer")
struct WritingEntryComposerTests {
    private static let start: Int64 = 1_790_350_931_387
    private static let slack = "com.tinyspeck.slackmacgap"
    private static let mail = "com.apple.mail"

    @Test("Backspace removes the keyboard's own characters from the entry")
    func deletion() throws {
        var composer = Self.composer()
        _ = composer.ingest([
            Self.typed("Pushing teh", at: Self.start),
            try Self.deletion(2, session: "chain_1", at: Self.start + 2_000),
            Self.typed("he launch", session: "chain_1", at: Self.start + 2_500),
        ], receivedAt: Self.date(Self.start + 3_000))
        let entry = try #require(composer.closeAll().first)
        #expect(entry.text == "Pushing the launch")
        #expect(entry.wordCount == 3)
        #expect(entry.characterCount == 18)
        #expect(entry.capturedAtMilliseconds == Self.start)
        #expect(entry.entryID == "entry-\(Self.start)")
    }

    @Test("A deletion can reach back through accepted text")
    func deletionAcrossPieces() throws {
        var composer = Self.composer()
        _ = composer.ingest([
            Self.typed("See you ", at: Self.start),
            Self.typed("tomorrow ", source: .acceptedSuggestion, at: Self.start + 1_000),
            try Self.deletion(10, session: "chain_1", at: Self.start + 2_000),
            Self.typed("Friday", session: "chain_1", at: Self.start + 3_000),
        ], receivedAt: Self.date(Self.start + 3_500))
        let entry = try #require(composer.closeAll().first)
        // "tomorrow " is 9 characters; the 10th Backspace takes the space.
        #expect(entry.text == "See youFriday")
        #expect(entry.acceptedWordCount == 0)
    }

    @Test("Deletions count UTF-16 units, so a mark typed on its own goes on its own")
    func deletionCountsUTF16Units() throws {
        var composer = Self.composer()
        _ = composer.ingest([
            Self.typed("Ok cafe", at: Self.start),
            // Joins the "e" before it into one Character once concatenated.
            Self.typed("\u{301}", at: Self.start + 500),
            try Self.deletion(1, session: "chain_1", at: Self.start + 1_000),
            Self.typed(" 👍", session: "chain_1", at: Self.start + 1_500),
            // A skin tone modifier: two UTF-16 units, one Character with 👍.
            Self.typed("\u{1F3FD}", session: "chain_1", at: Self.start + 2_000),
            try Self.deletion(2, session: "chain_1", at: Self.start + 2_500),
        ], receivedAt: Self.date(Self.start + 3_000))
        let entry = try #require(composer.closeAll().first)
        #expect(entry.text == "Ok cafe 👍")
    }

    @Test("A deletion from a chain that isn't open changes nothing")
    func strayDeletion() throws {
        var composer = Self.composer()
        _ = composer.ingest([try Self.deletion(3, session: "other_1", at: Self.start)], receivedAt: Self.date(Self.start))
        #expect(!composer.hasOpenEntry)
        _ = composer.ingest([Self.typed("hello there", at: Self.start + 1_000)], receivedAt: Self.date(Self.start + 1_000))
        let closed = composer.ingest(
            [try Self.deletion(3, session: "other_1", at: Self.start + 2_000)],
            receivedAt: Self.date(Self.start + 2_000)
        )
        #expect(closed.map(\.text) == ["hello there"])
    }

    @Test("An app switch starts a new entry")
    func appSwitch() throws {
        var composer = Self.composer()
        let closed = composer.ingest([
            Self.typed("Reply in Slack", at: Self.start),
            Self.typed("Email in Mail", session: "mail-chain", app: Self.mail, at: Self.start + 5_000),
        ], receivedAt: Self.date(Self.start + 6_000))
        #expect(closed.map(\.text) == ["Reply in Slack"])
        #expect(closed.first?.appBundleIdentifier == Self.slack)
        let rest = composer.closeAll()
        #expect(rest.map(\.text) == ["Email in Mail"])
        #expect(rest.first?.appBundleIdentifier == Self.mail)
    }

    @Test("A segment break the keyboard reports starts a new entry")
    func segmentBreak() {
        var composer = Self.composer()
        let closed = composer.ingest([
            Self.typed("First message", session: "chain-a", at: Self.start),
            Self.typed("Second message", session: "chain-b", at: Self.start + 1_000),
        ], receivedAt: Self.date(Self.start + 2_000))
        #expect(closed.map(\.text) == ["First message"])
        #expect(composer.closeAll().map(\.text) == ["Second message"])
    }

    @Test("Two minutes idle ends an entry")
    func idle() {
        var composer = Self.composer()
        _ = composer.ingest([Self.typed("before the break", at: Self.start)], receivedAt: Self.date(Self.start))
        #expect(composer.closeIdle(now: Self.date(Self.start + 120_000)).isEmpty)
        let continued = composer.ingest(
            [Self.typed(" still going", at: Self.start + 120_000)],
            receivedAt: Self.date(Self.start + 120_500)
        )
        #expect(continued.isEmpty)

        let closed = composer.ingest(
            [Self.typed("after the break", at: Self.start + 120_500 + 120_001)],
            receivedAt: Self.date(Self.start + 400_000)
        )
        #expect(closed.map(\.text) == ["before the break still going"])

        #expect(composer.closeIdle(now: Self.date(Self.start + 400_000 + 120_000)).isEmpty)
        #expect(composer.closeIdle(now: Self.date(Self.start + 400_000 + 120_001)).map(\.text) == ["after the break"])
        #expect(!composer.hasOpenEntry)
    }

    @Test("Idle counts from when a batch arrived, not from its first key")
    func idleCountsFromArrival() {
        var composer = Self.composer()
        // One coalesced event can span minutes of steady typing: its
        // timestamp is its first key, and it arrives after its last.
        _ = composer.ingest([Self.typed("a long steady paragraph", at: Self.start)], receivedAt: Self.date(Self.start + 110_000))
        let closed = composer.ingest(
            [Self.typed(" and more", at: Self.start + 150_000)],
            receivedAt: Self.date(Self.start + 151_000)
        )
        #expect(closed.isEmpty)
        #expect(composer.closeAll().map(\.text) == ["a long steady paragraph and more"])
    }

    @Test("Entries under 2 characters after trimming aren't saved")
    func minimumLength() {
        var composer = Self.composer()
        _ = composer.ingest([Self.typed("  k \u{00A0}", at: Self.start)], receivedAt: Self.date(Self.start))
        #expect(composer.closeAll().isEmpty)
        _ = composer.ingest([Self.typed(" ok ", at: Self.start)], receivedAt: Self.date(Self.start))
        let entry = composer.closeAll().first
        #expect(entry?.text == "ok")
        #expect(entry?.characterCount == 2)
        #expect(entry?.wordCount == 1)
    }

    @Test("Accepted words count the words that came from accepted suggestions")
    func acceptedWords() throws {
        var composer = Self.composer()
        _ = composer.ingest([
            Self.typed("Let's meet ", at: Self.start),
            Self.typed("on Thursday at ", source: .acceptedSuggestion, at: Self.start + 1_000),
            Self.typed("noon", source: .acceptedSuggestion, at: Self.start + 1_500),
            Self.typed(" ok", at: Self.start + 2_000),
        ], receivedAt: Self.date(Self.start + 2_500))
        let entry = try #require(composer.closeAll().first)
        #expect(entry.text == "Let's meet on Thursday at noon ok")
        #expect(entry.wordCount == 7)
        #expect(entry.acceptedWordCount == 4)
    }

    @Test("Writing under another consent or history starts over")
    func consentChange() {
        var composer = Self.composer()
        let closed = composer.ingest([
            Self.typed("before toggling", at: Self.start),
            Self.typed("after toggling", consent: "consent-b", at: Self.start + 1_000),
        ], receivedAt: Self.date(Self.start + 1_500))
        #expect(closed.map(\.text) == ["before toggling"])
        #expect(composer.closeAll().first?.consentIdentifier == "consent-b")
    }

    @Test("Discarding drops the open entry unsaved")
    func discard() {
        var composer = Self.composer()
        _ = composer.ingest([Self.typed("never saved", at: Self.start)], receivedAt: Self.date(Self.start))
        composer.discardOpenEntry()
        #expect(composer.closeAll().isEmpty)
    }

    // MARK: - Helpers

    private static func composer() -> WritingEntryComposer {
        WritingEntryComposer { "entry-\($0)" }
    }

    private static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: TimeInterval(milliseconds) / 1_000)
    }

    private static func typed(
        _ text: String,
        source: PersonalHistoryEventSource = .typed,
        session: String = "chain",
        app: String = slack,
        consent: String = "consent",
        at timestamp: Int64
    ) -> PersonalHistoryEvent {
        PersonalHistoryEvent(
            id: UUID().uuidString,
            timestampMilliseconds: timestamp,
            historyIdentifier: "history",
            consentIdentifier: consent,
            sessionIdentifier: session,
            appBundleIdentifier: app,
            source: source,
            text: text
        )!
    }

    private static func deletion(_ count: Int, session: String, at timestamp: Int64) throws -> PersonalHistoryEvent {
        try #require(PersonalHistoryEvent(
            deletionID: UUID().uuidString,
            timestampMilliseconds: timestamp,
            historyIdentifier: "history",
            consentIdentifier: "consent",
            sessionIdentifier: session,
            appBundleIdentifier: slack,
            deletedCharacters: count
        ))
    }
}
