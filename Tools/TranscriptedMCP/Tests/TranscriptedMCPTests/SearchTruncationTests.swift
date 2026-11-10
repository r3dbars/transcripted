import XCTest
@testable import transcripted_mcp

final class SearchTruncationTests: XCTestCase {
    func testHybridRetainsUpstreamMatchCountsAndTruncation() {
        let group = MeetingSearchGroup(meetingTitle: "Fixture", meetingDate: "2026-04-07", meetingDateTime: "2026-04-07T09:00:00", filename: "fixture", snippets: [])
        for (lexicalTotal, semanticTotal) in [(4, 1), (1, 5)] {
            let result = SemanticSearchFusion.fuseGrouped(
                lexical: GroupedSearchResult(results: [group], totalMeetingsMatched: lexicalTotal, truncated: lexicalTotal > 1),
                semantic: GroupedSearchResult(results: [group], totalMeetingsMatched: semanticTotal, truncated: semanticTotal > 1),
                maxMeetings: 1, snippetsPerMeeting: 3
            )
            XCTAssertEqual(result.results.count, 1)
            XCTAssertEqual(result.totalMeetingsMatched, max(lexicalTotal, semanticTotal))
            XCTAssertTrue(result.truncated)
        }
    }

    func testContextReportsOmittedMatchesForEveryKindAndMixedQueries() throws {
        let root = makeTempDir()
        defer { removeTempDir(root) }
        let indexDirectory = root.appendingPathComponent("index")
        try FileManager.default.createDirectory(at: indexDirectory, withIntermediateDirectories: true)
        let index = try TranscriptIndex(indexDir: indexDirectory)
        for number in 0..<3 {
            try writeFixture(makeFixtureJSON(utterances: [("system_0", 0, 5, "Needle fixture")]), filename: "Call_fixture_\(number)", to: root)
        }
        try writeFixture(makeDictationDayJSON(entries: (0..<3).map {
            ("dictation-\($0)", "2026-04-07T09:15:00Z", "Fixture", "Needle fixture", "Notes", "copied")
        }), filename: "Dictations_2026-04-07", to: root)
        let entries: [WritingFixtureEntry] = (0..<3).map {
            ("writing-\($0)", "2026-04-07T09:15:00Z", "09:15 AM - Fixture", "Notes", nil, 2, 14, 0, "Needle fixture")
        }
        try writeFixture(makeWritingDayMarkdown(date: "2026-04-07", entries: entries), filename: "Writing_2026-04-07", to: root)
        try index.reconcile(meetingDirs: [root], dictationDirs: [root], writingDirs: [root])

        for kind: ContextKind in [.meeting, .dictation, .writing, .all] {
            let capped = try index.searchContext(query: "needle", speaker: nil, kind: kind, dateFrom: nil, dateTo: nil, maxItems: 1)
            XCTAssertEqual(capped.results.count, 1, "\(kind)")
            XCTAssertGreaterThan(capped.totalItemsMatched, 1, "\(kind)")
            XCTAssertTrue(capped.truncated, "\(kind)")

            let complete = try index.searchContext(query: "needle", speaker: nil, kind: kind, dateFrom: nil, dateTo: nil, maxItems: 10)
            XCTAssertEqual(complete.totalItemsMatched, kind == .all ? 9 : 3)
            XCTAssertFalse(complete.truncated, "\(kind)")
        }
        let speakerOnly = try index.searchContext(query: "needle", speaker: "Jenny", kind: .all, dateFrom: nil, dateTo: nil, maxItems: 1)
        XCTAssertEqual(speakerOnly.totalItemsMatched, 3)
        XCTAssertTrue(speakerOnly.truncated)
        XCTAssertTrue(speakerOnly.results.allSatisfy { $0.kind == .meeting })
    }
}
