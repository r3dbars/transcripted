import XCTest
@testable import transcripted_mcp

final class TranscriptIndexTests: XCTestCase {
    var index: TranscriptIndex!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = makeTempDir()
        index = try! TranscriptIndex(indexDir: tempDir)
    }

    override func tearDown() {
        index = nil
        removeTempDir(tempDir)
        super.tearDown()
    }

    func testEmptyIndexReturnsNoResults() throws {
        let results = try index.searchUtterances(query: "hello", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertTrue(results.results.isEmpty)
    }

    func testEmptyIndexListsNoMeetings() throws {
        let meetings = try index.listRecentMeetings(count: 10)
        XCTAssertTrue(meetings.isEmpty)
    }

    func testIndexAndSearchSingleUtterance() throws {
        let fixture = makeFixtureJSON(utterances: [
            ("system_0", 0.0, 5.0, "Let's discuss the product roadmap"),
        ])
        try writeFixture(fixture, filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let results = try index.searchUtterances(query: "roadmap", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(results.results.count, 1)
        XCTAssertEqual(results.results[0].snippets.count, 1)
        XCTAssertTrue(results.results[0].snippets[0].text.contains("roadmap"))
    }

    func testPorterStemming() throws {
        let fixture = makeFixtureJSON(utterances: [
            ("mic_0", 0.0, 3.0, "We were designing the new feature"),
        ])
        try writeFixture(fixture, filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        // "design" should match "designing" via porter stemming
        let results = try index.searchUtterances(query: "design", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertFalse(results.results.isEmpty)
    }

    func testSpeakerFilter() throws {
        let fixture = makeFixtureJSON(utterances: [
            ("system_0", 0.0, 5.0, "Product is looking great"),
            ("mic_0", 5.0, 10.0, "I agree about the product"),
        ])
        try writeFixture(fixture, filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let results = try index.searchUtterances(query: "product", speaker: "Jenny", dateFrom: nil, dateTo: nil)
        XCTAssertEqual(results.results.count, 1)
        XCTAssertEqual(results.results[0].snippets.count, 1)
        XCTAssertEqual(results.results[0].snippets[0].speaker, "Jenny Wen")
    }

    func testDateRangeFilter() throws {
        let fixture1 = makeFixtureJSON(date: "2026-03-28T10:00:00-0500", utterances: [
            ("mic_0", 0.0, 3.0, "Old meeting discussion"),
        ])
        let fixture2 = makeFixtureJSON(date: "2026-03-30T10:00:00-0500", utterances: [
            ("mic_0", 0.0, 3.0, "New meeting discussion"),
        ])
        try writeFixture(fixture1, filename: "Call_2026-03-28_10-00-00", to: tempDir)
        try writeFixture(fixture2, filename: "Call_2026-03-30_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let results = try index.searchUtterances(query: "meeting", speaker: nil, dateFrom: "2026-03-29", dateTo: nil)
        XCTAssertEqual(results.results.count, 1)
        XCTAssertTrue(results.results[0].snippets[0].text.contains("New"))
    }

    func testReconcileRemovesDeletedFiles() throws {
        let fixture = makeFixtureJSON(utterances: [("mic_0", 0.0, 3.0, "Temporary")])
        try writeFixture(fixture, filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        XCTAssertEqual(try index.listRecentMeetings(count: 10).count, 1)

        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("Call_2026-03-29_10-00-00.md"))
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        XCTAssertEqual(try index.listRecentMeetings(count: 10).count, 0)
    }

    func testMalformedMarkdownIsSkipped() throws {
        try "not markdown".write(to: tempDir.appendingPathComponent("Call_2026-03-29_10-00-00.md"), atomically: true, encoding: .utf8)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let results = try index.listRecentMeetings(count: 10)
        XCTAssertTrue(results.isEmpty)
    }

    func testFTS5SpecialCharacters() throws {
        let fixture = makeFixtureJSON(utterances: [
            ("mic_0", 0.0, 5.0, "The C++ implementation is ready"),
        ])
        try writeFixture(fixture, filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        // These should not crash even with FTS5 special chars
        _ = try index.searchUtterances(query: "C++", speaker: nil, dateFrom: nil, dateTo: nil)
        _ = try index.searchUtterances(query: "\"quoted phrase\"", speaker: nil, dateFrom: nil, dateTo: nil)
        _ = try index.searchUtterances(query: "AND OR NEAR", speaker: nil, dateFrom: nil, dateTo: nil)
        _ = try index.searchUtterances(query: "(parentheses)", speaker: nil, dateFrom: nil, dateTo: nil)
        _ = try index.searchUtterances(query: "test*wildcard", speaker: nil, dateFrom: nil, dateTo: nil)
    }

    func testSearchGroupsByMeeting() throws {
        // One meeting with many matching utterances
        let fixture = makeFixtureJSON(utterances: [
            ("system_0", 0.0, 5.0, "Let's talk about the roadmap"),
            ("mic_0", 5.0, 10.0, "The roadmap needs updating"),
            ("system_0", 10.0, 15.0, "I agree the roadmap is stale"),
            ("mic_0", 15.0, 20.0, "We should revise the roadmap"),
            ("system_0", 20.0, 25.0, "The roadmap review is next week"),
        ])
        try writeFixture(fixture, filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let results = try index.searchUtterances(query: "roadmap", speaker: nil, dateFrom: nil, dateTo: nil, snippetsPerMeeting: 3)
        XCTAssertEqual(results.results.count, 1) // One meeting
        XCTAssertLessThanOrEqual(results.results[0].snippets.count, 3) // Max 3 snippets
    }

    func testListRecentMeetingsClampsTo50() throws {
        let meetings = try index.listRecentMeetings(count: 999)
        XCTAssertTrue(meetings.isEmpty) // Empty but didn't crash
    }

    func testListRecentMeetingsIncludesSpeakers() throws {
        let fixture = makeFixtureJSON()
        try writeFixture(fixture, filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let meetings = try index.listRecentMeetings(count: 10)
        XCTAssertEqual(meetings.count, 1)
        XCTAssertFalse(meetings[0].speakers.isEmpty)
    }

    func testGetSpeakerHistoryByName() throws {
        let fixture = makeFixtureJSON()
        try writeFixture(fixture, filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let history = try index.getSpeakerHistory(speaker: "Jenny")
        XCTAssertEqual(history.meetingCount, 1)
        XCTAssertEqual(history.matchedName, "Jenny Wen")
    }

    func testGetSpeakerHistoryByUUID() throws {
        let fixture = makeFixtureJSON()
        try writeFixture(fixture, filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let history = try index.getSpeakerHistory(speaker: "80FB272B-6061-4FC4-8408-3F7A974C59DB")
        XCTAssertEqual(history.meetingCount, 1)
    }

    func testGetSpeakerHistoryUnknownSpeaker() throws {
        let history = try index.getSpeakerHistory(speaker: "Nonexistent Person")
        XCTAssertEqual(history.meetingCount, 0)
    }

    func testListDictationDays() throws {
        try writeFixture(makeDictationDayJSON(), filename: "Dictations_2026-04-07", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let days = try index.listDictationDays(count: 10)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].entryCount, 2)
        XCTAssertTrue(days[0].sourceApps.contains("Slack"))
    }

    func testSearchContextReturnsMeetingsAndDictations() throws {
        try writeFixture(makeFixtureJSON(utterances: [
            ("system_0", 0.0, 5.0, "Roadmap meeting update"),
        ]), filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try writeFixture(makeDictationDayJSON(entries: [
            ("dictation-20260407-091500-000", "2026-04-07T09:15:00-0500", "Roadmap note", "Remember the roadmap follow-up after the meeting", "Slack", "copied"),
        ]), filename: "Dictations_2026-04-07", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let results = try index.searchContext(query: "roadmap", speaker: nil, kind: .all, dateFrom: nil, dateTo: nil, maxItems: 10)
        XCTAssertEqual(results.results.count, 2)
        XCTAssertEqual(results.results.first?.kind, .dictation)
        XCTAssertEqual(results.results.last?.kind, .meeting)
    }

    func testRecentContextIncludesDictationEntries() throws {
        try writeFixture(makeFixtureJSON(date: "2026-03-29T10:00:00-0500"), filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try writeFixture(makeDictationDayJSON(), filename: "Dictations_2026-04-07", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let result = try index.listRecentContext(kind: .all, count: 10)
        XCTAssertEqual(result.items.count, 3)
        XCTAssertEqual(result.items.first?.kind, .dictation)
    }

    func testRecentContextMeetingPreviewUsesFirstUtterance() throws {
        try writeFixture(makeFixtureJSON(date: "2026-03-29T10:00:00-0500"), filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let result = try index.listRecentContext(kind: .meeting, count: 10)

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.preview, "Good morning everyone")
    }

    func testRecentContextEmptyMeetingUsesExplicitPreview() throws {
        try writeFixture(
            makeFixtureJSON(
                date: "2026-03-29T10:00:00-0500",
                speakers: [],
                utterances: []
            ),
            filename: "Call_2026-03-29_10-00-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let result = try index.listRecentContext(kind: .meeting, count: 10)

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.preview, "No transcript captured.")
    }
}
