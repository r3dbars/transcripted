import XCTest
@testable import transcripted_mcp

final class MeetingSummaryPreviewTests: XCTestCase {
    /// A meeting transcript whose first dialogue lines are small-talk, plus an
    /// embedded local-summary block (the shape the app writes).
    private func meetingMarkdown(withSummary: Bool, frontmatterOnly: Bool = false) -> String {
        var frontmatter = """
        ---
        capture_type: meeting
        title: "Roadmap Sync"
        date: 2026-03-29
        time: "10:00:00"
        """
        if withSummary {
            frontmatter += "\n" + #"local_summary_version: "1""#
            if frontmatterOnly {
                frontmatter += "\n" + #"local_summary: "We agreed to ship the beta next Friday.""#
                frontmatter += "\n" + #"local_summary_decisions: "Ship the beta on Friday. | Freeze scope now.""#
                frontmatter += "\n" + #"local_summary_action_items: "Jenny drafts the changelog.""#
            }
        }
        frontmatter += "\n---\n"

        var body = """

        ## Full Transcript

        **You** [00:00]: Good morning everyone, can you hear me okay?
        **Jenny Wen** [00:05]: Yeah, audio sounds great on my end.
        """

        if withSummary && !frontmatterOnly {
            body += """


            \(LocalSummaryMarkers.start)
            ## Local Apple Summary

            ### Summary
            We agreed to ship the beta next Friday.

            ### Decisions
            - Ship the beta on Friday.
            - Freeze scope now.

            ### Action Items
            - Jenny drafts the changelog.

            ### Open Questions
            None found.
            \(LocalSummaryMarkers.end)
            """
        }

        return frontmatter + body
    }

    private enum LocalSummaryMarkers {
        static let start = "<!-- transcripted:local-summary:start v=1 -->"
        static let end = "<!-- transcripted:local-summary:end -->"
    }

    func testRecapPreviewReturnsSummaryNotRawGreetings() {
        let preview = meetingRecapPreview(from: meetingMarkdown(withSummary: true))

        XCTAssertFalse(preview.contains("Good morning"), "Recap should not surface raw greeting small-talk")
        XCTAssertTrue(preview.contains("ship the beta next Friday"), "Recap should surface the summary overview")
        XCTAssertTrue(preview.contains("Decisions:"))
        XCTAssertTrue(preview.contains("Ship the beta on Friday."))
        XCTAssertTrue(preview.contains("Action Items:"))
        XCTAssertTrue(preview.contains("Jenny drafts the changelog."))
        // "None found." sections are dropped.
        XCTAssertFalse(preview.contains("Open Questions"))
    }

    func testRecapPreviewFallsBackToDialogueWhenNoSummary() {
        let preview = meetingRecapPreview(from: meetingMarkdown(withSummary: false))

        XCTAssertTrue(preview.contains("Good morning"), "Without a summary, recap falls back to dialogue lines")
        XCTAssertNil(MeetingSummaryPreview.preview(from: meetingMarkdown(withSummary: false)))
    }

    func testPreviewFallsBackToFrontmatterValues() {
        let preview = MeetingSummaryPreview.preview(from: meetingMarkdown(withSummary: true, frontmatterOnly: true))

        XCTAssertNotNil(preview)
        XCTAssertTrue(preview!.contains("ship the beta next Friday"))
        XCTAssertTrue(preview!.contains("Ship the beta on Friday."))
        XCTAssertTrue(preview!.contains("Freeze scope now."))
        XCTAssertTrue(preview!.contains("Jenny drafts the changelog."))
    }
}
