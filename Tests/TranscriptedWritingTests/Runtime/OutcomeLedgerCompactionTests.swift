import Foundation
import Testing
@testable import TranscriptedWritingRuntime
@testable import TranscriptedWritingCore

/// The ledger stays bounded: past the threshold it is cut back to its newest
/// whole lines, and the seven-day window survives the cut. Temp files and an
/// explicit `now` only; nothing touches the owner's real ledger.
@Suite("Outcome ledger compaction")
struct OutcomeLedgerCompactionTests {
    private let now = Date(timeIntervalSince1970: 1_756_742_400)

    private func line(at occurredAt: Date, accepted: Int) throws -> Data {
        try TextFreeOnlineEvent.encodeJSONL(TextFreeOnlineEvent(
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
        ))
    }

    @Test("Past the threshold the file shrinks and keeps the last seven days")
    func compactsPastThreshold() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("outcome-ledger-compaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(TextFreeOnlineEventFile.fileName)

        let old = try line(at: now.addingTimeInterval(-86_400 * 20), accepted: 1)
        let recent = try line(at: now.addingTimeInterval(-86_400 * 2), accepted: 3)
        let recentCount = 2_000
        let oldCount = TextFreeOnlineEventFile.compactionThresholdBytes / old.count
        var data = Data(capacity: old.count * oldCount + recent.count * recentCount)
        for _ in 0..<oldCount { data.append(old) }
        for _ in 0..<recentCount { data.append(recent) }
        try data.write(to: url)
        #expect(data.count > TextFreeOnlineEventFile.compactionThresholdBytes)

        TextFreeOnlineEventFile.compactIfNeeded(at: url)

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = try #require(attributes[.size] as? Int)
        #expect(size <= TextFreeOnlineEventFile.retainedTailBytes)
        #expect((attributes[.posixPermissions] as? Int) == 0o600)

        let tail = OutcomeLedgerReader.readTail(url: url)
        #expect(!tail.truncated)
        let facts = OutcomeLedgerReader.facts(in: tail)
        #expect(facts.count == tail.lines.count)
        #expect(facts.filter { $0.acceptedCharacters == 3 }.count == recentCount)
        let summary = OutcomeLedgerSummary.make(facts: facts, now: now, truncated: tail.truncated)
        #expect(summary.keystrokesSavedLast7Days == 3 * recentCount)
    }

    @Test("Under the threshold the file is left alone")
    func leavesSmallFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("outcome-ledger-compaction-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(TextFreeOnlineEventFile.fileName)
        let data = try line(at: now, accepted: 4)
        try data.write(to: url)

        TextFreeOnlineEventFile.compactIfNeeded(at: url)

        #expect(try Data(contentsOf: url) == data)
    }
}
