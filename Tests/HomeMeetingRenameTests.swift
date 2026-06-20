import Foundation

func testHomeMeetingRename() {
    runSuite("HomeMeetingRename moves transcript, audio, and summary to the date-prefixed stem") {
        withTemporaryHomeMeetingRenameLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Call_2026-06-05_18-39-20.md")
            try writeRenameMeeting(title: "Quick notes", transcriptURL: transcriptURL)
            let audioDirectory = try writeRenameAudio(for: transcriptURL)
            let summaryURL = LocalMeetingSummaryStore.summaryURL(for: transcriptURL)
            try writeRenameSummary(summaryURL, sourceTranscript: transcriptURL.lastPathComponent)
            try writeInlineRenameSummary(transcriptURL: transcriptURL)

            do {
                let result = try HomeMeetingRename.rename(transcriptAt: transcriptURL, to: "  Launch planning  ")

                assertEqual(result.title, "Launch planning", "title should be trimmed/normalized")
                assertEqual(
                    result.transcriptURL.lastPathComponent,
                    "2026-06-05 Launch planning.md",
                    "transcript should land on the YYYY-MM-dd <title> stem"
                )
                assertTrue(FileManager.default.fileExists(atPath: result.transcriptURL.path), "renamed transcript should exist")
                assertFalse(FileManager.default.fileExists(atPath: transcriptURL.path), "original transcript should be gone")

                let updated = (try? String(contentsOf: result.transcriptURL, encoding: .utf8)) ?? ""
                assertTrue(updated.contains("title: \"Launch planning\""), "frontmatter title should be rewritten")
                assertTrue(updated.contains("# Launch planning"), "body heading should be rewritten")
                assertFalse(updated.contains("Quick notes"), "old title should not survive anywhere")
                assertTrue(
                    updated.contains("local_summary_source_transcript: \"2026-06-05 Launch planning.md\""),
                    "inline summary metadata should repoint at the renamed transcript"
                )
                assertTrue(
                    updated.contains("Source transcript: `2026-06-05 Launch planning.md`"),
                    "managed inline summary block should show the renamed source transcript"
                )
                assertFalse(
                    updated.contains("Source transcript: `Call_2026-06-05_18-39-20.md`"),
                    "managed inline summary block should not keep the stale source filename"
                )

                let movedAudio = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: result.transcriptURL)
                assertTrue(FileManager.default.fileExists(atPath: movedAudio.path), "audio directory should follow the rename")
                assertFalse(FileManager.default.fileExists(atPath: audioDirectory.path), "original audio directory should be gone")

                let movedSummary = LocalMeetingSummaryStore.summaryURL(for: result.transcriptURL)
                assertTrue(FileManager.default.fileExists(atPath: movedSummary.path), "summary sidecar should follow the rename")
                assertFalse(FileManager.default.fileExists(atPath: summaryURL.path), "original summary sidecar should be gone")
                let summaryContent = (try? String(contentsOf: movedSummary, encoding: .utf8)) ?? ""
                assertTrue(
                    summaryContent.contains("source_transcript: \"2026-06-05 Launch planning.md\""),
                    "summary should repoint at the renamed transcript"
                )
            } catch {
                assertionFailure("rename should not throw: \(error)")
            }
        }
    }

    runSuite("HomeMeetingRename rejects an empty title as a cancelled edit") {
        withTemporaryHomeMeetingRenameLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Call_2026-06-05_18-39-20.md")
            try writeRenameMeeting(title: "Quick notes", transcriptURL: transcriptURL)

            do {
                _ = try HomeMeetingRename.rename(transcriptAt: transcriptURL, to: "   ")
                assertionFailure("empty title should throw")
            } catch let error as HomeMeetingRenameError {
                assertEqual(error, .emptyTitle, "empty title should map to .emptyTitle")
                assertTrue(FileManager.default.fileExists(atPath: transcriptURL.path), "transcript should be untouched on cancel")
            } catch {
                assertionFailure("unexpected error: \(error)")
            }
        }
    }

    runSuite("HomeMeetingRename refuses non-owned transcripts") {
        withTemporaryHomeMeetingRenameLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Manual.md")
            try writeRenameMeeting(title: "Manual", transcriptURL: transcriptURL, includeIDs: false)

            do {
                _ = try HomeMeetingRename.rename(transcriptAt: transcriptURL, to: "Renamed")
                assertionFailure("non-owned transcript should throw")
            } catch let error as HomeMeetingRenameError {
                assertEqual(error, .notOwnedMeeting, "transcripts without owner IDs are not ours to rename")
                assertTrue(FileManager.default.fileExists(atPath: transcriptURL.path), "non-owned transcript should be untouched")
            } catch {
                assertionFailure("unexpected error: \(error)")
            }
        }
    }

    runSuite("HomeMeetingRename suffixes around an existing target name") {
        withTemporaryHomeMeetingRenameLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Call_2026-06-05_18-39-20.md")
            let blockerURL = meetingsRoot.appendingPathComponent("2026-06-05 Launch planning.md")
            try writeRenameMeeting(title: "Quick notes", transcriptURL: transcriptURL)
            try writeRenameMeeting(title: "Launch planning", transcriptURL: blockerURL)

            do {
                let result = try HomeMeetingRename.rename(transcriptAt: transcriptURL, to: "Launch planning")
                assertEqual(
                    result.transcriptURL.lastPathComponent,
                    "2026-06-05 Launch planning 2.md",
                    "a taken stem should be suffixed instead of overwriting"
                )
                assertTrue(FileManager.default.fileExists(atPath: blockerURL.path), "existing transcript should not be overwritten")
            } catch {
                assertionFailure("rename should not throw: \(error)")
            }
        }
    }

    runSuite("HomeMeetingRename.rewriteTitle inserts a title when frontmatter has none") {
        let raw = """
        ---
        capture_type: meeting
        date: "2026-06-05"
        ---

        # Old heading

        body
        """
        let rewritten = HomeMeetingRename.rewriteTitle(in: raw, to: "Brand New")
        assertTrue(rewritten.contains("title: \"Brand New\""), "missing title line should be inserted")
        assertTrue(rewritten.contains("# Brand New"), "first heading should be rewritten")
        assertFalse(rewritten.contains("# Old heading"), "old heading should be replaced")
    }
}

private func withTemporaryHomeMeetingRenameLibrary(_ body: (URL) throws -> Void) {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("build/home-meeting-rename-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let meetingsRoot = root.appendingPathComponent("meetings", isDirectory: true)

    do {
        try fm.createDirectory(at: meetingsRoot, withIntermediateDirectories: true)
        try body(meetingsRoot)
    } catch {
        assertionFailure("temporary rename fixture failed: \(error)")
    }
    try? fm.removeItem(at: root)
}

private func writeRenameMeeting(
    title: String,
    transcriptURL: URL,
    includeIDs: Bool = true
) throws {
    let id = UUID().uuidString
    var frontmatter: [String] = ["---"]
    if includeIDs {
        frontmatter.append("capture_id: \"\(id)\"")
        frontmatter.append("transcript_id: \"\(id)\"")
    }
    frontmatter.append(contentsOf: [
        "capture_type: meeting",
        "title: \"\(title)\"",
        "date: \"2026-06-05\"",
        "time: \"18:39:20\"",
        "duration: \"0:04\"",
        "total_word_count: 2",
        "mic_utterances: 1",
        "system_utterances: 1",
        "---"
    ])
    let markdown = frontmatter.joined(separator: "\n") + """


    # \(title)

    ## Transcript

    **00:01** [Mic/You]
    Synthetic test.
    """
    try markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
}

@discardableResult
private func writeRenameAudio(for transcriptURL: URL) throws -> URL {
    let audioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: transcriptURL)
    try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    try Data("system".utf8).write(to: audioDirectory.appendingPathComponent("system_audio.wav"))
    try Data("mic".utf8).write(to: audioDirectory.appendingPathComponent("microphone.wav"))
    return audioDirectory
}

private func writeRenameSummary(_ url: URL, sourceTranscript: String) throws {
    let markdown = """
    ---
    capture_type: meeting_summary
    source_transcript: "\(sourceTranscript)"
    ---

    # Summary
    Synthetic summary.
    """
    try markdown.write(to: url, atomically: true, encoding: .utf8)
}

private func writeInlineRenameSummary(transcriptURL: URL) throws {
    let raw = try String(contentsOf: transcriptURL, encoding: .utf8)
    let updated = LocalMeetingSummaryMarkdownUpdater.markdown(
        byApplying: LocalMeetingSummarySections(
            title: "Generated Summary",
            participants: "- You",
            summary: "Synthetic summary.",
            decisions: "None found.",
            actionItems: "None found.",
            openQuestions: "None found.",
            risksOrFollowUps: "None found.",
            accuracyNotes: "None found."
        ),
        to: raw,
        configuration: .m1Optimized(physicalMemoryBytes: 16 * 1024 * 1024 * 1024),
        generatedAt: Date(timeIntervalSince1970: 1_780_000_000),
        chunkCount: 1,
        sourceTranscriptFilename: transcriptURL.lastPathComponent
    )
    try updated.write(to: transcriptURL, atomically: true, encoding: .utf8)
}
