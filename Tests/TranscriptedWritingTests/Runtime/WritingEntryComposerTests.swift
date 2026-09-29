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
            Self.typed("The first full message", session: "chain-a", at: Self.start),
            Self.typed("Second message", session: "chain-b", at: Self.start + 1_000),
        ], receivedAt: Self.date(Self.start + 2_000))
        #expect(closed.map(\.text) == ["The first full message"])
        #expect(composer.closeAll().map(\.text) == ["Second message"])
    }

    @Test("A scrap folds into the same app's next segment within a minute")
    func scrapFolds() throws {
        var composer = Self.composer()
        let closed = composer.ingest([
            Self.typed("yeah ", session: "chain-a", at: Self.start),
            Self.typed("sure", source: .acceptedSuggestion, session: "chain-a", at: Self.start + 500),
            Self.typed("see you at the game", session: "chain-c", at: Self.start + 40_000),
            try Self.deletion(4, session: "chain-c", at: Self.start + 41_000),
            Self.typed("show", session: "chain-c", at: Self.start + 42_000),
        ], receivedAt: Self.date(Self.start + 43_000))
        #expect(closed.isEmpty)
        // Once the fold reaches 3 words it's no longer a scrap.
        let next = composer.ingest(
            [Self.typed("ok", session: "chain-d", at: Self.start + 50_000)],
            receivedAt: Self.date(Self.start + 50_500)
        )
        let entry = try #require(next.first)
        #expect(entry.text == "yeah sure\nsee you at the show")
        #expect(entry.capturedAtMilliseconds == Self.start)
        #expect(entry.wordCount == 7)
        #expect(entry.acceptedWordCount == 1)
    }

    @Test("A scrap stays its own entry after a minute, an app switch, or a deletion")
    func scrapDoesNotFold() throws {
        var composer = Self.composer()
        var closed = composer.ingest([
            Self.typed("sounds good", session: "chain-a", at: Self.start),
            Self.typed("A new thought much later", session: "chain-b", at: Self.start + 60_001),
        ], receivedAt: Self.date(Self.start + 61_000))
        #expect(closed.map(\.text) == ["sounds good"])
        _ = composer.closeAll()

        closed = composer.ingest([
            Self.typed("on it", session: "chain-a", at: Self.start + 100_000),
            Self.typed("Email in Mail", session: "mail-chain", app: Self.mail, at: Self.start + 101_000),
        ], receivedAt: Self.date(Self.start + 102_000))
        #expect(closed.map(\.text) == ["on it"])
        _ = composer.closeAll()

        closed = composer.ingest([
            Self.typed("thanks!", session: "chain-a", at: Self.start + 200_000),
            try Self.deletion(1, session: "chain-b", at: Self.start + 201_000),
        ], receivedAt: Self.date(Self.start + 202_000))
        #expect(closed.map(\.text) == ["thanks!"])
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

    // MARK: - Secrets never reach a saved entry

    private static let terminal = "com.apple.Terminal"
    private static let redactedPassword = "\u{27E8}redacted:password\u{27E9}"
    private static let redactedCard = "\u{27E8}redacted:card\u{27E9}"

    @Test("A closed entry's text is scrubbed, and its word and character counts describe the scrubbed text")
    func closedEntryIsScrubbed() throws {
        var composer = Self.composer()
        let closed = composer.ingest([
            Self.typed("the wifi password is sunshine", session: "chain-a", at: Self.start),
            Self.typed("Next message about lunch", session: "chain-b", at: Self.start + 2_000),
        ], receivedAt: Self.date(Self.start + 2_500))
        let entry = try #require(closed.first)
        let expected = "the wifi password is \(Self.redactedPassword)"
        #expect(entry.text == expected)
        #expect(!entry.text.contains("sunshine"))
        #expect(entry.wordCount == 5)
        #expect(entry.characterCount == expected.count)

        let card = "my card is \(Self.redactedCard) thanks"
        _ = composer.closeAll()
        _ = composer.ingest(
            [Self.typed("my card is 4111 1111 1111 1111 thanks", session: "chain-c", at: Self.start + 10_000)],
            receivedAt: Self.date(Self.start + 10_500)
        )
        let flushed = try #require(composer.closeAll().first)
        #expect(flushed.text == card)
        // The token counts as one word, as in the first entry above.
        #expect(flushed.wordCount == 5)
        #expect(flushed.characterCount == card.count)
    }

    @Test("An entry that is only redactions isn't saved")
    func onlyRedactionsNotSaved() {
        var composer = Self.composer()
        let closed = composer.ingest([
            Self.typed("Tr0ub4dor&3", session: "chain-a", at: Self.start),
            Self.typed("A normal sentence after it", session: "chain-b", at: Self.start + 70_000),
        ], receivedAt: Self.date(Self.start + 70_500))
        #expect(closed.isEmpty)
        #expect(composer.closeAll().map(\.text) == ["A normal sentence after it"])

        _ = composer.ingest(
            [Self.typed("4111 1111 1111 1111", session: "chain-c", at: Self.start + 200_000)],
            receivedAt: Self.date(Self.start + 200_500)
        )
        #expect(composer.closeAll().isEmpty)
    }

    @Test("Terminal: a password typed right after `sudo apt update` is dropped, and the command is saved")
    func terminalPasswordAfterSudoDropped() throws {
        var composer = Self.composer()
        _ = composer.ingest(
            [Self.typed("sudo apt update", session: "chain-a", app: Self.terminal, at: Self.start)],
            receivedAt: Self.date(Self.start + 500)
        )
        let closed = composer.ingest(
            [Self.typed("sunshine", session: "chain-b", app: Self.terminal, at: Self.start + 5_000)],
            receivedAt: Self.date(Self.start + 5_500)
        )
        #expect(closed.map(\.text) == ["sudo apt update"])
        #expect(composer.closeAll().isEmpty)
    }

    @Test("Terminal: the same word ten minutes after `sudo apt update` is saved, the context expired")
    func terminalContextExpires() {
        var composer = Self.composer()
        _ = composer.ingest(
            [Self.typed("sudo apt update", session: "chain-a", app: Self.terminal, at: Self.start)],
            receivedAt: Self.date(Self.start + 500)
        )
        let later = Self.start + 600_000
        let closed = composer.ingest(
            [Self.typed("sunshine", session: "chain-b", app: Self.terminal, at: later)],
            receivedAt: Self.date(later + 500)
        )
        #expect(closed.map(\.text) == ["sudo apt update"])
        #expect(composer.closeAll().map(\.text) == ["sunshine"])
    }

    @Test("Terminal: a word after `sudo apt update` typed in Slack is saved, context is per app")
    func terminalContextIsPerApp() {
        var composer = Self.composer()
        _ = composer.ingest(
            [Self.typed("sudo apt update", session: "chain-a", app: Self.slack, at: Self.start)],
            receivedAt: Self.date(Self.start + 500)
        )
        let closed = composer.ingest(
            [Self.typed("sunshine", session: "chain-b", app: Self.terminal, at: Self.start + 5_000)],
            receivedAt: Self.date(Self.start + 5_500)
        )
        #expect(closed.map(\.text) == ["sudo apt update"])
        #expect(composer.closeAll().map(\.text) == ["sunshine"])
    }

    @Test("The previous entry's text never leaks into the next entry")
    func previousEntryDoesNotLeak() throws {
        var composer = Self.composer()
        _ = composer.ingest(
            [Self.typed("sudo apt update", session: "chain-a", app: Self.terminal, at: Self.start)],
            receivedAt: Self.date(Self.start + 500)
        )
        // "sunshine" is a scrap, so the next segment folds in on its own line.
        _ = composer.ingest([
            Self.typed("sunshine", session: "chain-b", app: Self.terminal, at: Self.start + 5_000),
            Self.typed("ls -la", session: "chain-c", app: Self.terminal, at: Self.start + 8_000),
        ], receivedAt: Self.date(Self.start + 8_500))
        let entry = try #require(composer.closeAll().first)
        #expect(entry.text == "\(Self.redactedPassword)\nls -la")
        #expect(!entry.text.contains("sudo"))
        #expect(!entry.text.contains("sunshine"))
        #expect(entry.capturedAtMilliseconds == Self.start + 5_000)
    }

    @Test("Terminal: a password folded into the same entry as its sudo line is redacted in place")
    func passwordFoldedIntoSameEntry() throws {
        var composer = Self.composer()
        // "sudo -v" is a scrap, so the password segment folds into it.
        _ = composer.ingest([
            Self.typed("sudo -v", session: "chain-a", app: Self.terminal, at: Self.start),
            Self.typed("sunshine", session: "chain-b", app: Self.terminal, at: Self.start + 3_000),
        ], receivedAt: Self.date(Self.start + 3_500))
        let entry = try #require(composer.closeAll().first)
        #expect(entry.text == "sudo -v\n\(Self.redactedPassword)")
        #expect(entry.wordCount == 3)
        #expect(entry.characterCount == "sudo -v\n\(Self.redactedPassword)".count)
    }

    @Test("Discarding the open entry also forgets the previous entry's context")
    func discardForgetsContext() {
        var composer = Self.composer()
        _ = composer.ingest(
            [Self.typed("sudo apt update", session: "chain-a", app: Self.terminal, at: Self.start)],
            receivedAt: Self.date(Self.start + 500)
        )
        let closed = composer.ingest(
            [Self.typed("sunsh", session: "chain-b", app: Self.terminal, at: Self.start + 1_000)],
            receivedAt: Self.date(Self.start + 1_500)
        )
        #expect(closed.map(\.text) == ["sudo apt update"])
        // Save my writing turned off, or delete all.
        composer.discardOpenEntry()
        _ = composer.ingest(
            [Self.typed("sunshine", session: "chain-c", app: Self.terminal, at: Self.start + 3_000)],
            receivedAt: Self.date(Self.start + 3_500)
        )
        #expect(composer.closeAll().map(\.text) == ["sunshine"])
    }

    @Test("Closing everything (Writing stopping) forgets the raw context lines too")
    func closeAllForgetsContext() {
        var composer = Self.composer()
        _ = composer.ingest(
            [Self.typed("sudo apt update", session: "chain-a", app: Self.terminal, at: Self.start)],
            receivedAt: Self.date(Self.start + 500)
        )
        #expect(composer.closeAll().map(\.text) == ["sudo apt update"])
        // Nothing of the sudo line is left to read the next word as its password.
        _ = composer.ingest(
            [Self.typed("sunshine", session: "chain-b", app: Self.terminal, at: Self.start + 3_000)],
            receivedAt: Self.date(Self.start + 3_500)
        )
        #expect(composer.closeAll().map(\.text) == ["sunshine"])
    }

    // MARK: - Secrets typed over several segments (review regressions)

    /// Types each string as its own segment, 1.5 s apart, and returns every
    /// entry that would be saved.
    private static func savedTexts(_ segments: [(text: String, app: String)], gap: Int64 = 1_500) -> [String] {
        var composer = composer()
        var saved: [String] = []
        for (index, segment) in segments.enumerated() {
            let at = start + Int64(index) * gap
            saved += composer.ingest(
                [typed(segment.text, session: "segment-\(index)", app: segment.app, at: at)],
                receivedAt: date(at + 200)
            ).map(\.text)
        }
        return saved + composer.closeAll().map(\.text)
    }

    @Test("A card typed over four boxes, then its expiry and CVC, never reaches a saved entry")
    func splitCardNeverSaved() {
        let safari = "com.apple.Safari"
        let saved = Self.savedTexts(["4111", "1111", "1111", "1111", "12/28", "123"].map { ($0, safari) })
        #expect(saved.isEmpty)
        #expect(!saved.joined().contains { $0.isNumber })
    }

    @Test("A one-time code typed one digit per box never reaches a saved entry")
    func splitOTPNeverSaved() {
        let saved = Self.savedTexts(["4", "8", "2", "9", "1", "3"].map { ($0, "com.google.Chrome") })
        #expect(saved.isEmpty)
    }

    @Test("A code typed into two boxes of three digits never reaches a saved entry")
    func multiDigitBoxesNeverSaved() {
        #expect(Self.savedTexts([("482", "com.google.Chrome"), ("913", "com.google.Chrome")]).isEmpty)
    }

    @Test("A PIN shared as a scrap with the next line folded in is still removed")
    func pinScrapWithNextLine() {
        let messages = "com.apple.MobileSMS"
        let saved = Self.savedTexts([("PIN 4821", messages), ("see you tonight", messages)])
        #expect(!saved.joined().contains("4821"))
        #expect(saved.joined().contains("see you tonight"))
    }

    @Test("Terminal: a password that arrives one character per segment after sudo is one redaction")
    func perCharacterTerminalPassword() {
        let saved = Self.savedTexts([("sudo -v", Self.terminal)] + "hunter2".map { (String($0), Self.terminal) })
        #expect(saved == ["sudo -v\n\(Self.redactedPassword)"])
    }

    @Test("Terminal: a message in another app between sudo and the password doesn't lose the context")
    func terminalContextSurvivesOtherApp() {
        var composer = Self.composer()
        var saved = composer.ingest([
            Self.typed("sudo apt update", session: "t1", app: Self.terminal, at: Self.start),
            Self.typed("brb one sec", session: "s1", app: Self.slack, at: Self.start + 3_000),
            Self.typed("sunshine", session: "t2", app: Self.terminal, at: Self.start + 70_000),
        ], receivedAt: Self.date(Self.start + 70_500)).map(\.text)
        saved += composer.closeAll().map(\.text)
        #expect(saved == ["sudo apt update", "brb one sec"])
    }

    @Test("Terminal: the context lasts as long as sudo waits for a password")
    func terminalContextLastsWhileSudoWaits() {
        var composer = Self.composer()
        var saved = composer.ingest([
            Self.typed("sudo apt update", session: "t1", app: Self.terminal, at: Self.start),
            Self.typed("sunshine", session: "t2", app: Self.terminal, at: Self.start + 240_000),
        ], receivedAt: Self.date(Self.start + 240_500)).map(\.text)
        saved += composer.closeAll().map(\.text)
        #expect(saved == ["sudo apt update"])
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
