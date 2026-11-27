import Foundation

/// Every app reader and rewriter of meeting bodies on `format_version: 2`
/// rows (`[MM:SS] **Speaker:** text`, channel from the frontmatter), and the
/// on-device label's `## Summary` and `# ` heading.
func testMeetingTranscriptV2Readers() {
    runSuite("MeetingTranscriptV2ReadersTests") {
        testPreviewReadsV2RowsWithFrontmatterChannels()
        testSpeakerRenameRewritesV2Rows()
        testSpeakerRenameHandlesCascadesOnV2Rows()
        testSpeakerRenameQualifiesWhenNamesCollideAcrossChannels()
        testScannersAndPromptReadV2Rows()
        testDictionaryFixLeavesV2LabelsAlone()
        testTitlesLabelWritesSummaryAndHeading()
        testTitlesLabelKeepsAPersonsTitleHeading()
        testTitlesRelabelReplacesSummaryOnce()
    }
}

private let readerDbSpeaker = "22222222-2222-2222-2222-222222222222"

private func v2Meeting(
    title: String = "Quick notes",
    micRow: String = "",
    body: String = """
    [00:00] **You:** Thanks for making time today.

    [00:04] **Speaker 1:** Happy to help. Let's get started.

    [01:00:02] **Mic/Lee:** Lee from the room here.
    """
) -> String {
    """
    ---
    title: "\(title)"
    capture_id: "5E9A0000-0000-0000-0000-0000000000D2"
    capture_type: meeting
    format_version: 2
    transcript_style: styled
    recorded_at: 2026-11-26T19:58:41-06:00
    date: 2026-11-26
    time: 19:58:41
    duration: "8:34"
    total_word_count: 18
    speakers:\(micRow)
      - id: "1"
        channel: system
        db_id: "\(readerDbSpeaker)"
        name: "Speaker 1"
        confidence: unknown
        source: db_pending
    ---

    # \(title)

    Recorded Nov 26, 2026 at 7:58 PM  •  8 min, 34 sec  •  18 words  •  3 turns

    ## Transcript

    \(body)

    """
}

private func writeReaderFixture(_ markdown: String) -> (URL, URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("MeetingTranscriptV2ReadersTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("2026-11-26 Quick notes.md")
    try? markdown.write(to: url, atomically: true, encoding: .utf8)
    return (directory, url)
}

private func testPreviewReadsV2RowsWithFrontmatterChannels() {
    let lines = HomeMeetingPreviewContent.make(from: v2Meeting()).transcriptLines
    assertEqual(lines.map(\.time), ["00:00", "00:04", "01:00:02"])
    assertEqual(lines.map(\.speaker), ["You", "Speaker 1", "Lee"])
    assertEqual(lines.map(\.identity.channel), [.mic, .system, .mic])
    assertEqual(lines.map(\.text), [
        "Thanks for making time today.",
        "Happy to help. Let's get started.",
        "Lee from the room here.",
    ])
    assertEqual(lines[1].identity.diarizerSpeakerID, "1", "the call voice matches its speakers row")
    assertEqual(lines[1].identity.persistentSpeakerID, UUID(uuidString: readerDbSpeaker))
    assertEqual(lines[2].startSeconds, 3602)
}

private func testSpeakerRenameRewritesV2Rows() {
    let (directory, url) = writeReaderFixture(v2Meeting())
    defer { try? FileManager.default.removeItem(at: directory) }
    let lines = HomeMeetingPreviewContent.make(from: v2Meeting()).transcriptLines

    do {
        try HomeMeetingSpeakerRename.rename(transcriptAt: url, identity: lines[1].identity, to: "Priya")
    } catch {
        assertTrue(false, "rename failed: \(error)")
    }
    let renamed = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    assertTrue(renamed.contains("[00:04] **Priya:** Happy to help."), renamed)
    assertTrue(renamed.contains("name: \"Priya\""), renamed)
    assertTrue(renamed.contains("[00:00] **You:** Thanks"), "other rows keep their labels")
    assertTrue(renamed.contains("[01:00:02] **Mic/Lee:** Lee"), "a mic voice with no row stays qualified")
    assertEqual(
        HomeMeetingPreviewContent.make(from: renamed).transcriptLines.map(\.identity.channel),
        [.mic, .system, .mic],
        "the renamed file still reads back on the right channels"
    )
}

private func testSpeakerRenameHandlesCascadesOnV2Rows() {
    let markdown = v2Meeting(
        micRow: """

          - id: "0"
            channel: mic
            name: "Alex"
            confidence: high
            source: db
        """,
        body: """
        [00:00] **Alex:** First.

        [00:04] **Speaker 1:** Second.
        """
    )
    let (directory, url) = writeReaderFixture(markdown)
    defer { try? FileManager.default.removeItem(at: directory) }
    let lines = HomeMeetingPreviewContent.make(from: markdown).transcriptLines

    do {
        try HomeMeetingSpeakerRename.renameMany(transcriptAt: url, assignments: [
            HomeMeetingSpeakerAssignment(identity: lines[0].identity, newName: "Speaker 1", targetProfileID: nil),
            HomeMeetingSpeakerAssignment(identity: lines[1].identity, newName: "Morgan", targetProfileID: nil),
        ])
    } catch {
        assertTrue(false, "rename failed: \(error)")
    }
    let renamed = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    // Alex takes the old call label while that voice becomes Morgan; neither
    // swap bleeds into the other.
    assertTrue(renamed.contains("[00:04] **Morgan:** Second."), renamed)
    assertTrue(renamed.contains("[00:00] **Speaker 1:** First.") || renamed.contains("[00:00] **Mic/Speaker 1:** First."), renamed)
    assertEqual(
        HomeMeetingPreviewContent.make(from: renamed).transcriptLines.map(\.identity.channel),
        [.mic, .system]
    )
}

private func testSpeakerRenameQualifiesWhenNamesCollideAcrossChannels() {
    let (directory, url) = writeReaderFixture(v2Meeting(body: """
    [00:00] **You:** Hi.

    [00:04] **Speaker 1:** Hello.
    """))
    defer { try? FileManager.default.removeItem(at: directory) }
    let lines = HomeMeetingPreviewContent.make(from: v2Meeting()).transcriptLines

    do {
        try HomeMeetingSpeakerRename.rename(transcriptAt: url, identity: lines[1].identity, to: "You")
    } catch {
        assertTrue(false, "rename failed: \(error)")
    }
    let renamed = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    let readBack = HomeMeetingPreviewContent.make(from: renamed).transcriptLines
    assertEqual(readBack.map(\.speaker), ["You", "You"])
    assertEqual(readBack.map(\.identity.channel), [.mic, .system], "the call voice keeps its channel: \(renamed)")
}

private func testScannersAndPromptReadV2Rows() {
    let markdown = v2Meeting()
    assertEqual(
        RecentMeetingSpeakerStatus.transcriptSpeakerLabels(in: markdown),
        ["Mic/You", "System/Speaker 1", "Mic/Lee"]
    )
    let turns = MeetingTitlesTranscript.turns(fromMeetingMarkdown: markdown)
    assertEqual(turns.map(\.speaker), ["You", "Unknown speaker", "Lee"])
    assertEqual(turns.map(\.startSeconds), [0, 4, 3602])
    assertEqual(turns.first?.text, "Thanks for making time today.")
}

private func testDictionaryFixLeavesV2LabelsAlone() {
    let segments = DictionaryPastMeetingFix.spokenSegments(in: v2Meeting())
    assertTrue(segments.contains("Thanks for making time today."), "\(segments)")
    assertFalse(segments.contains { $0.contains("**") || $0.contains("Speaker 1:") }, "labels are not spoken text: \(segments)")
}

private let readerLabel = MeetingTitlesLabel(
    title: "Vendor contract renewal",
    line: "The renewal goes ahead for one year.",
    summary: "Two bids were compared. The current vendor stays."
)

private func testTitlesLabelWritesSummaryAndHeading() {
    let raw = v2Meeting()
    guard let updated = MeetingTitlesFrontmatterWriter.markdown(
        byApplying: readerLabel, replaceableTitle: "Quick notes", speakers: "s1", to: raw
    ) else {
        assertTrue(false, "expected a rewrite")
        return
    }
    let body = TranscriptFrontmatter.body(in: updated) ?? ""
    assertTrue(body.contains("\n# Vendor contract renewal\n"), "the heading follows ai_title: \(body)")
    assertTrue(body.contains("""
    18 words  •  3 turns

    ## Summary

    Two bids were compared. The current vendor stays.

    ## Transcript
    """), body)
    let values = TranscriptFrontmatter.values(in: updated) ?? [:]
    assertEqual(values["title"], "Quick notes", "title: and the filename never change")
    assertEqual(values["ai_title"], "Vendor contract renewal")
    assertEqual(MeetingTitlesBody.summary(in: body), "Two bids were compared. The current vendor stays.")
    assertEqual(
        HomeMeetingPreviewContent.make(from: updated).transcriptLines.count,
        3,
        "readers skip the summary section"
    )
}

private func testTitlesLabelKeepsAPersonsTitleHeading() {
    let raw = v2Meeting(title: "Budget review")
        .replacingOccurrences(of: "format_version: 2", with: "format_version: 2\ntitle_set_by_user: true")
    let updated = MeetingTitlesFrontmatterWriter.markdown(
        byApplying: readerLabel, replaceableTitle: "Budget review", speakers: "s1", to: raw
    ) ?? ""
    assertTrue(updated.contains("\n# Budget review\n"), "a title the person set keeps its heading")
    assertTrue(updated.contains("## Summary\n\nTwo bids were compared."), "the summary is still written")
}

private func testTitlesRelabelReplacesSummaryOnce() {
    let first = MeetingTitlesFrontmatterWriter.markdown(
        byApplying: readerLabel, replaceableTitle: "Quick notes", speakers: "before", to: v2Meeting()
    ) ?? ""
    let relabel = MeetingTitlesLabel(title: nil, line: nil, summary: "The vendor stays for a year.")
    let second = MeetingTitlesFrontmatterWriter.markdown(
        byApplying: relabel, replaceableTitle: "Quick notes", speakers: "after", to: first
    ) ?? ""
    assertEqual(second.components(separatedBy: "## Summary").count - 1, 1, "one summary section")
    assertTrue(second.contains("## Summary\n\nThe vendor stays for a year.\n\n## Transcript"), second)
    assertTrue(second.contains("\n# Quick notes\n"), "no model title now, so the heading shows title: again")

    let tooShort = MeetingTitlesFrontmatterWriter.markdown(
        recordingNoSummary: .tooShort, speakers: "later", to: second.replacingOccurrences(of: "ai_summary_version: \"1\"", with: "ai_summary_version: \"0\"")
    ) ?? ""
    assertFalse(tooShort.contains("## Summary"), "dropping the label drops the summary the app wrote")
}
