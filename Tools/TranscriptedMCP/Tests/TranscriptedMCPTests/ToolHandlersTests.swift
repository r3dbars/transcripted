import XCTest
@testable import transcripted_mcp

final class ToolHandlersTests: XCTestCase {
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

    func testHydrateMeetingSearchTitlesUsesFrontmatterTitle() throws {
        try writeFixture(
            makeFixtureJSON(title: "Roadmap Sync", date: "2026-03-26T16:04:11-0500"),
            filename: "Call_2026-03-26_16-04-11",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        var results = try index.searchUtterances(query: "roadmap", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(results.results.count, 1)
        // Before hydration the index reports the filename-derived title.
        XCTAssertEqual(results.results[0].meetingTitle, "2026:03:26 16:04:11")

        hydrateMeetingSearchTitles(in: &results, meetingDirs: [tempDir])

        XCTAssertEqual(results.results[0].meetingTitle, "Roadmap Sync")
    }

    func testHydrateMeetingSearchTitlesKeepsFilenameDerivedTitleWithoutFrontmatterTitle() throws {
        try writeFixture(
            makeFixtureJSON(date: "2026-03-26T16:04:11-0500"),
            filename: "Call_2026-03-26_16-04-11",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        var results = try index.searchUtterances(query: "roadmap", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(results.results.count, 1)

        hydrateMeetingSearchTitles(in: &results, meetingDirs: [tempDir])

        XCTAssertEqual(results.results[0].meetingTitle, "2026:03:26 16:04:11")
    }

    func testHydrateMeetingSearchTitlesKeepsFilenameDerivedTitleWhenMarkdownIsMissing() throws {
        try writeFixture(
            makeFixtureJSON(title: "Roadmap Sync", date: "2026-03-26T16:04:11-0500"),
            filename: "Call_2026-03-26_16-04-11",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        var results = try index.searchUtterances(query: "roadmap", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(results.results.count, 1)

        // Hydrating against a directory that has no matching markdown file
        // must leave the filename-derived title intact.
        let emptyDir = makeTempDir()
        defer { removeTempDir(emptyDir) }
        hydrateMeetingSearchTitles(in: &results, meetingDirs: [emptyDir])

        XCTAssertEqual(results.results[0].meetingTitle, "2026:03:26 16:04:11")
    }
}
