import Foundation
import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class RetroactiveSpeakerUpdaterTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var speakerDatabase: SpeakerDatabase!

    override func setUp() {
        super.setUp()
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RetroactiveSpeakerUpdaterTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        speakerDatabase = SpeakerDatabase(
            path: temporaryDirectory.appendingPathComponent("speakers.sqlite").path
        )
    }

    override func tearDown() {
        speakerDatabase = nil
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        super.tearDown()
    }

    func testRetroactivelyUpdateSpeakerRenamesEscapedQuotes() throws {
        let speakerId = UUID()
        let transcriptURL = temporaryDirectory.appendingPathComponent("quoted.md")
        let oldName = #"Dana "D" Smith"#
        let newName = #"Dana Smith"#

        try markdown(
            speakerId: speakerId,
            speakerName: oldName
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)

        TranscriptSaver.retroactivelyUpdateSpeaker(
            dbId: speakerId,
            newName: newName,
            directory: temporaryDirectory,
            speakerStoreForIndex: speakerDatabase
        )

        let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(updated.contains(#"name: "Dana Smith""#))
        XCTAssertTrue(updated.contains("[System/Dana Smith]"))
        XCTAssertFalse(updated.contains(#"name: "Dana \"D\" Smith""#))
        XCTAssertFalse(updated.contains(#"[System/Dana "D" Smith]"#))
    }

    func testRetroactivelyUpdateSpeakerRenamesEscapedBackslashes() throws {
        let speakerId = UUID()
        let transcriptURL = temporaryDirectory.appendingPathComponent("backslash.md")
        let oldName = #"C:\Users\Dana"#
        let newName = #"Dana Laptop"#

        try markdown(
            speakerId: speakerId,
            speakerName: oldName
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)

        TranscriptSaver.retroactivelyUpdateSpeaker(
            dbId: speakerId,
            newName: newName,
            directory: temporaryDirectory,
            speakerStoreForIndex: speakerDatabase
        )

        let updated = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(updated.contains(#"name: "Dana Laptop""#))
        XCTAssertTrue(updated.contains("[System/Dana Laptop]"))
        XCTAssertFalse(updated.contains(#"name: "C:\\Users\\Dana""#))
        XCTAssertFalse(updated.contains(#"[System/C:\Users\Dana]"#))
    }

    func testUpdateSpeakerNamesInsertsDbIdWhenTranscriptStartedGeneric() throws {
        let speakerId = UUID()
        let transcriptURL = temporaryDirectory.appendingPathComponent("generic.md")
        try genericMarkdown().write(to: transcriptURL, atomically: true, encoding: .utf8)
        try writeGenericAgentSidecar(nextTo: transcriptURL)

        let updated = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(
                    persistentSpeakerId: speakerId,
                    sortformerSpeakerId: "0",
                    newName: "Alex",
                    action: .named
                )
            ],
            speakerStoreForIndex: speakerDatabase
        )

        XCTAssertTrue(updated)

        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains(#"db_id: "\#(speakerId.uuidString)""#))
        XCTAssertTrue(markdown.contains(#"name: "Alex""#))
        XCTAssertTrue(markdown.contains("[System/Alex]"))

        let jsonURL = transcriptURL.deletingPathExtension().appendingPathExtension("json")
        let data = try Data(contentsOf: jsonURL)
        let transcript = try JSONDecoder().decode(AgentTranscript.self, from: data)
        let systemSpeaker = try XCTUnwrap(transcript.speakers.first(where: { $0.id == "system_0" }))
        XCTAssertEqual(systemSpeaker.persistentSpeakerId, speakerId.uuidString)
        XCTAssertEqual(systemSpeaker.name, "Alex")
    }

    private func markdown(speakerId: UUID, speakerName: String) -> String {
        """
        ---
        speakers:
          - id: "0"
            db_id: "\(speakerId.uuidString)"
            name: "\(TranscriptSaver.escapeYAML(speakerName))"
            confidence: medium
            source: db
        ---

        #### Remote Speaker Breakdown

        - **\(speakerName):** 1 utterances, ~2 words, 00:01

        ---

        [00:00] [System/\(speakerName)] hello there
        """
    }

    private func genericMarkdown() -> String {
        """
        ---
        speakers:
          - id: "0"
            name: "Speaker 0"
            confidence: medium
            source: db
        ---

        #### Remote Speaker Breakdown

        - **Speaker 0:** 1 utterances, ~2 words, 00:01

        ---

        [00:00] [System/Speaker 0] hello there
        """
    }

    private func writeGenericAgentSidecar(nextTo transcriptURL: URL) throws {
        let jsonURL = transcriptURL.deletingPathExtension().appendingPathExtension("json")
        let transcript = AgentTranscript(
            version: "1.0",
            recording: AgentRecording(
                date: "2026-04-09T21:00:00-0500",
                durationSeconds: 1,
                droppedSegments: 0,
                engines: AgentEngines(stt: "parakeet", diarization: "sortformer")
            ),
            speakers: [
                AgentSpeaker(
                    id: "system_0",
                    persistentSpeakerId: nil,
                    name: "Speaker 0",
                    confidence: "medium",
                    wordCount: 2,
                    speakingSeconds: 1
                )
            ],
            utterances: [
                AgentUtterance(start: 0, end: 1, speakerId: "system_0", text: "hello there")
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript).write(to: jsonURL, options: .atomic)
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
}
