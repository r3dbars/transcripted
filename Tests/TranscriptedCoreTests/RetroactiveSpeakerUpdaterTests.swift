import XCTest
@testable import TranscriptedCore

final class RetroactiveSpeakerUpdaterTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetroactiveSpeakerUpdaterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    func testConsolidateSpeakerBreakdownMergesDuplicateNamesAndCounts() {
        let content = """
        ---
        system_speakers: 3
        ---

        ## Speaker Analytics

        - **Speakers Detected:** 3

        #### Remote Speaker Breakdown

        - **Alex:** 2 utterances, ~10 words, 00:30
        - **Alex:** 1 utterances, ~5 words, 00:15
        - **Jordan:** 4 utterances, ~40 words, 01:00

        ---

        *2 channels | 4 speakers*
        """

        let updated = SpeakerBreakdownConsolidator.consolidate(content)

        XCTAssertTrue(updated.contains("system_speakers: 2"))
        XCTAssertTrue(updated.contains("- **Speakers Detected:** 2"))
        XCTAssertTrue(updated.contains("- **Alex:** 3 utterances, ~15 words, 00:45"))
        XCTAssertFalse(updated.contains("- **Alex:** 2 utterances, ~10 words, 00:30"))
        XCTAssertTrue(updated.contains("*2 channels | 3 speakers*"))
    }

    func testConsolidateSpeakerBreakdownLeavesUniqueNamesUntouched() {
        let content = """
        ---
        system_speakers: 2
        ---

        ## Speaker Analytics

        - **Speakers Detected:** 2

        #### Remote Speaker Breakdown

        - **Alex:** 2 utterances, ~10 words, 00:30
        - **Jordan:** 4 utterances, ~40 words, 01:00

        ---

        *2 channels | 3 speakers*
        """

        XCTAssertEqual(SpeakerBreakdownConsolidator.consolidate(content), content)
    }

    func testResolveTranscriptURLFindsRenamedTranscriptByStableId() throws {
        let transcriptId = UUID()
        let originalURL = tempDirectory.appendingPathComponent("Call_2026-04-10_15-01-23.md")
        let renamedURL = tempDirectory.appendingPathComponent("Meeting with Sarah Graham.md")

        try sampleTranscript(
            transcriptId: transcriptId,
            persistentSpeakerId: UUID(),
            speakerName: "Speaker 1"
        ).write(to: renamedURL, atomically: true, encoding: .utf8)

        let resolved = TranscriptSaver.resolveTranscriptURL(originalURL, transcriptId: transcriptId)

        XCTAssertEqual(resolved, renamedURL)
    }

    func testResolveTranscriptURLFailsWhenStableIdDoesNotMatchAnySibling() throws {
        let transcriptId = UUID()
        let originalURL = tempDirectory.appendingPathComponent("Call_2026-04-10_15-01-23.md")
        let wrongURL = tempDirectory.appendingPathComponent("Meeting with Someone Else.md")

        try sampleTranscript(
            transcriptId: UUID(),
            persistentSpeakerId: UUID(),
            speakerName: "Speaker 1"
        ).write(to: wrongURL, atomically: true, encoding: .utf8)

        let resolved = TranscriptSaver.resolveTranscriptURL(originalURL, transcriptId: transcriptId)

        XCTAssertNil(resolved)
    }

    func testUpdateSpeakerNamesRewritesPreviousSuggestedNameAndPersistentId() throws {
        let transcriptId = UUID()
        let originalPersistentId = UUID()
        let correctedPersistentId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("Meeting with Matt Vlasach.md")
        let jsonURL = transcriptURL.deletingPathExtension().appendingPathExtension("json")

        try sampleTranscript(
            transcriptId: transcriptId,
            persistentSpeakerId: originalPersistentId,
            speakerName: "Matt Vlasach"
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)

        let transcript = AgentTranscript(
            version: "1.0",
            transcriptId: transcriptId.uuidString,
            recording: AgentRecording(
                date: "2026-04-10T15:01:23-0500",
                durationSeconds: 90,
                droppedSegments: 0,
                engines: AgentEngines(stt: "parakeet-tdt-v3", diarization: "pyannote-offline")
            ),
            speakers: [
                AgentSpeaker(
                    id: "system_1",
                    persistentSpeakerId: originalPersistentId.uuidString,
                    name: "Matt Vlasach",
                    confidence: "medium",
                    wordCount: 5,
                    speakingSeconds: 12.0
                )
            ],
            utterances: [
                AgentUtterance(start: 1.0, end: 4.0, speakerId: "system_1", text: "Thanks for joining.")
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript).write(to: jsonURL, options: .atomic)

        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(
                    persistentSpeakerId: originalPersistentId,
                    sortformerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: "Matt Vlasach",
                    action: .corrected,
                    resolvedPersistentSpeakerId: correctedPersistentId
                )
            ]
        )

        XCTAssertTrue(didUpdate)

        let updatedMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(updatedMarkdown.contains(#"transcript_id: "\#(transcriptId.uuidString)""#))
        XCTAssertTrue(updatedMarkdown.contains(#"db_id: "\#(correctedPersistentId.uuidString)""#))
        XCTAssertTrue(updatedMarkdown.contains(#"name: "Sarah Graham""#))
        XCTAssertTrue(updatedMarkdown.contains("source: user_manual"))
        XCTAssertTrue(updatedMarkdown.contains("[System/Sarah Graham]"))
        XCTAssertFalse(updatedMarkdown.contains("Matt Vlasach"))

        let updatedTranscript = try JSONDecoder().decode(
            AgentTranscript.self,
            from: Data(contentsOf: jsonURL)
        )
        XCTAssertEqual(updatedTranscript.transcriptId, transcriptId.uuidString)
        XCTAssertEqual(updatedTranscript.speakers.first?.name, "Sarah Graham")
        XCTAssertEqual(updatedTranscript.speakers.first?.persistentSpeakerId, correctedPersistentId.uuidString)
    }

    private func sampleTranscript(
        transcriptId: UUID,
        persistentSpeakerId: UUID,
        speakerName: String
    ) -> String {
        """
        ---
        transcript_id: "\(transcriptId.uuidString)"
        date: 2026-04-10
        time: 15:01:23
        duration: "1:30"
        processing_time: "3.0s"
        transcription_engine: parakeet_local
        diarization_engine: pyannote_offline
        sources: [mic, system_audio]
        mic_utterances: 0
        system_utterances: 1
        mic_speakers: 0
        system_speakers: 1
        total_word_count: 5
        speakers:
          - id: "1"
            db_id: "\(persistentSpeakerId.uuidString)"
            name: "\(speakerName)"
            confidence: medium
            source: db_pending
        ---

        ## Full Transcript

        [00:01] [System/\(speakerName)] Thanks for joining.

        #### Remote Speaker Breakdown

        - **\(speakerName):** 1 utterances, ~5 words, 00:03

        ---
        """
    }
}
