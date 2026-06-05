import Foundation

func testLocalMeetingSummarizer() {
    runSuite("LocalMeetingTranscriptExtractor strips frontmatter and keeps only transcript text") {
        let markdown = """
        ---
        capture_type: meeting
        title: "Weekly Sync"
        ---

        # Weekly Sync

        Recorded Jun 5

        ## Channel & Speaker Analytics

        Ignore this analytics section.

        ## Transcript

        **00:01**  [System/Maya]
        We should ship the smaller version first.

        **00:09**  [Mic/Justin]
        I will write the follow-up.

        ## Notes

        Ignore this later section.
        """

        let transcript = LocalMeetingTranscriptExtractor.transcriptText(from: markdown)
        assertTrue(transcript.contains("We should ship the smaller version first."), "transcript text should be preserved")
        assertFalse(transcript.contains("capture_type"), "frontmatter should not be sent to the model")
        assertFalse(transcript.contains("Ignore this analytics section."), "non-transcript sections should be excluded")
        assertFalse(transcript.contains("Ignore this later section."), "later markdown sections should be excluded")
    }

    runSuite("LocalMeetingSummaryChunker keeps speaker turns together") {
        let transcript = """
        [Maya] 15:00:01
        First topic has enough text to fill the first chunk with a decision and some supporting context.

        [Justin] 15:01:10
        Second topic has enough text to spill into another chunk without splitting the speaker turn.

        [Sara] 15:02:20
        Third topic closes the loop.
        """

        let chunks = LocalMeetingSummaryChunker.chunks(from: transcript, targetCharacterLimit: 115)
        assertTrue(chunks.count >= 2, "long transcripts should be chunked for M1 memory safety")
        assertTrue(chunks.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }, "chunks should not be empty")
        assertTrue(chunks[0].contains("[Maya] 15:00:01"), "first turn should stay intact")
        assertTrue(chunks.dropFirst().joined(separator: "\n").contains("[Justin] 15:01:10"), "later turns should stay intact")
    }

    runSuite("LocalGemmaSummaryConfiguration uses a conservative M1 profile") {
        let gib = UInt64(1024 * 1024 * 1024)
        let m1Config = LocalGemmaSummaryConfiguration.m1Optimized(physicalMemoryBytes: 16 * gib)
        assertEqual(m1Config.profileName, "m1-low-memory", "16GB Apple Silicon should use the low-memory profile")
        assertTrue(m1Config.chunkCharacterLimit <= 14_000, "M1 profile should keep chunks small")
        do {
            try m1Config.validateHardware(physicalMemoryBytes: 16 * gib)
            assertTrue(true, "16GB should be allowed")
        } catch {
            assertTrue(false, "16GB should be allowed, got \(error)")
        }

        do {
            try m1Config.validateHardware(physicalMemoryBytes: 8 * gib)
            assertTrue(false, "8GB should be refused for Gemma 4 12B")
        } catch {
            guard case LocalMeetingSummaryError.insufficientMemory = error else {
                assertTrue(false, "Expected insufficient-memory error, got \(error)")
                return
            }
            assertTrue(true, "8GB should be refused for Gemma 4 12B")
        }
    }

    runSuite("LocalMeetingSummaryStore keeps the legacy sibling summary path for fallback reads") {
        let transcriptURL = URL(fileURLWithPath: "/tmp/Product Sync.md")
        assertEqual(
            LocalMeetingSummaryStore.summaryURL(for: transcriptURL).path,
            "/tmp/Product Sync.summary.md",
            "legacy summary artifacts should still be discoverable for older local summaries"
        )
    }

    runSuite("LocalMeetingSummaryNormalizer restores missing sections") {
        let normalized = LocalMeetingSummaryNormalizer.normalized("# Summary\nUseful brief.")
        for heading in [
            "# Title",
            "# Summary",
            "# Decisions",
            "# Action Items",
            "# Open Questions",
            "# Risks or Follow-ups",
            "# Accuracy Notes"
        ] {
            assertTrue(normalized.contains(heading), "normalized summaries should include \(heading)")
        }
    }

    runSuite("LocalMeetingSummaryNormalizer extracts generated titles") {
        let normalized = LocalMeetingSummaryNormalizer.normalized("""
        # Title
        Launch Pricing Review

        # Summary
        Team agreed to keep the first version small.
        """)

        assertEqual(
            LocalMeetingSummaryNormalizer.summaryTitle(in: normalized),
            "Launch Pricing Review",
            "summaries should expose a short generated title for Home"
        )
    }

    runSuite("LocalMeetingSummaryMarkdownUpdater embeds summary metadata into the transcript") {
        let markdown = """
        ---
        capture_type: meeting
        title: "Quick notes"
        date: "2026-06-05"
        speakers:
          - "Justin"
        ---

        # Quick notes

        ## Transcript

        **00:01** [Mic/Justin]
        We should launch the smaller version first.
        """
        let updated = LocalMeetingSummaryMarkdownUpdater.markdown(
            byApplying: sampleLocalMeetingSummarySections(),
            to: markdown,
            configuration: .m1Optimized(physicalMemoryBytes: 16 * 1024 * 1024 * 1024),
            generatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            chunkCount: 2
        )

        assertTrue(updated.contains("capture_type: meeting"), "existing frontmatter should be preserved")
        assertTrue(updated.contains("  - \"Justin\""), "nested frontmatter lines should be preserved")
        assertTrue(updated.contains("local_summary_version: \"1\""), "summary metadata should live in frontmatter")
        assertTrue(updated.contains("local_summary_title: \"Launch Pricing Review\""), "generated title should live in frontmatter")
        assertTrue(updated.contains("local_summary_action_items:"), "action items should live in frontmatter")
        assertTrue(updated.contains(LocalMeetingSummaryMarkdownUpdater.startMarker), "transcript should get a managed summary block")
        assertTrue(updated.contains("## Local Gemma Summary"), "managed block should be readable markdown")
        assertTrue(updated.contains("## Transcript"), "original transcript body should remain in the same file")
    }

    runSuite("LocalMeetingSummaryMarkdownUpdater replaces prior local summary metadata") {
        let firstPass = LocalMeetingSummaryMarkdownUpdater.markdown(
            byApplying: sampleLocalMeetingSummarySections(),
            to: """
            ---
            capture_type: meeting
            local_summary_title: "Old Title"
            local_summary: "Old summary"
            ---

            ## Transcript

            Original body.

            \(LocalMeetingSummaryMarkdownUpdater.startMarker)
            ## Local Gemma Summary

            ### Summary
            Old summary.
            \(LocalMeetingSummaryMarkdownUpdater.endMarker)
            """,
            configuration: .m1Optimized(physicalMemoryBytes: 16 * 1024 * 1024 * 1024),
            generatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            chunkCount: 1
        )

        assertEqual(
            firstPass.components(separatedBy: LocalMeetingSummaryMarkdownUpdater.startMarker).count - 1,
            1,
            "regeneration should keep exactly one managed summary block"
        )
        assertFalse(firstPass.contains("Old summary"), "old managed summary text should be replaced")
        assertTrue(firstPass.contains("local_summary_title: \"Launch Pricing Review\""), "managed frontmatter should be refreshed")
    }
}

private func sampleLocalMeetingSummarySections() -> LocalMeetingSummarySections {
    LocalMeetingSummarySections(
        title: "Launch Pricing Review",
        summary: "Team agreed to keep launch pricing simple.",
        decisions: "Ship the smaller launch version first.",
        actionItems: "Alex will check pricing language before Friday.",
        openQuestions: "Whether enterprise pricing needs a separate page.",
        risksOrFollowUps: "Pricing copy could overpromise the first version.",
        accuracyNotes: "Based only on the transcript."
    )
}
