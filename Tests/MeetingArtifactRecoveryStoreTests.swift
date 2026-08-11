import Foundation

func testMeetingArtifactRecoveryStore() {
    runSuite("MeetingArtifactRenamer never claims a foreign target transcript") {
        withTemporaryMeetingArtifactRecoveryLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Call_2026-06-05_18-39-20.md")
            try writeArtifactRecoveryMeeting(transcriptURL)
            let original = try Data(contentsOf: transcriptURL)
            let targetURL = meetingsRoot.appendingPathComponent("2026-06-05 Launch planning.md")
            guard let values = try TranscriptFrontmatter.readValues(from: transcriptURL),
                  let captureID = TranscriptFrontmatter.captureID(in: values) else {
                assertionFailure("fixture should include a capture ID")
                return
            }
            let foreign = Data("""
            ---
            capture_id: "\(captureID.uuidString)"
            transcript_id: "\(captureID.uuidString)"
            capture_type: meeting
            title: "Stale duplicate"
            ---

            # Stale duplicate
            """.utf8)

            do {
                _ = try MeetingArtifactRenamer.rename(
                    transcriptAt: transcriptURL,
                    toStem: "2026-06-05 Launch planning",
                    moveItem: { sourceURL, targetURL in
                        if sourceURL == transcriptURL {
                            try foreign.write(to: targetURL)
                            throw NSError(domain: "MeetingArtifactRenamerTests", code: 10)
                        }
                        try FileManager.default.moveItem(at: sourceURL, to: targetURL)
                    },
                    recoveryStoreDirectory: artifactRecoveryStoreDirectory(for: meetingsRoot)
                )
                assertionFailure("a target collision should not be reconciled as our transcript")
            } catch let error as MeetingArtifactRenameError {
                assertEqual(
                    error,
                    .transcriptMoveFailed(audioLocation: .notPresent, targetTranscriptURL: targetURL),
                    "a foreign target should remain a normal move failure"
                )
            } catch {
                assertionFailure("unexpected error: \(error)")
            }

            assertEqual(try Data(contentsOf: transcriptURL), original, "the owned transcript should remain untouched")
            assertEqual(try Data(contentsOf: targetURL), foreign, "a foreign target must never be deleted or adopted")
        }
    }

    runSuite("MeetingArtifactRenamer keeps the complete audio copy when fallback copying is partial") {
        withTemporaryMeetingArtifactRecoveryLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Call_2026-06-05_18-39-20.md")
            try writeArtifactRecoveryMeeting(transcriptURL)
            let sourceAudioDirectory = try writeArtifactRecoveryAudio(for: transcriptURL)
            let targetURL = meetingsRoot.appendingPathComponent("2026-06-05 Launch planning.md")
            let targetAudioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: targetURL)
            let recoveryStoreDirectory = artifactRecoveryStoreDirectory(for: meetingsRoot)

            do {
                _ = try MeetingArtifactRenamer.rename(
                    transcriptAt: transcriptURL,
                    toStem: "2026-06-05 Launch planning",
                    moveItem: { sourceURL, targetURL in
                        if sourceURL == transcriptURL || sourceURL == targetAudioDirectory {
                            throw NSError(domain: "MeetingArtifactRenamerTests", code: 11)
                        }
                        try FileManager.default.moveItem(at: sourceURL, to: targetURL)
                    },
                    copyItem: { sourceURL, targetURL in
                        if sourceURL == targetAudioDirectory {
                            try FileManager.default.createDirectory(at: targetURL, withIntermediateDirectories: true)
                            try Data("partial".utf8).write(to: targetURL.appendingPathComponent("system_audio.wav"))
                            throw NSError(domain: "MeetingArtifactRenamerTests", code: 12)
                        }
                        if sourceURL == transcriptURL {
                            throw NSError(domain: "MeetingArtifactRenamerTests", code: 13)
                        }
                        try FileManager.default.copyItem(at: sourceURL, to: targetURL)
                    },
                    recoveryStoreDirectory: recoveryStoreDirectory
                )
                assertionFailure("partial copy recovery should remain pending")
            } catch let error as MeetingArtifactRenameError {
                assertEqual(
                    error,
                    .transcriptMoveFailed(audioLocation: .atTarget, targetTranscriptURL: targetURL),
                    "the complete target must remain the recovery source"
                )
            } catch {
                assertionFailure("unexpected error: \(error)")
            }

            assertFalse(FileManager.default.fileExists(atPath: sourceAudioDirectory.path), "a partial source copy must be removed")
            assertEqual(
                try Data(contentsOf: targetAudioDirectory.appendingPathComponent("system_audio.wav")),
                Data("system".utf8),
                "the complete system-audio file must remain at the target"
            )
            assertEqual(
                try Data(contentsOf: targetAudioDirectory.appendingPathComponent("microphone.wav")),
                Data("mic".utf8),
                "the complete microphone file must remain at the target"
            )
            assertEqual(
                try MeetingArtifactRecoveryStore.pendingNotice(
                    for: transcriptURL,
                    directory: recoveryStoreDirectory
                ),
                MeetingArtifactRecoveryNotice(
                    sourceTranscriptURL: transcriptURL,
                    targetTranscriptURL: targetURL
                ),
                "the surviving target audio should stay journaled for recovery"
            )
        }
    }

    runSuite("MeetingArtifactRecoveryStore fails closed on a damaged journal") {
        withTemporaryMeetingArtifactRecoveryLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Call_2026-06-05_18-39-20.md")
            try writeArtifactRecoveryMeeting(transcriptURL)
            let original = try String(contentsOf: transcriptURL, encoding: .utf8)
            let sourceAudioDirectory = try writeArtifactRecoveryAudio(for: transcriptURL)
            let recoveryStoreDirectory = artifactRecoveryStoreDirectory(for: meetingsRoot)
            try FileManager.default.createDirectory(at: recoveryStoreDirectory, withIntermediateDirectories: true)
            try Data("not-json".utf8).write(
                to: recoveryStoreDirectory.appendingPathComponent("damaged.json")
            )
            var reportedDirectory: URL?
            let observer = NotificationCenter.default.addObserver(
                forName: .meetingArtifactRecoveryJournalUnavailable,
                object: nil,
                queue: nil
            ) { notification in
                reportedDirectory = notification.object as? URL
            }
            defer { NotificationCenter.default.removeObserver(observer) }

            do {
                _ = try HomeMeetingRename.rename(
                    transcriptAt: transcriptURL,
                    to: "Launch planning",
                    recoveryStoreDirectory: recoveryStoreDirectory
                )
                assertionFailure("a damaged journal should block artifact movement")
            } catch let error as HomeMeetingRenameError {
                assertEqual(error, .artifactRenameFailed, "journal damage should fail closed")
            } catch {
                assertionFailure("unexpected error: \(error)")
            }

            assertEqual(
                try String(contentsOf: transcriptURL, encoding: .utf8),
                original,
                "the title should be restored when journal validation fails"
            )
            assertTrue(FileManager.default.fileExists(atPath: sourceAudioDirectory.path), "retained audio should not move")
            assertEqual(
                reportedDirectory,
                recoveryStoreDirectory.standardizedFileURL,
                "a rename blocked by journal damage should surface the recovery directory"
            )
            do {
                _ = try MeetingArtifactRecoveryStore.pendingNotices(directory: recoveryStoreDirectory)
                assertionFailure("launch scanning should also report journal damage")
            } catch {
                // Expected: unreadable journals stay blocking instead of being skipped.
            }
        }
    }

    runSuite("MeetingArtifactRecoveryStore follows a relocated capture library") {
        withTemporaryMeetingArtifactRecoveryLibrary { meetingsRoot in
            let sourceTranscriptURL = meetingsRoot.appendingPathComponent("Call_2026-06-05_18-39-20.md")
            let targetTranscriptURL = meetingsRoot.appendingPathComponent("2026-06-05 Launch planning.md")
            try writeArtifactRecoveryMeeting(sourceTranscriptURL)
            let sourceAudioDirectory = try writeArtifactRecoveryAudio(for: sourceTranscriptURL)
            let targetAudioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: targetTranscriptURL)
            let recoveryStoreDirectory = artifactRecoveryStoreDirectory(for: meetingsRoot)
            _ = try MeetingArtifactRecoveryStore.prepare(
                sourceTranscriptURL: sourceTranscriptURL,
                targetTranscriptURL: targetTranscriptURL,
                hadSourceAudio: true,
                directory: recoveryStoreDirectory
            )
            try FileManager.default.moveItem(at: sourceAudioDirectory, to: targetAudioDirectory)

            let relocatedRoot = meetingsRoot
                .deletingLastPathComponent()
                .appendingPathComponent("relocated-meetings", isDirectory: true)
            try FileManager.default.createDirectory(at: relocatedRoot, withIntermediateDirectories: true)
            let relocatedSourceURL = relocatedRoot.appendingPathComponent(sourceTranscriptURL.lastPathComponent)
            let relocatedTargetURL = relocatedRoot.appendingPathComponent(targetTranscriptURL.lastPathComponent)
            try FileManager.default.copyItem(at: sourceTranscriptURL, to: relocatedSourceURL)
            try FileManager.default.createDirectory(
                at: MeetingAudioArchiveResolver.archiveDirectory(forTranscript: relocatedTargetURL)
                    .deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try FileManager.default.copyItem(
                at: targetAudioDirectory,
                to: MeetingAudioArchiveResolver.archiveDirectory(forTranscript: relocatedTargetURL)
            )

            assertEqual(
                try MeetingArtifactRecoveryStore.pendingNotice(
                    for: relocatedSourceURL,
                    directory: recoveryStoreDirectory
                ),
                MeetingArtifactRecoveryNotice(
                    sourceTranscriptURL: relocatedSourceURL,
                    targetTranscriptURL: relocatedTargetURL
                ),
                "capture-ID matching should rebase recovery paths to the active library"
            )
        }
    }
}

private func withTemporaryMeetingArtifactRecoveryLibrary(_ body: (URL) throws -> Void) {
    let fileManager = FileManager.default
    let root = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("build/meeting-artifact-recovery-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let meetingsRoot = root.appendingPathComponent("meetings", isDirectory: true)
    do {
        try fileManager.createDirectory(at: meetingsRoot, withIntermediateDirectories: true)
        try body(meetingsRoot)
    } catch {
        assertionFailure("temporary recovery fixture failed: \(error)")
    }
    try? fileManager.removeItem(at: root)
}

private func artifactRecoveryStoreDirectory(for meetingsRoot: URL) -> URL {
    meetingsRoot
        .deletingLastPathComponent()
        .appendingPathComponent("meeting-artifact-recovery", isDirectory: true)
}

private func writeArtifactRecoveryMeeting(_ transcriptURL: URL) throws {
    let id = UUID().uuidString
    let markdown = """
    ---
    capture_id: "\(id)"
    transcript_id: "\(id)"
    capture_type: meeting
    title: "Quick notes"
    date: "2026-06-05"
    time: "18:39:20"
    ---

    # Quick notes

    ## Transcript

    **00:01** [Mic/You]
    Synthetic test.
    """
    try markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
}

@discardableResult
private func writeArtifactRecoveryAudio(for transcriptURL: URL) throws -> URL {
    let audioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: transcriptURL)
    try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
    try Data("system".utf8).write(to: audioDirectory.appendingPathComponent("system_audio.wav"))
    try Data("mic".utf8).write(to: audioDirectory.appendingPathComponent("microphone.wav"))
    return audioDirectory
}
