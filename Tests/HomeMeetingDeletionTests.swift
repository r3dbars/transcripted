import Foundation

func testHomeMeetingDeletion() {
    runSuite("HomeMeetingDeletion removes the selected transcript summary and retained audio") {
        withTemporaryHomeMeetingDeletionLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Quick notes.md")
            let summaryURL = LocalMeetingSummaryStore.summaryURL(for: transcriptURL)
            try writeDeletionMeeting(title: "Quick notes", transcriptURL: transcriptURL)
            try writeDeletionSummary(summaryURL)
            let audioDirectory = try writeDeletionAudio(
                for: transcriptURL,
                systemBytes: "system one",
                micBytes: "mic one"
            )
            guard let item = deletionMeetingItem(transcriptURL) else {
                assertionFailure("synthetic meeting should scan")
                return
            }

            do {
                let result = try HomeMeetingDeletion.delete(item)

                assertFalse(FileManager.default.fileExists(atPath: transcriptURL.path), "transcript should be deleted")
                assertFalse(FileManager.default.fileExists(atPath: summaryURL.path), "summary sibling should be deleted")
                assertFalse(FileManager.default.fileExists(atPath: audioDirectory.path), "retained audio directory should be deleted")
                assertEqual(result.removedTranscriptURLs.map(\.lastPathComponent), ["Quick notes.md"], "result should report selected transcript")
                assertEqual(result.removedSummaryURLs.map(\.lastPathComponent), ["Quick notes.summary.md"], "result should report selected summary")
            } catch {
                assertionFailure("delete should not throw: \(error)")
            }
        }
    }

    runSuite("HomeMeetingDeletion leaves unrelated summary siblings alone") {
        withTemporaryHomeMeetingDeletionLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Quick notes.md")
            let summaryURL = LocalMeetingSummaryStore.summaryURL(for: transcriptURL)
            try writeDeletionMeeting(title: "Quick notes", transcriptURL: transcriptURL)
            try writeDeletionSummary(summaryURL, sourceTranscript: "Other.md")
            try writeDeletionAudio(
                for: transcriptURL,
                systemBytes: "system one",
                micBytes: "mic one"
            )
            guard let item = deletionMeetingItem(transcriptURL) else {
                assertionFailure("synthetic meeting should scan")
                return
            }

            do {
                let result = try HomeMeetingDeletion.delete(item)

                assertFalse(FileManager.default.fileExists(atPath: transcriptURL.path), "transcript should be deleted")
                assertTrue(FileManager.default.fileExists(atPath: summaryURL.path), "summary for a different source transcript should stay")
                assertTrue(result.removedSummaryURLs.isEmpty, "result should not report unrelated summaries")
            } catch {
                assertionFailure("delete should not throw: \(error)")
            }
        }
    }

    runSuite("HomeMeetingDeletion removes duplicate app-owned retranscriptions with matching retained audio") {
        withTemporaryHomeMeetingDeletionLibrary { meetingsRoot in
            let firstURL = meetingsRoot.appendingPathComponent("Quick notes.md")
            let duplicateURL = meetingsRoot.appendingPathComponent("Quick notes 2.md")
            let unrelatedURL = meetingsRoot.appendingPathComponent("Quick notes 3.md")
            try writeDeletionMeeting(title: "Quick notes", transcriptURL: firstURL)
            try writeDeletionMeeting(title: "Quick notes", transcriptURL: duplicateURL)
            try writeDeletionMeeting(title: "Quick notes", transcriptURL: unrelatedURL)
            let firstAudio = try writeDeletionAudio(for: firstURL, systemBytes: "same system", micBytes: "same mic")
            let duplicateAudio = try writeDeletionAudio(for: duplicateURL, systemBytes: "same system", micBytes: "same mic")
            let unrelatedAudio = try writeDeletionAudio(for: unrelatedURL, systemBytes: "different system", micBytes: "same mic")
            try writeDeletionSummary(LocalMeetingSummaryStore.summaryURL(for: duplicateURL))
            let scannedURLs = RecentMeetingsScanner.loadRecent(limit: 20, directory: meetingsRoot).map(\.transcriptURL)
            assertTrue(scannedURLs.contains(duplicateURL), "duplicate fixture should scan as a Home meeting row")
            let duplicateValues = try TranscriptFrontmatter.readValues(from: duplicateURL)
            assertNotNil(duplicateValues?["transcript_id"], "duplicate fixture should be app-owned")
            assertNotNil(MeetingAudioArchiveResolver.attachment(forTranscript: duplicateURL), "duplicate fixture should have retained audio")
            guard let item = deletionMeetingItem(firstURL) else {
                assertionFailure("synthetic meeting should scan")
                return
            }

            do {
                let result = try HomeMeetingDeletion.delete(item)

                assertFalse(FileManager.default.fileExists(atPath: firstURL.path), "selected transcript should be deleted")
                assertFalse(FileManager.default.fileExists(atPath: duplicateURL.path), "matching duplicate transcript should be deleted")
                assertFalse(FileManager.default.fileExists(atPath: firstAudio.path), "selected audio should be deleted")
                assertFalse(FileManager.default.fileExists(atPath: duplicateAudio.path), "matching duplicate audio should be deleted")
                assertFalse(FileManager.default.fileExists(atPath: LocalMeetingSummaryStore.summaryURL(for: duplicateURL).path), "duplicate summary should be deleted")
                assertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path), "different-audio transcript should stay")
                assertTrue(FileManager.default.fileExists(atPath: unrelatedAudio.path), "different-audio directory should stay")
                assertEqual(
                    result.removedTranscriptURLs.map(\.lastPathComponent).sorted(),
                    ["Quick notes 2.md", "Quick notes.md"],
                    "result should include selected and duplicate transcripts"
                )
            } catch {
                assertionFailure("delete should not throw: \(error)")
            }
        }
    }

    runSuite("HomeMeetingDeletion leaves non-owned matching audio siblings alone") {
        withTemporaryHomeMeetingDeletionLibrary { meetingsRoot in
            let selectedURL = meetingsRoot.appendingPathComponent("Owned.md")
            let nonOwnedURL = meetingsRoot.appendingPathComponent("Manual.md")
            try writeDeletionMeeting(title: "Owned", transcriptURL: selectedURL)
            try writeDeletionMeeting(title: "Manual", transcriptURL: nonOwnedURL, includeIDs: false)
            try writeDeletionAudio(for: selectedURL, systemBytes: "same system", micBytes: "same mic")
            let nonOwnedAudio = try writeDeletionAudio(for: nonOwnedURL, systemBytes: "same system", micBytes: "same mic")
            guard let item = deletionMeetingItem(selectedURL) else {
                assertionFailure("synthetic meeting should scan")
                return
            }

            do {
                _ = try HomeMeetingDeletion.delete(item)

                assertTrue(FileManager.default.fileExists(atPath: nonOwnedURL.path), "manual transcript without IDs should stay")
                assertTrue(FileManager.default.fileExists(atPath: nonOwnedAudio.path), "manual retained audio should stay")
            } catch {
                assertionFailure("delete should not throw: \(error)")
            }
        }
    }

    runSuite("HomeMeetingDeletion does not clean up owned siblings from a non-owned selected row") {
        withTemporaryHomeMeetingDeletionLibrary { meetingsRoot in
            let selectedURL = meetingsRoot.appendingPathComponent("Manual.md")
            let ownedURL = meetingsRoot.appendingPathComponent("Manual 2.md")
            try writeDeletionMeeting(title: "Manual", transcriptURL: selectedURL, includeIDs: false)
            try writeDeletionMeeting(title: "Manual", transcriptURL: ownedURL)
            try writeDeletionAudio(for: selectedURL, systemBytes: "same system", micBytes: "same mic")
            let ownedAudio = try writeDeletionAudio(for: ownedURL, systemBytes: "same system", micBytes: "same mic")
            guard let item = deletionMeetingItem(selectedURL) else {
                assertionFailure("synthetic meeting should scan")
                return
            }

            do {
                _ = try HomeMeetingDeletion.delete(item)

                assertFalse(FileManager.default.fileExists(atPath: selectedURL.path), "selected manual transcript should still be deleted")
                assertTrue(FileManager.default.fileExists(atPath: ownedURL.path), "owned sibling should stay when the selected row is not app-owned")
                assertTrue(FileManager.default.fileExists(atPath: ownedAudio.path), "owned sibling audio should stay when the selected row is not app-owned")
            } catch {
                assertionFailure("delete should not throw: \(error)")
            }
        }
    }

    runSuite("HomeMeetingDeletion leaves same-audio app-owned meetings with different titles alone") {
        withTemporaryHomeMeetingDeletionLibrary { meetingsRoot in
            let selectedURL = meetingsRoot.appendingPathComponent("Quick notes.md")
            let otherURL = meetingsRoot.appendingPathComponent("Other call.md")
            try writeDeletionMeeting(title: "Quick notes", transcriptURL: selectedURL)
            try writeDeletionMeeting(title: "Other call", transcriptURL: otherURL)
            try writeDeletionAudio(for: selectedURL, systemBytes: "same system", micBytes: "same mic")
            let otherAudio = try writeDeletionAudio(for: otherURL, systemBytes: "same system", micBytes: "same mic")
            guard let item = deletionMeetingItem(selectedURL) else {
                assertionFailure("synthetic meeting should scan")
                return
            }

            do {
                _ = try HomeMeetingDeletion.delete(item)

                assertFalse(FileManager.default.fileExists(atPath: selectedURL.path), "selected transcript should be deleted")
                assertTrue(FileManager.default.fileExists(atPath: otherURL.path), "same-audio transcript with a different title should stay")
                assertTrue(FileManager.default.fileExists(atPath: otherAudio.path), "same-audio directory with a different title should stay")
            } catch {
                assertionFailure("delete should not throw: \(error)")
            }
        }
    }

    runSuite("HomeMeetingDeletion preserves split-audio roles when matching duplicates") {
        withTemporaryHomeMeetingDeletionLibrary { meetingsRoot in
            let selectedURL = meetingsRoot.appendingPathComponent("Quick notes.md")
            let swappedURL = meetingsRoot.appendingPathComponent("Quick notes swapped.md")
            try writeDeletionMeeting(title: "Quick notes", transcriptURL: selectedURL)
            try writeDeletionMeeting(title: "Quick notes", transcriptURL: swappedURL)
            try writeDeletionAudio(for: selectedURL, systemBytes: "system stream", micBytes: "mic stream")
            let swappedAudio = try writeDeletionAudio(for: swappedURL, systemBytes: "mic stream", micBytes: "system stream")
            guard let item = deletionMeetingItem(selectedURL) else {
                assertionFailure("synthetic meeting should scan")
                return
            }

            do {
                let result = try HomeMeetingDeletion.delete(item)

                assertFalse(FileManager.default.fileExists(atPath: selectedURL.path), "selected transcript should be deleted")
                assertTrue(FileManager.default.fileExists(atPath: swappedURL.path), "same bytes in swapped audio roles should stay")
                assertTrue(FileManager.default.fileExists(atPath: swappedAudio.path), "swapped-role audio directory should stay")
                assertEqual(result.removedTranscriptURLs.map(\.lastPathComponent), ["Quick notes.md"], "result should only include the selected transcript")
            } catch {
                assertionFailure("delete should not throw: \(error)")
            }
        }
    }
}

private func withTemporaryHomeMeetingDeletionLibrary(_ body: (URL) throws -> Void) {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("build/home-meeting-deletion-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let meetingsRoot = root.appendingPathComponent("meetings", isDirectory: true)

    do {
        try fm.createDirectory(at: meetingsRoot, withIntermediateDirectories: true)
        try body(meetingsRoot)
    } catch {
        assertionFailure("temporary deletion fixture failed: \(error)")
    }
    try? fm.removeItem(at: root)
}

private func writeDeletionMeeting(
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

    **00:02** [System/Remote]
    Synthetic reply.
    """
    try markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
}

@discardableResult
private func writeDeletionAudio(
    for transcriptURL: URL,
    systemBytes: String,
    micBytes: String
) throws -> URL {
    let audioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: transcriptURL)
    try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    try Data(systemBytes.utf8).write(to: audioDirectory.appendingPathComponent("system_audio.wav"))
    try Data(micBytes.utf8).write(to: audioDirectory.appendingPathComponent("microphone.wav"))
    return audioDirectory
}

private func writeDeletionSummary(_ url: URL, sourceTranscript: String? = nil) throws {
    let sourceTranscript = sourceTranscript ?? "\(url.deletingPathExtension().deletingPathExtension().lastPathComponent).md"
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

private func deletionMeetingItem(_ transcriptURL: URL) -> RecentMeetingItem? {
    RecentMeetingsScanner.loadRecent(
        limit: 20,
        directory: transcriptURL.deletingLastPathComponent()
    ).first { $0.transcriptURL == transcriptURL }
}
