import Foundation

func testHomeMeetingDeletion() {
    runSuite("HomeMeetingDeletion waits for an in-flight whole-file update before deleting") {
        withTemporaryHomeMeetingDeletionLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Quick notes.md")
            try writeDeletionMeeting(title: "Quick notes", transcriptURL: transcriptURL)
            guard let item = deletionMeetingItem(transcriptURL) else {
                assertTrue(false, "synthetic meeting should scan")
                return
            }

            let writerEntered = DispatchSemaphore(value: 0)
            let releaseWriter = DispatchSemaphore(value: 0)
            let writerFinished = DispatchSemaphore(value: 0)
            let deletionStarted = DispatchSemaphore(value: 0)
            let deletionFinished = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                MeetingTranscriptFileUpdateSerializer.sync {
                    let raw = try? String(contentsOf: transcriptURL, encoding: .utf8)
                    writerEntered.signal()
                    _ = releaseWriter.wait(timeout: .now() + 5)
                    try? raw?.write(to: transcriptURL, atomically: true, encoding: .utf8)
                }
                writerFinished.signal()
            }
            assertEqual(writerEntered.wait(timeout: .now() + 2), .success, "writer should read before deletion")
            DispatchQueue.global().async {
                deletionStarted.signal()
                _ = try? HomeMeetingDeletion.delete(item)
                deletionFinished.signal()
            }
            assertEqual(deletionStarted.wait(timeout: .now() + 2), .success, "deletion should start")
            let prematureCompletion = deletionFinished.wait(timeout: .now() + 0.1)
            releaseWriter.signal()
            assertEqual(writerFinished.wait(timeout: .now() + 2), .success, "writer should finish")
            if prematureCompletion == .timedOut {
                assertEqual(deletionFinished.wait(timeout: .now() + 2), .success, "deletion should finish after update")
            }
            assertEqual(prematureCompletion, .timedOut, "deletion must join the whole-file update serializer")
            assertFalse(FileManager.default.fileExists(atPath: transcriptURL.path), "a finishing writer must not resurrect the deleted meeting")
        }
    }

    runSuite("HomeMeetingDeletion Trash waits for writers and Undo preserves the committed bytes") {
        withTemporaryHomeMeetingDeletionLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("2026-06-05 Quick notes.md")
            try writeDeletionMeeting(title: "Quick notes", transcriptURL: transcriptURL)
            let summaryURL = legacySummarySidecarURL(for: transcriptURL)
            try writeDeletionSummary(summaryURL)
            let audioDirectory = try writeDeletionAudio(for: transcriptURL, systemBytes: "system", micBytes: "mic")
            guard let item = deletionMeetingItem(transcriptURL) else {
                assertTrue(false, "synthetic meeting should scan")
                return
            }
            let original = try String(contentsOf: transcriptURL, encoding: .utf8)
            let committed = original.replacingOccurrences(of: "Synthetic reply.", with: "Updated reply.")
            let writerEntered = DispatchSemaphore(value: 0)
            let releaseWriter = DispatchSemaphore(value: 0)
            let writerFinished = DispatchSemaphore(value: 0)
            let deletionFinished = DispatchSemaphore(value: 0)
            let deletionResult = HomeMeetingDeletionTestResult()
            DispatchQueue.global().async {
                MeetingTranscriptFileUpdateSerializer.sync {
                    writerEntered.signal()
                    _ = releaseWriter.wait(timeout: .now() + 5)
                    try? committed.write(to: transcriptURL, atomically: true, encoding: .utf8)
                }
                writerFinished.signal()
            }
            assertEqual(writerEntered.wait(timeout: .now() + 2), .success, "writer should own the serializer first")
            DispatchQueue.global().async {
                deletionResult.set(Result { try HomeMeetingDeletion.trash(item) })
                deletionFinished.signal()
            }
            let prematureCompletion = deletionFinished.wait(timeout: .now() + 0.1)
            releaseWriter.signal()
            assertEqual(writerFinished.wait(timeout: .now() + 2), .success, "writer should finish")
            if prematureCompletion == .timedOut {
                assertEqual(deletionFinished.wait(timeout: .now() + 2), .success, "Trash should complete after the writer")
            }
            assertEqual(prematureCompletion, .timedOut, "Trash must not race the in-flight writer")
            guard let result = deletionResult.get() else {
                assertTrue(false, "Trash should return an undo payload")
                return
            }
            let payload = try result.get()
            defer { HomeMeetingDeletion.restore(payload) }
            assertFalse(FileManager.default.fileExists(atPath: transcriptURL.path), "transcript should remain deleted after the writer finishes")
            assertFalse(FileManager.default.fileExists(atPath: summaryURL.path), "owned summary should move to Trash")
            assertFalse(FileManager.default.fileExists(atPath: audioDirectory.path), "retained audio should move to Trash")

            // Real queued post-save writers must observe absence, not resurrect
            // a snapshot captured before this deletion.
            assertFalse(MeetingQuickSummaryWriter.ensureQuickSummary(at: transcriptURL), "late summary work should skip the deleted transcript")
            _ = MeetingTranscriptStyler.restyleTranscript(at: transcriptURL)
            assertFalse(FileManager.default.fileExists(atPath: transcriptURL.path), "late restyling must not recreate the meeting")

            HomeMeetingDeletion.restore(payload)
            assertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), committed, "Undo should restore the latest committed bytes, including original capture IDs")
            assertTrue(FileManager.default.fileExists(atPath: summaryURL.path), "Undo should restore the owned summary")
            assertTrue(FileManager.default.fileExists(atPath: audioDirectory.path), "Undo should restore retained audio")
            assertTrue(MeetingQuickSummaryWriter.ensureQuickSummary(at: transcriptURL), "normal writes should resume after Undo")
            let restoredValues = try TranscriptFrontmatter.readValues(from: transcriptURL)
            let originalValues = TranscriptFrontmatter.document(in: original)?.values
            assertEqual(restoredValues?["capture_id"], originalValues?["capture_id"], "Undo and later writes must preserve capture identity")
            assertEqual(restoredValues?["transcript_id"], originalValues?["transcript_id"], "Undo and later writes must preserve transcript identity")
        }
    }

    runSuite("HomeMeetingDeletion replans audio attached after the row was scanned") {
        withTemporaryHomeMeetingDeletionLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Quick notes.md")
            try writeDeletionMeeting(title: "Quick notes", transcriptURL: transcriptURL)
            guard let item = deletionMeetingItem(transcriptURL) else {
                assertTrue(false, "synthetic meeting should scan")
                return
            }
            assertNil(item.audio, "row starts without retained audio")
            let audioDirectory = try writeDeletionAudio(for: transcriptURL, systemBytes: "system", micBytes: "mic")
            let payload = try HomeMeetingDeletion.trash(item)
            defer { HomeMeetingDeletion.restore(payload) }
            assertTrue(payload.plan.audioDirectoryURLs.contains(audioDirectory), "transaction should resolve current retained audio")
            assertFalse(FileManager.default.fileExists(atPath: audioDirectory.path), "late-attached audio must move with its meeting")
        }
    }

    runSuite("HomeMeetingDeletion fails closed when a preceding restyle renamed the selected row") {
        withTemporaryHomeMeetingDeletionLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Quick notes.md")
            try writeDeletionMeeting(title: "Quick notes", transcriptURL: transcriptURL)
            try writeDeletionAudio(for: transcriptURL, systemBytes: "system", micBytes: "mic")
            guard let item = deletionMeetingItem(transcriptURL) else {
                assertTrue(false, "synthetic meeting should scan")
                return
            }
            let styled = MeetingTranscriptStyler.restyleTranscript(at: transcriptURL)
            assertFalse(styled.url == transcriptURL, "restyle fixture should rename the selected path")
            assertFalse(FileManager.default.fileExists(atPath: item.transcriptURL.path), "the scanned URL should no longer exist despite its prefetched metadata")
            do {
                let payload = try HomeMeetingDeletion.trash(item)
                HomeMeetingDeletion.restore(payload)
                assertTrue(false, "a stale row must not report a successful delete")
            } catch HomeMeetingDeletionError.transcriptUnavailable {
                assertTrue(FileManager.default.fileExists(atPath: styled.url.path), "renamed transcript should remain untouched for refresh")
                assertNotNil(MeetingAudioArchiveResolver.attachment(forTranscript: styled.url), "renamed audio should remain with its transcript")
            }
        }
    }

    runSuite("HomeMeetingDeletion removes the selected transcript summary and retained audio") {
        withTemporaryHomeMeetingDeletionLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Quick notes.md")
            let summaryURL = legacySummarySidecarURL(for: transcriptURL)
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
            let summaryURL = legacySummarySidecarURL(for: transcriptURL)
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

    runSuite("HomeMeetingDeletion resolves the on-disk URL for date-prefixed, accented filenames") {
        withTemporaryHomeMeetingDeletionLibrary { meetingsRoot in
            // Mirror a real capture-library filename: date-prefixed title with
            // diacritics. The scanned RecentMeetingItem.transcriptURL must point
            // at the exact on-disk file so delete and reveal resolve it.
            let transcriptURL = meetingsRoot.appendingPathComponent(
                "2026-06-13 Conversación técnica Observabilidad.md"
            )
            try writeDeletionMeeting(title: "Conversación técnica Observabilidad", transcriptURL: transcriptURL)

            guard let item = deletionMeetingItem(transcriptURL) else {
                assertionFailure("accented meeting should scan")
                return
            }

            assertEqual(item.transcriptURL.path, transcriptURL.path, "scanned URL should match the on-disk path byte-for-byte")
            assertTrue(FileManager.default.fileExists(atPath: item.transcriptURL.path), "scanned URL should resolve to an existing file")

            do {
                _ = try HomeMeetingDeletion.delete(item)
                assertFalse(FileManager.default.fileExists(atPath: transcriptURL.path), "accented transcript should be deleted")
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
            try writeDeletionSummary(legacySummarySidecarURL(for: duplicateURL))
            let scannedURLs = RecentMeetingsScanner.loadRecent(limit: 20, directory: meetingsRoot).map(\.transcriptURL)
            assertTrue(scannedURLs.contains(duplicateURL), "duplicate fixture should scan as a Home meeting row")
            let duplicateValues = try TranscriptFrontmatter.readValues(from: duplicateURL)
            assertNotNil(duplicateValues?["transcript_id"], "duplicate fixture should be app-owned")
            assertNotNil(MeetingAudioArchiveResolver.attachment(forTranscript: duplicateURL), "duplicate fixture should have retained audio")
            guard let item = deletionMeetingItem(firstURL) else {
                assertionFailure("synthetic meeting should scan")
                return
            }
            let duplicateAttachment = MeetingAudioArchiveResolver.attachment(forTranscript: duplicateURL)
            let plan = HomeMeetingDeletion.plan(for: item)
            assertEqual(
                Set(plan.audioAttachmentIDs),
                Set([item.audio?.id, duplicateAttachment?.id].compactMap { $0 }),
                "deletion plan should identify selected and duplicate audio playback attachments"
            )

            do {
                let result = try HomeMeetingDeletion.delete(item)

                assertFalse(FileManager.default.fileExists(atPath: firstURL.path), "selected transcript should be deleted")
                assertFalse(FileManager.default.fileExists(atPath: duplicateURL.path), "matching duplicate transcript should be deleted")
                assertFalse(FileManager.default.fileExists(atPath: firstAudio.path), "selected audio should be deleted")
                assertFalse(FileManager.default.fileExists(atPath: duplicateAudio.path), "matching duplicate audio should be deleted")
                assertFalse(FileManager.default.fileExists(atPath: legacySummarySidecarURL(for: duplicateURL).path), "duplicate summary should be deleted")
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

    runSuite("HomeMeetingDeletion only treats same-size audio as a duplicate when the bytes match") {
        withTemporaryHomeMeetingDeletionLibrary { meetingsRoot in
            let selectedURL = meetingsRoot.appendingPathComponent("Weekly sync.md")
            let sameSizeURL = meetingsRoot.appendingPathComponent("Weekly sync 2.md")
            let otherSizeURL = meetingsRoot.appendingPathComponent("Weekly sync 3.md")
            try writeDeletionMeeting(title: "Weekly sync", transcriptURL: selectedURL)
            try writeDeletionMeeting(title: "Weekly sync", transcriptURL: sameSizeURL)
            try writeDeletionMeeting(title: "Weekly sync", transcriptURL: otherSizeURL)
            try writeDeletionAudio(for: selectedURL, systemBytes: "system aaaa", micBytes: "mic aaaa")
            let sameSizeAudio = try writeDeletionAudio(for: sameSizeURL, systemBytes: "system bbbb", micBytes: "mic bbbb")
            let otherSizeAudio = try writeDeletionAudio(for: otherSizeURL, systemBytes: "system longer", micBytes: "mic longer")
            guard let item = deletionMeetingItem(selectedURL) else {
                assertionFailure("synthetic meeting should scan")
                return
            }

            do {
                let result = try HomeMeetingDeletion.delete(item)

                assertFalse(FileManager.default.fileExists(atPath: selectedURL.path), "selected transcript should be deleted")
                assertTrue(FileManager.default.fileExists(atPath: sameSizeURL.path), "same-size audio with different bytes should stay")
                assertTrue(FileManager.default.fileExists(atPath: sameSizeAudio.path), "same-size audio directory with different bytes should stay")
                assertTrue(FileManager.default.fileExists(atPath: otherSizeURL.path), "different-size audio should stay")
                assertTrue(FileManager.default.fileExists(atPath: otherSizeAudio.path), "different-size audio directory should stay")
                assertEqual(result.removedTranscriptURLs.map(\.lastPathComponent), ["Weekly sync.md"], "result should only include the selected transcript")
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

private final class HomeMeetingDeletionTestResult: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Result<HomeMeetingDeletion.UndoPayload, Error>?

    func set(_ value: Result<HomeMeetingDeletion.UndoPayload, Error>) {
        lock.lock()
        defer { lock.unlock() }
        self.value = value
    }

    func get() -> Result<HomeMeetingDeletion.UndoPayload, Error>? {
        lock.lock()
        defer { lock.unlock() }
        return value
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

/// Mirrors `HomeMeetingDeletion`'s legacy `<stem>.summary.md` sidecar naming
/// (the artifact the now-removed local AI summarizer used to write).
private func legacySummarySidecarURL(for transcriptURL: URL) -> URL {
    let base = transcriptURL.deletingPathExtension()
    return base
        .deletingLastPathComponent()
        .appendingPathComponent("\(base.lastPathComponent).summary")
        .appendingPathExtension("md")
}

private func deletionMeetingItem(_ transcriptURL: URL) -> RecentMeetingItem? {
    RecentMeetingsScanner.loadRecent(
        limit: 20,
        directory: transcriptURL.deletingLastPathComponent()
    ).first { $0.transcriptURL == transcriptURL }
}
