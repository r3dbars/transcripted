import Foundation

private enum E2ESmokeError: Error, CustomStringConvertible {
    case failed(String)

    var description: String {
        switch self {
        case .failed(let message):
            return message
        }
    }
}

@main
struct TranscriptedE2ESmoke {
    static func main() async {
        do {
            try await TranscriptedE2ESmokeHarness().run()
            print("[e2e] OK - deterministic capture contract passed")
        } catch {
            fputs("[e2e] FAIL: \(error)\n", stderr)
            exit(1)
        }
    }
}

private final class TranscriptedE2ESmokeHarness {
    private let fileManager = FileManager.default
    private let runRoot: URL

    init() {
        if let configuredRoot = ProcessInfo.processInfo.environment["TRANSCRIPTED_E2E_ROOT"],
           !configuredRoot.isEmpty {
            runRoot = URL(fileURLWithPath: configuredRoot, isDirectory: true).standardizedFileURL
        } else {
            runRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("TranscriptedE2ESmoke-\(UUID().uuidString)", isDirectory: true)
        }
    }

    func run() async throws {
        try fileManager.createDirectory(at: runRoot, withIntermediateDirectories: true)
        UserDefaults.standard.removeObject(forKey: TranscriptedStoragePreferences.captureLibraryLocationKey)

        let captureLibrary = fileManager.transcriptedDefaultCaptureLibraryDir
        let meetingsDir = captureLibrary.appendingPathComponent("meetings", isDirectory: true)
        let dictationsDir = captureLibrary.appendingPathComponent("dictations", isDirectory: true)
        let stateDir = fileManager.transcriptedStateDir
        let logsDir = fileManager.transcriptedLogsDir
        try [meetingsDir, dictationsDir, stateDir, logsDir].forEach {
            try fileManager.createDirectory(at: $0, withIntermediateDirectories: true)
        }

        let fixtures = try await writeCaptureFixtures(
            meetingsDir: meetingsDir,
            dictationsDir: dictationsDir,
            stateDir: stateDir,
            logsDir: logsDir
        )

        try await verifyAppFacingDiscovery(fixtures: fixtures)
        try verifyHomePreview(fixtures: fixtures)
        try verifyLocalSummaryArtifact(fixtures: fixtures)
        try verifyImportedAudioArtifact(fixtures: fixtures)
        try verifyMCPFacingDiscovery(fixtures: fixtures, captureLibrary: captureLibrary)
        try verifyFailedMeetingArtifact(fixtures: fixtures)
        try verifySupportDiagnosticsPrivacy(fixtures: fixtures, logsDir: logsDir)
        try verifyDeleteRemovesCanonicalArtifacts(fixtures: fixtures, captureLibrary: captureLibrary)
    }

    private func writeCaptureFixtures(
        meetingsDir: URL,
        dictationsDir: URL,
        stateDir: URL,
        logsDir: URL
    ) async throws -> SmokeFixtures {
        let meetingURL = meetingsDir.appendingPathComponent("Customer Launch Sync.md", isDirectory: false)
        let meetingMarkdown = """
        ---
        title: "Customer Launch Sync"
        date: 2026-05-18
        time: 09:30:00
        duration: "00:02:30"
        processing_time: "0.4s"
        transcription_engine: parakeet_local
        diarization_engine: pyannote_offline
        sources: [mic, system_audio]
        mic_utterances: 1
        system_utterances: 2
        mic_speakers: 1
        system_speakers: 1
        total_word_count: 36
        speakers:
          - id: "0"
            db_id: "11111111-1111-1111-1111-111111111111"
            name: "Jordan Lee"
            confidence: high
            source: db_scan
        ---

        # Customer Launch Sync

        Recorded May 18, 2026 at 9:30 AM  -  2 min, 30 sec  -  36 words  -  3 turns

        ## Transcript

        **00:00**  [Mic/You]
        The launch checklist should keep the download verification first.

        **00:42**  [System/Jordan Lee]
        I will confirm Sparkle and Homebrew are both pointing at the same release.

        **01:20**  [System/Jordan Lee]
        After that, we can send the customer note.
        """
        try meetingMarkdown.write(to: meetingURL, atomically: true, encoding: .utf8)

        let summaryURL = LocalMeetingSummaryStore.summaryURL(for: meetingURL)
        let summaryMarkdown = """
        ---
        capture_type: meeting_summary
        source_transcript: "\(meetingURL.lastPathComponent)"
        summary_title: "Launch Action Review"
        generated_at: "2026-05-18T14:08:00Z"
        model: "synthetic-gemma-fixture"
        ---

        # Title
        Launch Action Review

        # Summary
        The launch review stayed focused on release verification and customer follow-up.

        # Decisions
        Keep Sparkle and Homebrew verification before the customer note.

        # Action Items
        Jordan will confirm both release surfaces.

        # Open Questions
        None found.

        # Risks or Follow-ups
        The customer note should wait until install paths agree.

        # Accuracy Notes
        Synthetic E2E fixture only.
        """
        try summaryMarkdown.write(to: summaryURL, atomically: true, encoding: .utf8)

        let importedMeetingURL = meetingsDir.appendingPathComponent("Imported Partner Brief.md", isDirectory: false)
        let importedMeetingMarkdown = """
        ---
        capture_id: "22222222-2222-2222-2222-222222222222"
        transcript_id: "22222222-2222-2222-2222-222222222222"
        title: "Imported Partner Brief"
        capture_type: meeting
        date: 2026-05-17
        time: 16:15:00
        duration: "00:01:20"
        processing_time: "0.3s"
        transcription_engine: parakeet_local
        diarization_engine: pyannote_offline
        sources: [system_audio]
        mic_utterances: 0
        system_utterances: 2
        mic_speakers: 0
        system_speakers: 1
        total_word_count: 20
        speakers:
          - id: "0"
            channel: system
            db_id: "22222222-2222-2222-2222-222222222223"
            name: "Maya Chen"
            confidence: high
            source: db_scan
        ---

        # Imported Partner Brief

        Recorded May 17, 2026 at 4:15 PM  -  1 min, 20 sec  -  20 words  -  2 turns

        ## Transcript

        **00:00**  [System/Maya Chen]
        The imported recording should keep one canonical meeting note.

        **00:36**  [System/Maya Chen]
        The retained source audio should stay attached as recording audio.
        """
        try importedMeetingMarkdown.write(to: importedMeetingURL, atomically: true, encoding: .utf8)

        let dictationURL = dictationsDir.appendingPathComponent("Dictations_2026-05-18.md", isDirectory: false)
        let dictationMarkdown = """
        ---
        title: "Dictations for May 18, 2026"
        date: 2026-05-18
        capture_type: dictation_day
        ---

        # Dictations for May 18, 2026

        ## 8:45 AM - Verify the release checklist

        Entry ID: `dictation-20260518-084500-000`
        Captured: 2026-05-18T13:45:00.000Z
        Source app: Codex E2E
        Bundle ID: `app.transcripted.e2e`
        Delivery: pasted
        Words: 9
        Characters: 62

        Verify the release checklist before touching the signed build.

        ## 9:05 AM - Recent context proof

        Entry ID: `dictation-20260518-090500-000`
        Captured: 2026-05-18T14:05:00.000Z
        Source app: Codex E2E
        Bundle ID: `app.transcripted.e2e`
        Delivery: copied
        Words: 10
        Characters: 72

        Confirm the recent context feed can find this dictation.
        """
        try dictationMarkdown.write(to: dictationURL, atomically: true, encoding: .utf8)

        let audioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: meetingURL)
        try fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        let micAudioURL = audioDirectory.appendingPathComponent("microphone.m4a", isDirectory: false)
        let systemAudioURL = audioDirectory.appendingPathComponent("system_audio.m4a", isDirectory: false)
        try writeTinyAudioFixture(to: micAudioURL, amplitude: 0.20)
        try writeTinyAudioFixture(to: systemAudioURL, amplitude: 0.35)

        let importedAudioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: importedMeetingURL)
        try fileManager.createDirectory(at: importedAudioDirectory, withIntermediateDirectories: true)
        let importedAudioURL = importedAudioDirectory.appendingPathComponent("recording.m4a", isDirectory: false)
        try writeTinyAudioFixture(to: importedAudioURL, amplitude: 0.28)

        let failedQueueURL = stateDir.appendingPathComponent("failed_transcriptions.json", isDirectory: false)
        try await writeFailedQueueWithProductionManager(
            failedQueueURL: failedQueueURL,
            meetingsDir: meetingsDir,
            stateDir: stateDir,
            retainedAudioDir: audioDirectory,
            micAudioURL: micAudioURL,
            systemAudioURL: systemAudioURL
        )

        let eventLogURL = logsDir.appendingPathComponent("events.jsonl", isDirectory: false)
        let sanitizedEvent = AnalyticsPayloadSanitizer.sanitizeProperties(
            [
                "duration_bucket": "1_4m",
                "failure_kind": "Retry checked \(meetingURL.path) with token=sk-e2esecret",
                "transcript_text": "private launch transcript sentence",
            ],
            allowedKeys: ["duration_bucket", "failure_kind", "transcript_text"]
        )
        let eventData = try JSONSerialization.data(
            withJSONObject: sanitizedEvent,
            options: [.sortedKeys]
        )
        try eventData.write(to: eventLogURL)

        let fixtureDate = try fixedDate("2026-05-18T14:05:00Z")
        try fileManager.setAttributes(
            [.creationDate: fixtureDate, .modificationDate: fixtureDate],
            ofItemAtPath: meetingURL.path
        )
        try fileManager.setAttributes(
            [.creationDate: fixtureDate.addingTimeInterval(-120), .modificationDate: fixtureDate.addingTimeInterval(-120)],
            ofItemAtPath: importedMeetingURL.path
        )
        try fileManager.setAttributes(
            [.creationDate: fixtureDate, .modificationDate: fixtureDate],
            ofItemAtPath: dictationURL.path
        )
        try fileManager.setAttributes(
            [.creationDate: fixtureDate.addingTimeInterval(180), .modificationDate: fixtureDate.addingTimeInterval(180)],
            ofItemAtPath: summaryURL.path
        )

        return SmokeFixtures(
            meetingsDir: meetingsDir,
            dictationsDir: dictationsDir,
            meetingURL: meetingURL,
            summaryURL: summaryURL,
            importedMeetingURL: importedMeetingURL,
            dictationURL: dictationURL,
            micAudioURL: micAudioURL,
            systemAudioURL: systemAudioURL,
            importedAudioURL: importedAudioURL,
            failedQueueURL: failedQueueURL,
            eventLogURL: eventLogURL,
            meetingMarkdown: meetingMarkdown,
            summaryMarkdown: summaryMarkdown,
            importedMeetingMarkdown: importedMeetingMarkdown,
            dictationMarkdown: dictationMarkdown
        )
    }

    private func verifyAppFacingDiscovery(fixtures: SmokeFixtures) async throws {
        let snapshot = await RecentCaptureLoader.load(
            dictationLimit: 5,
            meetingLimit: 5,
            includeDictationCounts: true
        )

        try expect(snapshot.meetings.count == 2, "RecentCaptureLoader should discover captured and imported meetings")
        try expect(snapshot.dictations.count == 2, "RecentCaptureLoader should discover both dictation entries")
        try expect(snapshot.dictationCounts.total == 2, "Dictation counts should include both entries")
        try expect(snapshot.dictationCounts.totalWords == 19, "Dictation counts should include saved word totals")

        let meeting = try unwrap(
            snapshot.meetings.first { $0.transcriptURL.standardizedFileURL == fixtures.meetingURL.standardizedFileURL },
            "Captured meeting should be present"
        )
        try expect(meeting.title == "Customer Launch Sync", "Recent meeting title should come from frontmatter")
        try expect(meeting.displayTitle == "Launch Action Review", "Recent meeting display title should come from its attached summary")
        try expect(meeting.transcriptURL.standardizedFileURL == fixtures.meetingURL.standardizedFileURL, "Recent meeting should point at the saved markdown")
        try expect(meeting.summaryPreview?.url.standardizedFileURL == fixtures.summaryURL.standardizedFileURL, "Recent meeting summary preview should point at the matching summary artifact")
        try expect(meeting.speakerStatus == .ready, "Named meeting speakers should be ready")
        try expect(meeting.audio?.urls.count == 2, "Recent meeting should attach retained mic and system audio")

        let importedMeeting = try unwrap(
            snapshot.meetings.first { $0.transcriptURL.standardizedFileURL == fixtures.importedMeetingURL.standardizedFileURL },
            "Imported meeting should be present"
        )
        try expect(importedMeeting.title == "Imported Partner Brief", "Imported meeting title should come from frontmatter")
        try expect(importedMeeting.displayTitle == "Imported Partner Brief", "Imported meeting should keep its canonical title without a generated summary")
        try expect(importedMeeting.audio?.urls.map(\.lastPathComponent) == ["recording.m4a"], "Imported meeting should attach retained single-file recording audio")

        let latestDictation = try unwrap(snapshot.dictations.first, "Recent dictation should be present")
        try expect(latestDictation.title == "Recent context proof", "Recent dictation title should be parsed")
        try expect(latestDictation.text.contains("recent context feed"), "Recent dictation body should be readable")
    }

    private func verifyHomePreview(fixtures: SmokeFixtures) throws {
        let preview = HomeMeetingPreviewContent.make(from: fixtures.meetingMarkdown)
        try expect(preview.transcriptLines.count == 3, "Home preview should parse all meeting transcript rows")
        try expect(preview.transcriptLines.first?.speaker == "Mic/You", "Home preview should keep source and speaker")
        try expect(
            preview.transcriptLines.first?.text.contains("download verification") == true,
            "Home preview should include readable transcript text"
        )
        try expect(!preview.fallbackText.contains("transcript_id:"), "Home preview should not surface YAML-only metadata")
    }

    private func verifyLocalSummaryArtifact(fixtures: SmokeFixtures) throws {
        try expect(fileManager.fileExists(atPath: fixtures.summaryURL.path), "Local summary artifact should be saved beside the meeting transcript")
        try expect(
            fixtures.summaryURL.lastPathComponent == "Customer Launch Sync.summary.md",
            "Local summary artifact should use the canonical transcript basename"
        )

        let frontmatter = try unwrap(
            TranscriptFrontmatter.document(in: fixtures.summaryMarkdown),
            "Local summary artifact should have frontmatter"
        )
        try expect(frontmatter.values["capture_type"] == "meeting_summary", "Local summary artifact should not masquerade as a meeting transcript")
        try expect(frontmatter.values["source_transcript"] == fixtures.meetingURL.lastPathComponent, "Local summary artifact should point at the canonical source transcript")

        let meetings = RecentMeetingsScanner.loadRecent(limit: 5, directory: fixtures.meetingsDir)
        let capturedRows = meetings.filter { $0.transcriptURL.standardizedFileURL == fixtures.meetingURL.standardizedFileURL }
        try expect(capturedRows.count == 1, "Local summary artifacts should not create duplicate Home meeting rows")
        let meeting = try unwrap(capturedRows.first, "Recent meeting should remain visible with a summary")
        try expect(meeting.transcriptURL.standardizedFileURL == fixtures.meetingURL.standardizedFileURL, "Home row should still point at the canonical saved meeting markdown")
        try expect(meeting.summaryPreview?.summary.contains("release verification") == true, "Home row should expose the matching local summary preview")
    }

    private func verifyImportedAudioArtifact(fixtures: SmokeFixtures) throws {
        let frontmatter = try unwrap(
            TranscriptFrontmatter.document(in: fixtures.importedMeetingMarkdown),
            "Imported meeting should have frontmatter"
        )
        try expect(frontmatter.values["capture_type"] == "meeting", "Imported audio should still save as a meeting artifact")
        try expect(frontmatter.values["sources"] == "[system_audio]", "Imported audio should record the single source channel")
        try expect(frontmatter.values["mic_utterances"] == "0", "Imported audio should not invent mic turns")

        let meetings = RecentMeetingsScanner.loadRecent(limit: 5, directory: fixtures.meetingsDir)
        let imported = try unwrap(
            meetings.first { $0.transcriptURL.standardizedFileURL == fixtures.importedMeetingURL.standardizedFileURL },
            "Imported meeting should scan as one canonical Home row"
        )
        try expect(imported.audio?.urls.map(\.lastPathComponent) == ["recording.m4a"], "Imported recording audio should be attached to its canonical row")
        try expect(imported.audio?.retranscriptionInput?.micURL == nil, "Single-file imported audio should not invent a mic retranscription input")
        try expect(
            imported.audio?.retranscriptionInput?.systemURL.standardizedFileURL == fixtures.importedAudioURL.standardizedFileURL,
            "Single-file imported audio should remain the saved-audio retranscription input"
        )
    }

    private func verifyMCPFacingDiscovery(fixtures: SmokeFixtures, captureLibrary: URL) throws {
        let directories = TranscriptedDataDirectories.resolve(environment: [
            "TRANSCRIPTED_DATA_DIR": captureLibrary.path,
            "TRANSCRIPTED_INDEX_DIR": runRoot.appendingPathComponent("mcp-index", isDirectory: true).path,
        ])
        try expect(
            directories.meetingsDir.standardizedFileURL == fixtures.meetingsDir.standardizedFileURL,
            "MCP directory resolver should follow the capture-library meetings folder"
        )
        try expect(
            directories.dictationsDir.standardizedFileURL == fixtures.dictationsDir.standardizedFileURL,
            "MCP directory resolver should follow the capture-library dictations folder"
        )

        let transcript = try unwrap(
            TranscriptLoader.loadMeeting(fixtures.meetingURL),
            "MCP loader should read meeting markdown"
        )
        try expect(transcript.utterances.count == 3, "MCP loader should parse meeting utterances")
        try expect(
            transcript.speakers.contains { $0.name == "Jordan Lee" },
            "MCP loader should parse named remote speakers"
        )

        let dictationDay = try unwrap(
            TranscriptLoader.loadDictationDay(fixtures.dictationURL),
            "MCP loader should read dictation markdown"
        )
        try expect(dictationDay.entryCount == 2, "MCP loader should parse dictation entries")

        try fileManager.createDirectory(at: directories.indexDir, withIntermediateDirectories: true)
        let index = try TranscriptIndex(indexDir: directories.indexDir)
        try withLogsSuppressed {
            try index.reconcile(
                meetingDirs: directories.meetingDirs,
                dictationDirs: directories.dictationDirs
            )
        }

        let meetings = try index.listMeetings(count: 5, dateFrom: "2026-05-17", dateTo: "2026-05-18")
        try expect(meetings.count == 2, "MCP index should list captured and imported meetings")
        try expect(meetings.contains { $0.speakers.contains { $0.name == "Jordan Lee" } }, "MCP index should list captured meeting speakers")
        try expect(
            meetings.contains {
                $0.filename == fixtures.importedMeetingURL.deletingPathExtension().lastPathComponent
                    && $0.speakers.contains { $0.name == "Maya Chen" }
            },
            "MCP index should list imported meeting artifacts"
        )

        let dictations = try index.listDictationDays(count: 5, dateFrom: "2026-05-18", dateTo: "2026-05-18")
        try expect(dictations.count == 1, "MCP index should list the saved dictation day")
        try expect(dictations.first?.entryCount == 2, "MCP index should expose dictation entry counts")

        let recent = try index.listRecentContext(kind: .all, count: 5)
        try expect(recent.items.contains { $0.kind == .meeting }, "MCP recent context should include meetings")
        try expect(recent.items.contains { $0.kind == .dictation }, "MCP recent context should include dictations")

        let meetingSearch = try index.searchContext(
            query: "Sparkle",
            speaker: nil,
            kind: .all,
            dateFrom: "2026-05-18",
            dateTo: "2026-05-18"
        )
        try expect(meetingSearch.results.contains { $0.kind == .meeting }, "MCP search should find meeting text")

        let dictationSearch = try index.searchContext(
            query: "release checklist",
            speaker: nil,
            kind: .dictation,
            dateFrom: "2026-05-18",
            dateTo: "2026-05-18"
        )
        try expect(dictationSearch.results.count == 1, "MCP search should find dictation text")
    }

    private func verifyFailedMeetingArtifact(fixtures: SmokeFixtures) throws {
        let data = try Data(contentsOf: fixtures.failedQueueURL)
        let decoded = try JSONDecoder.iso8601.decode([FailedTranscription].self, from: data)

        try expect(decoded.count == 1, "Failed meeting queue should contain one representative artifact")
        let failed = try unwrap(decoded.first, "Failed meeting artifact should decode")
        try expect(failed.micAudioURL == fixtures.micAudioURL, "Failed meeting artifact should keep mic audio URL")
        try expect(failed.systemAudioURL == fixtures.systemAudioURL, "Failed meeting artifact should keep system audio URL")
        try expect(failed.audioFilesExist(), "Production failed transcription model should confirm retained audio exists")
        try expect(failed.isRetryable, "Temporary failed meeting fixture should stay retryable")
        try expect(fileManager.fileExists(atPath: failed.micAudioURL.path), "Failed meeting mic audio placeholder should exist")
        try expect(
            failed.systemAudioURL.map { fileManager.fileExists(atPath: $0.path) } == true,
            "Failed meeting system audio placeholder should exist"
        )
    }

    private func verifySupportDiagnosticsPrivacy(fixtures: SmokeFixtures, logsDir: URL) throws {
        let secretMeetingTitle = "Secret Phoenix Pricing Call"
        let secretSpeaker = "Avery Confidential"
        let secretEmail = "avery@example.com"
        let secretToken = "sk-e2esecret"
        let secretTranscript = "private launch transcript sentence"

        let diagnostics = SupportDiagnosticsBundle.text(
            snapshot: SupportDiagnosticsSnapshot(
                appVersion: "9.9.9",
                buildVersion: "999",
                osVersion: "Version 26.0",
                crashReportingAvailable: true,
                crashReportingEnabled: true,
                analyticsAvailable: true,
                analyticsEnabled: true,
                microphoneStatus: "authorized",
                systemAudioRecordingGranted: true,
                pastebackGranted: true,
                calendarGranted: false,
                audioRoute: [
                    "audio_device": "Private Studio Mic",
                    "input_device_class": "built_in",
                    "raw_url": "https://meet.example.com/private-room",
                ],
                runtime: [
                    "file_path": fixtures.meetingURL.path,
                    "session_kind": "meeting",
                    "session_stage": "recording",
                    "speaker_name": secretSpeaker,
                    "transcript_title": secretMeetingTitle,
                ],
                storage: [
                    "capture_library_status": "ok",
                    "transcript_path": fixtures.dictationURL.path,
                ],
                meetingState: "recording",
                meetingRecording: true,
                meetingDurationBucket: "1_4m",
                meetingDisplayStatus: "transcribing",
                speakerReviewPending: false,
                queuedMeetingCount: 1,
                meetingShortcut: "option-shift-m",
                reliabilityPackets: [
                    "event=retry path=\(fixtures.meetingURL.path) token=\(secretToken) email=\(secretEmail)"
                ],
                recentLogLines: [
                    "DIAG source_app_name=Codex transcript_text=\(secretTranscript)",
                    "DIAG meeting_title=\(secretMeetingTitle) speaker_name=\(secretSpeaker)",
                ]
            ),
            now: try fixedDate("2026-05-18T15:10:00Z")
        )

        let diagnosticsURL = logsDir.appendingPathComponent("support-diagnostics.txt", isDirectory: false)
        try diagnostics.write(to: diagnosticsURL, atomically: true, encoding: .utf8)

        for forbidden in [
            fixtures.meetingURL.path,
            fixtures.dictationURL.path,
            secretMeetingTitle,
            secretSpeaker,
            secretEmail,
            secretToken,
            secretTranscript,
            "Private Studio Mic",
            "https://meet.example.com/private-room",
        ] {
            try expect(!diagnostics.contains(forbidden), "Support diagnostics should not contain sensitive value: \(forbidden)")
        }

        // Absence of forbidden values alone also passes if a whole section was silently dropped or
        // the body came back empty. Assert the redacted structure actually survived: known-safe
        // fields must still be present, and the explicit redaction markers must appear, proving the
        // sensitive sections were emitted and redacted rather than omitted.
        for expected in [
            "Version: 9.9.9",
            "input_device_class: built_in",
            "session_stage: recording",
        ] {
            try expect(diagnostics.contains(expected), "Support diagnostics should keep known-safe field: \(expected)")
        }
        // Note: the injected sk- token only appears inside `token=...` assignments, so the
        // apiKeyRegex's "sk-****" is superseded by a later secret-assignment pass; the raw token's
        // absence is already asserted above. These markers prove sections were emitted and redacted.
        for marker in [
            "[redacted-path]",
            "[redacted-email]",
            "[redacted-sensitive-value]",
        ] {
            try expect(diagnostics.contains(marker), "Support diagnostics should surface redaction marker: \(marker)")
        }

        let eventLog = try String(contentsOf: fixtures.eventLogURL, encoding: .utf8)
        try expect(!eventLog.contains(fixtures.meetingURL.path), "Sanitized observability event should not contain file paths")
        try expect(!eventLog.contains(secretToken), "Sanitized observability event should not contain tokens")
        try expect(!eventLog.contains(secretTranscript), "Sanitized observability event should not contain transcript text")
    }

    private func verifyDeleteRemovesCanonicalArtifacts(fixtures: SmokeFixtures, captureLibrary: URL) throws {
        let meetingsBefore = RecentMeetingsScanner.loadRecent(limit: 5, directory: fixtures.meetingsDir)
        try expect(meetingsBefore.count == 2, "Delete fixture should start with captured and imported rows")
        let item = try unwrap(
            meetingsBefore.first { $0.transcriptURL.standardizedFileURL == fixtures.meetingURL.standardizedFileURL },
            "Delete fixture should find the captured meeting row"
        )
        let audioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: fixtures.meetingURL)
        let importedAudioDirectory = MeetingAudioArchiveResolver.archiveDirectory(forTranscript: fixtures.importedMeetingURL)

        let result = try HomeMeetingDeletion.delete(item)

        try expect(result.removedTranscriptURLs.map(\.lastPathComponent) == ["Customer Launch Sync.md"], "Delete should report the selected canonical transcript")
        try expect(result.removedSummaryURLs.map(\.lastPathComponent) == ["Customer Launch Sync.summary.md"], "Delete should report the matching generated summary")
        try expect(result.removedAudioDirectoryURLs.map(\.lastPathComponent) == ["Customer Launch Sync_audio"], "Delete should report the selected retained audio directory")
        try expect(!fileManager.fileExists(atPath: fixtures.meetingURL.path), "Delete should remove the selected transcript")
        try expect(!fileManager.fileExists(atPath: fixtures.summaryURL.path), "Delete should remove the matching summary artifact")
        try expect(!fileManager.fileExists(atPath: audioDirectory.path), "Delete should remove the selected retained audio directory")
        try expect(fileManager.fileExists(atPath: fixtures.importedMeetingURL.path), "Delete should leave the imported transcript alone")
        try expect(fileManager.fileExists(atPath: importedAudioDirectory.path), "Delete should leave unrelated imported audio alone")

        let meetingsAfter = RecentMeetingsScanner.loadRecent(limit: 5, directory: fixtures.meetingsDir)
        try expect(meetingsAfter.count == 1, "Deleting one canonical meeting should leave one Home row")
        try expect(
            meetingsAfter.first?.transcriptURL.standardizedFileURL == fixtures.importedMeetingURL.standardizedFileURL,
            "Remaining Home row should point at the imported meeting"
        )

        let directories = TranscriptedDataDirectories.resolve(environment: [
            "TRANSCRIPTED_DATA_DIR": captureLibrary.path,
            "TRANSCRIPTED_INDEX_DIR": runRoot.appendingPathComponent("mcp-delete-index", isDirectory: true).path,
        ])
        try fileManager.createDirectory(at: directories.indexDir, withIntermediateDirectories: true)
        let index = try TranscriptIndex(indexDir: directories.indexDir)
        try withLogsSuppressed {
            try index.reconcile(
                meetingDirs: directories.meetingDirs,
                dictationDirs: directories.dictationDirs
            )
        }
        let indexedMeetings = try index.listMeetings(count: 5, dateFrom: "2026-05-17", dateTo: "2026-05-18")
        try expect(indexedMeetings.count == 1, "Fresh MCP index should not resurrect a deleted meeting row")
        try expect(
            indexedMeetings.first?.filename == fixtures.importedMeetingURL.deletingPathExtension().lastPathComponent,
            "Fresh MCP index should keep the unaffected imported meeting"
        )
    }

    private func writeFailedQueueWithProductionManager(
        failedQueueURL: URL,
        meetingsDir: URL,
        stateDir: URL,
        retainedAudioDir: URL,
        micAudioURL: URL,
        systemAudioURL: URL
    ) async throws {
        let paths = CoreStoragePaths(
            transcripts: meetingsDir,
            speakerDB: stateDir.appendingPathComponent("speakers.sqlite", isDirectory: false),
            statsDB: stateDir.appendingPathComponent("stats.sqlite", isDirectory: false),
            failedQueue: failedQueueURL,
            speakerClips: stateDir.appendingPathComponent("speaker_clips", isDirectory: true),
            audioCaptures: retainedAudioDir,
            logs: stateDir.appendingPathComponent("logs", isDirectory: true)
        )

        let didPersist = await MainActor.run {
            let manager = FailedTranscriptionManager(paths: paths)
            return manager.addFailedTranscription(
                micAudioURL: micAudioURL,
                systemAudioURL: systemAudioURL,
                errorMessage: "Temporary transcription failure",
                meetingTitle: "Customer Launch Sync"
            )
        }

        try expect(didPersist, "Production failed transcription manager should persist failed meeting fixture")
    }
}

private struct SmokeFixtures {
    let meetingsDir: URL
    let dictationsDir: URL
    let meetingURL: URL
    let summaryURL: URL
    let importedMeetingURL: URL
    let dictationURL: URL
    let micAudioURL: URL
    let systemAudioURL: URL
    let importedAudioURL: URL
    let failedQueueURL: URL
    let eventLogURL: URL
    let meetingMarkdown: String
    let summaryMarkdown: String
    let importedMeetingMarkdown: String
    let dictationMarkdown: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw E2ESmokeError.failed(message)
    }
}

private func writeTinyAudioFixture(to url: URL, amplitude: Double) throws {
    let sampleRate = 16_000
    let frames = sampleRate
    var pcm = Data()
    pcm.reserveCapacity(frames * 2)

    for frame in 0..<frames {
        let phase = (Double(frame) / Double(sampleRate)) * 440.0 * 2.0 * Double.pi
        var sample = Int16(Double(Int16.max) * amplitude * sin(phase)).littleEndian
        Swift.withUnsafeBytes(of: &sample) { bytes in
            pcm.append(contentsOf: bytes)
        }
    }

    var data = Data()
    data.appendASCII("RIFF")
    data.appendLittleEndianUInt32(UInt32(36 + pcm.count))
    data.appendASCII("WAVE")
    data.appendASCII("fmt ")
    data.appendLittleEndianUInt32(16)
    data.appendLittleEndianUInt16(1)
    data.appendLittleEndianUInt16(1)
    data.appendLittleEndianUInt32(UInt32(sampleRate))
    data.appendLittleEndianUInt32(UInt32(sampleRate * 2))
    data.appendLittleEndianUInt16(2)
    data.appendLittleEndianUInt16(16)
    data.appendASCII("data")
    data.appendLittleEndianUInt32(UInt32(pcm.count))
    data.append(pcm)

    try data.write(to: url, options: .atomic)
}

private func unwrap<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else {
        throw E2ESmokeError.failed(message)
    }
    return value
}

private func fixedDate(_ value: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    if let date = formatter.date(from: value) {
        return date
    }
    throw E2ESmokeError.failed("Could not parse fixed date \(value)")
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension Data {
    mutating func appendASCII(_ value: String) {
        append(contentsOf: value.utf8)
    }

    mutating func appendLittleEndianUInt16(_ value: UInt16) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }

    mutating func appendLittleEndianUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { bytes in
            append(contentsOf: bytes)
        }
    }
}
