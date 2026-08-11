import Foundation

func testHomeMeetingRename() {
    runSuite("HomeMeetingRename moves transcript, audio, and summary to the date-prefixed stem") {
        withTemporaryHomeMeetingRenameLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Call_2026-06-05_18-39-20.md")
            try writeRenameMeeting(title: "Quick notes", transcriptURL: transcriptURL)
            let audioDirectory = try writeRenameAudio(for: transcriptURL)
            let summaryURL = legacyRenameSummarySidecarURL(for: transcriptURL)
            try writeRenameSummary(summaryURL, sourceTranscript: transcriptURL.lastPathComponent)

            do {
                let result = try HomeMeetingRename.rename(
                    transcriptAt: transcriptURL,
                    to: "  Launch planning  ",
                    recoveryStoreDirectory: renameRecoveryStoreDirectory(for: meetingsRoot)
                )

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
                let movedAudio = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: result.transcriptURL)
                assertTrue(FileManager.default.fileExists(atPath: movedAudio.path), "audio directory should follow the rename")
                assertFalse(FileManager.default.fileExists(atPath: audioDirectory.path), "original audio directory should be gone")

                let movedSummary = legacyRenameSummarySidecarURL(for: result.transcriptURL)
                assertTrue(FileManager.default.fileExists(atPath: movedSummary.path), "summary sidecar should follow the rename")
                assertFalse(FileManager.default.fileExists(atPath: summaryURL.path), "original summary sidecar should be gone")
                let summaryContent = (try? String(contentsOf: movedSummary, encoding: .utf8)) ?? ""
                assertTrue(
                    summaryContent.contains("source_transcript: \"2026-06-05 Launch planning.md\""),
                    "summary should repoint at the renamed transcript"
                )
                assertTrue(
                    summaryContent.contains("summary_title: \"Launch planning\""),
                    "legacy summary display title should follow the explicit user rename"
                )
            } catch {
                assertionFailure("rename should not throw: \(error)")
            }
        }
    }

    runSuite("MeetingArtifactRenamer leaves the meeting together when audio cannot move") {
        withTemporaryHomeMeetingRenameLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Call_2026-06-05_18-39-20.md")
            try writeRenameMeeting(title: "Quick notes", transcriptURL: transcriptURL)
            let audioDirectory = try writeRenameAudio(for: transcriptURL)
            let targetURL = meetingsRoot.appendingPathComponent("2026-06-05 Launch planning.md")
            let targetAudioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: targetURL)
            var loggedEvents: [String] = []

            do {
                _ = try MeetingArtifactRenamer.rename(
                    transcriptAt: transcriptURL,
                    toStem: "2026-06-05 Launch planning",
                    moveItem: { sourceURL, targetURL in
                        if sourceURL == audioDirectory {
                            throw NSError(domain: "MeetingArtifactRenamerTests", code: 1)
                        }
                        try FileManager.default.moveItem(at: sourceURL, to: targetURL)
                    },
                    recoveryStoreDirectory: renameRecoveryStoreDirectory(for: meetingsRoot),
                    logFailure: { event, _ in loggedEvents.append(event) }
                )
                assertionFailure("a failed audio move should throw")
            } catch let error as MeetingArtifactRenameError {
                assertEqual(
                    error,
                    .audioMoveFailed(audioLocation: .atSource, targetTranscriptURL: targetURL),
                    "the failure should preserve the safe audio location"
                )
            } catch {
                assertionFailure("unexpected error: \(error)")
            }

            assertTrue(FileManager.default.fileExists(atPath: transcriptURL.path), "the transcript should not move alone")
            assertTrue(FileManager.default.fileExists(atPath: audioDirectory.path), "retained audio should stay beside the transcript")
            assertFalse(FileManager.default.fileExists(atPath: targetURL.path), "the target transcript should not be created")
            assertFalse(FileManager.default.fileExists(atPath: targetAudioDirectory.path), "the target audio directory should not be created")
            assertTrue(loggedEvents.contains("meeting_audio_directory_rename_failed"), "the failed audio move should be observable")
        }
    }

    runSuite("MeetingArtifactRenamer rolls audio back when the transcript cannot move") {
        withTemporaryHomeMeetingRenameLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Call_2026-06-05_18-39-20.md")
            try writeRenameMeeting(title: "Quick notes", transcriptURL: transcriptURL)
            let audioDirectory = try writeRenameAudio(for: transcriptURL)
            let targetURL = meetingsRoot.appendingPathComponent("2026-06-05 Launch planning.md")
            let targetAudioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: targetURL)
            var rejectedTranscriptMove = false
            var transcriptFailureContext: [String: String] = [:]

            do {
                _ = try MeetingArtifactRenamer.rename(
                    transcriptAt: transcriptURL,
                    toStem: "2026-06-05 Launch planning",
                    moveItem: { sourceURL, targetURL in
                        if sourceURL == transcriptURL, !rejectedTranscriptMove {
                            rejectedTranscriptMove = true
                            throw NSError(domain: "MeetingArtifactRenamerTests", code: 2)
                        }
                        try FileManager.default.moveItem(at: sourceURL, to: targetURL)
                    },
                    recoveryStoreDirectory: renameRecoveryStoreDirectory(for: meetingsRoot),
                    logFailure: { event, context in
                        if event == "meeting_transcript_rename_failed" {
                            transcriptFailureContext = context
                        }
                    }
                )
                assertionFailure("a failed transcript move should throw")
            } catch let error as MeetingArtifactRenameError {
                assertEqual(
                    error,
                    .transcriptMoveFailed(audioLocation: .atSource, targetTranscriptURL: targetURL),
                    "the failure should report restored audio"
                )
            } catch {
                assertionFailure("unexpected error: \(error)")
            }

            assertTrue(FileManager.default.fileExists(atPath: transcriptURL.path), "the original transcript should remain")
            assertTrue(FileManager.default.fileExists(atPath: audioDirectory.path), "retained audio should be rolled back")
            assertFalse(FileManager.default.fileExists(atPath: targetURL.path), "the target transcript should not exist")
            assertFalse(FileManager.default.fileExists(atPath: targetAudioDirectory.path), "rolled-back audio should not remain at the target")
            assertEqual(transcriptFailureContext["audioLocation"], "atSource", "the failure event should prove audio was restored")
        }
    }

    runSuite("MeetingArtifactRenamer copies audio back when rollback movement fails") {
        withTemporaryHomeMeetingRenameLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Call_2026-06-05_18-39-20.md")
            try writeRenameMeeting(title: "Quick notes", transcriptURL: transcriptURL)
            let audioDirectory = try writeRenameAudio(for: transcriptURL)
            let targetURL = meetingsRoot.appendingPathComponent("2026-06-05 Launch planning.md")
            let targetAudioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: targetURL)

            do {
                _ = try MeetingArtifactRenamer.rename(
                    transcriptAt: transcriptURL,
                    toStem: "2026-06-05 Launch planning",
                    moveItem: { sourceURL, targetURL in
                        if sourceURL == transcriptURL || sourceURL == targetAudioDirectory {
                            throw NSError(domain: "MeetingArtifactRenamerTests", code: 3)
                        }
                        try FileManager.default.moveItem(at: sourceURL, to: targetURL)
                    },
                    recoveryStoreDirectory: renameRecoveryStoreDirectory(for: meetingsRoot)
                )
                assertionFailure("a failed transcript move should throw")
            } catch let error as MeetingArtifactRenameError {
                assertEqual(
                    error,
                    .transcriptMoveFailed(audioLocation: .atSource, targetTranscriptURL: targetURL),
                    "copy recovery should report restored audio"
                )
            } catch {
                assertionFailure("unexpected error: \(error)")
            }

            assertTrue(FileManager.default.fileExists(atPath: transcriptURL.path), "the original transcript should remain")
            assertTrue(FileManager.default.fileExists(atPath: audioDirectory.path), "copy recovery should restore retained audio")
            assertFalse(FileManager.default.fileExists(atPath: targetURL.path), "the target transcript should not exist")
            assertFalse(FileManager.default.fileExists(atPath: targetAudioDirectory.path), "the recovered target audio should be cleaned up")
        }
    }

    runSuite("MeetingArtifactRenamer reports when audio recovery also fails") {
        withTemporaryHomeMeetingRenameLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Call_2026-06-05_18-39-20.md")
            try writeRenameMeeting(title: "Quick notes", transcriptURL: transcriptURL)
            _ = try writeRenameAudio(for: transcriptURL)
            let targetURL = meetingsRoot.appendingPathComponent("2026-06-05 Launch planning.md")
            let targetAudioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: targetURL)
            var loggedEvents: [String] = []

            do {
                _ = try MeetingArtifactRenamer.rename(
                    transcriptAt: transcriptURL,
                    toStem: "2026-06-05 Launch planning",
                    moveItem: { sourceURL, targetURL in
                        if sourceURL == transcriptURL || sourceURL == targetAudioDirectory {
                            throw NSError(domain: "MeetingArtifactRenamerTests", code: 4)
                        }
                        try FileManager.default.moveItem(at: sourceURL, to: targetURL)
                    },
                    copyItem: { _, _ in
                        throw NSError(domain: "MeetingArtifactRenamerTests", code: 5)
                    },
                    recoveryStoreDirectory: renameRecoveryStoreDirectory(for: meetingsRoot),
                    logFailure: { event, _ in loggedEvents.append(event) }
                )
                assertionFailure("an unrecovered transcript move should throw")
            } catch let error as MeetingArtifactRenameError {
                assertEqual(
                    error,
                    .transcriptMoveFailed(audioLocation: .atTarget, targetTranscriptURL: targetURL),
                    "the unrecovered location should be explicit"
                )
            } catch {
                assertionFailure("unexpected error: \(error)")
            }

            assertTrue(FileManager.default.fileExists(atPath: transcriptURL.path), "the original transcript should remain")
            assertTrue(FileManager.default.fileExists(atPath: targetAudioDirectory.path), "unrecovered audio should remain available at its moved path")
            assertTrue(loggedEvents.contains("meeting_audio_directory_rename_recovery_failed"), "the failed recovery should be observable")
        }
    }

    runSuite("MeetingArtifactRenamer completes forward when audio cannot return") {
        withTemporaryHomeMeetingRenameLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Call_2026-06-05_18-39-20.md")
            try writeRenameMeeting(title: "Quick notes", transcriptURL: transcriptURL)
            _ = try writeRenameAudio(for: transcriptURL)
            let targetURL = meetingsRoot.appendingPathComponent("2026-06-05 Launch planning.md")
            let targetAudioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: targetURL)

            do {
                let result = try MeetingArtifactRenamer.rename(
                    transcriptAt: transcriptURL,
                    toStem: "2026-06-05 Launch planning",
                    moveItem: { sourceURL, targetURL in
                        if sourceURL == transcriptURL || sourceURL == targetAudioDirectory {
                            throw NSError(domain: "MeetingArtifactRenamerTests", code: 6)
                        }
                        try FileManager.default.moveItem(at: sourceURL, to: targetURL)
                    },
                    copyItem: { sourceURL, targetURL in
                        if sourceURL == targetAudioDirectory {
                            throw NSError(domain: "MeetingArtifactRenamerTests", code: 7)
                        }
                        try FileManager.default.copyItem(at: sourceURL, to: targetURL)
                    },
                    recoveryStoreDirectory: renameRecoveryStoreDirectory(for: meetingsRoot)
                )
                assertEqual(result, targetURL, "the transcript should complete forward beside stranded audio")
            } catch {
                assertionFailure("forward recovery should succeed: \(error)")
            }

            assertFalse(FileManager.default.fileExists(atPath: transcriptURL.path), "forward recovery should retire the original transcript")
            assertTrue(FileManager.default.fileExists(atPath: targetURL.path), "the recovered transcript should use the target stem")
            assertTrue(FileManager.default.fileExists(atPath: targetAudioDirectory.path), "retained audio should remain beside the recovered transcript")
        }
    }

    runSuite("MeetingArtifactRenamer marks duplicate audio as unsafe to retry") {
        withTemporaryHomeMeetingRenameLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Call_2026-06-05_18-39-20.md")
            try writeRenameMeeting(title: "Quick notes", transcriptURL: transcriptURL)
            let audioDirectory = try writeRenameAudio(for: transcriptURL)
            let targetURL = meetingsRoot.appendingPathComponent("2026-06-05 Launch planning.md")
            let targetAudioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: targetURL)

            do {
                _ = try MeetingArtifactRenamer.rename(
                    transcriptAt: transcriptURL,
                    toStem: "2026-06-05 Launch planning",
                    moveItem: { sourceURL, targetURL in
                        if sourceURL == transcriptURL || sourceURL == targetAudioDirectory {
                            throw NSError(domain: "MeetingArtifactRenamerTests", code: 8)
                        }
                        try FileManager.default.moveItem(at: sourceURL, to: targetURL)
                    },
                    removeItem: { targetURL in
                        if targetURL == targetAudioDirectory {
                            throw NSError(domain: "MeetingArtifactRenamerTests", code: 9)
                        }
                        try FileManager.default.removeItem(at: targetURL)
                    },
                    recoveryStoreDirectory: renameRecoveryStoreDirectory(for: meetingsRoot)
                )
                assertionFailure("duplicate target audio should remain an explicit failure")
            } catch let error as MeetingArtifactRenameError {
                assertEqual(
                    error,
                    .transcriptMoveFailed(audioLocation: .duplicated, targetTranscriptURL: targetURL),
                    "cleanup failure should be distinct from a safe rollback"
                )
            } catch {
                assertionFailure("unexpected error: \(error)")
            }

            assertTrue(FileManager.default.fileExists(atPath: transcriptURL.path), "the original transcript should remain")
            assertTrue(FileManager.default.fileExists(atPath: audioDirectory.path), "the original audio should remain usable")
            assertTrue(FileManager.default.fileExists(atPath: targetAudioDirectory.path), "the duplicate target should remain visible for recovery")
        }
    }

    runSuite("HomeMeetingRename restores the title when artifact movement fails") {
        withTemporaryHomeMeetingRenameLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Call_2026-06-05_18-39-20.md")
            try writeRenameMeeting(title: "Quick notes", transcriptURL: transcriptURL)
            let original = try String(contentsOf: transcriptURL, encoding: .utf8)
            let audioDirectory = try writeRenameAudio(for: transcriptURL)

            do {
                _ = try HomeMeetingRename.rename(
                    transcriptAt: transcriptURL,
                    to: "Launch planning",
                    moveItem: { sourceURL, targetURL in
                        if sourceURL == audioDirectory {
                            throw NSError(domain: "HomeMeetingRenameTests", code: 1)
                        }
                        try FileManager.default.moveItem(at: sourceURL, to: targetURL)
                    },
                    recoveryStoreDirectory: renameRecoveryStoreDirectory(for: meetingsRoot)
                )
                assertionFailure("the Home rename should surface the artifact failure")
            } catch let error as HomeMeetingRenameError {
                assertEqual(error, .artifactRenameFailed, "the caller should receive a user-facing rename failure")
            } catch {
                assertionFailure("unexpected error: \(error)")
            }

            let restored = try String(contentsOf: transcriptURL, encoding: .utf8)
            assertEqual(restored, original, "the original title and heading should be restored")
            assertTrue(FileManager.default.fileExists(atPath: audioDirectory.path), "retained audio should remain at the original path")
        }
    }

    runSuite("HomeMeetingRename blocks blind retry when audio remains at the target") {
        withTemporaryHomeMeetingRenameLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Call_2026-06-05_18-39-20.md")
            try writeRenameMeeting(title: "Quick notes", transcriptURL: transcriptURL)
            let original = try String(contentsOf: transcriptURL, encoding: .utf8)
            _ = try writeRenameAudio(for: transcriptURL)
            let targetURL = meetingsRoot.appendingPathComponent("2026-06-05 Launch planning.md")
            let targetAudioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: targetURL)
            let sourceAudioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: transcriptURL)
            let recoveryStoreDirectory = renameRecoveryStoreDirectory(for: meetingsRoot)
            let expectedNotice = MeetingArtifactRecoveryNotice(
                sourceTranscriptURL: transcriptURL,
                targetTranscriptURL: targetURL
            )

            do {
                _ = try HomeMeetingRename.rename(
                    transcriptAt: transcriptURL,
                    to: "Launch planning",
                    moveItem: { sourceURL, targetURL in
                        if sourceURL == transcriptURL || sourceURL == targetAudioDirectory {
                            throw NSError(domain: "HomeMeetingRenameTests", code: 2)
                        }
                        try FileManager.default.moveItem(at: sourceURL, to: targetURL)
                    },
                    copyItem: { _, _ in
                        throw NSError(domain: "HomeMeetingRenameTests", code: 3)
                    },
                    recoveryStoreDirectory: recoveryStoreDirectory
                )
                assertionFailure("the Home rename should surface the recovery location")
            } catch let error as HomeMeetingRenameError {
                assertEqual(
                    error,
                    .artifactRecoveryRequired(expectedNotice),
                    "the caller should block blind retry and preserve the audio location"
                )
            } catch {
                assertionFailure("unexpected error: \(error)")
            }

            let restored = try String(contentsOf: transcriptURL, encoding: .utf8)
            assertEqual(restored, original, "the title should be restored before asking for recovery")
            assertTrue(FileManager.default.fileExists(atPath: targetAudioDirectory.path), "the recovery location should remain inspectable")

            let persistedNotice = try MeetingArtifactRecoveryStore.pendingNotice(
                for: transcriptURL,
                directory: recoveryStoreDirectory
            )
            assertEqual(persistedNotice, expectedNotice, "the unsafe transaction should survive a relaunch")
            assertEqual(
                try MeetingArtifactRecoveryStore.pendingNotices(directory: recoveryStoreDirectory),
                [expectedNotice],
                "launch scanning should surface the same recovery action"
            )

            var attemptedArtifactMove = false
            do {
                _ = try HomeMeetingRename.rename(
                    transcriptAt: transcriptURL,
                    to: "A different title",
                    moveItem: { sourceURL, targetURL in
                        attemptedArtifactMove = true
                        try FileManager.default.moveItem(at: sourceURL, to: targetURL)
                    },
                    recoveryStoreDirectory: recoveryStoreDirectory
                )
                assertionFailure("a later rename should remain blocked until the artifacts are coherent")
            } catch let error as HomeMeetingRenameError {
                assertEqual(
                    error,
                    .artifactRecoveryRequired(expectedNotice),
                    "a persisted recovery record should block a suffix-producing retry"
                )
            } catch {
                assertionFailure("unexpected retry error: \(error)")
            }
            assertFalse(attemptedArtifactMove, "the durable recovery guard should run before any new artifact move")
            assertEqual(
                try String(contentsOf: transcriptURL, encoding: .utf8),
                original,
                "a blocked retry should restore the original title"
            )

            try FileManager.default.moveItem(at: targetAudioDirectory, to: sourceAudioDirectory)
            assertNil(
                try MeetingArtifactRecoveryStore.pendingNotice(
                    for: transcriptURL,
                    directory: recoveryStoreDirectory
                ),
                "a coherent source pair should automatically clear the journal"
            )
            assertTrue(
                try MeetingArtifactRecoveryStore.pendingNotices(directory: recoveryStoreDirectory).isEmpty,
                "resolved recovery records should not reappear on the next launch"
            )
        }
    }

    runSuite("MeetingArtifactRenameError emits recovery notices only for unsafe locations") {
        let sourceURL = URL(fileURLWithPath: "/tmp/source.md")
        let targetURL = URL(fileURLWithPath: "/tmp/target.md")
        let safeError = MeetingArtifactRenameError.transcriptMoveFailed(
            audioLocation: .atSource,
            targetTranscriptURL: targetURL
        )
        let unsafeError = MeetingArtifactRenameError.transcriptMoveFailed(
            audioLocation: .duplicated,
            targetTranscriptURL: targetURL
        )

        assertNil(
            safeError.recoveryNotice(sourceTranscriptURL: sourceURL),
            "safe rollback should retain the normal retry path"
        )
        assertEqual(
            unsafeError.recoveryNotice(sourceTranscriptURL: sourceURL),
            MeetingArtifactRecoveryNotice(
                sourceTranscriptURL: sourceURL,
                targetTranscriptURL: targetURL
            ),
            "unsafe placement should preserve both transcript locations"
        )
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
                let result = try HomeMeetingRename.rename(
                    transcriptAt: transcriptURL,
                    to: "Launch planning",
                    recoveryStoreDirectory: renameRecoveryStoreDirectory(for: meetingsRoot)
                )
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

    runSuite("HomeMeetingSpeakerRename updates one source-scoped speaker") {
        withTemporaryHomeMeetingRenameLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Scoped Speaker.md")
            let markdown = """
            ---
            capture_type: meeting
            speakers:
              - id: "0"
                channel: mic
                name: "You"
                source: unknown
              - id: "0"
                channel: system
                name: "You"
                source: unknown
            ---

            # Scoped Speaker

            ## Transcript

            **00:00** [Mic/You]
            Local line.

            **00:02** [System/You]
            Remote line.
            """
            try markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
            guard let identity = HomeMeetingPreviewContent.make(from: markdown).transcriptLines.first?.identity else {
                assertionFailure("fixture should expose a speaker identity")
                return
            }

            do {
                _ = try HomeMeetingSpeakerRename.rename(
                    transcriptAt: transcriptURL,
                    identity: identity,
                    to: "  Justin  "
                )
                let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
                assertTrue(updated.contains("[Mic/Justin]"), "the selected mic label should be renamed")
                assertTrue(updated.contains("[System/You]"), "a same-name system speaker should stay untouched")
                assertTrue(updated.contains("name: \"Justin\""), "the matching frontmatter row should be renamed")
                assertTrue(updated.contains("source: user_manual"), "the matching metadata should record the manual edit")
            } catch {
                assertionFailure("speaker rename should not throw: \(error)")
            }
        }
    }

    runSuite("HomeMeetingSpeakerRename preserves legacy Obsidian speaker links") {
        withTemporaryHomeMeetingRenameLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Legacy Speaker.md")
            let markdown = """
            # Legacy Speaker

            ## Full Transcript

            [00:05] [System/[[Alex]]] Nice to meet you.
            """
            try markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
            guard let identity = HomeMeetingPreviewContent.make(from: markdown).transcriptLines.first?.identity else {
                assertionFailure("fixture should expose a legacy speaker identity")
                return
            }

            do {
                _ = try HomeMeetingSpeakerRename.rename(
                    transcriptAt: transcriptURL,
                    identity: identity,
                    to: "Morgan"
                )
                let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
                assertTrue(updated.contains("[System/[[Morgan]]]"), "legacy link syntax should be preserved")
                assertFalse(updated.contains("[[Alex]]"), "the old linked name should be removed")
            } catch {
                assertionFailure("legacy speaker rename should not throw: \(error)")
            }
        }
    }

    runSuite("HomeMeetingSpeakerRename refuses empty names without changing the file") {
        withTemporaryHomeMeetingRenameLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Empty Speaker.md")
            let markdown = "[00:00] [Mic/You] Hello."
            try markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
            guard let identity = HomeMeetingPreviewContent.make(from: markdown).transcriptLines.first?.identity else {
                assertionFailure("fixture should expose a speaker identity")
                return
            }

            do {
                _ = try HomeMeetingSpeakerRename.rename(
                    transcriptAt: transcriptURL,
                    identity: identity,
                    to: "   "
                )
                assertionFailure("empty speaker name should throw")
            } catch let error as HomeMeetingSpeakerRenameError {
                assertEqual(error, .emptyName, "empty names should map to .emptyName")
                let unchanged = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
                assertEqual(unchanged, markdown, "empty rename should leave the transcript untouched")
            } catch {
                assertionFailure("unexpected error: \(error)")
            }
        }
    }

    runSuite("HomeMeetingSpeakerRename batches without cascading names") {
        withTemporaryHomeMeetingRenameLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Speaker Swap.md")
            let markdown = """
            ---
            capture_type: meeting
            speakers:
              - id: "0"
                channel: system
                name: "Alex"
                source: unknown
              - id: "1"
                channel: system
                name: "Jordan"
                source: unknown
            ---

            ## Transcript

            **00:00** [System/Alex]
            First voice.

            **00:02** [System/Jordan]
            Second voice.

            **00:04** [System/Alex]
            First voice again.
            """
            try markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
            let identities = HomeMeetingPreviewContent.make(from: markdown).transcriptLines.map(\.identity)
            guard let alex = identities.first(where: { $0.displayName == "Alex" }),
                  let jordan = identities.first(where: { $0.displayName == "Jordan" }) else {
                assertionFailure("fixture should expose both identities")
                return
            }

            do {
                _ = try HomeMeetingSpeakerRename.renameMany(
                    transcriptAt: transcriptURL,
                    assignments: [
                        HomeMeetingSpeakerAssignment(identity: alex, newName: "Jordan", targetProfileID: nil),
                        HomeMeetingSpeakerAssignment(identity: jordan, newName: "Morgan", targetProfileID: nil),
                    ]
                )
                let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
                assertEqual(
                    updated.components(separatedBy: "[System/Jordan]").count - 1,
                    2,
                    "Alex rows should become Jordan without being renamed a second time"
                )
                assertEqual(
                    updated.components(separatedBy: "[System/Morgan]").count - 1,
                    1,
                    "The original Jordan row alone should become Morgan"
                )
            } catch {
                assertionFailure("batch rename should not throw: \(error)")
            }
        }
    }

    runSuite("HomeMeetingSpeakerRename links an unlinked row to the selected saved person") {
        withTemporaryHomeMeetingRenameLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Link Speaker.md")
            let targetID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
            let markdown = """
            ---
            capture_type: meeting
            speakers:
              - id: "7"
                channel: system
                name: "Speaker 7"
                source: unknown
            ---

            ## Transcript

            **00:00** [System/Speaker 7]
            Hello from the remote speaker.
            """
            try markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
            guard let identity = HomeMeetingPreviewContent.make(from: markdown).transcriptLines.first?.identity else {
                assertionFailure("fixture should expose an unlinked identity")
                return
            }

            do {
                _ = try HomeMeetingSpeakerRename.rename(
                    transcriptAt: transcriptURL,
                    identity: identity,
                    to: "Alex",
                    linkingTo: targetID
                )
                let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
                assertTrue(updated.contains("name: \"Alex\""), "selected name should update metadata")
                assertTrue(updated.contains("db_id: \"\(targetID.uuidString)\""), "selected UUID should be linked")
                assertTrue(updated.contains("source: user_manual"), "manual assignment should record its source")
                assertTrue(updated.contains("[System/Alex]"), "visible transcript rows should update together")
            } catch {
                assertionFailure("link assignment should not throw: \(error)")
            }
        }
    }

    runSuite("HomeMeetingSpeakerRename repairs a stale saved-person link locally") {
        withTemporaryHomeMeetingRenameLibrary { meetingsRoot in
            let transcriptURL = meetingsRoot.appendingPathComponent("Stale Speaker Link.md")
            let staleProfileID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
            let markdown = """
            ---
            capture_type: meeting
            speakers:
              - id: "0"
                channel: system
                db_id: "\(staleProfileID.uuidString)"
                name: "Speaker 1"
                source: db_pending
              - id: "1"
                channel: system
                db_id: "\(staleProfileID.uuidString)"
                name: "Speaker 2"
                source: db_pending
            ---

            ## Transcript

            **00:00** [System/Speaker 1]
            First sample.

            **00:02** [System/Speaker 2]
            Second sample.
            """
            try markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
            let lines = HomeMeetingPreviewContent.make(from: markdown).transcriptLines
            guard let identity = lines.first?.identity else {
                assertionFailure("fixture should expose a stale saved identity")
                return
            }
            let assignment = HomeMeetingSpeakerAssignment(
                identity: identity,
                newName: "Patrick",
                targetProfileID: nil
            )

            guard let plan = HomeMeetingSpeakerNamingPolicy.assignmentPlan(
                for: [assignment],
                transcriptLines: lines,
                availableProfileIDs: []
            ) else {
                assertionFailure("a missing source profile should have a local recovery plan")
                return
            }
            assertTrue(plan.savedAssignments.isEmpty, "a deleted profile must not use the global rename path")
            assertEqual(plan.localAssignments.count, 2, "every row linked to the stale profile should be repaired")
            assertTrue(
                plan.localAssignments.allSatisfy { $0.removesPersistentSpeakerLink },
                "local recovery assignments should explicitly clear the dead profile identity"
            )

            do {
                _ = try HomeMeetingSpeakerRename.renameMany(
                    transcriptAt: transcriptURL,
                    assignments: plan.localAssignments
                )
                let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
                assertFalse(updated.contains(staleProfileID.uuidString), "the dead db_id should be removed")
                assertEqual(
                    updated.components(separatedBy: "name: \"Patrick\"").count - 1,
                    2,
                    "every metadata row for the stale person should receive the corrected name"
                )
                assertTrue(updated.contains("[System/Patrick]"), "visible transcript labels should be corrected")
            } catch {
                assertionFailure("stale speaker recovery should not throw: \(error)")
            }
        }
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

private func renameRecoveryStoreDirectory(for meetingsRoot: URL) -> URL {
    meetingsRoot
        .deletingLastPathComponent()
        .appendingPathComponent("meeting-artifact-recovery", isDirectory: true)
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

/// Mirrors `MeetingArtifactRenamer.legacySummarySidecarURL` (the legacy
/// `<stem>.summary.md` sidecar the now-removed local AI summarizer wrote).
private func legacyRenameSummarySidecarURL(for transcriptURL: URL) -> URL {
    let base = transcriptURL.deletingPathExtension()
    return base
        .deletingLastPathComponent()
        .appendingPathComponent("\(base.lastPathComponent).summary")
        .appendingPathExtension("md")
}

private func writeRenameSummary(_ url: URL, sourceTranscript: String) throws {
    let markdown = """
    ---
    capture_type: meeting_summary
    source_transcript: "\(sourceTranscript)"
    summary_title: "Generated Summary"
    ---

    # Summary
    Synthetic summary.
    """
    try markdown.write(to: url, atomically: true, encoding: .utf8)
}
