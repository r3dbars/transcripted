import Foundation

// Behavioral coverage for the Writing tab's day-file reader
// (Sources/Writing/WritingDayFileReader.swift) against the
// docs/capture-format.md writing_day shape.

func testWritingDayFileReader() {
    typealias Reader = WritingDayFileReader

    let sample = """
    ---
    title: "Writing for September 25, 2026"
    date: 2026-09-25
    capture_type: writing_day
    format_version: 1
    ---

    # Writing for September 25, 2026

    ## 10:42 AM - Pushing the launch to Thursday so QA

    Entry ID: `writing-20260925-104211-387-4f2a9c1e`
    Captured: 2026-09-25T15:42:11.387Z
    Source app: Slack
    Bundle ID: `com.tinyspeck.slackmacgap`
    Words: 12
    Characters: 65
    Accepted words: 3

    Pushing the launch to Thursday so QA can finish the AirPods pass.

    ## 11:05 AM - Agenda for the offsite

    Entry ID: `writing-20260925-110501-002-00ab12cd`
    Captured: 2026-09-25T16:05:01.002Z
    Source app: Notes
    Words: 9
    Characters: 48
    Accepted words: 0

    Agenda for the offsite
    \\## Not a heading
    Second paragraph here.
    """

    runSuite("Writing day files read newest first with their counts") {
        let day = Reader.parse(sample)
        assertEqual(day.entries.count, 2)
        assertEqual(day.entries.map(\.id), [
            "writing-20260925-110501-002-00ab12cd",
            "writing-20260925-104211-387-4f2a9c1e",
        ], "newest first")
        assertEqual(day.wordCount, 21, "the summary sums the Words: lines")

        let slack = day.entries[1]
        assertEqual(slack.title, "Pushing the launch to Thursday so QA")
        assertEqual(slack.sourceAppName, "Slack")
        assertEqual(slack.wordCount, 12)
        assertEqual(slack.acceptedWordCount, 3)
        assertEqual(slack.text, "Pushing the launch to Thursday so QA can finish the AirPods pass.")
        assertTrue(
            abs((slack.capturedAt?.timeIntervalSince1970 ?? 0) - 1_790_350_931.387) < 0.001,
            "Captured: keeps its milliseconds"
        )

        let notes = day.entries[0]
        assertEqual(notes.sourceAppName, "Notes")
        assertEqual(
            notes.text,
            "Agenda for the offsite\n## Not a heading\nSecond paragraph here.",
            "an escaped ## body line reads back as text, not a new entry"
        )
    }

    runSuite("Writing day files degrade to fewer entries, never an error") {
        assertEqual(Reader.parse(""), .empty)
        assertEqual(Reader.parse("---\ncapture_type: writing_day\n---\n\n# Writing for today\n"), .empty)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("WritingDayFileReaderTests-\(UUID().uuidString).md")
        assertEqual(Reader.read(url: missing), .empty, "a missing file is an empty day")

        let noMetadata = Reader.parse("## 9:00 AM - Hello there friend\n\nHello there friend, how are you")
        assertEqual(noMetadata.entries.count, 1)
        assertEqual(noMetadata.entries.first?.sourceAppName, "Unknown")
        assertEqual(noMetadata.entries.first?.wordCount, 6, "words are counted when the line is missing")
        assertNil(noMetadata.entries.first?.capturedAt)
    }

    runSuite("Writing day file name follows the local day") {
        var calendar = Calendar(identifier: .gregorian)
        let chicago = TimeZone(identifier: "America/Chicago")!
        calendar.timeZone = chicago
        let lateEvening = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 23, minute: 30))!
        assertEqual(Reader.fileName(for: lateEvening, timeZone: chicago), "Writing_2026-09-25.md")
        assertEqual(
            Reader.fileName(for: lateEvening, timeZone: TimeZone(identifier: "UTC")!),
            "Writing_2026-09-26.md",
            "the same instant is already tomorrow in UTC"
        )
        assertNil(Reader.capturedDate(""))
        assertEqual(Reader.capturedDate("2026-09-25T15:42:11Z"), Date(timeIntervalSince1970: 1_790_350_931))
    }
}
