import XCTest
@testable import transcripted_mcp

/// Cross-meeting summary rollup tests: list_action_items / list_decisions /
/// digest query layer. These seed facts directly through the index write seam
/// (`replaceSummaryFacts`) — the same seam the summary-index PR will call after
/// it parses meeting markdown — so they exercise the query layer without
/// depending on the (not-yet-landed) markdown extraction.
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

    /// Index two meetings so their summary facts have a real date/datetime to join
    /// against, then seed structured facts for each.
    private func seedTwoMeetings() throws {
        try writeFixture(
            makeFixtureJSON(title: "Roadmap Sync", date: "2026-03-26T16:04:11-0500"),
            filename: "Call_2026-03-26_16-04-11", to: tempDir
        )
        try writeFixture(
            makeFixtureJSON(title: "Pricing Review", date: "2026-04-02T09:30:00-0500"),
            filename: "Call_2026-04-02_09-30-00", to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        try index.replaceSummaryFacts(
            filename: "Call_2026-03-26_16-04-11",
            decisions: ["Ship the beta on April 15"],
            actionItems: [
                SummaryActionItem(text: "Draft the launch email", owner: "Nate Smith", status: "open"),
                SummaryActionItem(text: "Confirm the venue", owner: "Jenny Wen", status: "done"),
            ],
            openQuestions: ["Who signs off on pricing?"]
        )
        try index.replaceSummaryFacts(
            filename: "Call_2026-04-02_09-30-00",
            decisions: ["Adopt usage-based pricing"],
            actionItems: [
                SummaryActionItem(text: "Send the pricing model to finance", owner: "Nate", status: "open"),
                SummaryActionItem(text: "Update the deck", owner: "You", status: nil),
            ],
            openQuestions: []
        )
    }

    func testEmptyIndexReturnsNoActionItems() throws {
        let result = try index.listActionItems(owner: nil, query: nil, status: .all, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(result.count, 0)
        XCTAssertTrue(result.items.isEmpty)
    }

    func testActionItemsFilteredByOwnerAcrossMeetings() throws {
        try seedTwoMeetings()

        // "Nate" should match both "Nate Smith" (meeting 1) and "Nate" (meeting 2)
        // via name-variant + substring matching, spanning two meetings.
        let result = try index.listActionItems(owner: "Nate", query: nil, status: .open, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(result.count, 2)
        let files = Set(result.items.map(\.filename))
        XCTAssertEqual(files, ["Call_2026-03-26_16-04-11", "Call_2026-04-02_09-30-00"])
        XCTAssertTrue(result.items.allSatisfy { ($0.owner ?? "").localizedCaseInsensitiveContains("nate") })
    }

    func testOpenStatusFilterExcludesDoneItems() throws {
        try seedTwoMeetings()

        let open = try index.listActionItems(owner: nil, query: nil, status: .open, dateFrom: nil, dateTo: nil)
        // Jenny's "Confirm the venue" is done; the nil-status "Update the deck" counts as open.
        XCTAssertFalse(open.items.contains { $0.text == "Confirm the venue" })
        XCTAssertTrue(open.items.contains { $0.text == "Update the deck" })

        let done = try index.listActionItems(owner: nil, query: nil, status: .done, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(done.items.map(\.text), ["Confirm the venue"])

        let all = try index.listActionItems(owner: nil, query: nil, status: .all, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(all.count, 4)
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

    func testDecisionsAcrossMeetings() throws {
        try seedTwoMeetings()

        let result = try index.listDecisions(query: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(result.count, 2)
        // Newest meeting first.
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
        XCTAssertEqual(digest.openActionItemCount, 3) // all but Jenny's done item
        XCTAssertEqual(digest.decisionCount, 2)
        XCTAssertEqual(digest.openQuestionCount, 1)

        // Newest meeting first, with its facts grouped under it.
        let pricing = try XCTUnwrap(digest.meetings.first)
        XCTAssertEqual(pricing.filename, "Call_2026-04-02_09-30-00")
        XCTAssertEqual(pricing.decisions, ["Adopt usage-based pricing"])
        XCTAssertEqual(pricing.actionItems.count, 2)
        XCTAssertTrue(pricing.openQuestions.isEmpty)
    }

    func testDigestExcludesMeetingsWithoutFacts() throws {
        try seedTwoMeetings()
        // A third meeting with no summary facts must not appear in the digest.
        try writeFixture(
            makeFixtureJSON(title: "Standup", date: "2026-04-03T09:00:00-0500"),
            filename: "Call_2026-04-03_09-00-00", to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let digest = try index.digest(dateFrom: "2026-01-01", dateTo: "2026-12-31")
        XCTAssertFalse(digest.meetings.contains { $0.filename == "Call_2026-04-03_09-00-00" })
        XCTAssertEqual(digest.meetingCount, 2)
    }

    func testReplaceSummaryFactsIsIdempotent() throws {
        try seedTwoMeetings()
        // Re-seeding the same meeting should replace, not duplicate.
        try index.replaceSummaryFacts(
            filename: "Call_2026-04-02_09-30-00",
            decisions: ["Adopt usage-based pricing"],
            actionItems: [SummaryActionItem(text: "Send the pricing model to finance", owner: "Nate", status: "open")],
            openQuestions: []
        )
        let result = try index.listActionItems(owner: nil, query: nil, status: .all, dateFrom: "2026-04-01", dateTo: "2026-04-30")
        XCTAssertEqual(result.count, 1)
    }

    func testReindexClearsStaleSummaryFacts() throws {
        try seedTwoMeetings()
        // Rewriting the meeting markdown triggers a reindex, which must clear the
        // summary facts that were keyed to it (they are re-derived by the
        // summary-index PR, not preserved here).
        try writeFixture(
            makeFixtureJSON(title: "Pricing Review v2", date: "2026-04-02T09:30:00-0500"),
            filename: "Call_2026-04-02_09-30-00", to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let result = try index.listActionItems(owner: nil, query: nil, status: .all, dateFrom: "2026-04-01", dateTo: "2026-04-30")
        XCTAssertEqual(result.count, 0)
    }
}
