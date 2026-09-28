import Foundation
import Testing
@testable import TranscriptedWritingRuntime
@testable import TranscriptedWritingCore

/// Synthetic, text-free ledger lines only. Nothing here reads or writes the
/// owner's real Application Support directory.
private enum LedgerFixture {
    static let sessionA = TextFreeOnlineEvent.sessionDigest(sessionIdentifier: "a")
    static let sessionB = TextFreeOnlineEvent.sessionDigest(sessionIdentifier: "b")

    /// Whole seconds: ISO 8601 encoding drops fractions, so a round trip
    /// through the file must compare equal.
    static let noon = Date(timeIntervalSince1970: 1_756_742_400)

    static func shown(
        at occurredAt: Date,
        session: String = sessionA,
        accepted: Int,
        retainedAt30Seconds: Int? = nil,
        missingAt30Seconds: RetentionMissingness = .notYetObserved
    ) throws -> TextFreeOnlineEvent {
        TextFreeOnlineEvent(
            occurredAt: occurredAt,
            sessionDigestSHA256: session,
            appCategory: TextFreeAppCategory.prose.rawValue,
            register: "prose",
            boundary: TextFreeCursorBoundary.wordBoundary.rawValue,
            safeOpportunity: true,
            generated: true,
            displayed: true,
            outcome: accepted > 0 ? "accepted" : "ignored",
            acceptedCharacters: accepted,
            candidateCharacters: max(accepted, 1),
            candidateSourceBucket: TextFreeCandidateSource.baseModel.rawValue,
            candidateLengthBucket: TextFreeLengthBucket.oneWord.rawValue,
            opportunityCharacters: 12,
            retentionAt5Seconds: try RetainedCharacterObservation(retainedCharacters: accepted),
            retentionAt30Seconds: retainedAt30Seconds.map {
                try! RetainedCharacterObservation(retainedCharacters: $0)
            } ?? RetainedCharacterObservation(missingness: missingAt30Seconds),
            retentionAtSegmentClose: RetainedCharacterObservation(missingness: .notYetObserved)
        )
    }

    static func silent(
        at occurredAt: Date,
        session: String = sessionA,
        reason: SuggestionDecisionReason
    ) throws -> TextFreeOnlineEvent {
        try TextFreeOnlineEvent.silent(
            id: UUID(),
            occurredAt: occurredAt,
            sessionDigestSHA256: session,
            variant: "champion",
            appCategory: TextFreeAppCategory.prose.rawValue,
            register: "prose",
            boundary: TextFreeCursorBoundary.wordBoundary.rawValue,
            reason: reason,
            generated: false,
            deadlineMissed: false,
            generatorMilliseconds: nil,
            firstStableWordMilliseconds: nil,
            nextActionMilliseconds: nil,
            opportunityCharacters: 9
        )
    }

    static func write(_ events: [TextFreeOnlineEvent], to url: URL) throws {
        var data = Data()
        for event in events { data.append(try TextFreeOnlineEvent.encodeJSONL(event)) }
        try data.write(to: url)
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("outcome-ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@Suite("Outcome ledger aggregates")
struct OutcomeLedgerSummaryTests {
    private let now = LedgerFixture.noon

    @Test("Keystrokes saved separate today from the seven-day window")
    func keystrokesSaved() throws {
        let facts = [
            OutcomeLedgerFact(event: try LedgerFixture.shown(at: now.addingTimeInterval(-3_600), accepted: 12)),
            OutcomeLedgerFact(event: try LedgerFixture.shown(at: now.addingTimeInterval(-600), accepted: 7)),
            OutcomeLedgerFact(event: try LedgerFixture.shown(at: now.addingTimeInterval(-600), accepted: 0)),
            // Three days ago: in the window, not today.
            OutcomeLedgerFact(event: try LedgerFixture.shown(at: now.addingTimeInterval(-3 * 86_400), accepted: 40)),
            // Twenty days ago: outside the window entirely.
            OutcomeLedgerFact(event: try LedgerFixture.shown(at: now.addingTimeInterval(-20 * 86_400), accepted: 999)),
        ]

        let summary = OutcomeLedgerSummary.make(facts: facts, now: now)

        #expect(summary.keystrokesSavedToday == 19)
        #expect(summary.keystrokesSavedLast7Days == 59)
        #expect(summary.ghostsShownToday == 3)
        #expect(summary.acceptedGhostsToday == 2)
        #expect(summary.hasTodayEvidence)
    }

    @Test("A missing 30-second horizon is excluded, never counted as zero")
    func missingHorizonIsNotZero() throws {
        let kept = OutcomeLedgerFact(
            event: try LedgerFixture.shown(at: now, accepted: 10, retainedAt30Seconds: 8)
        )
        let unobserved = OutcomeLedgerFact(
            event: try LedgerFixture.shown(
                at: now,
                accepted: 100,
                missingAt30Seconds: .observerStopped
            )
        )

        let both = OutcomeLedgerSummary.make(facts: [kept, unobserved], now: now)
        #expect(both.keptAfter30SecondsObservations == 1)
        #expect(both.keptAfter30SecondsShare == 0.8)

        // Had the missing horizon been read as zero, the share would be 8/110.
        #expect(both.keptAfter30SecondsShare != 8.0 / 110.0)

        let noneObserved = OutcomeLedgerSummary.make(facts: [unobserved], now: now)
        #expect(noneObserved.keptAfter30SecondsShare == nil)
        #expect(noneObserved.keptAfter30SecondsObservations == 0)
        #expect(OutcomeLedgerPresentation.keptAfter30SecondsLine(summary: noneObserved) == nil)
    }

    @Test("Retention cannot exceed what was accepted")
    func retentionIsClamped() throws {
        let overshoot = OutcomeLedgerFact(
            event: try LedgerFixture.shown(at: now, accepted: 5, retainedAt30Seconds: 40)
        )
        let summary = OutcomeLedgerSummary.make(facts: [overshoot], now: now)
        #expect(summary.keptAfter30SecondsShare == 1)
    }

    @Test("Helpful streaks need three close accepts inside one session")
    func helpfulStreaks() throws {
        var facts: [OutcomeLedgerFact] = []
        // Session A: three accepts a minute apart — one streak.
        for step in 0..<3 {
            facts.append(OutcomeLedgerFact(event: try LedgerFixture.shown(
                at: now.addingTimeInterval(Double(step) * 60),
                session: LedgerFixture.sessionA,
                accepted: 4
            )))
        }
        // Session A again, an hour later: only two accepts, not a streak.
        for step in 0..<2 {
            facts.append(OutcomeLedgerFact(event: try LedgerFixture.shown(
                at: now.addingTimeInterval(3_600 + Double(step) * 30),
                session: LedgerFixture.sessionA,
                accepted: 4
            )))
        }
        // Session B: four accepts close together — a second, longer streak.
        for step in 0..<4 {
            facts.append(OutcomeLedgerFact(event: try LedgerFixture.shown(
                at: now.addingTimeInterval(Double(step) * 20),
                session: LedgerFixture.sessionB,
                accepted: 4
            )))
        }

        let summary = OutcomeLedgerSummary.make(facts: facts, now: now)
        #expect(summary.helpfulStreaksToday == 2)
        #expect(summary.longestHelpfulStreakToday == 4)
        #expect(OutcomeLedgerPresentation.helpfulStreakLine(summary: summary)
            == "2 helpful streaks today (best 4 in a row)")
    }

    @Test("Three accepts spread far apart are not a streak")
    func spreadAcceptsAreNotAStreak() throws {
        let facts = try (0..<3).map { step in
            OutcomeLedgerFact(event: try LedgerFixture.shown(
                at: now.addingTimeInterval(Double(step) * 600),
                accepted: 4
            ))
        }
        #expect(OutcomeLedgerSummary.make(facts: facts, now: now).helpfulStreaksToday == 0)
    }
}

@Suite("Outcome ledger silence grouping")
struct OutcomeLedgerReasonTests {
    private let now = LedgerFixture.noon

    @Test("Every terminal reason but shown lands in exactly one human bucket")
    func everyReasonIsGrouped() {
        for reason in SuggestionDecisionReason.allCases {
            let bucket = HeldBackReason(reason: reason)
            if reason == .shown {
                #expect(bucket == nil)
            } else {
                #expect(bucket != nil, "\(reason.rawValue) has no human reason")
            }
        }
    }

    @Test("Silent events group and pick a top reason")
    func grouping() throws {
        let reasons: [SuggestionDecisionReason] = [
            .supersededByTyping, .supersededByTyping, .notAtGrowingEdge, .fieldTargetLost,
            .sensitiveScene,
            .noSuggestion, .emptyOutput,
            .completeSentenceScene, .selfRepetition, .promptLeak,
        ]
        let facts = try reasons.map {
            OutcomeLedgerFact(event: try LedgerFixture.silent(at: now, reason: $0))
        }

        let summary = OutcomeLedgerSummary.make(facts: facts, now: now)
        #expect(summary.heldBackToday == 10)
        #expect(summary.heldBackTodayByReason[.keptTyping] == 4)
        #expect(summary.heldBackTodayByReason[.sensitive] == 1)
        #expect(summary.heldBackTodayByReason[.modelHadNothing] == 2)
        #expect(summary.heldBackTodayByReason[.filtersNotConfident] == 3)
        #expect(summary.heldBackTodayByReason[.notReady] == nil)
        #expect(summary.topHeldBackReason == .keptTyping)
        #expect(summary.ghostsShownToday == 0)
        #expect(summary.keystrokesSavedToday == 0)

        #expect(OutcomeLedgerPresentation.heldBackLine(summary: summary, screenAccessGranted: true)
            == "Autocomplete held back 10 times today, mostly because you kept typing.")
    }

    @Test("A tie breaks toward the most actionable reason")
    func tieBreak() throws {
        let facts = try [SuggestionDecisionReason.supersededByTyping, .runtimeUnavailable].map {
            OutcomeLedgerFact(event: try LedgerFixture.silent(at: now, reason: $0))
        }
        #expect(OutcomeLedgerSummary.make(facts: facts, now: now).topHeldBackReason == .notReady)
    }

    @Test("Considered silence never reads as a broken product")
    func silenceIsExplained() throws {
        let notReady = try (0..<4).map { _ in
            OutcomeLedgerFact(event: try LedgerFixture.silent(at: now, reason: .runtimeUnavailable))
        }
        let summary = OutcomeLedgerSummary.make(facts: notReady, now: now)

        let line = OutcomeLedgerPresentation.heldBackLine(
            summary: summary,
            screenAccessGranted: true
        )
        #expect(line == "Autocomplete held back 4 times today because it was not ready. Check the model status and Screen Recording.")

        let blocked = OutcomeLedgerPresentation.heldBackLine(
            summary: summary,
            screenAccessGranted: false
        )
        // Access went off part-way through a day that already has evidence:
        // the line must not claim the whole day was silent.
        #expect(blocked == "Screen Recording is off now, so autocomplete is not suggesting. Turn it on to get suggestions back.")
        #expect(OutcomeLedgerPresentation.heldBackLine(summary: .empty, screenAccessGranted: false)
            == "Screen Recording is off now, so autocomplete is not suggesting. Turn it on to get suggestions back.")

        // A quiet, healthy day says nothing at all.
        #expect(OutcomeLedgerPresentation.heldBackLine(
            summary: .empty,
            screenAccessGranted: true
        ) == nil)
    }

    @Test("Menu detail leads with value and stays honest when Tilde cannot answer")
    func menuDetail() throws {
        let helpful = OutcomeLedgerSummary.make(
            facts: [
                OutcomeLedgerFact(event: try LedgerFixture.shown(at: now, accepted: 120)),
                OutcomeLedgerFact(event: try LedgerFixture.silent(at: now, reason: .supersededByTyping)),
                OutcomeLedgerFact(event: try LedgerFixture.silent(at: now, reason: .supersededByTyping)),
            ],
            now: now
        )
        #expect(OutcomeLedgerPresentation.menuDetail(
            summary: helpful,
            wordsToday: 40,
            screenAccessGranted: true
        ) == "120 keystrokes saved today · held back 2×")

        let stalled = OutcomeLedgerSummary.make(
            facts: [
                OutcomeLedgerFact(event: try LedgerFixture.shown(at: now, accepted: 5)),
                OutcomeLedgerFact(event: try LedgerFixture.silent(at: now, reason: .runtimeUnavailable)),
            ],
            now: now
        )
        #expect(OutcomeLedgerPresentation.menuDetail(
            summary: stalled,
            wordsToday: 40,
            screenAccessGranted: true
        ) == "5 keystrokes saved today · quiet 1×, autocomplete was not ready")

        // No ledger evidence yet: the old words line, unchanged.
        #expect(OutcomeLedgerPresentation.menuDetail(
            summary: .empty,
            wordsToday: 40,
            screenAccessGranted: true
        ) == "40 words with autocomplete today")
        #expect(OutcomeLedgerPresentation.menuDetail(
            summary: .empty,
            wordsToday: 40,
            screenAccessGranted: false
        ) == "Screen Recording is off now — autocomplete is not suggesting")
    }
}

@Suite("Outcome ledger tail reader")
struct OutcomeLedgerReaderTests {
    private let now = LedgerFixture.noon

    @Test("A missing file is empty, not an error")
    func missingFile() async throws {
        let directory = try LedgerFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.jsonl")

        #expect(OutcomeLedgerReader.readTail(url: url) == .empty)
        #expect(await OutcomeLedgerReader.summary(url: url, now: now) == .empty)
    }

    @Test("An empty file and a garbage line degrade to fewer facts")
    func partialFile() async throws {
        let directory = try LedgerFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.jsonl")

        try Data().write(to: url)
        #expect(OutcomeLedgerReader.readTail(url: url) == .empty)

        var data = try TextFreeOnlineEvent.encodeJSONL(
            try LedgerFixture.shown(at: now, accepted: 6)
        )
        data.append(Data("{\"schema\":\"nope\"}\n".utf8))
        data.append(Data("not json at all\n".utf8))
        // A half-written final line, exactly as a crash would leave it.
        data.append(Data("{\"schema\":\"tilde-lab.online-event.v3\",\"accep".utf8))
        try data.write(to: url)

        let tail = OutcomeLedgerReader.readTail(url: url)
        #expect(tail.lines.count == 3)
        #expect(!tail.truncated)

        let summary = await OutcomeLedgerReader.summary(url: url, now: now)
        #expect(summary.keystrokesSavedToday == 6)
        #expect(summary.ghostsShownToday == 1)
    }

    @Test("The tail read is capped and drops the line the cut landed in")
    func tailCap() async throws {
        let directory = try LedgerFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.jsonl")

        let events = try (0..<60).map { step in
            try LedgerFixture.shown(at: now.addingTimeInterval(Double(-step)), accepted: 1)
        }
        try LedgerFixture.write(events, to: url)

        let fileBytes = try Data(contentsOf: url).count
        let cap = fileBytes / 4
        let tail = OutcomeLedgerReader.readTail(url: url, maximumBytes: cap)

        #expect(tail.truncated)
        #expect(!tail.lines.isEmpty)
        #expect(tail.lines.count < events.count)
        // Never more than the cap, counting the newline the writer appended.
        #expect(tail.lines.reduce(0) { $0 + $1.count + 1 } <= cap)
        // Every surviving line is whole and decodable.
        for line in tail.lines {
            #expect((try? TextFreeOnlineEvent.decodeProductionLine(line)) != nil)
        }

        let capped = await OutcomeLedgerReader.summary(url: url, now: now, maximumBytes: cap)
        #expect(capped.truncated)
        #expect(capped.keystrokesSavedToday == tail.lines.count)

        let whole = await OutcomeLedgerReader.summary(url: url, now: now)
        #expect(!whole.truncated)
        #expect(whole.keystrokesSavedToday == 60)
    }

    @Test("A round trip through the file preserves the aggregates")
    func roundTrip() async throws {
        let directory = try LedgerFixture.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.jsonl")

        try LedgerFixture.write([
            try LedgerFixture.shown(at: now, accepted: 10, retainedAt30Seconds: 9),
            try LedgerFixture.shown(at: now.addingTimeInterval(30), accepted: 6, retainedAt30Seconds: 6),
            try LedgerFixture.shown(at: now.addingTimeInterval(60), accepted: 4, retainedAt30Seconds: 3),
            try LedgerFixture.silent(at: now, reason: .sensitiveScene),
        ], to: url)

        let summary = await OutcomeLedgerReader.summary(url: url, now: now)
        #expect(summary.keystrokesSavedToday == 20)
        #expect(summary.acceptedGhostsToday == 3)
        #expect(summary.helpfulStreaksToday == 1)
        #expect(summary.heldBackToday == 1)
        #expect(summary.topHeldBackReason == .sensitive)
        #expect(summary.keptAfter30SecondsObservations == 3)
        #expect(summary.keptAfter30SecondsShare == 18.0 / 20.0)
    }
}

@Suite("Outcome ledger reads numbers only")
struct OutcomeLedgerFactProjectionTests {
    @Test("Every key the reader names is a real, text-free production key")
    func readKeysAreProductionKeys() {
        #expect(OutcomeLedgerFact.readKeys.isSubset(of: TextFreeOnlineEvent.allowedKeys))
    }

    @Test("Two events differing in every unread field project to the same fact")
    func projectionIgnoresEverythingElse() throws {
        let occurredAt = LedgerFixture.noon
        let session = LedgerFixture.sessionA

        func event(
            variant: String,
            appCategory: String,
            register: String,
            boundary: String,
            typingSpeedBucket: String,
            safeOpportunity: Bool,
            generated: Bool,
            policyHidden: Bool,
            outcome: String,
            replaced: Int,
            nextAction: Int?,
            generator: Int?,
            firstStableWord: Int?,
            settledVisible: Int?,
            deadlineMissed: Bool,
            candidateCharacters: Int,
            candidateSource: String,
            candidateLength: String,
            championDisagreed: Bool,
            configurationDigest: String?,
            crashed: Bool,
            timedOut: Bool,
            opportunityCharacters: Int,
            retentionAt5Seconds: Int,
            retentionAtSegmentClose: RetainedCharacterObservation
        ) throws -> TextFreeOnlineEvent {
            TextFreeOnlineEvent(
                occurredAt: occurredAt,
                sessionDigestSHA256: session,
                variant: variant,
                appCategory: appCategory,
                register: register,
                boundary: boundary,
                typingSpeedBucket: typingSpeedBucket,
                safeOpportunity: safeOpportunity,
                generated: generated,
                displayed: true,
                policyHidden: policyHidden,
                outcome: outcome,
                acceptedCharacters: 11,
                replacedCharactersWithin5Seconds: replaced,
                nextActionMilliseconds: nextAction,
                generatorMilliseconds: generator,
                firstStableWordMilliseconds: firstStableWord,
                settledVisibleMilliseconds: settledVisible,
                deadlineMissed: deadlineMissed,
                candidateCharacters: candidateCharacters,
                candidateSourceBucket: candidateSource,
                candidateLengthBucket: candidateLength,
                championDisagreed: championDisagreed,
                guardReason: nil,
                configurationDigestSHA256: configurationDigest,
                crashed: crashed,
                timedOut: timedOut,
                opportunityCharacters: opportunityCharacters,
                retentionAt5Seconds: try RetainedCharacterObservation(
                    retainedCharacters: retentionAt5Seconds
                ),
                retentionAt30Seconds: try RetainedCharacterObservation(retainedCharacters: 7),
                retentionAtSegmentClose: retentionAtSegmentClose
            )
        }

        let left = try event(
            variant: "champion",
            appCategory: "prose",
            register: "prose",
            boundary: "word-boundary",
            typingSpeedBucket: "slow",
            safeOpportunity: true,
            generated: true,
            policyHidden: false,
            outcome: "accepted",
            replaced: 0,
            nextAction: 120,
            generator: 300,
            firstStableWord: 90,
            settledVisible: 400,
            deadlineMissed: false,
            candidateCharacters: 11,
            candidateSource: TextFreeCandidateSource.baseModel.rawValue,
            candidateLength: TextFreeLengthBucket.oneWord.rawValue,
            championDisagreed: false,
            configurationDigest: "aaaa",
            crashed: false,
            timedOut: false,
            opportunityCharacters: 5,
            retentionAt5Seconds: 11,
            retentionAtSegmentClose: RetainedCharacterObservation(missingness: .notYetObserved)
        )

        let right = try event(
            variant: "candidate",
            appCategory: "chat",
            register: "chat",
            boundary: "mid-word",
            typingSpeedBucket: "fast",
            safeOpportunity: false,
            generated: false,
            policyHidden: true,
            outcome: "typed-through",
            replaced: 9,
            nextAction: nil,
            generator: nil,
            firstStableWord: nil,
            settledVisible: nil,
            deadlineMissed: true,
            candidateCharacters: 99,
            candidateSource: TextFreeCandidateSource.personal.rawValue,
            candidateLength: TextFreeLengthBucket.eightPlus.rawValue,
            championDisagreed: true,
            configurationDigest: nil,
            crashed: true,
            timedOut: true,
            opportunityCharacters: 4_000,
            retentionAt5Seconds: 0,
            retentionAtSegmentClose: RetainedCharacterObservation(missingness: .privacyExcluded)
        )

        #expect(left != right)
        #expect(OutcomeLedgerFact(event: left) == OutcomeLedgerFact(event: right))
    }

    @Test("A shown ghost carries no held-back reason and a silent one carries no accepts")
    func shapeOfEachSide() throws {
        let shown = OutcomeLedgerFact(event: try LedgerFixture.shown(
            at: LedgerFixture.noon,
            accepted: 3,
            retainedAt30Seconds: 3
        ))
        #expect(shown.displayed)
        #expect(shown.heldBackReason == nil)

        let silent = OutcomeLedgerFact(event: try LedgerFixture.silent(
            at: LedgerFixture.noon,
            reason: .timeout
        ))
        #expect(!silent.displayed)
        #expect(silent.acceptedCharacters == 0)
        #expect(silent.heldBackReason == .notReady)
        #expect(silent.retainedCharactersAt30Seconds == nil)
    }
}
