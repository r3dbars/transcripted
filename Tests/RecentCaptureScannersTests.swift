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

    await runSuite("RecentCaptureLoader keeps Home dashboard loading bounded with a large local history") {
        let fm = FileManager.default
        let root = temporaryRecentCapturePerformanceRoot(fileManager: fm)
        let meetingDir = root.appendingPathComponent("meetings", isDirectory: true)
        let dictationDir = root.appendingPathComponent("dictations", isDirectory: true)
        let today = recentCapturePerformanceDate(year: 2026, month: 5, day: 31)
        defer { try? fm.removeItem(at: root) }

        do {
            try fm.createDirectory(at: meetingDir, withIntermediateDirectories: true)
            try fm.createDirectory(at: dictationDir, withIntermediateDirectories: true)
            try writeRecentCapturePerformanceMeetings(
                count: 500,
                namedSpeakersPerMeeting: 64,
                directory: meetingDir,
                fileManager: fm,
                today: today
            )
            try writeRecentCapturePerformanceDictations(
                dayCount: 120,
                entriesPerDay: 3,
                directory: dictationDir,
                today: today
            )
        } catch {
            assertTrue(false, "performance fixture setup should succeed: \(error)")
            return
        }

        let startedAt = Date()
        let snapshot = await RecentCaptureLoader.load(
            dictationLimit: 5,
            meetingLimit: 5,
            includeDictationCounts: true,
            meetingDirectory: meetingDir,
            dictationDirectory: dictationDir,
            today: today
        )
        let elapsed = Date().timeIntervalSince(startedAt)
        let m1FriendlyBudgetSeconds = 2.5

        assertEqual(snapshot.meetings.count, 5, "Home should only prepare the visible recent meetings")
        assertEqual(snapshot.dictations.count, 5, "Home should only prepare the visible recent dictations")
        assertEqual(snapshot.dictationCounts.total, 360, "Home stats should still count the whole dictation history")
        assertEqual(snapshot.dictationCounts.today, 3, "Home stats should count today's dictations")
        assertEqual(snapshot.dictationCounts.totalWords, 2_160, "Home stats should sum dictated words")
        assertTrue(
            snapshot.meetings.allSatisfy { $0.speakerStatus == .ready },
            "Home should not treat large sets of real named speakers as review work"
        )
        assertTrue(
            elapsed < m1FriendlyBudgetSeconds,
            String(format: "Home recent-capture load took %.3fs, expected under %.1fs on an M1-friendly fixture", elapsed, m1FriendlyBudgetSeconds)
        )
    }

    await testRecentCaptureLoader()
}

private func temporaryRecentCapturePerformanceRoot(fileManager: FileManager) -> URL {
    fileManager.temporaryDirectory.appendingPathComponent(
        "TranscriptedRecentCapturePerformance-\(UUID().uuidString)",
        isDirectory: true
    )
}

private func writeRecentCapturePerformanceMeetings(
    count: Int,
    namedSpeakersPerMeeting: Int,
    directory: URL,
    fileManager: FileManager,
    today: Date
) throws {
    for index in 0..<count {
        let recordedAt = today.addingTimeInterval(TimeInterval(-index * 60))
        let title = String(format: "Performance Meeting %03d", index)
        let transcriptLines = (0..<namedSpeakersPerMeeting)
            .map { speakerIndex in
                let timestamp = String(format: "00:%02d", speakerIndex % 60)
                let channel = speakerIndex.isMultiple(of: 2) ? "System" : "Mic"
                return """
                **\(timestamp)**  [\(channel)/Person \(index)-\(speakerIndex)]
                Checking Home performance with a real named speaker.
                """
            }
            .joined(separator: "\n\n")
        let transcript = """
        ---
        capture_type: meeting
        title: "\(title)"
        date: 2026-05-31
        time: 10:00:00
        duration: "12:30"
        mic_utterances: 1
        system_utterances: \(namedSpeakersPerMeeting)
        total_word_count: \(namedSpeakersPerMeeting * 8)
        ---

        ## Transcript

        \(transcriptLines)
        """
        let url = directory.appendingPathComponent(String(format: "Meeting_%03d.md", index))
        try transcript.write(to: url, atomically: true, encoding: .utf8)
        try fileManager.setAttributes(
            [
                .creationDate: recordedAt,
                .modificationDate: recordedAt
            ],
            ofItemAtPath: url.path
        )
    }
}

private func writeRecentCapturePerformanceDictations(
    dayCount: Int,
    entriesPerDay: Int,
    directory: URL,
    today: Date
) throws {
    let calendar = recentCapturePerformanceCalendar()
    let dayFormatter = recentCaptureDayFormatter()
    let isoFormatter = ISO8601DateFormatter()
    isoFormatter.formatOptions = [.withInternetDateTime]

    for dayOffset in 0..<dayCount {
        guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: today) else {
            continue
        }

        let dayString = dayFormatter.string(from: day)
        var sections: [String] = [
            """
            ---
            title: "Dictations for \(dayString)"
            date: \(dayString)
            capture_type: dictation_day
            ---

            # Dictations for \(dayString)
            """
        ]

        for entryIndex in 0..<entriesPerDay {
            let capturedAt = day.addingTimeInterval(TimeInterval(entryIndex * 600))
            sections.append(
                """
                ## 10:0\(entryIndex) AM - Performance entry \(entryIndex)

                Entry ID: `dictation-\(dayOffset)-\(entryIndex)`
                Captured: \(isoFormatter.string(from: capturedAt))
                Source app: Notes
                Delivery: pasted
                Words: 6
                Characters: 42

                one two three four five six
                """
            )
        }

        let url = directory.appendingPathComponent("Dictations_\(dayString).md")
        try sections.joined(separator: "\n\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

private func recentCapturePerformanceDate(year: Int, month: Int, day: Int) -> Date {
    let calendar = recentCapturePerformanceCalendar()
    return DateComponents(calendar: calendar, timeZone: calendar.timeZone, year: year, month: month, day: day, hour: 12)
        .date ?? Date(timeIntervalSince1970: 0)
}

private func recentCapturePerformanceCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

private func recentCaptureDayFormatter() -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
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
}

private func withTemporaryRecentCaptureLibrary(
    _ body: (URL) async -> Void
) async {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("build/recent-capture-loader-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    let captureRoot = root.appendingPathComponent("captures", isDirectory: true)
    let previous = UserDefaults.standard.object(forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)

    try? fm.createDirectory(
        at: captureRoot.appendingPathComponent("meetings", isDirectory: true),
        withIntermediateDirectories: true
    )
    try? fm.createDirectory(
        at: captureRoot.appendingPathComponent("dictations", isDirectory: true),
        withIntermediateDirectories: true
    )
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

private func writeRecentLoaderMeeting(title: String, date: Date, to url: URL) throws {
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

    **00:01** [Mic/You]
    Synthetic test meeting.

    **00:04** [System/Alex]
    Synthetic response.
    """
    try markdown.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
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
