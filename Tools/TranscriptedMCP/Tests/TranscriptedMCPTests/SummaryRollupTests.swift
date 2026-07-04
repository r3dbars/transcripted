import XCTest
@testable import transcripted_mcp

/// End-to-end rollup coverage for saved meeting summaries:
/// meeting markdown -> summary parser -> MCP index -> list_action_items /
/// list_decisions / digest query layer.
final class SummaryRollupTests: XCTestCase {
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

    private func seedTwoMeetings() throws {
        try writeFixture(
            makeMeetingWithInlineSummary(
                date: "2026-03-26",
                time: "16:04:11",
                decisions: ["Ship the beta on April 15"],
                actionItems: [
                    "Nate Smith: Draft the launch email",
                    "Jenny Wen: Confirm the venue",
                ],
                openQuestions: ["Who signs off on pricing?"]
            ),
            filename: "Call_2026-03-26_16-04-11",
            to: tempDir
        )
        try writeFixture(
            makeMeetingWithInlineSummary(
                date: "2026-04-02",
                time: "09:30:00",
                decisions: ["Adopt usage-based pricing"],
                actionItems: [
                    "Nate: Send the pricing model to finance",
                    "Update the deck",
                ],
                openQuestions: []
            ),
            filename: "Call_2026-04-02_09-30-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
    }

    func testEmptyIndexReturnsNoActionItems() throws {
        let result = try index.listActionItems(owner: nil, query: nil, status: .all, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(result.count, 0)
        XCTAssertTrue(result.items.isEmpty)
    }

    func testActionItemsFilteredByOwnerAcrossMeetings() throws {
        try seedTwoMeetings()

        let result = try index.listActionItems(owner: "Nate", query: nil, status: .open, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.items.map(\.filename)), ["Call_2026-03-26_16-04-11", "Call_2026-04-02_09-30-00"])
        XCTAssertTrue(result.items.allSatisfy { ($0.owner ?? "").localizedCaseInsensitiveContains("nate") })
    }

    func testActionItemsStatusFilterMatchesIndexedSummaryShape() throws {
        try seedTwoMeetings()

        let open = try index.listActionItems(owner: nil, query: nil, status: .open, dateFrom: nil, dateTo: nil)
        let all = try index.listActionItems(owner: nil, query: nil, status: .all, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(open.count, 4)
        XCTAssertEqual(all.count, 4)
        XCTAssertTrue(open.items.allSatisfy { $0.status == nil && $0.due == nil })

        let done = try index.listActionItems(owner: nil, query: nil, status: .done, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(done.count, 0)
    }

    func testDoneAndDueMarkersDriveStatusFilterAndDigestCounts() throws {
        try writeFixture(
            makeMeetingWithInlineSummary(
                date: "2026-05-01",
                time: "10:00:00",
                decisions: [],
                actionItems: [
                    "Nate Smith: Draft the launch email (due: Friday)",
                    "Jenny Wen: Confirm the venue (done)",
                    "Send the recap (status: completed)",
                ],
                openQuestions: []
            ),
            filename: "Call_2026-05-01_10-00-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let open = try index.listActionItems(owner: nil, query: nil, status: .open, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(open.items.map(\.text), ["Draft the launch email"])
        XCTAssertEqual(open.items.first?.due, "Friday")
        XCTAssertNil(open.items.first?.status)

        let done = try index.listActionItems(owner: nil, query: nil, status: .done, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(done.count, 2)
        XCTAssertEqual(Set(done.items.map(\.text)), ["Confirm the venue", "Send the recap"])
        XCTAssertEqual(Set(done.items.compactMap(\.status)), ["done", "completed"])

        let all = try index.listActionItems(owner: nil, query: nil, status: .all, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(all.count, 3)

        let digest = try index.digest(dateFrom: "2026-05-01", dateTo: "2026-05-01")
        XCTAssertEqual(digest.actionItemCount, 3)
        XCTAssertEqual(digest.openActionItemCount, 1)
        let digestActions = try XCTUnwrap(digest.meetings.first?.actionItems)
        XCTAssertEqual(digestActions.compactMap(\.due), ["Friday"])
    }

    func testActionItemsDateWindowFilter() throws {
        try seedTwoMeetings()

        let result = try index.listActionItems(
            owner: nil, query: nil, status: .all,
            dateFrom: "2026-04-01", dateTo: "2026-04-30"
        )
        XCTAssertTrue(result.items.allSatisfy { $0.filename == "Call_2026-04-02_09-30-00" })
        XCTAssertEqual(result.count, 2)
    }

    func testActionItemsFullTextQuery() throws {
        try seedTwoMeetings()

        let result = try index.listActionItems(owner: nil, query: "pricing", status: .all, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(result.items.map(\.text), ["Send the pricing model to finance"])
    }

    func testAutoSummaryFrontmatterFeedsRollupTools() throws {
        try writeFixture(
            makeMeetingWithAutoSummary(
                date: "2026-04-18",
                time: "14:15:00",
                decisions: ["Keep the launch date"],
                actionItems: ["Nate: Send the recap"],
                openQuestions: ["Who signs off on pricing?"]
            ),
            filename: "Call_2026-04-18_14-15-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let actions = try index.listActionItems(owner: "Nate", query: "recap", status: .open, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(actions.items.map(\.text), ["Send the recap"])
        XCTAssertEqual(actions.items.first?.owner, "Nate")

        let decisions = try index.listDecisions(query: "launch", dateFrom: nil, dateTo: nil)
        XCTAssertEqual(decisions.decisions.map(\.text), ["Keep the launch date"])

        let digest = try index.digest(dateFrom: "2026-04-18", dateTo: "2026-04-18")
        XCTAssertEqual(digest.meetingCount, 1)
        XCTAssertEqual(digest.openQuestionCount, 1)
        XCTAssertEqual(digest.meetings.first?.openQuestions, ["Who signs off on pricing?"])
    }

    func testDecisionsAcrossMeetings() throws {
        try seedTwoMeetings()

        let result = try index.listDecisions(query: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.decisions.first?.text, "Adopt usage-based pricing")
        XCTAssertTrue(result.decisions.contains { $0.text == "Ship the beta on April 15" })
    }

    func testDecisionsFullTextQuery() throws {
        try seedTwoMeetings()

        let result = try index.listDecisions(query: "pricing", dateFrom: nil, dateTo: nil)
        XCTAssertEqual(result.decisions.map(\.text), ["Adopt usage-based pricing"])
    }

    func testDigestRollsUpAcrossMeetings() throws {
        try seedTwoMeetings()

        let digest = try index.digest(dateFrom: "2026-01-01", dateTo: "2026-12-31")
        XCTAssertEqual(digest.meetingCount, 2)
        XCTAssertEqual(digest.actionItemCount, 4)
        XCTAssertEqual(digest.openActionItemCount, 4)
        XCTAssertEqual(digest.decisionCount, 2)
        XCTAssertEqual(digest.openQuestionCount, 1)

        let pricing = try XCTUnwrap(digest.meetings.first)
        XCTAssertEqual(pricing.filename, "Call_2026-04-02_09-30-00")
        XCTAssertEqual(pricing.decisions, ["Adopt usage-based pricing"])
        XCTAssertEqual(pricing.actionItems.count, 2)
        XCTAssertTrue(pricing.openQuestions.isEmpty)
    }

    func testDigestExcludesMeetingsWithoutFacts() throws {
        try seedTwoMeetings()
        try writeFixture(
            makeFixtureJSON(title: "Standup", date: "2026-04-03T09:00:00-0500"),
            filename: "Call_2026-04-03_09-00-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let digest = try index.digest(dateFrom: "2026-01-01", dateTo: "2026-12-31")
        XCTAssertFalse(digest.meetings.contains { $0.filename == "Call_2026-04-03_09-00-00" })
        XCTAssertEqual(digest.meetingCount, 2)
    }

    func testDigestLimitAppliesAfterFilteringSummarizedMeetings() throws {
        try writeFixture(
            makeMeetingWithInlineSummary(
                date: "2026-01-01",
                time: "09:00:00",
                decisions: ["Keep the summarized launch plan"],
                actionItems: [],
                openQuestions: []
            ),
            filename: "Call_2026-01-01_09-00-00",
            to: tempDir
        )

        for day in 1...120 {
            let date = String(format: "2026-04-%02dT09:00:00-0500", ((day - 1) % 28) + 1)
            try writeFixture(
                makeFixtureJSON(title: "Empty \(day)", date: date),
                filename: String(format: "Call_2026-04-%02d_09-00-00_%03d", ((day - 1) % 28) + 1, day),
                to: tempDir
            )
        }

        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        let digest = try index.digest(dateFrom: "2026-01-01", dateTo: "2026-12-31", maxMeetings: 1)

        XCTAssertEqual(digest.meetingCount, 1)
        XCTAssertEqual(digest.meetings.first?.filename, "Call_2026-01-01_09-00-00")
        XCTAssertEqual(digest.decisionCount, 1)
    }

    func testReindexReplacesSummaryFactsFromMarkdown() throws {
        try seedTwoMeetings()

        try writeFixture(
            makeMeetingWithInlineSummary(
                date: "2026-04-02",
                time: "09:30:00",
                decisions: ["Adopt usage-based pricing"],
                actionItems: ["Nate: Send the pricing model to finance"],
                openQuestions: []
            ),
            filename: "Call_2026-04-02_09-30-00",
            to: tempDir
        )
        let url = tempDir.appendingPathComponent("Call_2026-04-02_09-30-00.md")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let result = try index.listActionItems(owner: nil, query: nil, status: .all, dateFrom: "2026-04-01", dateTo: "2026-04-30")
        XCTAssertEqual(result.count, 1)
    }
}
