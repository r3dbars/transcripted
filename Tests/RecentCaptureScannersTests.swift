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

    runSuite("RecentMeetingItem.hasGeneratedTitle detects distinct generated summary titles") {
        let item = sampleRecentMeetingTitleItem(
            title: "Original Capture",
            summaryPreview: sampleRecentMeetingSummaryPreview(title: "Generated Summary")
        )

        assertEqual(item.displayTitle, "Generated Summary", "generated summary title should drive Home display")
        assertTrue(item.hasGeneratedTitle, "distinct generated titles should be marked as generated")
    }

    runSuite("RecentMeetingItem.hasGeneratedTitle stays false without a summary preview") {
        let item = sampleRecentMeetingTitleItem(
            title: "Original Capture",
            summaryPreview: nil
        )

        assertEqual(item.displayTitle, "Original Capture", "meetings without summaries should keep the original title")
        assertFalse(item.hasGeneratedTitle, "missing summary previews should not look generated")
    }

    runSuite("RecentMeetingItem.hasGeneratedTitle stays false when the summary title is nil") {
        let item = sampleRecentMeetingTitleItem(
            title: "Original Capture",
            summaryPreview: sampleRecentMeetingSummaryPreview(title: nil)
        )

        assertEqual(item.displayTitle, "Original Capture", "summaries without generated titles should keep the original title")
        assertFalse(item.hasGeneratedTitle, "nil generated titles should not show generated-title treatment")
    }

    runSuite("RecentMeetingItem.hasGeneratedTitle ignores case and diacritic-only differences") {
        let caseOnly = sampleRecentMeetingTitleItem(
            title: "Planning Review",
            summaryPreview: sampleRecentMeetingSummaryPreview(title: "planning review")
        )
        let diacriticOnly = sampleRecentMeetingTitleItem(
            title: "Resume Review",
            summaryPreview: sampleRecentMeetingSummaryPreview(title: "Résumé Review")
        )

        assertFalse(caseOnly.hasGeneratedTitle, "case-only title differences should not show generated-title treatment")
        assertFalse(diacriticOnly.hasGeneratedTitle, "diacritic-only title differences should not show generated-title treatment")
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

    runSuite("RecentMeetingSpeakerReviewActionPolicy stays scoped to the row transcript") {
        let pendingURL = URL(fileURLWithPath: "/tmp/Pending_Call.md")
        let reviewedURL = URL(fileURLWithPath: "/tmp/Reviewed_Call.md")
        let pendingReviewTranscriptPaths: Set<String> = [pendingURL.standardizedFileURL.path]

        assertFalse(
            RecentMeetingSpeakerReviewActionPolicy.shouldShowReviewAction(
                speakerStatus: .needsReview(1),
                hasSpeakerReviewWork: pendingReviewTranscriptPaths.contains(reviewedURL.standardizedFileURL.path)
            ),
            "A stale generic row should not show Review speakers just because another meeting has pending review work"
        )
        assertTrue(
            RecentMeetingSpeakerReviewActionPolicy.shouldShowReviewAction(
                speakerStatus: .needsReview(1),
                hasSpeakerReviewWork: pendingReviewTranscriptPaths.contains(pendingURL.standardizedFileURL.path)
            ),
            "The meeting that actually has pending speaker-review work should still show Review speakers"
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

    runSuite("LocalMeetingSummaryAvailabilityPolicy blocks while models prepare") {
        assertEqual(
            LocalMeetingSummaryAvailabilityPolicy.unavailableReason(
                isDictationActive: false,
                isMeetingRecording: false,
                isPreparingModels: true,
                hasMeetingWork: false,
                isSpeakerReviewPending: false
            ),
            "Preparing models...",
            "local meeting summaries should not start while model prep is in flight"
        )
    }

    runSuite("LocalMeetingSummaryAvailabilityPolicy blocks during live work") {
        assertEqual(
            LocalMeetingSummaryAvailabilityPolicy.unavailableReason(
                isDictationActive: true,
                isMeetingRecording: false,
                isPreparingModels: false,
                hasMeetingWork: false,
                isSpeakerReviewPending: false
            ),
            "Wait for the current dictation to finish before summarizing a meeting.",
            "local meeting summaries should not race an active dictation"
        )
        assertEqual(
            LocalMeetingSummaryAvailabilityPolicy.unavailableReason(
                isDictationActive: false,
                isMeetingRecording: true,
                isPreparingModels: false,
                hasMeetingWork: false,
                isSpeakerReviewPending: false
            ),
            "Stop the current recording before summarizing a saved meeting.",
            "local meeting summaries should not start while a meeting is recording"
        )
        assertEqual(
            LocalMeetingSummaryAvailabilityPolicy.unavailableReason(
                isDictationActive: false,
                isMeetingRecording: false,
                isPreparingModels: false,
                hasMeetingWork: true,
                isSpeakerReviewPending: false
            ),
            "Wait for the current meeting to finish saving or transcribing before summarizing.",
            "local meeting summaries should stay single-flight with background meeting work"
        )
        assertEqual(
            LocalMeetingSummaryAvailabilityPolicy.unavailableReason(
                isDictationActive: false,
                isMeetingRecording: false,
                isPreparingModels: false,
                hasMeetingWork: false,
                isSpeakerReviewPending: true
            ),
            "Finish the speaker review window before summarizing a meeting.",
            "local meeting summaries should wait until speaker review is resolved"
        )
    }

    runSuite("LocalMeetingSummaryAvailabilityPolicy allows idle saved meetings") {
        assertNil(
            LocalMeetingSummaryAvailabilityPolicy.unavailableReason(
                isDictationActive: false,
                isMeetingRecording: false,
                isPreparingModels: false,
                hasMeetingWork: false,
                isSpeakerReviewPending: false
            ),
            "idle saved meetings should stay summarizable"
        )
    }

    runSuite("RecentMeetingSummaryPreviewParser extracts generated title and summary sections") {
        let summaryURL = URL(fileURLWithPath: "/tmp/launch.summary.md")
        let markdown = """
        ---
        capture_type: meeting_summary
        title: "Quick notes"
        summary_title: "Launch Pricing Review"
        source_transcript: "launch.md"
        ---

        # Title
        Ignored Body Title

        # Summary
        - Team agreed to keep the launch simple.
        - Alex will check pricing language before Friday.

        # Decisions
        Keep the first version small.

        # Action Items
        Alex will check pricing language before Friday.
        """

        guard let preview = RecentMeetingSummaryPreviewParser.preview(
            from: markdown,
            url: summaryURL,
            sourceTranscriptFilename: "launch.md"
        ) else {
            assertTrue(false, "valid local summary should produce a Home preview")
            return
        }

        assertEqual(preview.title, "Launch Pricing Review", "summary_title should become the generated display title")
        assertEqual(
            preview.summary,
            "Team agreed to keep the launch simple.\nAlex will check pricing language before Friday.",
            "Home preview should use only the # Summary section"
        )
        assertEqual(
            preview.sections.map(\.title),
            ["Summary", "Decisions", "Action Items"],
            "expanded Home rows should expose the full generated-summary sections"
        )
        assertFalse(preview.summary.contains("Decisions"), "preview should not bleed later sections into the row")
    }

    runSuite("RecentMeetingSummaryPreviewParser extracts embedded transcript summaries first") {
        let transcriptURL = URL(fileURLWithPath: "/tmp/launch.md")
        let baseMarkdown = """
        ---
        capture_type: meeting
        title: "Quick notes"
        date: "2026-05-24"
        time: "14:00:00"
        duration: "10:00"
        ---

        # Quick notes

        ## Transcript

        **00:01** [Mic/Justin]
        We should keep the launch simple.
        """
        let markdown = LocalMeetingSummaryMarkdownUpdater.markdown(
            byApplying: sampleRecentCaptureLocalSummarySections(),
            to: baseMarkdown,
            configuration: .m1Optimized(physicalMemoryBytes: 16 * 1024 * 1024 * 1024),
            generatedAt: recentLoaderDate("2026-05-24T14:20:00Z"),
            chunkCount: 1
        )

        guard let preview = RecentMeetingSummaryPreviewParser.inlinePreview(
            from: markdown,
            url: transcriptURL
        ) else {
            assertTrue(false, "embedded summary metadata should produce a Home preview")
            return
        }

        assertEqual(preview.title, "Launch Pricing Review", "embedded title should drive Home display")
        assertEqual(preview.summary, "Team agreed to keep launch pricing simple.", "summary should come from the managed transcript block")
        assertEqual(
            preview.sections.map(\.title),
            ["Summary", "Decisions", "Action Items", "Open Questions", "Risks or Follow-ups", "Accuracy Notes"],
            "embedded summaries should expose every managed section for Show more"
        )
    }

    runSuite("RecentMeetingSummaryPreviewParser fails closed for mismatched summaries") {
        let summaryURL = URL(fileURLWithPath: "/tmp/other.summary.md")
        let markdown = """
        ---
        capture_type: meeting_summary
        title: "Other"
        summary_title: "Other Summary"
        source_transcript: "other.md"
        ---

        # Summary
        This belongs to another meeting.
        """

        assertTrue(
            RecentMeetingSummaryPreviewParser.preview(
                from: markdown,
                url: summaryURL,
                sourceTranscriptFilename: "launch.md"
            ) == nil,
            "summary previews should ignore sibling files that point at a different transcript"
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

    await runSuite("RecentCaptureLoader active tasks still publish rows") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
            let dictationsRoot = captureRoot.appendingPathComponent("dictations", isDirectory: true)

            try? writeRecentLoaderMeeting(
                title: "Active Task Row",
                date: recentLoaderDate("2026-06-04T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("active.md", isDirectory: false)
            )
            _ = try? DictationTranscriptStore.save(
                text: "active task dictation row",
                sourceApp: nil,
                delivery: .copied,
                createdAt: recentLoaderDate("2026-06-04T13:00:00Z"),
                directory: dictationsRoot
            )

            let task = Task {
                await RecentCaptureLoader.load(
                    dictationLimit: 1,
                    meetingLimit: 1,
                    includeDictationCounts: true
                )
            }
            let snapshot = await task.value

            assertEqual(snapshot.meetings.map(\.title), ["Active Task Row"], "active task loads should still publish meeting rows")
            assertEqual(snapshot.dictations.map(\.text), ["active task dictation row"], "active task loads should still publish dictation rows")
            assertEqual(snapshot.dictationCounts.total, 1, "active task loads should still publish requested counts")
        }
    }

    await runSuite("RecentMeetingsScanner cancellation returns no rows") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)

            try? writeRecentLoaderMeeting(
                title: "Canceled Scanner Row A",
                date: recentLoaderDate("2026-06-05T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("canceled-a.md", isDirectory: false)
            )
            try? writeRecentLoaderMeeting(
                title: "Canceled Scanner Row B",
                date: recentLoaderDate("2026-06-04T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("canceled-b.md", isDirectory: false)
            )

            let task = Task { () -> [RecentMeetingItem] in
                while !Task.isCancelled {
                    await Task.yield()
                }
                return RecentMeetingsScanner.loadRecent(limit: 2)
            }
            task.cancel()
            let meetings = await task.value

            assertEqual(meetings.count, 0, "canceled scanner tasks should fail closed before publishing meeting rows")
        }
    }

    await runSuite("DictationTranscriptStore cancellation skips recent dictation rows") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let dictationsRoot = captureRoot.appendingPathComponent("dictations", isDirectory: true)

            _ = try? DictationTranscriptStore.save(
                text: "canceled recent dictation row",
                sourceApp: nil,
                delivery: .copied,
                createdAt: recentLoaderDate("2026-06-05T13:00:00Z"),
                directory: dictationsRoot
            )

            let task = Task { () -> [SavedDictationEntry] in
                while !Task.isCancelled {
                    await Task.yield()
                }
                return DictationTranscriptStore.recentSavedDictations(limit: 1, directory: dictationsRoot)
            }
            task.cancel()
            let dictations = await task.value

            assertEqual(dictations.count, 0, "canceled dictation row scans should fail closed before publishing entries")
        }
    }

    await runSuite("DictationTranscriptStore cancellation skips dictation counts") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let dictationsRoot = captureRoot.appendingPathComponent("dictations", isDirectory: true)
            let today = recentLoaderDate("2026-06-05T13:00:00Z")

            _ = try? DictationTranscriptStore.save(
                text: "canceled count dictation row",
                sourceApp: nil,
                delivery: .copied,
                createdAt: today,
                directory: dictationsRoot
            )

            let task = Task { () -> DictationTranscriptCounts in
                while !Task.isCancelled {
                    await Task.yield()
                }
                return DictationTranscriptStore.savedDictationCounts(directory: dictationsRoot, today: today)
            }
            task.cancel()
            let counts = await task.value

            assertEqual(counts.total, 0, "canceled count scans should not publish total entries")
            assertEqual(counts.today, 0, "canceled count scans should not publish today's entries")
            assertEqual(counts.totalWords, 0, "canceled count scans should not publish word totals")
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

    await runSuite("RecentCaptureLoader honors different positive limits per surface") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
            let dictationsRoot = captureRoot.appendingPathComponent("dictations", isDirectory: true)

            for index in 0..<3 {
                let date = Date(timeIntervalSince1970: 1_779_470_400 + Double(index * 60))
                try? writeRecentLoaderMeeting(
                    title: "Split Limit Capture \(index)",
                    date: date,
                    to: meetingsRoot.appendingPathComponent("split-\(index).md", isDirectory: false)
                )
                _ = try? DictationTranscriptStore.save(
                    text: "split limit dictation \(index)",
                    sourceApp: nil,
                    delivery: .copied,
                    createdAt: date,
                    directory: dictationsRoot
                )
            }

            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: 1,
                meetingLimit: 2,
                includeDictationCounts: true
            )

            assertEqual(snapshot.meetings.map(\.title), ["Split Limit Capture 2", "Split Limit Capture 1"], "meeting rows should honor their own page size")
            assertEqual(snapshot.dictations.map(\.text), ["split limit dictation 2"], "dictation rows should honor their own page size")
            assertEqual(snapshot.dictationCounts.total, 3, "requested counts should stay independent of the row page size")
        }
    }

    await runSuite("RecentCaptureLoader treats negative dictation limits as row-disabled") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
            let dictationsRoot = captureRoot.appendingPathComponent("dictations", isDirectory: true)

            try? writeRecentLoaderMeeting(
                title: "Meeting With Negative Dictation Limit",
                date: recentLoaderDate("2026-05-28T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("meeting.md", isDirectory: false)
            )
            _ = try? DictationTranscriptStore.save(
                text: "counted dictation row",
                sourceApp: nil,
                delivery: .copied,
                createdAt: recentLoaderDate("2026-05-28T13:00:00Z"),
                directory: dictationsRoot
            )

            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: -1,
                meetingLimit: 1,
                includeDictationCounts: true
            )

            assertEqual(snapshot.meetings.map(\.title), ["Meeting With Negative Dictation Limit"], "negative dictation limits should not block meeting rows")
            assertEqual(snapshot.dictations.count, 0, "negative dictation limits should disable dictation rows")
            assertEqual(snapshot.dictationCounts.total, 1, "requested counts should still load when dictation rows are disabled")
        }
    }

    await runSuite("RecentCaptureLoader treats negative meeting limits as row-disabled") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
            let dictationsRoot = captureRoot.appendingPathComponent("dictations", isDirectory: true)

            try? writeRecentLoaderMeeting(
                title: "Hidden Negative Meeting Limit",
                date: recentLoaderDate("2026-05-29T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("meeting.md", isDirectory: false)
            )
            _ = try? DictationTranscriptStore.save(
                text: "visible negative meeting limit dictation",
                sourceApp: nil,
                delivery: .copied,
                createdAt: recentLoaderDate("2026-05-29T13:00:00Z"),
                directory: dictationsRoot
            )

            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: 1,
                meetingLimit: -1,
                includeDictationCounts: true
            )

            assertEqual(snapshot.meetings.count, 0, "negative meeting limits should disable meeting rows")
            assertEqual(snapshot.dictations.map(\.text), ["visible negative meeting limit dictation"], "negative meeting limits should not block dictation rows")
            assertEqual(snapshot.dictationCounts.total, 1, "requested counts should still load when meeting rows are disabled")
        }
    }

    await runSuite("RecentCaptureLoader.load(limit:) fails closed for negative shared limits") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
            let dictationsRoot = captureRoot.appendingPathComponent("dictations", isDirectory: true)

            try? writeRecentLoaderMeeting(
                title: "Hidden Shared Negative Limit",
                date: recentLoaderDate("2026-05-30T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("meeting.md", isDirectory: false)
            )
            _ = try? DictationTranscriptStore.save(
                text: "hidden shared negative limit dictation",
                sourceApp: nil,
                delivery: .copied,
                createdAt: recentLoaderDate("2026-05-30T13:00:00Z"),
                directory: dictationsRoot
            )

            let snapshot = await RecentCaptureLoader.load(limit: -1)

            assertEqual(snapshot.meetings.count, 0, "negative shared limits should not return meeting rows")
            assertEqual(snapshot.dictations.count, 0, "negative shared limits should not return dictation rows")
            assertEqual(snapshot.dictationCounts.total, 0, "default shared-limit loads should still skip counts")
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

    await runSuite("RecentCaptureLoader returns newest same-day dictations when meetings are disabled") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let dictationsRoot = captureRoot.appendingPathComponent("dictations", isDirectory: true)

            _ = try? DictationTranscriptStore.save(
                text: "same day older row",
                sourceApp: nil,
                delivery: .copied,
                createdAt: recentLoaderDate("2026-06-01T13:00:00Z"),
                directory: dictationsRoot
            )
            _ = try? DictationTranscriptStore.save(
                text: "same day newer row",
                sourceApp: nil,
                delivery: .pasted,
                createdAt: recentLoaderDate("2026-06-01T14:00:00Z"),
                directory: dictationsRoot
            )

            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: 2,
                meetingLimit: 0,
                includeDictationCounts: false
            )

            assertEqual(snapshot.meetings.count, 0, "disabled meeting rows should stay empty")
            assertEqual(snapshot.dictations.map(\.text), ["same day newer row", "same day older row"], "same-day dictations should stay newest-first")
            assertEqual(snapshot.dictationCounts.total, 0, "disabled counts should stay empty")
        }
    }

    await runSuite("RecentCaptureLoader fills dictation limit after skipping non-dictation markdown") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let dictationsRoot = captureRoot.appendingPathComponent("dictations", isDirectory: true)
            let unrelatedMarkdown = dictationsRoot.appendingPathComponent("notes.md", isDirectory: false)

            try? """
            # Not a dictation day

            ## 9:00 AM - Looks similar

            Words: 100

            This is not a saved dictation artifact.
            """.write(to: unrelatedMarkdown, atomically: true, encoding: .utf8)
            _ = try? DictationTranscriptStore.save(
                text: "newer valid dictation row",
                sourceApp: nil,
                delivery: .copied,
                createdAt: recentLoaderDate("2026-05-31T14:00:00Z"),
                directory: dictationsRoot
            )
            _ = try? DictationTranscriptStore.save(
                text: "older valid dictation row",
                sourceApp: nil,
                delivery: .pasted,
                createdAt: recentLoaderDate("2026-05-30T14:00:00Z"),
                directory: dictationsRoot
            )

            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: 2,
                meetingLimit: 0,
                includeDictationCounts: true
            )

            assertEqual(snapshot.dictations.map(\.text), ["newer valid dictation row", "older valid dictation row"], "non-dictation markdown should not consume dictation slots")
            assertEqual(snapshot.dictationCounts.total, 2, "non-dictation markdown should not inflate dictation counts")
            assertEqual(snapshot.dictationCounts.totalWords, 8, "counts should only include real dictation rows")
        }
    }

    await runSuite("RecentCaptureLoader fills dictation limit after an empty newer day file") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let dictationsRoot = captureRoot.appendingPathComponent("dictations", isDirectory: true)
            let emptyDayFile = dictationsRoot.appendingPathComponent("Dictations_2026-06-02.md", isDirectory: false)

            try? """
            ---
            title: "Dictations for June 2, 2026"
            date: 2026-06-02
            capture_type: dictation_day
            ---

            # Dictations for June 2, 2026
            """.write(to: emptyDayFile, atomically: true, encoding: .utf8)
            _ = try? DictationTranscriptStore.save(
                text: "filled newer dictation row",
                sourceApp: nil,
                delivery: .copied,
                createdAt: recentLoaderDate("2026-06-01T14:00:00Z"),
                directory: dictationsRoot
            )
            _ = try? DictationTranscriptStore.save(
                text: "filled older dictation row",
                sourceApp: nil,
                delivery: .pasted,
                createdAt: recentLoaderDate("2026-05-31T14:00:00Z"),
                directory: dictationsRoot
            )

            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: 2,
                meetingLimit: 0,
                includeDictationCounts: true
            )

            assertEqual(snapshot.dictations.map(\.text), ["filled newer dictation row", "filled older dictation row"], "empty newer day files should not starve older valid dictations")
            assertEqual(snapshot.dictationCounts.total, 2, "empty dictation day files should count as zero entries")
        }
    }

    await runSuite("RecentCaptureLoader fills dictation limit after skipping unreadable newer day files") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let dictationsRoot = captureRoot.appendingPathComponent("dictations", isDirectory: true)
            let unreadableDayFile = dictationsRoot.appendingPathComponent("Dictations_2026-06-03.md", isDirectory: false)

            try? """
            # Dictations for June 3, 2026

            ## 9:00 AM - Unreadable synthetic row

            Words: 4

            hidden unreadable synthetic row
            """.write(to: unreadableDayFile, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableDayFile.path)
            _ = try? DictationTranscriptStore.save(
                text: "readable newer dictation row",
                sourceApp: nil,
                delivery: .copied,
                createdAt: recentLoaderDate("2026-06-02T14:00:00Z"),
                directory: dictationsRoot
            )
            _ = try? DictationTranscriptStore.save(
                text: "readable older dictation row",
                sourceApp: nil,
                delivery: .pasted,
                createdAt: recentLoaderDate("2026-06-01T14:00:00Z"),
                directory: dictationsRoot
            )

            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: 2,
                meetingLimit: 0,
                includeDictationCounts: true
            )

            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadableDayFile.path)
            assertEqual(snapshot.dictations.map(\.text), ["readable newer dictation row", "readable older dictation row"], "unreadable newer day files should fail closed without starving older valid dictations")
            assertEqual(snapshot.dictationCounts.total, 2, "unreadable dictation day files should not inflate counts")
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

    await runSuite("RecentCaptureLoader ignores unrelated capture root siblings") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
            let dictationsRoot = captureRoot.appendingPathComponent("dictations", isDirectory: true)

            try? "not a capture artifact".write(
                to: captureRoot.appendingPathComponent("README.md", isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
            try? FileManager.default.createDirectory(
                at: captureRoot.appendingPathComponent("scratch", isDirectory: true),
                withIntermediateDirectories: true
            )
            try? writeRecentLoaderMeeting(
                title: "Visible Meeting",
                date: recentLoaderDate("2026-05-25T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("meeting.md", isDirectory: false)
            )
            _ = try? DictationTranscriptStore.save(
                text: "visible dictation row",
                sourceApp: nil,
                delivery: .copied,
                createdAt: recentLoaderDate("2026-05-25T13:00:00Z"),
                directory: dictationsRoot
            )

            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: 1,
                meetingLimit: 1,
                includeDictationCounts: true
            )

            assertEqual(snapshot.meetings.map(\.title), ["Visible Meeting"], "capture-root clutter should not hide valid meeting rows")
            assertEqual(snapshot.dictations.map(\.text), ["visible dictation row"], "capture-root clutter should not hide valid dictations")
            assertEqual(snapshot.dictationCounts.total, 1, "capture-root clutter should not affect dictation counts")
        }
    }

    await runSuite("RecentCaptureLoader loads dictations when the meetings path is a file") {
        await withTemporaryRecentCaptureLibrary(createMeetingsDirectory: false) { captureRoot in
            let meetingsPath = captureRoot.appendingPathComponent("meetings", isDirectory: false)
            let dictationsRoot = captureRoot.appendingPathComponent("dictations", isDirectory: true)
            FileManager.default.createFile(atPath: meetingsPath.path, contents: Data("not a directory".utf8))
            _ = try? DictationTranscriptStore.save(
                text: "resilient dictation row",
                sourceApp: nil,
                delivery: .copied,
                createdAt: recentLoaderDate("2026-05-26T13:00:00Z"),
                directory: dictationsRoot
            )

            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: 1,
                meetingLimit: 1,
                includeDictationCounts: true
            )

            assertEqual(snapshot.meetings.count, 0, "file-shaped meeting storage should fail closed")
            assertEqual(snapshot.dictations.map(\.text), ["resilient dictation row"], "dictations should still load when meeting storage is damaged")
            assertEqual(snapshot.dictationCounts.total, 1, "dictation counts should still load when meeting storage is damaged")
        }
    }

    await runSuite("RecentCaptureLoader loads meetings when the dictations path is a file") {
        await withTemporaryRecentCaptureLibrary(createDictationsDirectory: false) { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
            let dictationsPath = captureRoot.appendingPathComponent("dictations", isDirectory: false)
            FileManager.default.createFile(atPath: dictationsPath.path, contents: Data("not a directory".utf8))
            try? writeRecentLoaderMeeting(
                title: "Resilient Meeting Row",
                date: recentLoaderDate("2026-05-26T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("meeting.md", isDirectory: false)
            )

            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: 1,
                meetingLimit: 1,
                includeDictationCounts: true
            )

            assertEqual(snapshot.meetings.map(\.title), ["Resilient Meeting Row"], "meetings should still load when dictation storage is damaged")
            assertEqual(snapshot.dictations.count, 0, "file-shaped dictation storage should fail closed for rows")
            assertEqual(snapshot.dictationCounts.total, 0, "file-shaped dictation storage should fail closed for counts")
        }
    }

    await runSuite("RecentCaptureLoader count-only loads fail closed when the dictations path is a file") {
        await withTemporaryRecentCaptureLibrary(createDictationsDirectory: false) { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
            let dictationsPath = captureRoot.appendingPathComponent("dictations", isDirectory: false)
            FileManager.default.createFile(atPath: dictationsPath.path, contents: Data("not a directory".utf8))
            try? writeRecentLoaderMeeting(
                title: "Hidden By Count Only",
                date: recentLoaderDate("2026-05-27T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("meeting.md", isDirectory: false)
            )

            let snapshot = await RecentCaptureLoader.load(
                dictationLimit: 0,
                meetingLimit: 0,
                includeDictationCounts: true
            )

            assertEqual(snapshot.meetings.count, 0, "count-only loads should not return meeting rows")
            assertEqual(snapshot.dictations.count, 0, "count-only loads should not return dictation rows")
            assertEqual(snapshot.dictationCounts.total, 0, "file-shaped dictation storage should report zero total entries")
            assertEqual(snapshot.dictationCounts.totalWords, 0, "file-shaped dictation storage should report zero dictated words")
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

    await runSuite("RecentMeetingsScanner attaches local summary previews without counting summary files as rows") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
            let transcriptURL = meetingsRoot.appendingPathComponent("launch.md", isDirectory: false)

            try? writeRecentLoaderMeeting(
                title: "Quick notes",
                date: recentLoaderDate("2026-05-24T14:00:00Z"),
                to: transcriptURL
            )
            try? writeRecentLoaderSummary(
                title: "Launch Pricing Review",
                summary: "Team agreed to keep launch pricing simple.",
                sourceTranscript: transcriptURL.lastPathComponent,
                to: LocalMeetingSummaryStore.summaryURL(for: transcriptURL)
            )
            setRecentLoaderFileDate(
                recentLoaderDate("2026-05-25T14:00:00Z"),
                at: LocalMeetingSummaryStore.summaryURL(for: transcriptURL)
            )

            let meetings = RecentMeetingsScanner.loadRecent(limit: 3)

            assertEqual(meetings.count, 1, "summary markdown should enhance its meeting row, not become a second row")
            assertEqual(meetings.first?.title, "Quick notes", "original meeting title should stay available")
            assertEqual(meetings.first?.displayTitle, "Launch Pricing Review", "generated title should drive Home display")
            assertEqual(
                meetings.first?.summaryPreview?.summary,
                "Team agreed to keep launch pricing simple.",
                "scanner should attach the local summary preview"
            )
        }
    }

    await runSuite("RecentMeetingsScanner reads embedded local summaries and meeting end times") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
            let transcriptURL = meetingsRoot.appendingPathComponent("embedded-launch.md", isDirectory: false)
            let recordedAt = recentLoaderDate("2026-05-24T14:00:00Z")
            let baseMarkdown = """
            ---
            title: "Quick notes"
            capture_type: meeting
            date: "\(recentLoaderFormat(recordedAt, "yyyy-MM-dd"))"
            time: "\(recentLoaderFormat(recordedAt, "HH:mm:ss"))"
            duration: "10:00"
            ---

            # Quick notes

            ## Transcript

            **00:01** [Mic/Justin]
            We should keep launch pricing simple.
            """
            let enhancedMarkdown = LocalMeetingSummaryMarkdownUpdater.markdown(
                byApplying: sampleRecentCaptureLocalSummarySections(),
                to: baseMarkdown,
                configuration: .m1Optimized(physicalMemoryBytes: 16 * 1024 * 1024 * 1024),
                generatedAt: recentLoaderDate("2026-05-24T14:20:00Z"),
                chunkCount: 1
            )

            try? enhancedMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
            setRecentLoaderFileDate(recordedAt, at: transcriptURL)

            let meetings = RecentMeetingsScanner.loadRecent(limit: 3)
            let meeting = meetings.first

            assertEqual(meetings.count, 1, "embedded summaries should not create an extra row")
            assertEqual(meeting?.displayTitle, "Launch Pricing Review", "embedded generated title should drive Home display")
            assertEqual(meeting?.summaryPreview?.summary, "Team agreed to keep launch pricing simple.", "embedded summary should attach to the row")
            assertNotNil(meeting?.startDate, "scanner should expose the meeting start time")
            assertNotNil(meeting?.endDate, "scanner should expose the meeting end time")
            assertEqual(
                meeting?.endDate?.timeIntervalSince(meeting?.startDate ?? Date.distantPast),
                600,
                "scanner should derive end time from frontmatter duration"
            )
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

    await runSuite("RecentMeetingsScanner orders rows by filesystem recency") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
            let freshFileDate = recentLoaderDate("2026-05-29T14:00:00Z")
            let olderFileDate = recentLoaderDate("2026-05-28T14:00:00Z")

            try? writeRecentLoaderMeeting(
                title: "Fresh Copied Meeting",
                date: recentLoaderDate("2026-05-01T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("fresh-copy.md", isDirectory: false),
                fileDate: freshFileDate
            )
            try? writeRecentLoaderMeeting(
                title: "Older Newer-Frontmatter Meeting",
                date: recentLoaderDate("2026-05-30T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("older-frontmatter.md", isDirectory: false),
                fileDate: olderFileDate
            )

            let meetings = RecentMeetingsScanner.loadRecent(limit: 2)

            assertEqual(meetings.map(\.title), ["Fresh Copied Meeting", "Older Newer-Frontmatter Meeting"], "Home recency should follow filesystem dates, not stale or future transcript metadata")
            assertEqual(meetings.first?.date, freshFileDate, "meeting row dates should use the scanner date that controls ordering")
        }
    }

    await runSuite("RecentMeetingsScanner fills the limit after skipping dictation markdown in meetings storage") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
            let dictationMarkdown = meetingsRoot.appendingPathComponent("Dictations_2026-05-31.md", isDirectory: false)

            try? """
            ---
            title: "Dictations for May 31, 2026"
            date: 2026-05-31
            capture_type: dictation_day
            ---

            # Dictations for May 31, 2026
            """.write(to: dictationMarkdown, atomically: true, encoding: .utf8)
            setRecentLoaderFileDate(recentLoaderDate("2026-05-31T14:00:00Z"), at: dictationMarkdown)
            try? writeRecentLoaderMeeting(
                title: "Valid Meeting C",
                date: recentLoaderDate("2026-05-30T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("valid-c.md", isDirectory: false)
            )
            try? writeRecentLoaderMeeting(
                title: "Valid Meeting D",
                date: recentLoaderDate("2026-05-29T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("valid-d.md", isDirectory: false)
            )

            let meetings = RecentMeetingsScanner.loadRecent(limit: 2)

            assertEqual(meetings.map(\.title), ["Valid Meeting C", "Valid Meeting D"], "non-meeting markdown in the meetings folder should not consume Home meeting slots")
        }
    }

    await runSuite("RecentMeetingsScanner fills the limit after skipping unreadable newer candidates") {
        await withTemporaryRecentCaptureLibrary { captureRoot in
            let meetingsRoot = captureRoot.appendingPathComponent("meetings", isDirectory: true)
            let unreadableMeeting = meetingsRoot.appendingPathComponent("unreadable.md", isDirectory: false)

            try? writeRecentLoaderMeeting(
                title: "Unreadable Meeting",
                date: recentLoaderDate("2026-05-31T14:00:00Z"),
                to: unreadableMeeting
            )
            try? FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableMeeting.path)
            try? writeRecentLoaderMeeting(
                title: "Valid Meeting E",
                date: recentLoaderDate("2026-05-30T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("valid-e.md", isDirectory: false)
            )
            try? writeRecentLoaderMeeting(
                title: "Valid Meeting F",
                date: recentLoaderDate("2026-05-29T14:00:00Z"),
                to: meetingsRoot.appendingPathComponent("valid-f.md", isDirectory: false)
            )

            let meetings = RecentMeetingsScanner.loadRecent(limit: 2)

            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadableMeeting.path)
            assertEqual(meetings.map(\.title), ["Valid Meeting E", "Valid Meeting F"], "unreadable newer markdown should fail closed without starving valid meeting rows")
        }
    }
}

private func sampleRecentMeetingTitleItem(
    title: String,
    summaryPreview: RecentMeetingSummaryPreview?
) -> RecentMeetingItem {
    RecentMeetingItem(
        title: title,
        date: Date(timeIntervalSinceReferenceDate: 10),
        startDate: nil,
        endDate: nil,
        transcriptURL: FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-meeting.md"),
        audio: nil,
        speakerStatus: .ready,
        summaryPreview: summaryPreview
    )
}

private func sampleRecentMeetingSummaryPreview(title: String?) -> RecentMeetingSummaryPreview {
    RecentMeetingSummaryPreview(
        title: title,
        summary: "Synthetic summary.",
        sections: [],
        url: FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-summary.md")
    )
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
    fileDate: Date? = nil,
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
    setRecentLoaderFileDate(fileDate ?? date, at: url)
}

private func writeRecentLoaderSummary(
    title: String,
    summary: String,
    sourceTranscript: String,
    to url: URL
) throws {
    let markdown = """
    ---
    capture_type: meeting_summary
    title: "Quick notes"
    summary_title: "\(title)"
    source_transcript: "\(sourceTranscript)"
    summary_model: mlx-community/gemma-4-12B-it-4bit
    summary_runtime: mlx-vlm
    summary_profile: m1-low-memory
    summary_chunk_count: 1
    created_at: 2026-05-24T14:00:00Z
    ---

    # Title
    \(title)

    # Summary
    \(summary)

    # Decisions
    None found.
    """
    try markdown.write(to: url, atomically: true, encoding: .utf8)
}

private func sampleRecentCaptureLocalSummarySections() -> LocalMeetingSummarySections {
    LocalMeetingSummarySections(
        title: "Launch Pricing Review",
        summary: "Team agreed to keep launch pricing simple.",
        decisions: "Keep the first version small.",
        actionItems: "Alex will check pricing language before Friday.",
        openQuestions: "Whether enterprise pricing needs a separate page.",
        risksOrFollowUps: "Pricing copy could overpromise the first version.",
        accuracyNotes: "Based only on the transcript."
    )
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
