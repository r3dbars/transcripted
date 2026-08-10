import Foundation

func testHomeMeetingPreviewFormatter() {
    runSuite("HomeMeetingPreviewFormatter parses current styled meeting markdown") {
        let content = HomeMeetingPreviewContent.make(from: styledMeetingMarkdown())

        assertEqual(content.transcriptLines.count, 4, "Styled transcript blocks should become readable rows")
        assertEqual(content.transcriptLines.first?.time, "00:00", "First row should keep the timestamp")
        assertEqual(content.transcriptLines.first?.startTimeSeconds, 0, "Timestamp should be available for audio sync")
        assertEqual(content.transcriptLines.first?.speaker, "Speaker 1", "Preview should show only the speaker name")
        assertEqual(content.transcriptLines.first?.identity.channel, .system, "Source should stay available without appearing in the name")
        assertEqual(
            content.transcriptLines.first?.identity.persistentSpeakerID,
            UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
            "Frontmatter identity should follow the visible transcript row"
        )
        assertTrue(
            content.transcriptLines.first?.text.hasPrefix("touch screen. Yeah.") == true,
            "Text on the line after the timestamp should be attached to the row"
        )
        assertFalse(content.fallbackText.contains("capture_id:"), "Preview fallback should not expose YAML metadata")
    }

    runSuite("HomeMeetingPreviewFormatter parses legacy inline transcript rows") {
        let content = HomeMeetingPreviewContent.make(from: legacyInlineMarkdown())

        assertEqual(content.transcriptLines.count, 2, "Legacy inline transcript rows should still preview cleanly")
        assertEqual(content.transcriptLines[0].text, "Hello there.", "Inline text should stay on the row")
        assertEqual(content.transcriptLines[0].speaker, "You", "Mic source prefixes should not appear in the speaker name")
        assertEqual(content.transcriptLines[1].speaker, "Alex", "Obsidian speaker links should be cleaned for preview")
        assertEqual(content.transcriptLines[1].text, "Nice to meet you.", "Nested speaker links should not leak closing brackets into text")
    }

    runSuite("HomeMeetingTranscriptPlaybackPolicy highlights the audible source and follows it") {
        let lines = HomeMeetingPreviewContent.make(from: styledMeetingMarkdown()).transcriptLines

        assertEqual(
            HomeMeetingTranscriptPlaybackPolicy.activeLineIndices(
                lines: lines,
                currentTime: 0,
                source: .all
            ),
            Set([0, 1]),
            "Mixed playback should highlight simultaneous mic and system rows"
        )
        assertEqual(
            HomeMeetingTranscriptPlaybackPolicy.activeLineIndices(
                lines: lines,
                currentTime: 0,
                source: .system
            ),
            Set([0]),
            "System-only playback should highlight only the system row"
        )
        assertEqual(
            HomeMeetingTranscriptPlaybackPolicy.activeLineIndices(
                lines: lines,
                currentTime: 13,
                source: .mic
            ),
            Set([2]),
            "Playback should advance to the latest timestamp at or before the playhead"
        )
        assertEqual(
            HomeMeetingTranscriptPlaybackPolicy.source(forPlaybackChoiceID: "microphone:/tmp/microphone.wav"),
            .mic,
            "Mic playback choices should select mic transcript rows"
        )
        assertEqual(
            HomeMeetingTranscriptPlaybackPolicy.visibleLineIndices(
                totalCount: 12,
                activeIndices: Set([10]),
                limit: 8
            ),
            Array(4...11),
            "The collapsed excerpt should follow a later active row"
        )
    }
}

private func styledMeetingMarkdown() -> String {
    """
    ---
    title: "Meeting with Linus"
    capture_id: "297F08B7-62AE-4291-9EA3-41EB0B17A64A"
    capture_type: meeting
    total_word_count: 117
    speakers:
      - id: "1"
        channel: system
        db_id: "11111111-1111-1111-1111-111111111111"
        name: "Speaker 1"
        source: db_pending
      - id: "0"
        channel: mic
        name: "Linus"
        source: user_manual
      - id: "2"
        channel: system
        name: "Linus"
        source: user_manual
    ---

    # Meeting with Linus

    Recorded Apr 25, 2026 at 12:18 PM  •  31 sec  •  117 words  •  4 turns

    ## Transcript

    **00:00**  [System/Speaker 1]
    touch screen. Yeah. It actually is that it took us this long.

    **00:00**  [Mic/Linus]
    Yeah. It actually is and it took us a bit long to get to Or if we have

    **00:12**  [Mic/Linus]
    Oh

    **00:26**  [System/Linus]
    Dude, this is incredible. I'm honestly impressed.
    """
}

private func legacyInlineMarkdown() -> String {
    """
    ---
    capture_type: meeting
    ---

    # Meeting Recording

    ## Full Transcript

    [00:01] [Mic/You] Hello there.

    [00:05] [System/[[Alex]]] Nice to meet you.

    *Generated by Transcripted with Parakeet*
    """
}
