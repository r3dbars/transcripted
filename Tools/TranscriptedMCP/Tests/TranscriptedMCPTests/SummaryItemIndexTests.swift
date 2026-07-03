import SQLite3
import XCTest
@testable import transcripted_mcp

/// parse → index → query coverage for the structured summary fields
/// (Decisions / Action Items / Open Questions) added to the MCP index.
final class SummaryItemIndexTests: XCTestCase {
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

    func testIndexesInlineSummaryItems() throws {
        try writeFixture(makeMeetingWithInlineSummary(), filename: "Call_2026-04-18_09-15-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let decisions = try index.listSummaryItems(kind: TranscriptIndex.SummaryItemKind.decision)
        XCTAssertEqual(decisions.map(\.text), ["Ship the beta on Friday", "Cut the legacy import path"])
        XCTAssertEqual(decisions.map(\.position), [0, 1])
        XCTAssertEqual(decisions.first?.meetingDate, "2026-04-18")

        let questions = try index.listSummaryItems(kind: TranscriptIndex.SummaryItemKind.openQuestion)
        XCTAssertEqual(questions.map(\.text), ["Do we need a migration window?"])
    }

    func testSearchIndexesSummaryTitleAttendeesAndSections() throws {
        try writeFixture(
            makeMeetingWithInlineSummary(
                attendees: ["Jenny", "Priya"],
                decisions: ["Adopt pricing decision memo"],
                actionItems: ["Priya: send launch checklist"],
                openQuestions: ["Should enterprise pricing wait?"]
            ),
            filename: "Call_2026-04-18_09-15-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let decision = try index.searchUtterances(query: "pricing decision", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(decision.results.first?.filename, "Call_2026-04-18_09-15-00")
        XCTAssertEqual(decision.results.first?.snippets.first?.speaker, "Summary")
        XCTAssertTrue(decision.results.first?.snippets.first?.text.contains("Decisions") == true)

        let attendee = try index.searchUtterances(query: "Priya", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(attendee.results.first?.filename, "Call_2026-04-18_09-15-00")
        XCTAssertTrue(attendee.results.first?.snippets.contains(where: { $0.timestamp == "Attendees" }) == true)

        let title = try index.searchUtterances(query: "Beta launch", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(title.results.first?.meetingTitle, "Beta launch sync")
    }

    func testSearchIndexesTitleAndAttendeesWhenFactSectionsAreEmpty() throws {
        try writeFixture(
            makeMeetingWithInlineSummary(
                attendees: ["Priya"],
                decisions: [],
                actionItems: [],
                openQuestions: []
            ),
            filename: "Call_2026-04-18_09-15-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        XCTAssertTrue(try index.listSummaryItems().isEmpty)

        let attendee = try index.searchUtterances(query: "Priya", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(attendee.results.first?.filename, "Call_2026-04-18_09-15-00")
        XCTAssertEqual(attendee.results.first?.snippets.first?.speaker, "Summary")

        let title = try index.searchUtterances(query: "Beta launch", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(title.results.first?.meetingTitle, "Beta launch sync")
    }

    func testSummarySearchRanksAboveRawUtteranceHits() throws {
        try writeFixture(
            makeMeetingWithInlineSummary(
                date: "2026-04-18",
                decisions: ["Pricing decision is to keep the beta free"],
                actionItems: [],
                openQuestions: []
            ).replacingOccurrences(
                of: "[00:00] [System/Jenny] Let's lock the launch.",
                with: "[00:00] [System/Jenny] Raw pricing decision transcript evidence"
            ),
            filename: "Call_2026-04-18_09-15-00",
            to: tempDir
        )
        try writeFixture(
            makeFixtureJSON(
                date: "2026-04-19T09:15:00-0500",
                utterances: [("system_0", 0.0, 5.0, "Raw pricing decision chatter")]
            ),
            filename: "Call_2026-04-19_09-15-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let results = try index.searchUtterances(query: "pricing decision", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(results.results.map(\.filename), [
            "Call_2026-04-18_09-15-00",
            "Call_2026-04-19_09-15-00"
        ])
        XCTAssertEqual(results.results.first?.snippets.first?.speaker, "Summary")
        XCTAssertEqual(results.results.first?.snippets.count, 3)
        XCTAssertTrue(results.results.first?.snippets.contains(where: {
            $0.speaker == "Jenny" && $0.timestamp == "0:00" && $0.text.contains("transcript evidence")
        }) == true)
    }

    func testIndexesActionItemOwnerAndUnassigned() throws {
        try writeFixture(makeMeetingWithInlineSummary(), filename: "Call_2026-04-18_09-15-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let actions = try index.listSummaryItems(kind: TranscriptIndex.SummaryItemKind.actionItem)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions[0].owner, "Jenny")
        XCTAssertEqual(actions[0].text, "send the revised spec")
        XCTAssertNil(actions[1].owner)

        // Owner filter rolls up across meetings; "" selects unassigned.
        let jenny = try index.listSummaryItems(kind: TranscriptIndex.SummaryItemKind.actionItem, owner: "jenny")
        XCTAssertEqual(jenny.map(\.text), ["send the revised spec"])
        let unassigned = try index.listSummaryItems(kind: TranscriptIndex.SummaryItemKind.actionItem, owner: "")
        XCTAssertEqual(unassigned.map(\.text), ["Follow up with legal"])
    }

    func testRollsUpAcrossMeetingsNewestFirst() throws {
        try writeFixture(
            makeMeetingWithInlineSummary(date: "2026-04-10", decisions: ["Older decision"]),
            filename: "Call_2026-04-10_09-15-00", to: tempDir
        )
        try writeFixture(
            makeMeetingWithInlineSummary(date: "2026-04-20", decisions: ["Newer decision"]),
            filename: "Call_2026-04-20_09-15-00", to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let decisions = try index.listSummaryItems(kind: TranscriptIndex.SummaryItemKind.decision)
        XCTAssertEqual(decisions.map(\.text), ["Newer decision", "Older decision"])

        let dated = try index.listSummaryItems(
            kind: TranscriptIndex.SummaryItemKind.decision,
            dateFrom: "2026-04-15"
        )
        XCTAssertEqual(dated.map(\.text), ["Newer decision"])
    }

    func testReindexReplacesSummaryItems() throws {
        let filename = "Call_2026-04-18_09-15-00"
        try writeFixture(makeMeetingWithInlineSummary(), filename: filename, to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        XCTAssertEqual(try index.listSummaryItems(kind: TranscriptIndex.SummaryItemKind.decision).count, 2)

        // Rewrite the same meeting with a single decision; reconcile should
        // replace, not accumulate.
        try writeFixture(
            makeMeetingWithInlineSummary(decisions: ["Only one decision now"]),
            filename: filename, to: tempDir
        )
        // Bump mtime so reconcile re-indexes.
        let url = tempDir.appendingPathComponent("\(filename).md")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let decisions = try index.listSummaryItems(kind: TranscriptIndex.SummaryItemKind.decision)
        XCTAssertEqual(decisions.map(\.text), ["Only one decision now"])
    }

    func testRemovingMeetingClearsSummaryItems() throws {
        let filename = "Call_2026-04-18_09-15-00"
        try writeFixture(makeMeetingWithInlineSummary(), filename: filename, to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        XCTAssertFalse(try index.listSummaryItems().isEmpty)

        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("\(filename).md"))
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        XCTAssertTrue(try index.listSummaryItems().isEmpty)
    }

    func testMeetingWithoutSummaryIndexesNoItems() throws {
        try writeFixture(makeFixtureJSON(), filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        XCTAssertTrue(try index.listSummaryItems().isEmpty)
        // The transcript itself still indexes as a meeting.
        XCTAssertEqual(try index.listRecentMeetings(count: 10).count, 1)
    }

    func testOlderSchemaVersionForcesRebuild() throws {
        // Simulate a pre-v2 index: index a meeting-with-summary, then stamp the
        // on-disk DB back to an older user_version to mimic an index built before
        // meeting_summary_items existed.
        try writeFixture(makeMeetingWithInlineSummary(), filename: "Call_2026-04-18_09-15-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        XCTAssertFalse(try index.listSummaryItems().isEmpty)
        index = nil // close the handle (deinit closes the db)

        let dbPath = tempDir.appendingPathComponent("mcp_index.sqlite").path
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "PRAGMA user_version=1", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        // Reopening trips the schema gate, which wipes the stale index.
        let reopened = try TranscriptIndex(indexDir: tempDir)
        XCTAssertTrue(try reopened.listRecentMeetings(count: 10).isEmpty)

        // A reconcile rebuilds everything, now including summary items.
        try reopened.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        XCTAssertEqual(try reopened.listRecentMeetings(count: 10).count, 1)
        XCTAssertEqual(try reopened.listSummaryItems(kind: TranscriptIndex.SummaryItemKind.decision).count, 2)
    }

    func testVersionTwoIndexBackfillsSummarySearchDocuments() throws {
        try writeFixture(makeMeetingWithInlineSummary(), filename: "Call_2026-04-18_09-15-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        index = nil

        let dbPath = tempDir.appendingPathComponent("mcp_index.sqlite").path
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "PRAGMA user_version=2", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        let reopened = try TranscriptIndex(indexDir: tempDir)
        XCTAssertTrue(try reopened.searchUtterances(query: "beta", speaker: nil, dateFrom: nil, dateTo: nil).results.isEmpty)

        try reopened.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        XCTAssertEqual(
            try reopened.searchUtterances(query: "Beta launch", speaker: nil, dateFrom: nil, dateTo: nil).results.first?.filename,
            "Call_2026-04-18_09-15-00"
        )
    }

    func testFiveHundredMeetingSummaryBackfillBudget() throws {
        for index in 0..<500 {
            try writeFixture(
                makeMeetingWithInlineSummary(
                    decisions: ["Synthetic pricing decision \(index)"],
                    actionItems: ["Jenny: follow up on synthetic task \(index)"],
                    openQuestions: ["Should synthetic question \(index) stay open?"]
                ),
                filename: String(format: "Call_2026-04-18_09-15-%03d", index),
                to: tempDir
            )
        }

        let started = Date()
        try withLogsSuppressed {
            try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        }
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 60, "500-meeting summary backfill should stay under the PRD budget")
        XCTAssertEqual(try index.listRecentMeetings(count: 50).count, 50)
        XCTAssertEqual(
            try index.searchUtterances(query: "Synthetic pricing decision 499", speaker: nil, dateFrom: nil, dateTo: nil).results.first?.snippets.first?.speaker,
            "Summary"
        )
    }

    func testGeneratedSidecarIsNotIndexedAsMeetingButFeedsSummary() throws {
        // A transcript with no inline summary, plus a `<stem>.summary.md` sidecar.
        try writeFixture(makeFixtureJSON(), filename: "2026-04-18 Beta sync", to: tempDir)
        let sidecar = """
        ---
        capture_type: meeting_summary
        source_transcript: "2026-04-18 Beta sync.md"
        summary_title: "Beta sync"
        ---

        # Decisions
        - Adopt the sidecar plan

        # Action Items
        - Sam: wire the rollup

        # Open Questions
        - None found.
        """
        try writeFixture(sidecar, filename: "2026-04-18 Beta sync.summary", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        // The sidecar must not appear as its own meeting row.
        let meetings = try index.listRecentMeetings(count: 10)
        XCTAssertEqual(meetings.count, 1)
        XCTAssertEqual(meetings.first?.filename, "2026-04-18 Beta sync")

        // Its summary feeds the parent transcript's summary items.
        let decisions = try index.listSummaryItems(kind: TranscriptIndex.SummaryItemKind.decision)
        XCTAssertEqual(decisions.map(\.text), ["Adopt the sidecar plan"])
        XCTAssertEqual(decisions.first?.filename, "2026-04-18 Beta sync")
        let actions = try index.listSummaryItems(kind: TranscriptIndex.SummaryItemKind.actionItem)
        XCTAssertEqual(actions.first?.owner, "Sam")
    }
}
