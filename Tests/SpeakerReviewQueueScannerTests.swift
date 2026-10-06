import Foundation

func testSpeakerReviewQueueScanner() {
    runSuite("SpeakerReviewQueueScanner recovers system-only samples without changing profile clips") {
        withRetainedReviewAudio(stems: ["recording.m4a"]) { transcriptURL, audioURLs in
            let speakerId = UUID()
            let markdown = deferredMarkdown(
                speakerId: speakerId,
                title: "Failed naming import",
                speakerName: "Speaker 1",
                sampleText: "A recoverable voice."
            ) + "\n\n**00:05** [System/Someone else]\nThe next voice.\n"
            try? markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
            let profiles = [makeReviewQueueProfile(id: speakerId, name: nil)]
            let items = SpeakerReviewQueueScanner.loadPendingItems(
                transcriptsDirectory: transcriptURL.deletingLastPathComponent(),
                profiles: profiles,
                clipURLsByProfileID: [:]
            )
            assertRetainedSample(items.first?.retainedAudioSample, SpeakerRetainedAudioSample(
                url: audioURLs[0], startTime: 1, duration: 4
            ), "a failed system-only review should play its own turn from compressed retained audio")
            assertEqual(items.first?.sampleText, "A recoverable voice.")
            assertEqual(items.first?.clipURL, nil, "fallback must not masquerade as a confirmed profile clip")
            assertEqual(try? String(contentsOf: transcriptURL, encoding: .utf8), markdown)
            assertEqual(try? Data(contentsOf: audioURLs[0]), Data([1]), "scanning must leave retained audio unchanged")

            let existingClip = transcriptURL.deletingLastPathComponent().appendingPathComponent("\(speakerId.uuidString).wav")
            try? Data([7, 8, 9]).write(to: existingClip)
            let withClip = SpeakerReviewQueueScanner.pendingItems(
                in: markdown, transcriptURL: transcriptURL,
                profilesById: [speakerId: profiles[0]], clipURLsByProfileID: [speakerId: existingClip]
            )
            assertEqual(withClip.first?.clipURL, existingClip)
            assertEqual(withClip.first?.retainedAudioSample, nil, "a saved profile clip remains preferred")
            assertEqual(try? Data(contentsOf: existingClip), Data([7, 8, 9]), "recovery must never overwrite another voice's clip")
        }
    }

    runSuite("SpeakerReviewQueueScanner resolves styled samples and clips the last turn to duration") {
        withRetainedReviewAudio(stems: ["recording.wav"]) { transcriptURL, audioURLs in
            let speakerId = UUID()
            let markdown = deferredMarkdown(
                speakerId: speakerId, title: "Styled import", speakerName: "Speaker 1", sampleText: "Late voice."
            )
                .replacingOccurrences(of: "capture_type: meeting", with: "capture_type: meeting\nduration: \"01:34:00\"")
                .replacingOccurrences(of: "**00:01** [System/Speaker 1]", with: "**01:33:58** [Speaker 1]")
            let items = SpeakerReviewQueueScanner.pendingItems(
                in: markdown, transcriptURL: transcriptURL,
                profilesById: [speakerId: makeReviewQueueProfile(id: speakerId, name: nil)], clipURLsByProfileID: [:]
            )
            assertRetainedSample(items.first?.retainedAudioSample, SpeakerRetainedAudioSample(
                url: audioURLs[0], startTime: 5_638, duration: 2
            ), "styled 94-minute imports should resolve the exact voice and stop at the saved meeting end")
            assertEqual(items.first?.sampleText, "Late voice.")
        }
    }

    runSuite("SpeakerReviewQueueScanner keeps mic and system voices on their own retained channels") {
        withRetainedReviewAudio(stems: ["system_audio.wav", "microphone.m4a"]) { transcriptURL, audioURLs in
            let systemId = UUID()
            let micId = UUID()
            let markdown = """
            ---
            capture_type: meeting
            duration: "00:20"
            speakers:
              - id: "1"
                channel: system
                db_id: "\(systemId.uuidString)"
                name: "Speaker 1"
                source: db_pending
              - id: "1"
                channel: mic
                db_id: "\(micId.uuidString)"
                name: "Speaker 1"
                source: db_pending
            ---
            ## Full Transcript
            [00:01] [System/Speaker 1] Remote voice.
            [00:02] [Mic/Speaker 1] Local voice.
            [00:06] [System/Someone else] Another remote voice.
            """
            let items = SpeakerReviewQueueScanner.pendingItems(
                in: markdown, transcriptURL: transcriptURL,
                profilesById: [systemId: makeReviewQueueProfile(id: systemId, name: nil), micId: makeReviewQueueProfile(id: micId, name: nil)],
                clipURLsByProfileID: [:]
            )
            assertRetainedSample(items.first(where: { $0.channel == .system })?.retainedAudioSample, SpeakerRetainedAudioSample(
                url: audioURLs[0], startTime: 1, duration: 5
            ), "system playback should stop before the next system turn, not an overlapping mic turn")
            assertRetainedSample(items.first(where: { $0.channel == .mic })?.retainedAudioSample, SpeakerRetainedAudioSample(
                url: audioURLs[1], startTime: 2, duration: 8
            ), "mic playback should use the mic file and stay capped at eight seconds")
            try? FileManager.default.removeItem(at: audioURLs[1])
            let missingMic = SpeakerReviewQueueScanner.pendingItems(
                in: markdown, transcriptURL: transcriptURL,
                profilesById: [micId: makeReviewQueueProfile(id: micId, name: nil)], clipURLsByProfileID: [:]
            )
            assertEqual(missingMic.first?.retainedAudioSample, nil, "missing mic audio must not play the remote track instead")
        }
    }

    runSuite("SpeakerReviewQueueScanner refuses missing audio and ambiguous timestamps") {
        withRetainedReviewAudio(stems: ["recording.wav"]) { transcriptURL, audioURLs in
            let speakerId = UUID()
            let markdown = deferredMarkdown(
                speakerId: speakerId, title: "Broken timing", speakerName: "Speaker 1", sampleText: "A voice."
            )
            for marker in ["**00:99**", "**-1:01**", "**99999999999999999999:01**"] {
                let items = SpeakerReviewQueueScanner.pendingItems(
                    in: markdown.replacingOccurrences(of: "**00:01**", with: marker), transcriptURL: transcriptURL,
                    profilesById: [speakerId: makeReviewQueueProfile(id: speakerId, name: nil)], clipURLsByProfileID: [:]
                )
                assertEqual(items.first?.retainedAudioSample, nil, "malformed timing should stay unavailable")
            }
            let overlapping = SpeakerReviewQueueScanner.pendingItems(
                in: markdown + "\n**00:01** [System/Other voice]\nOverlapping speaker.\n", transcriptURL: transcriptURL,
                profilesById: [speakerId: makeReviewQueueProfile(id: speakerId, name: nil)], clipURLsByProfileID: [:]
            )
            assertEqual(overlapping.first?.retainedAudioSample, nil, "same-time voices have no isolated sample range")
            try? FileManager.default.removeItem(at: audioURLs[0])
            let missing = SpeakerReviewQueueScanner.pendingItems(
                in: markdown, transcriptURL: transcriptURL,
                profilesById: [speakerId: makeReviewQueueProfile(id: speakerId, name: nil)], clipURLsByProfileID: [:]
            )
            assertEqual(missing.first?.retainedAudioSample, nil, "retention-pruned audio should remain unavailable")
        }
    }

    runSuite("SpeakerReviewQueueScanner extracts deferred speakers with call context") {
        let speakerId = UUID()
        let transcriptId = UUID()
        let clipURL = URL(fileURLWithPath: "/tmp/\(speakerId.uuidString).wav")
        let transcriptURL = URL(fileURLWithPath: "/tmp/Customer_Sync.md")

        let markdown = deferredMarkdown(
            speakerId: speakerId,
            title: "Customer Sync",
            transcriptId: transcriptId,
            date: "2026-05-20",
            time: "09:30:00",
            speakerName: "Speaker 1",
            sampleText: "We should finish the pricing memo."
        )

        let items = SpeakerReviewQueueScanner.pendingItems(
            in: markdown,
            transcriptURL: transcriptURL,
            profilesById: [
                speakerId: makeReviewQueueProfile(id: speakerId, name: nil, calls: 3)
            ],
            clipURLsByProfileID: [speakerId: clipURL]
        )

        assertEqual(items.count, 1, "one db_pending speaker should become one review queue item")
        assertEqual(items.first?.meetingTitle, "Customer Sync", "queue item should keep the meeting title")
        assertEqual(items.first?.transcriptId, transcriptId, "queue item should keep the stable transcript identity")
        assertEqual(items.first?.sampleText, "We should finish the pricing memo.", "queue item should include a useful sample line")
        assertEqual(items.first?.clipURL, clipURL, "queue item should carry the persisted speaker clip")
        assertEqual(items.first?.callCount, 3, "queue item should keep the profile's call count")
        assertEqual(items.first?.speakerLabel, "System/Speaker 1", "queue item should identify the original speaker label")
        assertTrue(items.first?.recordedAt != nil, "queue item should parse the meeting date and time")
    }

    runSuite("SpeakerReviewQueueScanner hides pending metadata once the profile is named") {
        let speakerId = UUID()
        let markdown = deferredMarkdown(
            speakerId: speakerId,
            title: "Already Named",
            speakerName: "Speaker 2",
            sampleText: "This should no longer appear."
        )

        let items = SpeakerReviewQueueScanner.pendingItems(
            in: markdown,
            transcriptURL: URL(fileURLWithPath: "/tmp/Already_Named.md"),
            profilesById: [
                speakerId: makeReviewQueueProfile(id: speakerId, name: "Maya")
            ],
            clipURLsByProfileID: [:]
        )

        assertEqual(items.count, 0, "named profiles should not keep stale db_pending rows in the queue")
    }

    runSuite("SpeakerReviewQueueScanner deduplicates repeated deferred speaker metadata") {
        let speakerId = UUID()
        let transcriptURL = URL(fileURLWithPath: "/tmp/Duplicate_Review.md")
        let markdown = """
        ---
        title: "Duplicate Review"
        date: 2026-05-20
        time: 09:30:00
        speakers:
          - id: "1"
            channel: system
            db_id: "\(speakerId.uuidString)"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
          - id: "1"
            channel: system
            db_id: "\(speakerId.uuidString)"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
        ---

        # Duplicate Review

        ## Transcript

        **00:01** [System/Speaker 1]
        This duplicated metadata should produce one row.
        """

        let items = SpeakerReviewQueueScanner.pendingItems(
            in: markdown,
            transcriptURL: transcriptURL,
            profilesById: [
                speakerId: makeReviewQueueProfile(id: speakerId, name: nil)
            ],
            clipURLsByProfileID: [:]
        )

        assertEqual(items.count, 1, "duplicate frontmatter for the same pending speaker should not create duplicate review rows")
        assertEqual(items.first?.sampleText, "This duplicated metadata should produce one row.", "deduplicated rows should keep the transcript sample")
    }

    runSuite("SpeakerReviewQueueScanner clears Home review status after deferred speaker naming") {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("SpeakerReviewQueueScannerTests-\(UUID().uuidString)", isDirectory: true)
        let transcriptURL = directory.appendingPathComponent("Reviewed_Call.md")
        let speakerId = UUID()
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }

        try? deferredMarkdown(
            speakerId: speakerId,
            title: "Reviewed Call",
            speakerName: "Speaker 1",
            sampleText: "This row should be renamed."
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)

        let before = SpeakerReviewQueueScanner.loadPendingItems(
            transcriptsDirectory: directory,
            profiles: [makeReviewQueueProfile(id: speakerId, name: nil)],
            clipURLsByProfileID: [:]
        )
        assertEqual(before.count, 1, "fixture should start with one pending speaker-review row")
        let homeBefore = RecentMeetingsScanner.loadRecent(limit: 5, directory: directory)
        assertEqual(homeBefore.count, 1, "pending speaker review should still surface one canonical Home row")
        assertEqual(homeBefore.first?.speakerStatus, .needsReview(1), "pending speaker review should mark the canonical row")

        let completedMarkdown = """
        ---
        title: "Reviewed Call"
        capture_type: meeting
        date: 2026-05-20
        time: 09:30:00
        speakers:
          - id: "1"
            channel: system
            db_id: "\(speakerId.uuidString)"
            name: "Maya"
            confidence: confirmed
            source: user_manual
        ---

        # Reviewed Call

        ## Transcript

        **00:01** [System/Maya]
        This row should be renamed.
        """
        try? completedMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
        let updatedMarkdown = (try? String(contentsOf: transcriptURL, encoding: .utf8)) ?? ""
        let after = SpeakerReviewQueueScanner.loadPendingItems(
            transcriptsDirectory: directory,
            profiles: [makeReviewQueueProfile(id: speakerId, name: "Maya")],
            clipURLsByProfileID: [:]
        )

        assertEqual(after.count, 0, "completed speaker review should leave no pending queue item")
        let homeAfter = RecentMeetingsScanner.loadRecent(limit: 5, directory: directory)
        assertEqual(homeAfter.count, 1, "completed speaker review should not create duplicate Home rows")
        assertEqual(homeAfter.first?.transcriptURL.standardizedFileURL, transcriptURL.standardizedFileURL, "completed speaker review should keep the original transcript row")
        assertEqual(
            RecentMeetingSpeakerStatus.detect(in: updatedMarkdown),
            .ready,
            "Home row speaker status should be ready after the saved label is named"
        )
    }

    runSuite("SpeakerReviewQueueScanner rereads a skipped transcript once it changes") {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("SpeakerReviewQueueScannerTests-\(UUID().uuidString)", isDirectory: true)
        let transcriptURL = directory.appendingPathComponent("Named_Then_Pending.md")
        let speakerId = UUID()
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }

        let namedMarkdown = """
        ---
        title: "Named Call"
        capture_type: meeting
        speakers:
          - id: "1"
            channel: system
            db_id: "\(speakerId.uuidString)"
            name: "Maya"
            confidence: confirmed
            source: user_manual
        ---

        # Named Call
        """
        try? namedMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
        assertFalse(
            SpeakerReviewQueueScanner.hasPendingSpeakers(in: namedMarkdown),
            "a transcript with only named speakers has nothing to review"
        )
        let profiles = [makeReviewQueueProfile(id: speakerId, name: nil)]
        let first = SpeakerReviewQueueScanner.loadPendingItems(
            transcriptsDirectory: directory,
            profiles: profiles,
            clipURLsByProfileID: [:]
        )
        assertEqual(first.count, 0, "no pending speakers means no review rows")

        let pendingMarkdown = deferredMarkdown(
            speakerId: speakerId,
            title: "Named Call",
            speakerName: "Speaker 1",
            sampleText: "Now this voice needs a name, and the file grew."
        )
        assertTrue(
            SpeakerReviewQueueScanner.hasPendingSpeakers(in: pendingMarkdown),
            "a db_pending speaker counts as pending"
        )
        try? pendingMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
        let second = SpeakerReviewQueueScanner.loadPendingItems(
            transcriptsDirectory: directory,
            profiles: profiles,
            clipURLsByProfileID: [:]
        )
        assertEqual(second.count, 1, "a rewritten transcript must be read again, not skipped from the cache")
    }

    runSuite("SpeakerReviewQueueScanner shows a voice named in the database on the next scan of an untouched transcript") {
        withUntouchedPendingTranscript(sampleText: "Name me without editing the file.") { directory, speakerId, _ in
            let unnamed = [makeReviewQueueProfile(id: speakerId, name: nil)]
            let first = SpeakerReviewQueueScanner.loadPendingItems(
                transcriptsDirectory: directory, profiles: unnamed, clipURLsByProfileID: [:]
            )
            assertEqual(first.count, 1, "an unnamed pending voice starts in the queue")

            let named = SpeakerReviewQueueScanner.loadPendingItems(
                transcriptsDirectory: directory,
                profiles: [makeReviewQueueProfile(id: speakerId, name: "Maya")],
                clipURLsByProfileID: [:]
            )
            assertEqual(named.count, 0, "naming the voice in the database must clear it even though the transcript did not change")

            let unnamedAgain = SpeakerReviewQueueScanner.loadPendingItems(
                transcriptsDirectory: directory, profiles: unnamed, clipURLsByProfileID: [:]
            )
            assertEqual(unnamedAgain.count, 1, "an unnamed profile brings the row back from the same untouched transcript")
        }
    }

    runSuite("SpeakerReviewQueueScanner drops a deleted voice on the next scan of an untouched transcript") {
        withUntouchedPendingTranscript(sampleText: "Delete this voice.") { directory, speakerId, _ in
            let first = SpeakerReviewQueueScanner.loadPendingItems(
                transcriptsDirectory: directory,
                profiles: [makeReviewQueueProfile(id: speakerId, name: nil)],
                clipURLsByProfileID: [:]
            )
            assertEqual(first.count, 1, "the pending voice starts in the queue")

            let afterDelete = SpeakerReviewQueueScanner.loadPendingItems(
                transcriptsDirectory: directory, profiles: [], clipURLsByProfileID: [:]
            )
            assertEqual(afterDelete.count, 0, "a deleted profile must leave the queue even though the transcript did not change")
        }
    }

    runSuite("SpeakerReviewQueueScanner applies profile clips fresh on every scan of an untouched transcript") {
        withUntouchedPendingTranscript(sampleText: "Clips come and go.") { directory, speakerId, _ in
            let profiles = [makeReviewQueueProfile(id: speakerId, name: nil)]
            // Keep the clip outside the scanned folder so it can't count as a transcript.
            let clipURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("SpeakerReviewQueueClip-\(UUID().uuidString).wav")
            try? Data([4, 5, 6]).write(to: clipURL)
            defer { try? FileManager.default.removeItem(at: clipURL) }

            let withClip = SpeakerReviewQueueScanner.loadPendingItems(
                transcriptsDirectory: directory, profiles: profiles, clipURLsByProfileID: [speakerId: clipURL]
            )
            assertEqual(withClip.count, 1)
            assertEqual(withClip.first?.clipURL, clipURL, "the first scan carries the profile's clip")

            let withoutClip = SpeakerReviewQueueScanner.loadPendingItems(
                transcriptsDirectory: directory, profiles: profiles, clipURLsByProfileID: [:]
            )
            assertEqual(withoutClip.count, 1)
            assertEqual(withoutClip.first?.clipURL, nil, "a clip removed since the last scan must not stick to the row")
            assertEqual(withoutClip.first?.sampleText, "Clips come and go.", "the row keeps its transcript sample without a clip")
            assertEqual(withoutClip.first?.retainedAudioSample, nil, "no retained audio exists in this fixture")

            // And back again, still without touching the transcript.
            let clipAgain = SpeakerReviewQueueScanner.loadPendingItems(
                transcriptsDirectory: directory, profiles: profiles, clipURLsByProfileID: [speakerId: clipURL]
            )
            assertEqual(clipAgain.first?.clipURL, clipURL, "a clip added since the last scan shows up on the row")
            assertEqual(clipAgain.first?.sampleText, "Clips come and go.")
            let clipGoneAgain = SpeakerReviewQueueScanner.loadPendingItems(
                transcriptsDirectory: directory, profiles: profiles, clipURLsByProfileID: [:]
            )
            assertEqual(clipGoneAgain.first?.clipURL, nil, "the clip drops off again once it's gone")
            assertEqual(clipGoneAgain.first?.sampleText, "Clips come and go.")
        }
    }

    runSuite("SpeakerReviewQueueScanner returns the same visible row on repeated scans of an untouched transcript") {
        withUntouchedPendingTranscript(sampleText: "Same row twice.") { directory, speakerId, transcriptId in
            let profiles = [makeReviewQueueProfile(id: speakerId, name: nil)]
            let first = SpeakerReviewQueueScanner.loadPendingItems(
                transcriptsDirectory: directory, profiles: profiles, clipURLsByProfileID: [:]
            )
            let second = SpeakerReviewQueueScanner.loadPendingItems(
                transcriptsDirectory: directory, profiles: profiles, clipURLsByProfileID: [:]
            )
            assertEqual(first.count, 1)
            assertEqual(second.count, 1)
            // Pin the first scan to the fixture so "equal" can't mean "both empty".
            assertEqual(first.first?.meetingTitle, "Untouched Call")
            assertEqual(first.first?.transcriptId, transcriptId)
            assertEqual(first.first?.sampleText, "Same row twice.")
            assertEqual(first.first?.meetingDurationSeconds, 42 * 60 + 10)
            assertTrue(first.first?.recordedAt != nil, "fixture date and time should parse")

            assertEqual(second.first?.meetingTitle, first.first?.meetingTitle, "title stays the same across scans")
            assertEqual(second.first?.recordedAt, first.first?.recordedAt, "recorded time stays the same across scans")
            assertEqual(second.first?.transcriptId, first.first?.transcriptId, "transcript identity stays the same across scans")
            assertEqual(second.first?.sampleText, first.first?.sampleText, "sample line stays the same across scans")
            assertEqual(second.first?.sourceName, first.first?.sourceName, "speaker label stays the same across scans")
            assertEqual(second.first?.meetingDurationSeconds, first.first?.meetingDurationSeconds, "duration stays the same across scans")
            assertEqual(second.first?.isImported, first.first?.isImported, "import flag stays the same across scans")
        }
    }

    runSuite("SpeakerReviewQueueScanner no-pending cache matches only the same file version") {
        let cache = SpeakerReviewQueueScanner.NoPendingSpeakersCache()
        let url = URL(fileURLWithPath: "/tmp/Cache_Probe.md")
        let date = Date(timeIntervalSinceReferenceDate: 100)
        let fingerprint = SpeakerReviewQueueScanner.NoPendingSpeakersCache.Fingerprint(modifiedAt: date, size: 10)
        assertFalse(cache.contains(url, fingerprint: fingerprint), "an empty cache skips nothing")
        cache.insert(url, fingerprint: fingerprint)
        assertTrue(cache.contains(url, fingerprint: fingerprint), "the same version is skipped")
        assertFalse(
            cache.contains(url, fingerprint: .init(modifiedAt: date, size: 11)),
            "a size change means the file must be read again"
        )
        assertFalse(
            cache.contains(url, fingerprint: .init(modifiedAt: date.addingTimeInterval(1), size: 10)),
            "a new modification date means the file must be read again"
        )
        let undated = SpeakerReviewQueueScanner.NoPendingSpeakersCache.Fingerprint(modifiedAt: nil, size: 10)
        cache.insert(url, fingerprint: undated)
        assertFalse(cache.contains(url, fingerprint: undated), "without a modification date nothing is cached")
    }

    runSuite("SpeakerReviewQueueScanner treats missing channel as legacy system audio") {
        let speakerId = UUID()
        let transcriptURL = URL(fileURLWithPath: "/tmp/Legacy_Deferred.md")
        let markdown = """
        ---
        title: "Legacy Deferred"
        date: 2026-05-20
        time: 09:30:00
        speakers:
          - id: "1"
            db_id: "\(speakerId.uuidString)"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
        ---

        # Legacy Deferred

        ## Transcript

        **00:01** [System/Speaker 1]
        This old transcript should still be nameable.
        """

        let items = SpeakerReviewQueueScanner.pendingItems(
            in: markdown,
            transcriptURL: transcriptURL,
            profilesById: [
                speakerId: makeReviewQueueProfile(id: speakerId, name: nil)
            ],
            clipURLsByProfileID: [:]
        )

        assertEqual(items.count, 1, "legacy db_pending speakers without channel metadata should stay in the queue")
        assertEqual(items.first?.channel, .system, "missing channel metadata should default to legacy system audio")
        assertEqual(items.first?.sampleText, "This old transcript should still be nameable.", "legacy system rows should still find a sample")
    }

    runSuite("SpeakerReviewQueueScanner sorts newest calls first") {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("SpeakerReviewQueueScannerTests-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }

        let olderId = UUID()
        let newerId = UUID()
        let olderURL = directory.appendingPathComponent("Older.md")
        let newerURL = directory.appendingPathComponent("Newer.md")
        try? deferredMarkdown(
            speakerId: olderId,
            title: "Older Call",
            date: "2026-05-19",
            time: "16:00:00",
            speakerName: "Speaker 1",
            sampleText: "Older sample."
        ).write(to: olderURL, atomically: true, encoding: .utf8)
        try? deferredMarkdown(
            speakerId: newerId,
            title: "Newer Call",
            date: "2026-05-20",
            time: "08:00:00",
            speakerName: "Speaker 2",
            sampleText: "Newer sample."
        ).write(to: newerURL, atomically: true, encoding: .utf8)

        let items = SpeakerReviewQueueScanner.loadPendingItems(
            transcriptsDirectory: directory,
            profiles: [
                makeReviewQueueProfile(id: olderId, name: nil),
                makeReviewQueueProfile(id: newerId, name: nil)
            ],
            clipURLsByProfileID: [:]
        )

        assertEqual(items.map(\.meetingTitle), ["Newer Call", "Older Call"], "newer deferred speaker work should appear first")
    }

    runSuite("SpeakerReviewQueueScanner groups the pending queue into one row per voice") {
        let repeatedId = UUID()
        let otherId = UUID()
        let firstURL = URL(fileURLWithPath: "/tmp/Newest_Call.md")
        let secondURL = URL(fileURLWithPath: "/tmp/Older_Call.md")

        let newestRepeated = SpeakerReviewQueueScanner.pendingItems(
            in: deferredMarkdown(
                speakerId: repeatedId,
                title: "Newest Call",
                date: "2026-05-21",
                speakerName: "Speaker 1",
                sampleText: "Newest sample line."
            ),
            transcriptURL: firstURL,
            profilesById: [repeatedId: makeReviewQueueProfile(id: repeatedId, name: nil, calls: 2)],
            clipURLsByProfileID: [:]
        )
        let olderRepeated = SpeakerReviewQueueScanner.pendingItems(
            in: deferredMarkdown(
                speakerId: repeatedId,
                title: "Older Call",
                date: "2026-05-19",
                speakerName: "Speaker 1",
                sampleText: "Older sample line."
            ),
            transcriptURL: secondURL,
            profilesById: [repeatedId: makeReviewQueueProfile(id: repeatedId, name: nil, calls: 2)],
            clipURLsByProfileID: [:]
        )
        let other = SpeakerReviewQueueScanner.pendingItems(
            in: deferredMarkdown(
                speakerId: otherId,
                title: "Other Call",
                date: "2026-05-20",
                speakerName: "Speaker 2",
                sampleText: "Other voice sample."
            ),
            transcriptURL: URL(fileURLWithPath: "/tmp/Other_Call.md"),
            profilesById: [otherId: makeReviewQueueProfile(id: otherId, name: nil)],
            clipURLsByProfileID: [:]
        )

        let groups = SpeakerReviewQueueScanner.groupedByVoice(newestRepeated + olderRepeated + other)

        assertEqual(groups.count, 2, "two distinct voices should collapse into two groups")
        assertEqual(groups.first?.representative.speakerId, repeatedId, "groups should keep queue order, newest voice first")
        assertEqual(groups.first?.meetingCount, 2, "a voice heard in two saved meetings should count both")
        assertEqual(groups.first?.representative.meetingTitle, "Newest Call", "the representative should be the newest appearance")
        assertEqual(groups.last?.meetingCount, 1, "a voice heard once should count one meeting")
    }

    runSuite("SpeakerReviewQueueScanner groups voices under the call they were last heard in") {
        let repeatedId = UUID()
        let otherId = UUID()
        let newestURL = URL(fileURLWithPath: "/tmp/Design_sync.md")
        let olderURL = URL(fileURLWithPath: "/tmp/Standup.md")
        let designSyncId = UUID()
        let newest = SpeakerReviewQueueScanner.pendingItems(
            in: deferredMarkdown(speakerId: repeatedId, title: "Design sync", transcriptId: designSyncId, date: "2026-05-21", speakerName: "Speaker 1", sampleText: "Newest line.")
                .replacingOccurrences(of: "capture_type: meeting", with: "capture_type: meeting\nduration: \"42:10\""),
            transcriptURL: newestURL,
            profilesById: [repeatedId: makeReviewQueueProfile(id: repeatedId, name: nil, calls: 2)],
            clipURLsByProfileID: [:]
        )
        let older = SpeakerReviewQueueScanner.pendingItems(
            in: deferredMarkdown(speakerId: repeatedId, title: "Standup", date: "2026-05-19", speakerName: "Speaker 1", sampleText: "Older line."),
            transcriptURL: olderURL,
            profilesById: [repeatedId: makeReviewQueueProfile(id: repeatedId, name: nil, calls: 2)],
            clipURLsByProfileID: [:]
        )
        let otherInNewest = SpeakerReviewQueueScanner.pendingItems(
            in: deferredMarkdown(speakerId: otherId, title: "Design sync", transcriptId: designSyncId, date: "2026-05-21", speakerName: "Speaker 2", sampleText: "Second voice."),
            transcriptURL: newestURL,
            profilesById: [otherId: makeReviewQueueProfile(id: otherId, name: nil)],
            clipURLsByProfileID: [:]
        )

        let voices = SpeakerReviewQueueScanner.groupedByVoice(newest + otherInNewest + older)
        let calls = SpeakerReviewQueueScanner.groupedByMeeting(voices)

        assertEqual(calls.count, 1, "a voice heard in two calls shows once, under its newest call")
        assertEqual(calls.first?.meetingTitle, "Design sync")
        assertEqual(calls.first?.voices.map(\.id), [repeatedId, otherId], "both voices from that call, in queue order")
        assertEqual(calls.first?.durationSeconds, 42 * 60 + 10, "the card knows how long the call was")
        assertFalse(calls.first?.isImported ?? true, "a recorded call can look up its invitees")
    }

    runSuite("SpeakerReviewSkippedCalls remembers a skipped call") {
        let suite = "speaker-review-skip-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = UUID()
        let key = SpeakerReviewSkippedCalls.key(transcriptId: id, transcriptURL: URL(fileURLWithPath: "/tmp/Call.md"))
        assertEqual(key, id.uuidString, "a call is keyed by its transcript id so a rename keeps the skip")
        assertEqual(
            SpeakerReviewSkippedCalls.key(transcriptId: nil, transcriptURL: URL(fileURLWithPath: "/tmp/Call.md")),
            "/tmp/Call.md",
            "an old transcript without an id falls back to its path"
        )
        assertTrue(SpeakerReviewSkippedCalls.load(defaults: defaults).isEmpty)
        SpeakerReviewSkippedCalls.add(key, defaults: defaults)
        SpeakerReviewSkippedCalls.add(key, defaults: defaults)
        assertEqual(SpeakerReviewSkippedCalls.load(defaults: defaults), [key], "skipping twice stores it once, and it survives a reload")
    }

    runSuite("SpeakerReviewQueueScanner voice groups fall back to any usable sample text") {
        let speakerId = UUID()
        let noSample = SpeakerReviewQueueScanner.pendingItems(
            in: deferredMarkdownWithoutSample(speakerId: speakerId, title: "Silent Call", speakerName: "Speaker 1"),
            transcriptURL: URL(fileURLWithPath: "/tmp/Silent_Call.md"),
            profilesById: [speakerId: makeReviewQueueProfile(id: speakerId, name: nil)],
            clipURLsByProfileID: [:]
        )
        let withSample = SpeakerReviewQueueScanner.pendingItems(
            in: deferredMarkdown(
                speakerId: speakerId,
                title: "Chatty Call",
                date: "2026-05-18",
                speakerName: "Speaker 1",
                sampleText: "A usable quote."
            ),
            transcriptURL: URL(fileURLWithPath: "/tmp/Chatty_Call.md"),
            profilesById: [speakerId: makeReviewQueueProfile(id: speakerId, name: nil)],
            clipURLsByProfileID: [:]
        )

        let groups = SpeakerReviewQueueScanner.groupedByVoice(noSample + withSample)

        assertEqual(groups.count, 1, "the same voice across meetings should make one group")
        assertEqual(groups.first?.sampleText, "A usable quote.", "the group should borrow a sample from an older meeting when the newest has none")
    }

    runSuite("SpeakerReviewQueueScanner tolerates UTF-8 split at preview limit") {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("SpeakerReviewQueueScannerTests-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }

        let speakerId = UUID()
        let transcriptURL = directory.appendingPathComponent("SplitPreview.md")
        let prefix = deferredMarkdown(
            speakerId: speakerId,
            title: "Split Preview",
            speakerName: "Speaker 3",
            sampleText: "This should survive a split preview."
        )
        let previewLimit = 256 * 1024
        let fillerByteCount = previewLimit - prefix.utf8.count - 1
        assertTrue(fillerByteCount > 0, "fixture should leave room to split a multi-byte character")
        let multibyteCharacter = String(UnicodeScalar(0x1F4AC)!)
        let content = prefix + String(repeating: "a", count: max(0, fillerByteCount)) + multibyteCharacter
        try? content.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let items = SpeakerReviewQueueScanner.loadPendingItems(
            transcriptsDirectory: directory,
            profiles: [
                makeReviewQueueProfile(id: speakerId, name: nil)
            ],
            clipURLsByProfileID: [:]
        )

        assertEqual(items.count, 1, "split UTF-8 at the preview limit should not make the scanner skip the transcript")
        assertEqual(items.first?.meetingTitle, "Split Preview", "scanner should still parse frontmatter from the preview")
    }
}

private func assertRetainedSample(
    _ actual: SpeakerRetainedAudioSample?,
    _ expected: SpeakerRetainedAudioSample,
    _ message: String,
    file: String = #file,
    line: Int = #line
) {
    // Directory enumeration and constructed URLs can spell /private/var
    // differently on macOS. Compare both through the same normalization.
    assertEqual(actual?.url.resolvingSymlinksInPath(), expected.url.resolvingSymlinksInPath(), message, file: file, line: line)
    assertEqual(actual?.startTime, expected.startTime, message, file: file, line: line)
    assertEqual(actual?.duration, expected.duration, message, file: file, line: line)
}

private func withRetainedReviewAudio(stems: [String], _ body: (URL, [URL]) -> Void) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SpeakerReviewAudio-\(UUID().uuidString)")
    let transcriptURL = directory.appendingPathComponent("Meeting.md")
    let audioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: transcriptURL)
    defer { try? FileManager.default.removeItem(at: directory) }
    do {
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let urls = stems.map { audioDirectory.appendingPathComponent($0) }
        // Scanner fixtures prove range/source resolution only. Playback tests
        // use a real, silent WAV and exercise AVPlayer separately.
        for url in urls { try Data([1]).write(to: url) }
        body(transcriptURL, urls)
    } catch {
        assertTrue(false, "could not create retained-audio fixture: \(error)")
    }
}

/// Writes one pending-speaker transcript into a fresh folder, then hands the
/// folder, the speaker id and the transcript id to `body`. The body must not
/// write to the transcript: these tests scan the same file version repeatedly.
private func withUntouchedPendingTranscript(sampleText: String, _ body: (URL, UUID, UUID) -> Void) {
    let fm = FileManager.default
    let directory = fm.temporaryDirectory
        .appendingPathComponent("SpeakerReviewQueueScannerTests-\(UUID().uuidString)", isDirectory: true)
    let transcriptURL = directory.appendingPathComponent("Untouched_Call.md")
    let speakerId = UUID()
    let transcriptId = UUID()
    try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: directory) }

    let markdown = deferredMarkdown(
        speakerId: speakerId,
        title: "Untouched Call",
        transcriptId: transcriptId,
        speakerName: "Speaker 1",
        sampleText: sampleText
    ).replacingOccurrences(of: "capture_type: meeting", with: "capture_type: meeting\nduration: \"42:10\"")
    do {
        try markdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
    } catch {
        assertTrue(false, "could not write untouched transcript fixture: \(error)")
        return
    }
    body(directory, speakerId, transcriptId)
}

private func deferredMarkdown(
    speakerId: UUID,
    title: String,
    transcriptId: UUID = UUID(),
    date: String = "2026-05-20",
    time: String = "09:30:00",
    speakerName: String,
    sampleText: String
) -> String {
    """
    ---
    transcript_id: "\(transcriptId.uuidString)"
    title: "\(title)"
    capture_type: meeting
    date: \(date)
    time: \(time)
    speakers:
      - id: "\(speakerName.replacingOccurrences(of: "Speaker ", with: ""))"
        channel: system
        db_id: "\(speakerId.uuidString)"
        name: "\(speakerName)"
        confidence: unknown
        source: db_pending
    ---

    # \(title)

    ## Transcript

    **00:01** [System/\(speakerName)]
    \(sampleText)
    """
}

private func deferredMarkdownWithoutSample(
    speakerId: UUID,
    title: String,
    speakerName: String
) -> String {
    """
    ---
    title: "\(title)"
    capture_type: meeting
    date: 2026-05-20
    time: 09:30:00
    speakers:
      - id: "\(speakerName.replacingOccurrences(of: "Speaker ", with: ""))"
        channel: system
        db_id: "\(speakerId.uuidString)"
        name: "\(speakerName)"
        confidence: unknown
        source: db_pending
    ---

    # \(title)

    ## Transcript
    """
}

private func makeReviewQueueProfile(
    id: UUID,
    name: String?,
    calls: Int = 1
) -> SpeakerProfile {
    SpeakerProfile(
        id: id,
        displayName: name,
        nameSource: name == nil ? nil : NameSource.userManual,
        embedding: [0.1, 0.2, 0.3],
        firstSeen: Date(timeIntervalSinceReferenceDate: 0),
        lastSeen: Date(timeIntervalSinceReferenceDate: 10),
        callCount: calls,
        confidence: 0.8,
        disputeCount: 0
    )
}
