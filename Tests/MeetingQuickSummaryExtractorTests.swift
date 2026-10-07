import Foundation

func testMeetingQuickSummaryExtractor() {
    runSuite("extracts action items with owner prefix from styled transcript") {
        let transcript = """
        **00:01**  [Mic/Justin]
        I'll send the updated pricing deck to the team by Friday.

        **00:09**  [System/Maya]
        Sounds good, thanks.
        """

        let sections = MeetingQuickSummaryExtractor.sections(transcript: transcript)
        assertTrue(
            sections.actionItems.contains("Justin:"),
            "action item should be attributed to the speaker, got: \(sections.actionItems)"
        )
        assertTrue(
            sections.actionItems.contains("pricing deck"),
            "action item should preserve the concrete commitment"
        )
        assertTrue(
            sections.actionItems.contains("(due: Friday)"),
            "deadline cue should produce a due marker, got: \(sections.actionItems)"
        )
        assertFalse(
            sections.actionItems.lowercased().contains("sounds good"),
            "small talk should not become an action item"
        )
    }

    runSuite("does not append a due marker when an action lacks a deadline cue") {
        let transcript = """
        **00:15**  [System/Maya]
        I'll take care of the vendor follow-up.
        """

        let sections = MeetingQuickSummaryExtractor.sections(transcript: transcript)
        assertTrue(
            sections.actionItems.contains("vendor follow-up"),
            "action without a deadline should still be extracted, got: \(sections.actionItems)"
        )
        assertFalse(
            sections.actionItems.contains("(due:"),
            "action without a deadline cue must not get a due marker"
        )
    }

    runSuite("a courtesy opener does not hide a decision or action item in the same sentence") {
        let transcript = """
        **00:01**  [System/Maya]
        Sounds good, we'll go with Postgres.

        **00:12**  [Mic/Justin]
        Thanks everyone, I'll send the deck Friday.

        **00:20**  [System/Maya]
        Thanks everyone, that was a really productive session today.

        **00:24**  [Mic/Justin]
        Thanks everyone!
        """

        let sections = MeetingQuickSummaryExtractor.sections(transcript: transcript)
        assertTrue(
            sections.decisions.contains("we'll go with Postgres"),
            "a decision after a courtesy opener should be kept, got: \(sections.decisions)"
        )
        assertTrue(
            sections.actionItems.contains("send the deck Friday"),
            "an action item after a courtesy opener should be kept, got: \(sections.actionItems)"
        )
        assertFalse(
            sections.summary.lowercased().contains("productive session"),
            "a courtesy sentence with no decision or action cue is still small talk, got: \(sections.summary)"
        )
        assertFalse(
            (sections.decisions + sections.actionItems + sections.openQuestions).contains("Thanks everyone!"),
            "pure courtesy lines stay filtered"
        )
    }

    runSuite("courtesy closers with a weak action phrase stay small talk") {
        let transcript = """
        **00:01**  [System/Maya]
        Thanks everyone, let me know if anything comes up.

        **00:05**  [Mic/Justin]
        Sounds good, I'll see you then.

        **00:09**  [System/Maya]
        Have a good weekend, let's catch up Monday.

        **00:12**  [Mic/Justin]
        No worries, I have to run to another call.

        **00:13**  [System/Maya]
        Talk soon, I'll let you go.

        **00:14**  [Mic/Justin]
        Have a good one, I'll talk to you later.

        **00:14**  [System/Maya]
        Sounds good, I'll catch you later.

        **00:15**  [System/Maya]
        We'll go with the blue logo, sounds good.
        """

        let sections = MeetingQuickSummaryExtractor.sections(transcript: transcript)
        assertEqual(sections.actionItems, "None found.", "courtesy closers are not action items, got: \(sections.actionItems)")
        for closer in ["let me know", "see you then", "catch up Monday", "run to another call", "let you go", "talk to you later", "catch you later"] {
            assertFalse(
                (sections.summary + sections.decisions + sections.openQuestions).contains(closer),
                "courtesy closer should stay out of every section: \(closer)"
            )
        }
        assertTrue(
            sections.decisions.contains("blue logo"),
            "a decision followed by a courtesy tail is still a decision, got: \(sections.decisions)"
        )
    }

    runSuite("a real deadline that says have to go through is not a sign-off") {
        let transcript = """
        **00:01**  [System/Maya]
        No worries, we have to go through the contract by Friday.
        """

        let sections = MeetingQuickSummaryExtractor.sections(transcript: transcript)
        assertTrue(
            sections.actionItems.contains("go through the contract"),
            "\"have to go through\" is work, not a sign-off, got: \(sections.actionItems)"
        )
    }

    runSuite("extracts decisions and keeps them out of action items") {
        let transcript = """
        **00:01**  [System/Maya]
        We decided to ship the smaller version first.

        **00:20**  [Mic/Justin]
        Okay.
        """

        let sections = MeetingQuickSummaryExtractor.sections(transcript: transcript)
        assertTrue(
            sections.decisions.contains("ship the smaller version first"),
            "decision should be captured, got: \(sections.decisions)"
        )
        assertEqual(
            sections.actionItems,
            "None found.",
            "a decision sentence should not double-count as an action item"
        )
    }

    runSuite("extracts substantive open questions but skips short rhetorical ones") {
        let transcript = """
        **00:01**  [System/Maya]
        How should we handle refunds for annual plans that cancel early?

        **00:10**  [Mic/Justin]
        Right?
        """

        let sections = MeetingQuickSummaryExtractor.sections(transcript: transcript)
        assertTrue(
            sections.openQuestions.lowercased().contains("refunds"),
            "substantive question should be captured, got: \(sections.openQuestions)"
        )
        assertFalse(
            sections.openQuestions.contains("Right?"),
            "short rhetorical questions should be ignored"
        )
    }

    runSuite("empty / tiny transcript yields None found, never crashes") {
        let sections = MeetingQuickSummaryExtractor.sections(transcript: "Hi. Hello.")
        assertEqual(sections.decisions, "None found.")
        assertEqual(sections.actionItems, "None found.")
        assertEqual(sections.openQuestions, "None found.")
    }

    runSuite("parses inline [label] timestamp text form") {
        let transcript = """
        [Maya] 15:00:01
        We agreed to use Postgres for the new service.
        """
        let turns = MeetingQuickSummaryExtractor.turns(in: transcript)
        assertEqual(turns.count, 1, "should parse one turn")
        assertEqual(turns.first?.speaker, "Maya")
        let sections = MeetingQuickSummaryExtractor.sections(transcript: transcript)
        assertTrue(sections.decisions.lowercased().contains("postgres"))
    }

    runSuite("writer adds auto_summary_* frontmatter for a meeting") {
        let markdown = """
        ---
        capture_type: meeting
        format_version: 1
        transcript_style: raw
        title: "Weekly Sync"
        ---

        # Weekly Sync

        ## Transcript

        **00:01**  [Mic/Justin]
        I'll write the launch checklist before Monday.

        **00:09**  [System/Maya]
        We decided to delay the rollout by a week.
        """

        let date = Date(timeIntervalSince1970: 1_700_000_000)
        guard let updated = MeetingQuickSummaryWriter.markdown(byApplyingQuickSummaryTo: markdown, generatedAt: date) else {
            assertTrue(false, "writer should produce updated markdown for a meeting")
            return
        }
        assertTrue(updated.contains("auto_summary_version: \"1\""), "version should be written")
        assertTrue(updated.contains("auto_summary_method: \"heuristic-v1\""), "method should be written")
        assertTrue(updated.contains("auto_summary_action_items:"), "action items key should be present")
        assertTrue(updated.contains("auto_summary_decisions:"), "decisions key should be present")
        assertTrue(updated.contains("launch checklist"), "extracted action item should be persisted")
        assertTrue(updated.contains("delay the rollout"), "extracted decision should be persisted")
        // Body preserved verbatim.
        assertTrue(updated.contains("## Transcript"), "transcript body should be preserved")
        // Capture-format keys (docs/capture-format.md) are not managed by this
        // writer and must survive the frontmatter rewrite untouched.
        assertTrue(updated.contains("format_version: 1"), "format_version must survive summary injection")
        assertTrue(updated.contains("transcript_style: raw"), "transcript_style must survive summary injection")
        assertFalse(
            updated.contains("local_summary_version"),
            "cheap extraction must not write the heavy summarizer's keys"
        )
    }

    runSuite("writer is idempotent and skips non-meetings") {
        let alreadyDone = """
        ---
        capture_type: meeting
        auto_summary_version: "1"
        ---

        ## Transcript

        **00:01**  [Mic/Justin]
        I'll handle the follow-up.
        """
        assertNil(
            MeetingQuickSummaryWriter.markdown(byApplyingQuickSummaryTo: alreadyDone),
            "writer should not re-process a transcript that already has auto_summary_version"
        )

        let dictation = """
        ---
        capture_type: dictation
        ---

        Some dictation text.
        """
        assertNil(
            MeetingQuickSummaryWriter.markdown(byApplyingQuickSummaryTo: dictation),
            "writer should skip non-meeting captures"
        )
    }

    runSuite("writer joins the shared transcript update serializer") {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingQuickSummarySerializerTests-\(UUID().uuidString)", isDirectory: true)
        let transcriptURL = root.appendingPathComponent("Call.md")
        let markdown = """
        ---
        capture_type: meeting
        title: "Call"
        ---

        ## Transcript

        **00:01** [Mic/Justin]
        I will send the launch checklist before Friday.
        """
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)

            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                MeetingTranscriptFileUpdateSerializer.sync {
                    entered.signal()
                    _ = release.wait(timeout: .now() + 2)
                }
            }
            assertEqual(entered.wait(timeout: .now() + 2), .success, "serializer fixture should acquire the shared lock")

            let writerFinished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                _ = MeetingQuickSummaryWriter.ensureQuickSummary(at: transcriptURL)
                writerFinished.signal()
            }
            assertEqual(
                writerFinished.wait(timeout: .now() + 0.1),
                .timedOut,
                "whole-file quick-summary writes must wait for concurrent transcript updates"
            )
            release.signal()
            assertEqual(writerFinished.wait(timeout: .now() + 2), .success, "writer should continue after the shared lock is released")
        } catch {
            assertTrue(false, "serializer fixture should run: \(error)")
        }
        try? FileManager.default.removeItem(at: root)
    }
}
