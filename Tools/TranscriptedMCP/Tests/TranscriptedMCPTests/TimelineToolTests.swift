import MCP
import XCTest
@testable import TranscriptedCaptureKit
@testable import transcripted_mcp

final class TimelineToolTests: XCTestCase {
    var index: TranscriptIndex!
    var tempDir: URL!
    var timelineDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = makeTempDir()
        timelineDir = tempDir.appendingPathComponent("timeline", isDirectory: true)
        try! FileManager.default.createDirectory(at: timelineDir, withIntermediateDirectories: true)
        index = try! TranscriptIndex(indexDir: tempDir)
    }

    override func tearDown() {
        index = nil
        removeTempDir(tempDir)
        super.tearDown()
    }

    func testIndexesTimelineAndReturnsGetTimeline() throws {
        try writeTimelineFixture(date: "2026-03-20")
        try index.reconcile(meetingDirs: [], dictationDirs: [], timelineDirs: [timelineDir])

        let days = try index.listTimelineDays(dateFrom: "2026-03-20", dateTo: "2026-03-20")
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days.first?.cards.first?.title, "Timeline implementation")

        let result = try handleGetTimeline(
            params: CallTool.Parameters(name: "get_timeline", arguments: ["date": .string("2026-03-20")]),
            index: index,
            timelineDirs: [timelineDir]
        )
        XCTAssertFalse(result.isError ?? false)
        XCTAssertTrue(resultText(result).contains("Timeline implementation"))
    }

    func testDigestIncludesTimelineDaysWithoutMeetingSummaryFacts() throws {
        try writeTimelineFixture(date: "2026-03-20")
        try index.reconcile(meetingDirs: [], dictationDirs: [], timelineDirs: [timelineDir])

        let result = try handleDigest(
            params: CallTool.Parameters(name: "digest", arguments: ["date_from": .string("2026-03-20"), "date_to": .string("2026-03-20")]),
            index: index,
            meetingDirs: [],
            timelineDirs: [timelineDir]
        )
        XCTAssertFalse(result.isError ?? false)
        XCTAssertTrue(resultText(result).contains("\"timeline_days\""))
        XCTAssertTrue(resultText(result).contains("Timeline implementation"))
    }

    private func writeTimelineFixture(date: String) throws {
        let markdown = TimelineMarkdownFormat.markdown(
            date: date,
            cards: [
                TimelineMarkdownFormat.Card(
                    start: Date(timeIntervalSince1970: 1_774_164_600),
                    end: Date(timeIntervalSince1970: 1_774_167_300),
                    title: "Timeline implementation",
                    category: "Work",
                    summary: "Implemented agent-readable timeline output.",
                    details: "No screenshots or OCR are included."
                )
            ],
            calendar: utcCalendar()
        )
        try markdown.write(to: timelineDir.appendingPathComponent("\(date).md"), atomically: true, encoding: .utf8)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func resultText(_ result: CallTool.Result) -> String {
        guard case .text(let text, _, _) = result.content.first else {
            return ""
        }
        return text
    }
}
