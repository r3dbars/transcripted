import Foundation
import Testing
@testable import TranscriptedWritingCore

/// The strict production-line decode, as a table of inputs and outcomes:
/// an object first, then no unknown top-level key, then the v3 schema, then
/// the fields. Synthetic, text-free lines only.
@Suite("Production ledger line decode contract")
struct TextFreeOnlineEventDecodeContractTests {
    private static let occurredAt = Date(timeIntervalSince1970: 1_756_742_400)

    private func shown() throws -> TextFreeOnlineEvent {
        TextFreeOnlineEvent(
            occurredAt: Self.occurredAt,
            sessionDigestSHA256: TextFreeOnlineEvent.sessionDigest(sessionIdentifier: "s"),
            appCategory: "prose",
            register: "prose",
            boundary: "word-boundary",
            safeOpportunity: true,
            generated: true,
            displayed: true,
            outcome: "accepted",
            acceptedCharacters: 5,
            settledVisibleMilliseconds: 400,
            candidateCharacters: 5,
            candidateSourceBucket: TextFreeCandidateSource.baseModel.rawValue,
            candidateLengthBucket: TextFreeLengthBucket.oneWord.rawValue,
            opportunityCharacters: 12,
            retentionAt5Seconds: try RetainedCharacterObservation(retainedCharacters: 5),
            retentionAt30Seconds: RetainedCharacterObservation(missingness: .notYetObserved),
            retentionAtSegmentClose: RetainedCharacterObservation(missingness: .notYetObserved)
        )
    }

    private func silent() throws -> TextFreeOnlineEvent {
        try TextFreeOnlineEvent.silent(
            id: UUID(),
            occurredAt: Self.occurredAt,
            sessionDigestSHA256: TextFreeOnlineEvent.sessionDigest(sessionIdentifier: "s"),
            variant: "champion",
            appCategory: "chat",
            register: "chat",
            boundary: "word-boundary",
            reason: .sensitiveScene,
            generated: false,
            deadlineMissed: false,
            generatorMilliseconds: nil,
            firstStableWordMilliseconds: nil,
            nextActionMilliseconds: nil,
            opportunityCharacters: 4
        )
    }

    /// The writer's line without its newline, as a mutable string.
    private func line(_ event: TextFreeOnlineEvent) throws -> String {
        String(decoding: try TextFreeOnlineEvent.encodeJSONL(event).dropLast(), as: UTF8.self)
    }

    /// Puts raw JSON members first in the object.
    private func prepending(_ members: String, to line: String) -> Data {
        Data(("{" + members + "," + line.dropFirst()).utf8)
    }

    private func withoutSchema(_ line: String) -> String {
        line.replacingOccurrences(of: "\"schema\":\"\(TextFreeOnlineEvent.schema)\",", with: "")
    }

    @Test("Writer-encoded shown and silent lines round-trip")
    func writerLinesRoundTrip() throws {
        for event in [try shown(), try silent()] {
            let data = Data(try line(event).utf8)
            #expect(try TextFreeOnlineEvent.decodeProductionLine(data) == event)
        }
    }

    @Test("An unknown key is refused before the schema is checked")
    func unknownKeyBeatsSchema() throws {
        let v2 = withoutSchema(try line(try shown()))
        let data = prepending("\"aaa\":1,\"schema\":\"tilde-lab.online-event.v2\"", to: v2)
        #expect(throws: TextFreeOnlineEventError.unexpectedKey("aaa")) {
            try TextFreeOnlineEvent.decodeProductionLine(data)
        }
        // Several unknown keys: the first in sorted order is named.
        let two = prepending("\"zzz\":1,\"bbb\":2", to: try line(try shown()))
        #expect(throws: TextFreeOnlineEventError.unexpectedKey("bbb")) {
            try TextFreeOnlineEvent.decodeProductionLine(two)
        }
    }

    @Test("Anything but the v3 schema string is unsupported")
    func schemaMustBeV3() throws {
        let bare = withoutSchema(try line(try shown()))
        let cases: [Data] = [
            prepending("\"schema\":\"tilde-lab.online-event.v2\"", to: bare),
            prepending("\"schema\":null", to: bare),
            prepending("\"schema\":3", to: bare),
            Data(bare.utf8),
        ]
        for data in cases {
            #expect(throws: TextFreeOnlineEventError.unsupportedSchema) {
                try TextFreeOnlineEvent.decodeProductionLine(data)
            }
        }
    }

    @Test("A top-level array is a malformed line")
    func arrayIsMalformed() throws {
        let data = Data(("[" + (try line(try shown())) + "]").utf8)
        #expect(throws: TextFreeOnlineEventError.malformedLine) {
            try TextFreeOnlineEvent.decodeProductionLine(data)
        }
    }

    @Test("Garbage, trailing garbage, glued objects and raw control characters all throw")
    func invalidJSONThrows() throws {
        let good = try line(try shown())
        let cases: [Data] = [
            Data("not json at all".utf8),
            Data((good + " x").utf8),
            Data((good + good).utf8),
            Data(good.replacingOccurrences(of: "\"prose\"", with: "\"pro\u{01}se\"").utf8),
            Data(good.dropLast(10).utf8),
        ]
        for data in cases {
            #expect(throws: (any Error).self) {
                try TextFreeOnlineEvent.decodeProductionLine(data)
            }
        }
    }

    @Test("A duplicated schema key is judged by its first value")
    func duplicateSchemaFirstWins() throws {
        let event = try shown()
        let good = try line(event)
        let v3First = prepending("\"schema\":\"\(TextFreeOnlineEvent.schema)\"", to: withoutSchema(good))
        let duplicateAfterV3 = Data(
            (String(decoding: v3First, as: UTF8.self).dropLast() + ",\"schema\":\"tilde-lab.online-event.v2\"}").utf8
        )
        #expect(try TextFreeOnlineEvent.decodeProductionLine(duplicateAfterV3) == event)

        let v2First = prepending("\"schema\":\"tilde-lab.online-event.v2\"", to: good)
        #expect(throws: TextFreeOnlineEventError.unsupportedSchema) {
            try TextFreeOnlineEvent.decodeProductionLine(v2First)
        }
    }

    @Test("A leading byte order mark is accepted")
    func byteOrderMarkAccepted() throws {
        let event = try shown()
        var data = Data([0xEF, 0xBB, 0xBF])
        data.append(Data(try line(event).utf8))
        #expect(try TextFreeOnlineEvent.decodeProductionLine(data) == event)
    }

    @Test("Only top-level keys are checked; a nested extra key is ignored")
    func nestedExtraKeyAccepted() throws {
        let event = try shown()
        let good = try line(event)
        let nested = good.replacingOccurrences(
            of: "\"retentionAt5Seconds\":{",
            with: "\"retentionAt5Seconds\":{\"extra\":1,"
        )
        #expect(nested != good)
        #expect(try TextFreeOnlineEvent.decodeProductionLine(Data(nested.utf8)) == event)
    }
}
