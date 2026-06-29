import XCTest
@testable import TranscriptedCaptureKit

final class CaptureMarkdownParserTests: XCTestCase {
    func testParseFrontmatterNormalizesInlineAndBlockLists() throws {
        let markdown = """
        ---
        title: "Release QA"
        transcription_engine: parakeet_local
        sources:
          - mic
          - system_audio
        tags: [release, qa]
        ---
        ## Transcript
        Body
        """

        let document = try XCTUnwrap(CaptureMarkdownParser.parseFrontmatter(from: markdown))

        XCTAssertEqual(document.values["title"], "Release QA")
        XCTAssertEqual(document.values["sources"], "mic, system_audio")
        XCTAssertEqual(document.values["tags"], "release, qa")
        XCTAssertTrue(document.frontmatter.contains("transcription_engine: parakeet_local"))
        XCTAssertTrue(document.body.contains("## Transcript"))
    }

    func testParseFrontmatterIgnoresNestedObjectFields() throws {
        let markdown = """
        ---
        capture_type: meeting
        speakers:
          - id: "0"
            channel: system
            name: "Alex"
            confidence: high
        tags:
          - transcripted
        ---
        ## Transcript
        Body
        """

        let document = try XCTUnwrap(CaptureMarkdownParser.parseFrontmatter(from: markdown))

        XCTAssertEqual(document.values["capture_type"], "meeting")
        XCTAssertEqual(document.values["tags"], "transcripted")
        XCTAssertNil(document.values["channel"])
        XCTAssertNil(document.values["name"])
        XCTAssertNil(document.values["confidence"])
    }

    // Frontmatter mirrors what TranscriptFormatter.formatTranscriptMarkdown
    // actually writes: recording-health keys and gap_events before speakers,
    // channel-qualified speaker entries, and Obsidian tags/aliases after.
    func testParseMeetingLegacyTranscriptAssignsSpeakerIdsAndMetadata() throws {
        let markdown = """
        ---
        capture_type: meeting
        date: 2026-04-18
        time: 09:15:00
        duration: "30:00"
        dropped_segments: 2
        transcription_engine: parakeet_local
        diarization_engine: pyannote_offline
        capture_quality: degraded
        audio_gaps: 1
        device_switches: 0
        gap_events:
          - "Audio gap at 00:42 (1.5s)"
        audio_health: mic_attenuated_by_call_app
        mic_boost_prompt: "Mic level was boosted after a call app attenuated it."
        speakers:
          - id: "0"
            channel: system
            db_id: "80FB272B-6061-4FC4-8408-3F7A974C59DB"
            name: "Jenny Wen"
            confidence: high
            source: db_scan
        tags:
          - transcripted
          - meeting
          - speaker/jenny-wen
        aliases:
          - "Meeting 2026-04-18 09:15:00"
        cssclasses:
          - transcripted
        ---

        # Meeting Fixture

        ## Full Transcript

        [00:00] [Mic/You] Good morning everyone

        [00:05] [System/Jenny Wen] Let's discuss the product roadmap
        """

        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: markdown))

        XCTAssertEqual(parsed.datetime, "2026-04-18T09:15:00")
        XCTAssertEqual(parsed.durationSeconds, 1800)
        XCTAssertEqual(parsed.droppedSegments, 2)
        XCTAssertEqual(parsed.sttEngine, "parakeet_local")
        XCTAssertEqual(parsed.diarizationEngine, "pyannote_offline")
        XCTAssertEqual(parsed.utterances.count, 2)
        XCTAssertEqual(parsed.utterances.map(\.speakerId), ["mic_0", "system_0"])

        let mic = try XCTUnwrap(parsed.speakers.first(where: { $0.id == "mic_0" }))
        XCTAssertEqual(mic.name, "You")
        XCTAssertNil(mic.persistentSpeakerId)
        XCTAssertNil(mic.confidence)

        let system = try XCTUnwrap(parsed.speakers.first(where: { $0.id == "system_0" }))
        XCTAssertEqual(system.name, "Jenny Wen")
        XCTAssertEqual(system.persistentSpeakerId, "80FB272B-6061-4FC4-8408-3F7A974C59DB")
        XCTAssertEqual(system.confidence, "high")
        XCTAssertEqual(system.wordCount, 5)
    }

    func testParseMeetingSpeakerMetadataWithWriterChannelLines() throws {
        let markdown = """
        ---
        capture_id: "2C356828-221B-43E8-B1BB-93E0C3360E2F"
        capture_type: meeting
        transcript_id: "2C356828-221B-43E8-B1BB-93E0C3360E2F"
        date: 2026-06-12
        time: 09:30:00
        duration: "1:05"
        processing_time: "1.2s"
        transcription_engine: parakeet_local
        diarization_engine: pyannote_offline
        sources: [microphone, system_audio]
        mic_utterances: 1
        system_utterances: 1
        mic_speakers: 1
        system_speakers: 1
        total_word_count: 8
        title: "Writer faithful meeting"
        speakers:
          - id: "0"
            channel: mic
            db_id: "11111111-1111-1111-1111-111111111111"
            name: "Justin"
            confidence: manual
            source: db_scan
          - id: "1"
            channel: system
            db_id: "22222222-2222-2222-2222-222222222222"
            name: "Alex"
            confidence: high
            source: db_scan
        ---

        # Meeting Recording - Jun 12, 2026 at 9:30 AM

        **Duration:** 1:05 | **Words:** 8 | **Utterances:** 2

        ---

        ---

        ## Channel & Speaker Analytics

        ### Microphone (You)
        - **Utterances:** 1
        - **Words:** ~4
        - **Speaking Time:** 2s

        ### Meeting Audio (Remote Participants)
        - **Utterances:** 1
        - **Words:** ~4
        - **Speaking Time:** 3s
        - **Speakers Detected:** 1

        #### Remote Speaker Breakdown

        - **Alex:** 1 utterances, ~4 words, 3s

        ---

        ## Full Transcript

        [00:00] [Mic/Justin] I can hear you now

        [00:02] [System/Alex] Channel metadata should survive

        ---

        *Generated by Transcripted with Parakeet + PyAnnote (local) | Duration: 1:05 | 8 words | 2 speakers*
        """

        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: markdown))

        XCTAssertEqual(parsed.utterances.map(\.speakerId), ["mic_0", "system_1"])

        let mic = try XCTUnwrap(parsed.speakers.first(where: { $0.id == "mic_0" }))
        XCTAssertEqual(mic.name, "Justin")
        XCTAssertEqual(mic.persistentSpeakerId, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(mic.confidence, "manual")

        let system = try XCTUnwrap(parsed.speakers.first(where: { $0.id == "system_1" }))
        XCTAssertEqual(system.name, "Alex")
        XCTAssertEqual(system.persistentSpeakerId, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(system.confidence, "high")
    }

    func testParseMeetingSameDisplayNameKeepsSpeakerMetadataChannelScoped() throws {
        let markdown = """
        ---
        capture_type: meeting
        date: 2026-06-12
        time: 10:00:00
        duration: "0:05"
        speakers:
          - id: "0"
            channel: mic
            db_id: "11111111-1111-1111-1111-111111111111"
            name: "Justin"
            confidence: manual
            source: db_scan
          - id: "1"
            channel: system
            db_id: "22222222-2222-2222-2222-222222222222"
            name: "Justin"
            confidence: high
            source: db_scan
        ---

        ## Full Transcript

        [00:00] [Mic/Justin] Local speaker.

        [00:02] [System/Justin] Remote speaker.
        """

        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: markdown))

        XCTAssertEqual(parsed.utterances.map(\.speakerId), ["mic_0", "system_1"])

        let mic = try XCTUnwrap(parsed.speakers.first(where: { $0.id == "mic_0" }))
        XCTAssertEqual(mic.persistentSpeakerId, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(mic.confidence, "manual")

        let system = try XCTUnwrap(parsed.speakers.first(where: { $0.id == "system_1" }))
        XCTAssertEqual(system.persistentSpeakerId, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(system.confidence, "high")
    }

    func testParseMeetingAmbiguousSameChannelNamesDoNotAttachArbitraryMetadata() throws {
        let markdown = """
        ---
        capture_type: meeting
        date: 2026-06-12
        time: 10:03:00
        duration: "0:05"
        speakers:
          - id: "0"
            channel: system
            db_id: "11111111-1111-1111-1111-111111111111"
            name: "Alex"
            confidence: high
            source: db_scan
          - id: "1"
            channel: system
            db_id: "22222222-2222-2222-2222-222222222222"
            name: "Alex"
            confidence: medium
            source: db_scan
        ---

        ## Full Transcript

        [00:00] [System/Alex] Shared display name.

        [00:02] [System/Alex] Same ambiguous label.
        """

        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: markdown))

        XCTAssertEqual(parsed.utterances.map(\.speakerId), ["system_2", "system_2"])

        let alex = try XCTUnwrap(parsed.speakers.first(where: { $0.id == "system_2" }))
        XCTAssertEqual(alex.name, "Alex")
        XCTAssertNil(alex.persistentSpeakerId)
        XCTAssertNil(alex.confidence)
    }

    func testParseMeetingFallbackSpeakerIdsDoNotCollideWithFrontmatterIds() throws {
        let markdown = """
        ---
        capture_type: meeting
        date: 2026-06-12
        time: 10:05:00
        duration: "0:08"
        speakers:
          - id: "0"
            channel: mic
            db_id: "11111111-1111-1111-1111-111111111111"
            name: "Justin"
            confidence: manual
            source: db_scan
          - id: "0"
            channel: system
            db_id: "22222222-2222-2222-2222-222222222222"
            name: "Alex"
            confidence: high
            source: db_scan
        ---

        ## Full Transcript

        [00:00] [Mic/Guest] Unmatched local speaker.

        [00:02] [Mic/Justin] Known local speaker.

        [00:04] [System/Guest] Unmatched remote speaker.

        [00:06] [System/Alex] Known remote speaker.
        """

        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: markdown))

        XCTAssertEqual(parsed.utterances.map(\.speakerId), ["mic_1", "mic_0", "system_1", "system_0"])

        let guestMic = try XCTUnwrap(parsed.speakers.first(where: { $0.id == "mic_1" }))
        XCTAssertEqual(guestMic.name, "Guest")
        XCTAssertNil(guestMic.persistentSpeakerId)

        let knownMic = try XCTUnwrap(parsed.speakers.first(where: { $0.id == "mic_0" }))
        XCTAssertEqual(knownMic.name, "Justin")
        XCTAssertEqual(knownMic.persistentSpeakerId, "11111111-1111-1111-1111-111111111111")

        let guestSystem = try XCTUnwrap(parsed.speakers.first(where: { $0.id == "system_1" }))
        XCTAssertEqual(guestSystem.name, "Guest")
        XCTAssertNil(guestSystem.persistentSpeakerId)

        let knownSystem = try XCTUnwrap(parsed.speakers.first(where: { $0.id == "system_0" }))
        XCTAssertEqual(knownSystem.name, "Alex")
        XCTAssertEqual(knownSystem.persistentSpeakerId, "22222222-2222-2222-2222-222222222222")
    }

    func testParseMeetingLegacyChannellessMetadataDoesNotCollideWithMicFallbackIds() throws {
        let markdown = """
        ---
        capture_type: meeting
        date: 2026-06-12
        time: 10:10:00
        duration: "0:06"
        speakers:
          - id: "0"
            db_id: "22222222-2222-2222-2222-222222222222"
            name: "Justin"
            confidence: high
            source: db_scan
        ---

        ## Full Transcript

        [00:00] [Mic/Guest] Unmatched local speaker.

        [00:02] [Mic/Justin] Local label matches legacy metadata name.

        [00:04] [System/Justin] Remote legacy metadata owner.
        """

        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: markdown))

        XCTAssertEqual(parsed.utterances.map(\.speakerId), ["mic_0", "mic_1", "system_0"])

        let guestMic = try XCTUnwrap(parsed.speakers.first(where: { $0.id == "mic_0" }))
        XCTAssertEqual(guestMic.name, "Guest")
        XCTAssertNil(guestMic.persistentSpeakerId)

        let justinMic = try XCTUnwrap(parsed.speakers.first(where: { $0.id == "mic_1" }))
        XCTAssertEqual(justinMic.name, "Justin")
        XCTAssertNil(justinMic.persistentSpeakerId)

        let justinSystem = try XCTUnwrap(parsed.speakers.first(where: { $0.id == "system_0" }))
        XCTAssertEqual(justinSystem.name, "Justin")
        XCTAssertEqual(justinSystem.persistentSpeakerId, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(justinSystem.confidence, "high")
    }

    func testParseMeetingStyledTranscriptSection() throws {
        let markdown = """
        ---
        capture_type: meeting
        date: 2026-04-18
        time: 09:15:00
        duration: "0:18"
        ---

        ## Transcript

        **00:03 [Mic/You]**
        Styled entry text here.

        **00:07 [System/Alex]**
        Reply from the other side.
        """

        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: markdown))

        XCTAssertEqual(parsed.utterances.count, 2)
        XCTAssertEqual(parsed.utterances.first?.text, "Styled entry text here.")
        XCTAssertEqual(parsed.utterances.first?.start, 3)
        XCTAssertEqual(parsed.utterances.first?.end, 7)
    }

    func testParseMeetingSkipsMalformedLegacyRows() throws {
        let markdown = """
        ---
        capture_type: meeting
        date: 2026-04-18
        time: 09:15:00
        duration: "0:18"
        ---

        ## Full Transcript

        [00:00]
        [00:01]x
        [00:02] [
        [00:03] [Mic/You] Still works.
        """

        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: markdown))

        XCTAssertEqual(parsed.utterances.count, 1)
        XCTAssertEqual(parsed.utterances.first?.text, "Still works.")
    }

    func testMalformedDurationFallsBackToZero() throws {
        for duration in ["1:bad", "-1:02"] {
            let markdown = """
            ---
            date: 2026-04-18
            time: 09:15:00
            duration: "\(duration)"
            ---

            ## Full Transcript

            [00:03] [Mic/You] Still works.
            """
            let parsed = CaptureMarkdownParser.parseMeeting(from: markdown)
            XCTAssertEqual(parsed?.durationSeconds, 0)
        }
    }

    func testParseMeetingDuplicateSpeakerNamesDoesNotCrash() throws {
        let markdown = """
        ---
        date: 2026-04-18
        time: 09:15:00
        speakers:
          - id: "0"
            channel: system
            db_id: "AAA"
            name: "Alex"
          - id: "1"
            channel: system
            db_id: "BBB"
            name: "Alex"
        ---

        ## Full Transcript

        [00:00] [System/Alex] First speaker with the shared display name.

        [00:04] [System/Alex] Second speaker with the shared display name.
        """

        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: markdown))
        XCTAssertEqual(parsed.utterances.count, 2)
    }

    func testParseMeetingMalformedContentReturnsNil() {
        XCTAssertNil(CaptureMarkdownParser.parseMeeting(from: "not markdown at all"))
    }

    func testParseDictationDayEntriesSortedByCreatedAt() throws {
        let markdown = """
        ---
        title: "Dictations for 2026-04-07"
        date: 2026-04-07
        capture_type: dictation_day
        ---

        # Dictations for 2026-04-07

        ## 6:30 PM - Evening note

        Entry ID: `dictation-2`
        Captured: 2026-04-07T18:30:00Z
        Source app: Mail
        Delivery: pasted
        Words: 7

        Remember to send the recap before dinner

        ## 9:15 AM - Morning note

        Entry ID: `dictation-1`
        Captured: 2026-04-07T09:15:00Z
        Source app: Slack
        Bundle ID: `com.example.slack`
        Delivery: copied
        Words: 7

        Ship the follow-up note to product today
        """

        let url = URL(fileURLWithPath: "/tmp/Dictations_2026-04-07.md")
        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseDictationDay(from: markdown, markdownURL: url))

        XCTAssertEqual(parsed.captureType, "dictation_day")
        XCTAssertEqual(parsed.date, "2026-04-07")
        XCTAssertEqual(parsed.markdownFilename, "Dictations_2026-04-07.md")
        XCTAssertEqual(parsed.entryCount, 2)
        XCTAssertEqual(parsed.entries.map(\.id), ["dictation-1", "dictation-2"])
        XCTAssertEqual(parsed.entries.first?.title, "Morning note")
        XCTAssertEqual(parsed.entries.first?.sourceAppBundleId, "com.example.slack")
        XCTAssertEqual(parsed.wordCount, 14)
    }

    func testParseDictationDayWithoutFrontmatterReturnsNil() {
        let url = URL(fileURLWithPath: "/tmp/Dictations_2026-04-07.md")
        XCTAssertNil(CaptureMarkdownParser.parseDictationDay(from: "# No frontmatter", markdownURL: url))
    }

    func testParseDictationDayDateFallsBackToFilename() throws {
        let markdown = """
        ---
        capture_type: dictation_day
        ---

        ## 9:15 AM - Note

        Entry ID: `dictation-1`
        Captured: 2026-04-08T09:15:00Z

        Some text
        """
        let url = URL(fileURLWithPath: "/tmp/Dictations_2026-04-08.md")
        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseDictationDay(from: markdown, markdownURL: url))
        XCTAssertEqual(parsed.date, "2026-04-08")
    }

    func testExtractTitleTrimsQuotes() {
        let markdown = """
        ---
        title: "Product review"
        date: 2026-04-18
        ---

        body
        """
        XCTAssertEqual(CaptureMarkdown.extractTitle(from: markdown), "Product review")
        XCTAssertNil(CaptureMarkdown.extractTitle(from: "no frontmatter"))
        XCTAssertNil(CaptureMarkdown.extractTitle(from: "---\n---\n"))
    }

    // A file of nothing but "---" delimiter lines passes parseFrontmatter (and
    // file-level capture detection), so it reaches title hydration in both
    // standalone tools. extractTitle used to trap on the inverted-range slice.
    func testDegenerateDelimiterOnlyFrontmatterDoesNotTrap() {
        XCTAssertNil(CaptureMarkdown.extractTitle(from: "---\n---\n"))
        XCTAssertNil(CaptureMarkdown.extractTitle(from: "---\n---\n---\n"))
        XCTAssertNil(CaptureMarkdown.extractTitle(from: "---\n---\n---\n\n# Body\n"))

        let degenerate = "---\n---\n---\n"
        XCTAssertNotNil(CaptureMarkdownParser.parseFrontmatter(from: degenerate))
        let meeting = CaptureMarkdownParser.parseMeeting(from: degenerate)
        XCTAssertNotNil(meeting)
        XCTAssertEqual(meeting?.utterances.count, 0)
        XCTAssertEqual(meeting?.speakers.count, 0)

        XCTAssertNil(CaptureMarkdownParser.parseMeeting(from: "---\n---\n"))
    }

    func testLooksLikeCaptureMarkdown() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dictation = tempDir.appendingPathComponent("Dictations_2026-04-07.md")
        try "anything".write(to: dictation, atomically: true, encoding: .utf8)
        XCTAssertTrue(CaptureMarkdown.looksLikeCaptureMarkdown(dictation))

        let meeting = tempDir.appendingPathComponent("Call_test.md")
        try "---\ndate: 2026-04-18\n---\n\nbody".write(to: meeting, atomically: true, encoding: .utf8)
        XCTAssertTrue(CaptureMarkdown.looksLikeCaptureMarkdown(meeting))

        let notes = tempDir.appendingPathComponent("CLAUDE.md")
        try "# Notes".write(to: notes, atomically: true, encoding: .utf8)
        XCTAssertFalse(CaptureMarkdown.looksLikeCaptureMarkdown(notes))

        XCTAssertTrue(CaptureMarkdown.directoryHasCaptureMarkdownFiles(tempDir))
    }

    // MARK: - Format-sync round trip with the Core writer

    // Parser side of the format-sync contract. The fixture below is a faithful
    // full-document sample of TranscriptSaver.formatTranscriptMarkdown output:
    // flat frontmatter, the channel-qualified speakers block, the
    // "Channel & Speaker Analytics" section, the "## Full Transcript" rows, and
    // the footer. The writer side is pinned by
    // TranscriptFormatterCaptureKitContractTests in TranscriptedCoreTests. If
    // the written format changes, update both together.
    func testRoundTripParsesWriterDocument() throws {
        let markdown = """
        ---
        capture_id: "2C356828-221B-43E8-B1BB-93E0C3360E2F"
        capture_type: meeting
        transcript_id: "2C356828-221B-43E8-B1BB-93E0C3360E2F"
        date: 2026-04-18
        time: 09:15:00
        duration: "0:09"
        processing_time: "1.2s"
        transcription_engine: parakeet_local
        diarization_engine: pyannote_offline
        sources: [mic, system_audio]
        mic_utterances: 1
        system_utterances: 1
        mic_speakers: 1
        system_speakers: 1
        total_word_count: 8
        speakers:
          - id: "0"
            channel: system
            db_id: "80FB272B-6061-4FC4-8408-3F7A974C59DB"
            name: "Jenny Wen"
            confidence: high
            source: db_scan
        ---

        # Meeting Recording - Apr 18, 2026 at 9:15 AM

        **Duration:** 0:09 | **Words:** 8 | **Utterances:** 2

        ---

        ---

        ## Channel & Speaker Analytics

        ### Microphone (You)
        - **Utterances:** 1
        - **Words:** ~3
        - **Speaking Time:** 4s

        ### Meeting Audio (Remote Participants)
        - **Utterances:** 1
        - **Words:** ~5
        - **Speaking Time:** 4s
        - **Speakers Detected:** 1

        #### Remote Speaker Breakdown

        - **Jenny Wen:** 1 utterances, ~5 words, 4s

        ---

        ## Full Transcript

        [00:00] [Mic/You] Good morning everyone

        [00:05] [System/Jenny Wen] Let us discuss the roadmap

        ---

        *Generated by Transcripted with Parakeet + PyAnnote (local) | Duration: 0:09 | 8 words | 2 speakers*
        """

        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: markdown))

        XCTAssertEqual(parsed.datetime, "2026-04-18T09:15:00")
        XCTAssertEqual(parsed.durationSeconds, 9)
        XCTAssertEqual(parsed.sttEngine, "parakeet_local")
        XCTAssertEqual(parsed.diarizationEngine, "pyannote_offline")
        XCTAssertEqual(parsed.utterances.map(\.speakerId), ["mic_0", "system_0"])
        XCTAssertEqual(parsed.utterances.map(\.text), [
            "Good morning everyone",
            "Let us discuss the roadmap",
        ])

        let mic = try XCTUnwrap(parsed.speakers.first(where: { $0.id == "mic_0" }))
        XCTAssertEqual(mic.name, "You")
        XCTAssertNil(mic.persistentSpeakerId)

        let system = try XCTUnwrap(parsed.speakers.first(where: { $0.id == "system_0" }))
        XCTAssertEqual(system.name, "Jenny Wen")
        XCTAssertEqual(system.persistentSpeakerId, "80FB272B-6061-4FC4-8408-3F7A974C59DB")
        XCTAssertEqual(system.confidence, "high")
        XCTAssertEqual(system.wordCount, 5)
    }

    // MARK: - Malformed / adversarial input hardening

    func testUnicodeSpeakerNameAndBodySurviveParsing() throws {
        let markdown = """
        ---
        capture_type: meeting
        date: 2026-04-18
        time: 09:15:00
        duration: "0:05"
        speakers:
          - id: "0"
            channel: system
            db_id: "11111111-1111-1111-1111-111111111111"
            name: "José Ñoño 🎤"
            confidence: high
        ---

        ## Full Transcript

        [00:00] [System/José Ñoño 🎤] Café au lait, naïve façade — emoji 🎤 survives.
        """

        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: markdown))

        XCTAssertEqual(parsed.utterances.count, 1)
        XCTAssertTrue(parsed.utterances.first?.text.contains("Café au lait") == true)

        let speaker = try XCTUnwrap(parsed.speakers.first(where: { $0.id == "system_0" }))
        XCTAssertEqual(speaker.name, "José Ñoño 🎤")
        XCTAssertEqual(speaker.persistentSpeakerId, "11111111-1111-1111-1111-111111111111")
    }

    func testFrontmatterValueWithEmbeddedColonKeepsRemainder() throws {
        let markdown = """
        ---
        title: "Q3: Planning sync"
        date: 2026-04-18
        time: 09:15:00
        ---

        ## Full Transcript

        [00:00] [Mic/You] Hi.
        """

        let document = try XCTUnwrap(CaptureMarkdownParser.parseFrontmatter(from: markdown))
        XCTAssertEqual(document.values["title"], "Q3: Planning sync")
        XCTAssertNotNil(CaptureMarkdownParser.parseMeeting(from: markdown))
    }

    func testMissingClosingDelimiterReturnsNilWithoutTrapping() {
        let unterminated = "---\ndate: 2026-04-18\ntime: 09:15:00\n\nbody with no closing fence"
        XCTAssertNil(CaptureMarkdownParser.parseFrontmatter(from: unterminated))
        XCTAssertNil(CaptureMarkdownParser.parseMeeting(from: unterminated))
        XCTAssertNil(CaptureMarkdown.extractTitle(from: unterminated))
    }

    // Forward compatibility: an indented writer field the parser does not model
    // (a future `source:`/`future_field:` line) must not terminate the speakers
    // block — only a new top-level key does.
    func testUnknownIndentedSpeakerFieldDoesNotTerminateBlock() throws {
        let markdown = """
        ---
        capture_type: meeting
        date: 2026-04-18
        time: 09:15:00
        duration: "0:05"
        speakers:
          - id: "0"
            channel: system
            name: "Alex"
            confidence: high
            source: db_scan
            future_field: "ignored by parser"
        ---

        ## Full Transcript

        [00:00] [System/Alex] Forward-compatible metadata.
        """

        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: markdown))
        let speaker = try XCTUnwrap(parsed.speakers.first(where: { $0.id == "system_0" }))
        XCTAssertEqual(speaker.name, "Alex")
        XCTAssertEqual(speaker.confidence, "high")
    }

    func testStyledTranscriptHeaderMissingBracketIsSkipped() throws {
        let markdown = """
        ---
        capture_type: meeting
        date: 2026-04-18
        time: 09:15:00
        duration: "0:18"
        ---

        ## Transcript

        **00:03 [Mic/You**
        Header is missing its closing bracket.

        **00:07 [System/Alex]**
        Well-formed entry still parses.
        """

        let parsed = try XCTUnwrap(CaptureMarkdownParser.parseMeeting(from: markdown))
        XCTAssertEqual(parsed.utterances.count, 1)
        XCTAssertEqual(parsed.utterances.first?.text, "Well-formed entry still parses.")
    }
}
