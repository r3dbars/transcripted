import XCTest
@testable import TranscriptedCaptureKit

final class CaptureSummaryParserTests: XCTestCase {
    // Inline summary mirrors LocalMeetingSummaryMarkdownUpdater: frontmatter
    // `local_summary_*` keys plus a marker-bounded `## Local Summary` body block
    // with `###` subsections.
    private func inlineMeeting(
        decisions: String = "### Decisions\n- Ship the beta on Friday\n- Cut the legacy import path",
        actionItems: String = "### Action Items\n- Jenny: send the revised spec\n- Follow up with legal",
        openQuestions: String = "### Open Questions\n- Do we need a migration window?"
    ) -> String {
        """
        ---
        capture_type: meeting
        date: 2026-04-18
        time: 09:15:00
        duration: "30:00"
        transcription_engine: parakeet_local
        diarization_engine: pyannote_offline
        local_summary_version: "1"
        local_summary_title: "Beta launch sync"
        local_summary_decisions: "Ship the beta on Friday | Cut the legacy import path"
        local_summary_action_items: "Jenny: send the revised spec | Follow up with legal"
        local_summary_open_questions: "Do we need a migration window?"
        ---

        # Meeting

        ## Full Transcript

        [00:00] [System/Jenny] Let's lock the launch.

        <!-- transcripted:local-summary:start v=1 -->
        ## Local Summary

        ### Summary
        - The team aligned on launch.

        ### Next Steps
        - None found.

        \(decisions)

        \(openQuestions)

        ### Participants
        - Jenny

        \(actionItems)

        ### Risks or Follow-ups
        - None found.

        ### Accuracy Notes
        - None found.
        <!-- transcripted:local-summary:end -->
        """
    }

    func testParsesInlineBodyBlockSections() throws {
        let summary = try XCTUnwrap(CaptureSummaryParser.parse(from: inlineMeeting()))
        XCTAssertEqual(summary.title, "Beta launch sync")
        XCTAssertEqual(summary.attendees, ["Jenny"])
        XCTAssertEqual(summary.decisions, ["Ship the beta on Friday", "Cut the legacy import path"])
        XCTAssertEqual(summary.openQuestions, ["Do we need a migration window?"])
        XCTAssertEqual(summary.actionItems.count, 2)
    }

    func testExtractsActionItemOwner() throws {
        let summary = try XCTUnwrap(CaptureSummaryParser.parse(from: inlineMeeting()))
        XCTAssertEqual(summary.actionItems[0].owner, "Jenny")
        XCTAssertEqual(summary.actionItems[0].text, "send the revised spec")
        // No "Owner:" prefix → unassigned, full text retained.
        XCTAssertNil(summary.actionItems[1].owner)
        XCTAssertEqual(summary.actionItems[1].text, "Follow up with legal")
    }

    func testParsesTrailingDueAndStatusMarkers() throws {
        let markdown = inlineMeeting(
            actionItems: """
            ### Action Items
            - Jenny: send the revised spec (due: Friday)
            - Nate: draft the launch email (status: done)
            - Confirm the venue (done) (due: next week)
            - Follow up with legal
            """
        )
        let summary = try XCTUnwrap(CaptureSummaryParser.parse(from: markdown))
        XCTAssertEqual(summary.actionItems.count, 4)

        XCTAssertEqual(summary.actionItems[0].owner, "Jenny")
        XCTAssertEqual(summary.actionItems[0].text, "send the revised spec")
        XCTAssertNil(summary.actionItems[0].status)
        XCTAssertEqual(summary.actionItems[0].due, "Friday")

        XCTAssertEqual(summary.actionItems[1].owner, "Nate")
        XCTAssertEqual(summary.actionItems[1].text, "draft the launch email")
        XCTAssertEqual(summary.actionItems[1].status, "done")
        XCTAssertNil(summary.actionItems[1].due)

        XCTAssertEqual(summary.actionItems[2].text, "Confirm the venue")
        XCTAssertEqual(summary.actionItems[2].status, "done")
        XCTAssertEqual(summary.actionItems[2].due, "next week")

        XCTAssertNil(summary.actionItems[3].status)
        XCTAssertNil(summary.actionItems[3].due)
    }

    func testKeepsRealParentheticalsOutOfMarkers() throws {
        let markdown = inlineMeeting(
            actionItems: "### Action Items\n- Jenny: call the vendor (the new one)"
        )
        let summary = try XCTUnwrap(CaptureSummaryParser.parse(from: markdown))
        XCTAssertEqual(summary.actionItems[0].text, "call the vendor (the new one)")
        XCTAssertNil(summary.actionItems[0].status)
        XCTAssertNil(summary.actionItems[0].due)
    }

    func testDoesNotShredSentenceColonsIntoOwner() throws {
        let markdown = inlineMeeting(
            actionItems: "### Action Items\n- Discuss the new API: review the public endpoints and document them"
        )
        let summary = try XCTUnwrap(CaptureSummaryParser.parse(from: markdown))
        XCTAssertNil(summary.actionItems[0].owner)
        XCTAssertEqual(summary.actionItems[0].text, "Discuss the new API: review the public endpoints and document them")
    }

    func testNormalizesPlaceholderOwnersToUnassigned() throws {
        let markdown = inlineMeeting(actionItems: "### Action Items\n- Unassigned: triage the backlog")
        let summary = try XCTUnwrap(CaptureSummaryParser.parse(from: markdown))
        XCTAssertNil(summary.actionItems[0].owner)
        XCTAssertEqual(summary.actionItems[0].text, "triage the backlog")
    }

    func testTreatsNoneFoundAsEmptySection() throws {
        let markdown = inlineMeeting(
            decisions: "### Decisions\n- None found.",
            openQuestions: "### Open Questions\n- None found."
        )
        let summary = try XCTUnwrap(CaptureSummaryParser.parse(from: markdown))
        XCTAssertTrue(summary.decisions.isEmpty)
        XCTAssertTrue(summary.openQuestions.isEmpty)
        XCTAssertEqual(summary.actionItems.count, 2)
    }

    func testParsesTitleAndParticipantsWhenFactSectionsAreEmpty() throws {
        let markdown = inlineMeeting(
            decisions: "### Decisions\n- None found.",
            actionItems: "### Action Items\n- None found.",
            openQuestions: "### Open Questions\n- None found."
        )
        let summary = try XCTUnwrap(CaptureSummaryParser.parse(from: markdown))

        XCTAssertEqual(summary.title, "Beta launch sync")
        XCTAssertEqual(summary.attendees, ["Jenny"])
        XCTAssertTrue(summary.decisions.isEmpty)
        XCTAssertTrue(summary.actionItems.isEmpty)
        XCTAssertTrue(summary.openQuestions.isEmpty)
    }

    func testFallsBackToFrontmatterWhenBodyBlockMissing() throws {
        let markdown = """
        ---
        capture_type: meeting
        date: 2026-04-18
        time: 09:15:00
        local_summary_version: "1"
        local_summary_decisions: "Adopt the new schema | Freeze the old endpoint"
        local_summary_action_items: "Sam: write the migration"
        local_summary_open_questions: "When do we cut over?"
        ---

        # Meeting

        ## Full Transcript

        [00:00] [System/Sam] Body has no local-summary block.
        """
        let summary = try XCTUnwrap(CaptureSummaryParser.parse(from: markdown))
        XCTAssertEqual(summary.decisions, ["Adopt the new schema", "Freeze the old endpoint"])
        XCTAssertEqual(summary.openQuestions, ["When do we cut over?"])
        XCTAssertEqual(summary.actionItems.first?.owner, "Sam")
        XCTAssertEqual(summary.actionItems.first?.text, "write the migration")
    }

    func testParsesAutoSummaryFrontmatter() throws {
        let markdown = """
        ---
        capture_type: meeting
        date: 2026-04-18
        time: 09:15:00
        auto_summary_version: "1"
        auto_summary_method: "heuristic-v1"
        auto_summary_decisions: "Keep the launch date | Cut the old import path"
        auto_summary_action_items: "Nate: send the recap | Follow up with legal"
        auto_summary_open_questions: "Who signs off on pricing?"
        ---

        # Meeting

        ## Full Transcript

        [00:00] [System/Nate] Body has only the normal transcript.
        """
        let summary = try XCTUnwrap(CaptureSummaryParser.parse(from: markdown))
        XCTAssertEqual(summary.decisions, ["Keep the launch date", "Cut the old import path"])
        XCTAssertEqual(summary.openQuestions, ["Who signs off on pricing?"])
        XCTAssertEqual(summary.actionItems.first?.owner, "Nate")
        XCTAssertEqual(summary.actionItems.first?.text, "send the recap")
        XCTAssertNil(summary.actionItems.last?.owner)
        XCTAssertEqual(summary.actionItems.last?.text, "Follow up with legal")
    }

    func testFallsBackToAutoSummaryWhenLocalSummaryIsEmpty() throws {
        let markdown = """
        ---
        capture_type: meeting
        date: 2026-04-18
        time: 09:15:00
        local_summary_version: "1"
        local_summary_decisions: "None found."
        local_summary_action_items: "None found."
        local_summary_open_questions: "None found."
        auto_summary_version: "1"
        auto_summary_method: "heuristic-v1"
        auto_summary_decisions: "Keep the launch date"
        auto_summary_action_items: "Nate: send the recap"
        auto_summary_open_questions: "Who signs off on pricing?"
        ---

        # Meeting

        ## Full Transcript

        [00:00] [System/Nate] Body has only the normal transcript.
        """
        let summary = try XCTUnwrap(CaptureSummaryParser.parse(from: markdown))
        XCTAssertEqual(summary.decisions, ["Keep the launch date"])
        XCTAssertEqual(summary.openQuestions, ["Who signs off on pricing?"])
        XCTAssertEqual(summary.actionItems.first?.owner, "Nate")
        XCTAssertEqual(summary.actionItems.first?.text, "send the recap")
    }

    func testParsesGeneratedSidecarSections() throws {
        let sidecar = """
        ---
        capture_type: meeting_summary
        source_transcript: "2026-04-18 Beta launch sync.md"
        summary_title: "Beta launch sync"
        ---

        # Title
        Beta launch sync

        # Summary
        - The team aligned on launch.

        # Decisions
        - Ship the beta on Friday

        # Action Items
        - Jenny: send the revised spec

        # Open Questions
        - Do we need a migration window?
        """
        let summary = try XCTUnwrap(CaptureSummaryParser.parse(from: sidecar))
        XCTAssertEqual(summary.title, "Beta launch sync")
        XCTAssertTrue(summary.attendees.isEmpty)
        XCTAssertEqual(summary.decisions, ["Ship the beta on Friday"])
        XCTAssertEqual(summary.actionItems.first?.owner, "Jenny")
        XCTAssertEqual(summary.openQuestions, ["Do we need a migration window?"])
    }

    func testReturnsNilWhenNoSummaryPresent() {
        let markdown = """
        ---
        capture_type: meeting
        date: 2026-04-18
        time: 09:15:00
        ---

        # Meeting

        ## Full Transcript

        [00:00] [System/Sam] No summary here.
        """
        XCTAssertNil(CaptureSummaryParser.parse(from: markdown))
    }

    func testReturnsNilWhenEverySectionEmpty() {
        let markdown = """
        ---
        capture_type: meeting
        date: 2026-04-18
        time: 09:15:00
        local_summary_version: "1"
        local_summary_decisions: "None found."
        local_summary_action_items: "None found."
        local_summary_open_questions: "None found."
        ---

        # Meeting

        ## Full Transcript

        [00:00] [System/Jenny] Nothing to summarize.

        ## Local Summary

        ### Decisions
        - None found.

        ### Action Items
        - None found.

        ### Open Questions
        - None found.
        """
        XCTAssertNil(CaptureSummaryParser.parse(from: markdown))
    }
}
