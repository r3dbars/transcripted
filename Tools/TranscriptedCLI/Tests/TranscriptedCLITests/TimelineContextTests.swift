import XCTest
@testable import TranscriptedCaptureKit
@testable import transcripted_cli

final class TimelineContextTests: XCTestCase {
    func testListAndReadTimelineDay() throws {
        let root = makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let timelineDir = root.appendingPathComponent("timeline", isDirectory: true)
        try FileManager.default.createDirectory(at: timelineDir, withIntermediateDirectories: true)

        let markdown = TimelineMarkdownFormat.markdown(
            date: "2026-03-20",
            cards: [
                TimelineMarkdownFormat.Card(
                    start: Date(timeIntervalSince1970: 1_774_164_600),
                    end: Date(timeIntervalSince1970: 1_774_167_300),
                    title: "Planning",
                    category: "Work",
                    summary: "Planned the timeline handoff."
                )
            ],
            calendar: utcCalendar()
        )
        try markdown.write(to: timelineDir.appendingPathComponent("2026-03-20.md"), atomically: true, encoding: .utf8)

        let directories = CLIContextDirectories(
            meetingDirs: [],
            dictationDirs: [],
            timelineDirs: [timelineDir]
        )

        let days = CLIContextStore.listTimelineDays(in: directories, count: 10, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(days.map(\.filename), ["2026-03-20"])
        XCTAssertEqual(days.first?.cardCount, 1)

        let read = try CLIContextStore.readTimeline(filename: "2026-03-20", in: directories)
        XCTAssertEqual(read.day.date, "2026-03-20")
        XCTAssertEqual(read.day.cards.first?.summary, "Planned the timeline handoff.")
        XCTAssertTrue(read.markdown.contains("capture_type: timeline"))
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TimelineContextTests-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
