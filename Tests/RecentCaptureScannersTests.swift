import Foundation

func testRecentCaptureScanners() async {
    runSuite("RecentMeetingSpeakerStatus.detect flags generic speaker labels") {
        let markdown = """
        # Design review

        ## Transcript

        **00:01**  [System/Speaker 1]
        We should review this later.

        **00:12**  [Mic/Unknown speaker]
        I can follow up.
        """

        assertEqual(
            RecentMeetingSpeakerStatus.detect(in: markdown),
            .needsReview(2),
            "Generic speaker labels should surface as needing review"
        )
    }

    runSuite("RecentMeetingSpeakerStatus.detect treats named speakers as ready") {
        let markdown = """
        # Product sync

        ## Transcript

        **00:01**  [System/Maya]
        The plan looks good.

        **00:12**  [Mic/Justin]
        I will ship the follow-up.
        """

        assertEqual(
            RecentMeetingSpeakerStatus.detect(in: markdown),
            .ready,
            "Named speakers should not create a review badge"
        )
    }

    runSuite("RecentMeetingSpeakerStatus.detect ignores generic words in transcript text") {
        let markdown = """
        # Product sync

        ## Transcript

        **00:01**  [System/Maya]
        The customer said Speaker 1 and Unknown speaker during the demo.

        **00:12**  [Mic/Justin]
        I wrote Review later in the notes, but this speaker label is named.
        """

        assertEqual(
            RecentMeetingSpeakerStatus.detect(in: markdown),
            .ready,
            "Only actual speaker labels should create review work"
        )
    }

    runSuite("RecentMeetingSpeakerStatus.detect flags legacy inline generic labels") {
        let markdown = """
        # Legacy recording

        ## Full Transcript

        [00:01] [Mic/Speaker 1] Hello there.

        [00:05] [System/Review later] Nice to meet you.
        """

        assertEqual(
            RecentMeetingSpeakerStatus.detect(in: markdown),
            .needsReview(2),
            "Legacy inline transcript labels should still surface review work"
        )
    }

    runSuite("RecentMeetingSpeakerStatus.detect deduplicates repeated generic labels") {
        let markdown = """
        # Repeated generic labels

        ## Transcript

        **00:01** [Mic/Speaker 1]
        First line.

        **00:02** [System/Speaker 1]
        Same generic label again.

        **00:03** [System/Unknown speaker]
        Another generic label.
        """

        assertEqual(
            RecentMeetingSpeakerStatus.detect(in: markdown),
            .needsReview(2),
            "speaker review badges should count unique generic labels, not every line"
        )
        assertEqual(
            RecentMeetingSpeakerStatus.needsReview(1).summary,
            "1 speaker needs review",
            "singular speaker summary should read naturally"
        )
        assertEqual(
            RecentMeetingSpeakerStatus.ready.summary,
            "Speakers ready",
            "ready speaker status should stay terse"
        )
    }

    runSuite("RecentMeetingSpeakerReviewActionPolicy hides stale meeting review buttons when people queue is clean") {
        assertFalse(
            RecentMeetingSpeakerReviewActionPolicy.shouldShowReviewAction(
                speakerStatus: .needsReview(1),
                hasSpeakerReviewWork: false
            ),
            "A generic old transcript should not keep showing a review button after the Speakers queue is clean"
        )
    }

    runSuite("RecentMeetingSpeakerReviewActionPolicy shows actionable meeting review buttons") {
        assertTrue(
            RecentMeetingSpeakerReviewActionPolicy.shouldShowReviewAction(
                speakerStatus: .needsReview(1),
                hasSpeakerReviewWork: true
            ),
            "Generic speaker labels should still show a review button while Speakers has review work"
        )
        assertFalse(
            RecentMeetingSpeakerReviewActionPolicy.shouldShowReviewAction(
                speakerStatus: .ready,
                hasSpeakerReviewWork: true
            ),
            "Ready meetings should not show a speaker review button"
        )
    }

    runSuite("RecentMeetingRetranscriptionActionPolicy shows saved-audio speaker ID fallback") {
        assertTrue(
            RecentMeetingRetranscriptionActionPolicy.shouldShowInlineAction(
                speakerStatus: .needsReview(1),
                hasRetainedAudio: true,
                hasSpeakerReviewWork: false
            ),
            "A saved meeting with generic labels and retained audio should offer a new speaker-ID pass when no review queue exists"
        )
        assertFalse(
            RecentMeetingRetranscriptionActionPolicy.shouldShowInlineAction(
                speakerStatus: .needsReview(1),
                hasRetainedAudio: false,
                hasSpeakerReviewWork: false
            ),
            "Re-transcription needs retained audio"
        )
        assertFalse(
            RecentMeetingRetranscriptionActionPolicy.shouldShowInlineAction(
                speakerStatus: .needsReview(1),
                hasRetainedAudio: true,
                hasSpeakerReviewWork: true
            ),
            "Existing speaker review work should keep the normal Review speakers action"
        )
        assertFalse(
            RecentMeetingRetranscriptionActionPolicy.shouldShowInlineAction(
                speakerStatus: .ready,
                hasRetainedAudio: true,
                hasSpeakerReviewWork: false
            ),
            "Ready meetings should keep re-transcription in the row menu instead of showing an inline warning action"
        )
    }

    runSuite("SavedMeetingRetranscriptionAvailabilityPolicy blocks while models prepare") {
        assertEqual(
            SavedMeetingRetranscriptionAvailabilityPolicy.unavailableReason(
                isDictationActive: false,
                isMeetingRecording: false,
                isPreparingModels: true,
                hasMeetingWork: false,
                isSpeakerReviewPending: false
            ),
            "Preparing models...",
            "saved-meeting re-transcription should not accept duplicate clicks while model prep is in flight"
        )
    }

    runSuite("SavedMeetingRetranscriptionAvailabilityPolicy blocks during live work") {
        assertEqual(
            SavedMeetingRetranscriptionAvailabilityPolicy.unavailableReason(
                isDictationActive: true,
                isMeetingRecording: false,
                isPreparingModels: false,
                hasMeetingWork: false,
                isSpeakerReviewPending: false
            ),
            "Wait for the current dictation to finish before re-transcribing saved audio.",
            "saved-meeting re-transcription should not race an active dictation"
        )
        assertEqual(
            SavedMeetingRetranscriptionAvailabilityPolicy.unavailableReason(
                isDictationActive: false,
                isMeetingRecording: true,
                isPreparingModels: false,
                hasMeetingWork: false,
                isSpeakerReviewPending: false
            ),
            "Stop the current recording before re-transcribing saved audio.",
            "saved-meeting re-transcription should not start while a meeting is recording"
        )
        assertEqual(
            SavedMeetingRetranscriptionAvailabilityPolicy.unavailableReason(
                isDictationActive: false,
                isMeetingRecording: false,
                isPreparingModels: false,
                hasMeetingWork: true,
                isSpeakerReviewPending: false
            ),
            "Wait for the current meeting to finish saving or transcribing before re-transcribing saved audio.",
            "saved-meeting re-transcription should stay single-flight with background meeting work"
        )
        assertEqual(
            SavedMeetingRetranscriptionAvailabilityPolicy.unavailableReason(
                isDictationActive: false,
                isMeetingRecording: false,
                isPreparingModels: false,
                hasMeetingWork: false,
                isSpeakerReviewPending: true
            ),
            "Finish the speaker review window before re-transcribing saved audio.",
            "saved-meeting re-transcription should wait until speaker review is resolved"
        )
    }

    runSuite("SavedMeetingRetranscriptionAvailabilityPolicy allows idle saved meetings") {
        assertNil(
            SavedMeetingRetranscriptionAvailabilityPolicy.unavailableReason(
                isDictationActive: false,
                isMeetingRecording: false,
                isPreparingModels: false,
                hasMeetingWork: false,
                isSpeakerReviewPending: false
            ),
            "idle saved meetings with retained audio should stay re-transcribable"
        )
    }

    await testRecentCaptureLoader()
}

func testRecentCaptureLoader() async {
    await runSuite("RecentCaptureLoader returns newest rows and requested dictation counts from a temp library") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
            let dictationsRoot = captureRoot.appendingPathComponent("dictations", isDirectory: true)

            try? writeRecentLoaderMeeting(
                title: "Older Sync",
                date: recentLoaderDate("2026-05-17T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("older.md", isDirectory: false)
            )
            try? writeRecentLoaderMeeting(
                title: "Newer Sync",
                date: recentLoaderDate("2026-05-18T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("newer.md", isDirectory: false)
            )
            _ = try? DictationTranscriptStore.save(
                text: "older dictation words",
                sourceApp: nil,
                delivery: .copied,
                createdAt: recentLoaderDate("2026-05-17T13:00:00Z"),
                directory: dictationsRoot
            )
            _ = try? DictationTranscriptStore.save(
                text: "newer dictation words now",
                sourceApp: nil,
                delivery: .pasted,
                createdAt: recentLoaderDate("2026-05-18T13:00:00Z"),
                directory: dictationsRoot
            )

            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: 2,
                meetingLimit: 2,
                includeDictationCounts: true
            )

            assertEqual(snapshot.meetings.map(\.title), ["Newer Sync", "Older Sync"], "meetings should be newest-first")
            assertEqual(snapshot.dictations.map(\.text), ["newer dictation words now", "older dictation words"], "dictations should be newest-first")
            assertEqual(snapshot.dictationCounts.total, 2, "requested dictation counts should include all entries")
            assertEqual(snapshot.dictationCounts.totalWords, 7, "requested dictation counts should include word totals")
        }
    }

    await runSuite("RecentCaptureLoader cancellation returns no stale rows") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
            let dictationsRoot = captureRoot.appendingPathComponent("dictations", isDirectory: true)
            for index in 0..<200 {
                let date = Date(timeIntervalSince1970: 1_779_470_400 - Double(index * 60))
                try? writeRecentLoaderMeeting(
                    title: "Canceled Sync \(index)",
                    date: date,
                    to: meetingsRoot.appendingPathComponent("meeting-\(index).md", isDirectory: false)
                )
                _ = try? DictationTranscriptStore.save(
                    text: "canceled dictation \(index)",
                    sourceApp: nil,
                    delivery: .copied,
                    createdAt: date,
                    directory: dictationsRoot
                )
            }

            let task = Task {
                await RecentCaptureLoader.load(
                    dictationLimit: 10,
                    meetingLimit: 10,
                    includeDictationCounts: true
                )
            }
            task.cancel()
            let snapshot = await task.value

            assertEqual(snapshot.meetings.count, 0, "canceled loads should not publish meeting rows")
            assertEqual(snapshot.dictations.count, 0, "canceled loads should not publish dictation rows")
            assertEqual(snapshot.dictationCounts.total, 0, "canceled loads should not publish stale counts")
        }
    }

    await runSuite("RecentCaptureLoader.load(limit:) limits both surfaces and skips counts by default") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
            let dictationsRoot = captureRoot.appendingPathComponent("dictations", isDirectory: true)

            for index in 0..<3 {
                let date = Date(timeIntervalSince1970: 1_779_470_400 + Double(index * 60))
                try? writeRecentLoaderMeeting(
                    title: "Synthetic Capture \(index)",
                    date: date,
                    to: meetingsRoot.appendingPathComponent("capture-\(index).md", isDirectory: false)
                )
                _ = try? DictationTranscriptStore.save(
                    text: "synthetic dictation \(index)",
                    sourceApp: nil,
                    delivery: .copied,
                    createdAt: date,
                    directory: dictationsRoot
                )
            }

            let snapshot = await RecentCaptureLoader.load(limit: 1)

            assertEqual(snapshot.meetings.map(\.title), ["Synthetic Capture 2"], "default loading should cap meeting rows")
            assertEqual(snapshot.dictations.map(\.text), ["synthetic dictation 2"], "default loading should cap dictation rows")
            assertEqual(snapshot.dictationCounts.total, 0, "default loading should avoid the slower count scan")
            assertEqual(snapshot.dictationCounts.totalWords, 0, "default loading should not compute word totals")
        }
    }

    await runSuite("RecentCaptureLoader handles split zero limits without counts") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
            let dictationsRoot = captureRoot.appendingPathComponent("dictations", isDirectory: true)

            try? writeRecentLoaderMeeting(
                title: "Only Meeting Row",
                date: recentLoaderDate("2026-05-19T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("meeting.md", isDirectory: false)
            )
            _ = try? DictationTranscriptStore.save(
                text: "hidden dictation row",
                sourceApp: nil,
                delivery: .copied,
                createdAt: recentLoaderDate("2026-05-19T13:00:00Z"),
                directory: dictationsRoot
            )

            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: 0,
                meetingLimit: 1,
                includeDictationCounts: false
            )

            assertEqual(snapshot.meetings.map(\.title), ["Only Meeting Row"], "meeting rows should still load when dictation rows are disabled")
            assertEqual(snapshot.dictations.count, 0, "zero dictation limit should not return saved dictations")
            assertEqual(snapshot.dictationCounts.total, 0, "disabled counts should stay empty even when dictations exist")
        }
    }

    await runSuite("RecentCaptureLoader handles zero meeting limits without dropping dictations") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
            let dictationsRoot = captureRoot.appendingPathComponent("dictations", isDirectory: true)

            try? writeRecentLoaderMeeting(
                title: "Synthetic Capture Row",
                date: recentLoaderDate("2026-05-20T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("meeting.md", isDirectory: false)
            )
            _ = try? DictationTranscriptStore.save(
                text: "visible dictation row",
                sourceApp: nil,
                delivery: .copied,
                createdAt: recentLoaderDate("2026-05-20T13:00:00Z"),
                directory: dictationsRoot
            )

            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: 1,
                meetingLimit: 0,
                includeDictationCounts: false
            )

            assertEqual(snapshot.meetings.count, 0, "zero meeting limit should not return meeting rows")
            assertEqual(snapshot.dictations.map(\.text), ["visible dictation row"], "dictation rows should still load when meeting rows are disabled")
            assertEqual(snapshot.dictationCounts.total, 0, "disabled counts should stay empty for split zero-limit loads")
        }
    }

    await runSuite("RecentCaptureLoader supports requested count-only loads") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
            let dictationsRoot = captureRoot.appendingPathComponent("dictations", isDirectory: true)

            try? writeRecentLoaderMeeting(
                title: "Synthetic Count Row",
                date: recentLoaderDate("2026-05-21T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("meeting.md", isDirectory: false)
            )
            _ = try? DictationTranscriptStore.save(
                text: "first count row",
                sourceApp: nil,
                delivery: .copied,
                createdAt: recentLoaderDate("2026-05-20T13:00:00Z"),
                directory: dictationsRoot
            )
            _ = try? DictationTranscriptStore.save(
                text: "second count row",
                sourceApp: nil,
                delivery: .pasted,
                createdAt: recentLoaderDate("2026-05-21T13:00:00Z"),
                directory: dictationsRoot
            )

            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: 0,
                meetingLimit: 0,
                includeDictationCounts: true
            )

            assertEqual(snapshot.meetings.count, 0, "count-only loads should not return meeting rows")
            assertEqual(snapshot.dictations.count, 0, "count-only loads should not return dictation rows")
            assertEqual(snapshot.dictationCounts.total, 2, "requested count-only loads should still compute total dictations")
            assertEqual(snapshot.dictationCounts.totalWords, 6, "requested count-only loads should still compute word totals")
        }
    }

    await runSuite("RecentCaptureLoader loads dictations when the meetings folder is missing") {
        await withTemporaryRecentCaptureLibrary(createMeetingsDirectory: false) { captureRoot in
            let dictationsRoot = captureRoot.appendingPathComponent("dictations", isDirectory: true)

            _ = try? DictationTranscriptStore.save(
                text: "fresh dictation row",
                sourceApp: nil,
                delivery: .copied,
                createdAt: recentLoaderDate("2026-05-24T13:00:00Z"),
                directory: dictationsRoot
            )

            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: 1,
                meetingLimit: 1,
                includeDictationCounts: true
            )

            assertEqual(snapshot.meetings.count, 0, "missing meetings folder should fail closed")
            assertEqual(snapshot.dictations.map(\.text), ["fresh dictation row"], "dictation rows should still load without meeting artifacts")
            assertEqual(snapshot.dictationCounts.total, 1, "dictation counts should still use the existing dictation folder")
        }
    }

    await runSuite("RecentCaptureLoader loads meetings when the dictations folder is missing") {
        await withTemporaryRecentCaptureLibrary(createDictationsDirectory: false) { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)

            try? writeRecentLoaderMeeting(
                title: "Fresh Meeting Row",
                date: recentLoaderDate("2026-05-24T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("meeting.md", isDirectory: false)
            )

            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: 1,
                meetingLimit: 1,
                includeDictationCounts: true
            )

            assertEqual(snapshot.meetings.map(\.title), ["Fresh Meeting Row"], "meeting rows should still load without dictation artifacts")
            assertEqual(snapshot.dictations.count, 0, "missing dictations folder should fail closed")
            assertEqual(snapshot.dictationCounts.total, 0, "counts should stay zero when the dictation folder is absent")
        }
    }

    await runSuite("RecentCaptureLoader returns an empty snapshot when capture folders are absent") {
        await withTemporaryRecentCaptureLibrary(
            createMeetingsDirectory: false,
            createDictationsDirectory: false
        ) { _ in
            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: 3,
                meetingLimit: 3,
                includeDictationCounts: true
            )

            assertEqual(snapshot.meetings.count, 0, "missing meeting storage should not surface stale rows")
            assertEqual(snapshot.dictations.count, 0, "missing dictation storage should not surface stale rows")
            assertEqual(snapshot.dictationCounts.total, 0, "missing dictation storage should report zero total entries")
            assertEqual(snapshot.dictationCounts.totalWords, 0, "missing dictation storage should report zero dictated words")
        }
    }

    await runSuite("RecentMeetingsScanner returns empty when the meetings path is not a directory") {
        await withTemporaryRecentCaptureLibrary(createMeetingsDirectory: false) { captureRoot in
            let meetingsPath = captureRoot.appendingPathComponent("meetings", isDirectory: false)
            FileManager.default.createFile(atPath: meetingsPath.path, contents: Data("not a directory".utf8))

            let meetings = RecentMeetingsScanner.loadRecent(limit: 3)

            assertEqual(meetings.count, 0, "a file at the meetings path should fail closed instead of scanning siblings")
        }
    }

    await runSuite("RecentMeetingsScanner ignores agent docs hidden files and markdown directories") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
            let directoryShapedMarkdown = meetingsRoot.appendingPathComponent("folder.md", isDirectory: true)

            try? writeRecentLoaderMeeting(
                title: "Included Meeting",
                date: recentLoaderDate("2026-05-19T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("included.md", isDirectory: false)
            )
            try? writeRecentLoaderMeeting(
                title: "Agent Doc",
                date: recentLoaderDate("2026-05-20T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("AGENT.md", isDirectory: false)
            )
            try? writeRecentLoaderMeeting(
                title: "Claude Doc",
                date: recentLoaderDate("2026-05-21T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("CLAUDE.md", isDirectory: false)
            )
            try? writeRecentLoaderMeeting(
                title: "Hidden Meeting",
                date: recentLoaderDate("2026-05-22T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent(".hidden.md", isDirectory: false)
            )
            try? FileManager.default.createDirectory(at: directoryShapedMarkdown, withIntermediateDirectories: false)

            let meetings = RecentMeetingsScanner.loadRecent(limit: 5)

            assertEqual(meetings.map(\.title), ["Included Meeting"], "scanner should only surface real meeting markdown")
        }
    }

    await runSuite("RecentMeetingsScanner preserves retained audio and speaker review metadata") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
            let transcriptURL = meetingsRoot.appendingPathComponent("audio-review.md", isDirectory: false)

            try? writeRecentLoaderMeeting(
                title: "Synthetic Audio Row",
                date: recentLoaderDate("2026-05-23T14:00:00Z"),
                to: transcriptURL,
                micLabel: "Speaker 1"
            )
            let audioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: transcriptURL)
            try? FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
            FileManager.default.createFile(
                atPath: audioDirectory.appendingPathComponent("microphone.wav").path,
                contents: Data("mic".utf8)
            )
            FileManager.default.createFile(
                atPath: audioDirectory.appendingPathComponent("system_audio.wav").path,
                contents: Data("system".utf8)
            )

            let meetings = RecentMeetingsScanner.loadRecent(limit: 1)

            assertEqual(meetings.map(\.title), ["Synthetic Audio Row"], "scanner should keep the valid meeting row")
            assertEqual(meetings.first?.audio?.urls.map(\.lastPathComponent), ["system_audio.wav", "microphone.wav"], "scanner should attach retained meeting audio")
            assertEqual(meetings.first?.speakerStatus, .needsReview(1), "scanner should keep speaker review metadata from the transcript")
        }
    }

    await runSuite("RecentMeetingsScanner returns empty for non-positive limits") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)

            try? writeRecentLoaderMeeting(
                title: "Synthetic Limited Row",
                date: recentLoaderDate("2026-05-23T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("limited.md", isDirectory: false)
            )

            assertEqual(RecentMeetingsScanner.loadRecent(limit: 0).count, 0, "zero meeting limit should not load rows")
            assertEqual(RecentMeetingsScanner.loadRecent(limit: -1).count, 0, "negative meeting limit should not load rows")
        }
    }

    await runSuite("RecentMeetingsScanner fills the limit after skipping malformed newer candidates") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
            let plainMarkdown = meetingsRoot.appendingPathComponent("newer-note.md", isDirectory: false)

            try? "# Synthetic note\n\nNot a meeting transcript.\n".write(to: plainMarkdown, atomically: true, encoding: .utf8)
            setRecentLoaderFileDate(recentLoaderDate("2026-05-22T14:00:00Z"), at: plainMarkdown)
            try? writeRecentLoaderMeeting(
                title: "Valid Meeting A",
                date: recentLoaderDate("2026-05-21T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("valid-a.md", isDirectory: false)
            )
            try? writeRecentLoaderMeeting(
                title: "Valid Meeting B",
                date: recentLoaderDate("2026-05-20T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("valid-b.md", isDirectory: false)
            )

            let meetings = RecentMeetingsScanner.loadRecent(limit: 2)

            assertEqual(meetings.map(\.title), ["Valid Meeting A", "Valid Meeting B"], "bad newer markdown should not starve older valid meeting rows")
        }
    }
}

private func withTemporaryRecentCaptureLibrary(
    createMeetingsDirectory: Bool = true,
    createDictationsDirectory: Bool = true,
    _ body: (URL) async -> Void
) async {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("build/recent-capture-loader-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let captureRoot = root.appendingPathComponent("captures", isDirectory: true)
    let previous = UserDefaults.standard.object(forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)

    try? fm.createDirectory(at: captureRoot, withIntermediateDirectories: true)
    if createMeetingsDirectory {
        try? fm.createDirectory(
            at: captureRoot.appendingPathComponent("meetings", isDirectory: true),
            withIntermediateDirectories: true
        )
    }
    if createDictationsDirectory {
        try? fm.createDirectory(
            at: captureRoot.appendingPathComponent("dictations", isDirectory: true),
            withIntermediateDirectories: true
        )
    }
    UserDefaults.standard.set(captureRoot.path, forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)

    await body(captureRoot)

    if let previous {
        UserDefaults.standard.set(previous, forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
    } else {
        UserDefaults.standard.removeObject(forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)
    }
    _ = fm.transcriptedCaptureLibraryDir
    try? fm.removeItem(at: root)
}

private func writeRecentLoaderMeeting(
    title: String,
    date: Date,
    to url: URL,
    micLabel: String = "You",
    systemLabel: String = "Remote Participant"
) throws {
    let markdown = """
    ---
    title: "\(title)"
    capture_type: meeting
    date: "\(recentLoaderFormat(date, "yyyy-MM-dd"))"
    time: "\(recentLoaderFormat(date, "HH:mm:ss"))"
    duration: "10:00"
    total_word_count: 5
    mic_utterances: 1
    system_utterances: 1
    ---

    # \(title)

    ## Transcript

    **00:01** [Mic/\(micLabel)]
    Synthetic test meeting.

    **00:04** [System/\(systemLabel)]
    Synthetic response.
    """
    try markdown.write(to: url, atomically: true, encoding: .utf8)
    setRecentLoaderFileDate(date, at: url)
}

private func setRecentLoaderFileDate(_ date: Date, at url: URL) {
    try? FileManager.default.setAttributes(
        [.creationDate: date, .modificationDate: date],
        ofItemAtPath: url.path
    )
}

private func recentLoaderDate(_ string: String) -> Date {
    ISO8601DateFormatter().date(from: string) ?? Date(timeIntervalSince1970: 0)
}

private func recentLoaderFormat(_ date: Date, _ pattern: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = pattern
    return formatter.string(from: date)
}
