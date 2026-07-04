import XCTest
@testable import TranscriptedCaptureKit

final class TimelineMarkdownTests: XCTestCase {
    func testWriterAndParserRoundTripTimelineDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 1_774_164_600)
        let markdown = TimelineMarkdownFormat.markdown(
            date: "2026-03-20",
            cards: [
                TimelineMarkdownFormat.Card(
                    start: start,
                    end: start.addingTimeInterval(45 * 60),
                    title: "Launch planning",
                    category: "Work",
                    summary: "Merged product planning with meeting follow-up.",
                    details: "Kept the output agent-readable and privacy-safe.",
                    kind: "activity"
                ),
                TimelineMarkdownFormat.Card(
                    start: start.addingTimeInterval(60 * 60),
                    end: start.addingTimeInterval(90 * 60),
                    title: "Beta launch sync",
                    category: "Meetings",
                    summary: "Decided to ship the beta.",
                    kind: "meeting",
                    transcriptFilename: "Call_2026-03-20_10-30-00"
                ),
            ],
            calendar: calendar
        )

        let url = URL(fileURLWithPath: "/tmp/2026-03-20.md")
        let parsed = try XCTUnwrap(TimelineMarkdownParser.parseTimelineDay(from: markdown, markdownURL: url))

        XCTAssertEqual(parsed.captureType, "timeline")
        XCTAssertEqual(parsed.formatVersion, 1)
        XCTAssertEqual(parsed.date, "2026-03-20")
        XCTAssertEqual(parsed.cardCount, 2)
        XCTAssertEqual(parsed.activeMinutes, 75)
        XCTAssertEqual(parsed.categories, ["Meetings", "Work"])
        XCTAssertEqual(parsed.cards.map(\.title), ["Launch planning", "Beta launch sync"])
        XCTAssertEqual(parsed.cards.last?.kind, "meeting")
        XCTAssertEqual(parsed.cards.last?.transcriptPath, "../meetings/Call_2026-03-20_10-30-00.md")
    }

    func testParserRejectsNonTimelineCapture() {
        let markdown = """
        ---
        capture_type: meeting
        date: 2026-03-20
        ---

        # Not timeline
        """
        XCTAssertNil(TimelineMarkdownParser.parseTimelineDay(from: markdown, markdownURL: URL(fileURLWithPath: "/tmp/nope.md")))
    }
}
