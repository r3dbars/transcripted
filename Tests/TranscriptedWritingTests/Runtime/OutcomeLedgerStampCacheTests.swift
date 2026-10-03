import Foundation
import Testing
@testable import TranscriptedWritingRuntime
@testable import TranscriptedWritingCore

/// The Writing tab's stamped refresh: an unchanged ledger hands back the
/// previous summary without reading a line; an append, a new day, a
/// replaced file or a missing file all recompute. Temp files and an
/// explicit `now` only; nothing touches the owner's real ledger.
@Suite("Outcome ledger stamp cache")
struct OutcomeLedgerStampCacheTests {
    /// Whole seconds, so ISO 8601 round trips compare equal.
    private let now = Date(timeIntervalSince1970: 1_756_742_400)
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// A deliberately impossible summary: getting it back proves a hit
    /// didn't re-read the file.
    private let sentinel = OutcomeLedgerSummary(
        keystrokesSavedToday: 999_999,
        ghostsShownToday: 1,
        acceptedGhostsToday: 1,
        keptAfter30SecondsShare: nil,
        keptAfter30SecondsObservations: 0,
        helpfulStreaksToday: 0,
        longestHelpfulStreakToday: 0,
        heldBackTodayByReason: [:],
        keystrokesSavedLast7Days: 999_999,
        truncated: false
    )

    private func event(at occurredAt: Date, accepted: Int) throws -> TextFreeOnlineEvent {
        TextFreeOnlineEvent(
            occurredAt: occurredAt,
            sessionDigestSHA256: TextFreeOnlineEvent.sessionDigest(sessionIdentifier: "a"),
            appCategory: TextFreeAppCategory.prose.rawValue,
            register: "prose",
            boundary: TextFreeCursorBoundary.wordBoundary.rawValue,
            safeOpportunity: true,
            generated: true,
            displayed: true,
            outcome: "accepted",
            acceptedCharacters: accepted,
            candidateCharacters: accepted,
            candidateSourceBucket: TextFreeCandidateSource.baseModel.rawValue,
            candidateLengthBucket: TextFreeLengthBucket.oneWord.rawValue,
            opportunityCharacters: 12,
            retentionAt5Seconds: try RetainedCharacterObservation(retainedCharacters: accepted),
            retentionAt30Seconds: RetainedCharacterObservation(missingness: .notYetObserved),
            retentionAtSegmentClose: RetainedCharacterObservation(missingness: .notYetObserved)
        )
    }

    private func lines(_ events: [TextFreeOnlineEvent]) throws -> Data {
        var data = Data()
        for event in events { data.append(try TextFreeOnlineEvent.encodeJSONL(event)) }
        return data
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("outcome-ledger-stamp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func uncached(_ url: URL, now: Date) -> OutcomeLedgerSummary {
        OutcomeLedgerSummary.make(
            facts: OutcomeLedgerReader.facts(in: OutcomeLedgerReader.readTail(url: url)),
            now: now,
            calendar: calendar,
            truncated: OutcomeLedgerReader.readTail(url: url).truncated
        )
    }

    private func stamped(
        _ url: URL,
        now: Date,
        reusing previous: (stamp: OutcomeLedgerReader.Stamp, summary: OutcomeLedgerSummary)?
    ) -> (summary: OutcomeLedgerSummary, stamp: OutcomeLedgerReader.Stamp?) {
        OutcomeLedgerReader.stampedSummary(
            url: url,
            now: now,
            maximumBytes: OutcomeLedgerReader.maximumTailBytes,
            reusing: previous,
            calendar: calendar
        )
    }

    @Test("A cold read matches the uncached summary")
    func coldReadMatches() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.jsonl")
        try lines([
            try event(at: now, accepted: 4),
            try event(at: now.addingTimeInterval(-86_400 * 2), accepted: 7),
        ]).write(to: url)

        let cold = stamped(url, now: now, reusing: nil)
        #expect(cold.stamp != nil)
        #expect(cold.summary == uncached(url, now: now))
        #expect(cold.summary.keystrokesSavedToday == 4)
        #expect(cold.summary.keystrokesSavedLast7Days == 11)

        // The async entry point, on the default calendar, agrees with the
        // existing uncached one.
        let viaAsync = await OutcomeLedgerReader.summary(url: url, now: now, reusing: nil)
        #expect(viaAsync.summary == (await OutcomeLedgerReader.summary(url: url, now: now)))
    }

    @Test("An unchanged file hands back the previous summary")
    func unchangedFileHits() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.jsonl")
        try lines([try event(at: now, accepted: 4)]).write(to: url)

        let cold = stamped(url, now: now, reusing: nil)
        let stamp = try #require(cold.stamp)
        let hit = stamped(url, now: now.addingTimeInterval(60), reusing: (stamp, sentinel))
        #expect(hit.summary == sentinel)
        #expect(hit.stamp == stamp)
    }

    @Test("An appended line recomputes")
    func appendRecomputes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.jsonl")
        try lines([try event(at: now, accepted: 4)]).write(to: url)
        let stamp = try #require(stamped(url, now: now, reusing: nil).stamp)

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: try lines([try event(at: now.addingTimeInterval(10), accepted: 3)]))
        try handle.close()

        let after = stamped(url, now: now, reusing: (stamp, sentinel))
        #expect(after.summary != sentinel)
        #expect(after.summary == uncached(url, now: now))
        #expect(after.summary.keystrokesSavedToday == 7)
        #expect(after.stamp != stamp)
    }

    @Test("The next day recomputes on the same file")
    func dayChangeRecomputes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.jsonl")
        try lines([try event(at: now, accepted: 4)]).write(to: url)
        let stamp = try #require(stamped(url, now: now, reusing: nil).stamp)

        let tomorrow = now.addingTimeInterval(86_400)
        let next = stamped(url, now: tomorrow, reusing: (stamp, sentinel))
        #expect(next.summary != sentinel)
        #expect(next.summary == uncached(url, now: tomorrow))
        #expect(next.summary.keystrokesSavedToday == 0)
        #expect(next.summary.keystrokesSavedLast7Days == 4)
    }

    @Test("A same-length file swapped in by rename recomputes")
    func replacedFileRecomputes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.jsonl")
        let original = try lines([try event(at: now, accepted: 4)])
        try original.write(to: url)
        let stamp = try #require(stamped(url, now: now, reusing: nil).stamp)

        let replacement = try lines([try event(at: now, accepted: 5)])
        #expect(replacement.count == original.count)
        let staging = directory.appendingPathComponent("events.jsonl.new")
        try replacement.write(to: staging)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: staging)

        let after = stamped(url, now: now, reusing: (stamp, sentinel))
        #expect(after.summary != sentinel)
        #expect(after.summary.keystrokesSavedToday == 5)
    }

    @Test("A missing file is empty with no stamp, whatever came before")
    func missingFileIsEmpty() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.jsonl")
        try lines([try event(at: now, accepted: 4)]).write(to: url)
        let stamp = try #require(stamped(url, now: now, reusing: nil).stamp)

        try FileManager.default.removeItem(at: url)
        let gone = stamped(url, now: now, reusing: (stamp, sentinel))
        #expect(gone.summary == .empty)
        #expect(gone.stamp == nil)
    }
}
