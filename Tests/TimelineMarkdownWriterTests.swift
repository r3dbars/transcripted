import Foundation

func testTimelineMarkdownWriter() {
    runSuite("TimelineMarkdownWriter writes stable daily Markdown") {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TimelineMarkdownWriterTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 1_774_164_600) // 2026-03-20 09:30 UTC
        let cards = [
            TimelineMarkdownCard(
                start: start,
                end: start.addingTimeInterval(30 * 60),
                title: "Roadmap review",
                category: "Meetings",
                summary: "Reviewed the launch plan.",
                details: "Only timeline summaries are written by this formatter.",
                kind: "meeting",
                transcriptFilename: "Call_2026-03-20_09-30-00"
            )
        ]

        do {
            let url = try TimelineMarkdownWriter.writeDay(
                date: "2026-03-20",
                cards: cards,
                captureLibrary: tempRoot,
                calendar: calendar
            )
            let markdown = try String(contentsOf: url, encoding: .utf8)
            assertEqual(url.lastPathComponent, "2026-03-20.md", "timeline filename should be the stable day key")
            assert(markdown.contains("capture_type: timeline"), "frontmatter should identify timeline captures")
            assert(markdown.contains("card_count: 1"), "frontmatter should include card count")
            assert(markdown.contains("active_minutes: 30"), "frontmatter should include active minutes")
            assert(markdown.contains("[transcript](../meetings/Call_2026-03-20_09-30-00.md)"), "meeting cards should link to meeting Markdown relatively")
            assert(!markdown.localizedCaseInsensitiveContains("screenshot"), "writer output should stay free of screenshot references")
            assert(!markdown.localizedCaseInsensitiveContains("ocr"), "writer output should stay free of raw OCR references")
        } catch {
            assertionFailure("TimelineMarkdownWriter threw unexpectedly: \(error)")
        }
    }
}
