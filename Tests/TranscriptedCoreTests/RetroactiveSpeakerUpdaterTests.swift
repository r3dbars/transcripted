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
            in: temporaryDirectory
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
            in: temporaryDirectory
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

    private struct MarkdownSpeaker {
        let id: String
        let persistentSpeakerId: UUID
        let name: String
        let confidence: String
        let source: String
    }

    private struct MarkdownUtterance {
        let timestamp: String
        let source: String
        let label: String
        let text: String
        let sortformerSpeakerId: Int?
        let speakingSeconds: Double

        init(
            timestamp: String,
            source: String,
            label: String,
            text: String,
            sortformerSpeakerId: Int? = nil,
            speakingSeconds: Double = 3.0
        ) {
            self.timestamp = timestamp
            self.source = source
            self.label = label
            self.text = text
            self.sortformerSpeakerId = sortformerSpeakerId
            self.speakingSeconds = speakingSeconds
        }
    }

    private struct BreakdownEntry {
        let name: String
        let utterances: Int
        let wordCount: Int
        let duration: String
    }

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

        ## Full Transcript

        [00:00] [System/Speaker 0] hello there

        ---

        *Generated by Transcripted*
        """
    }

    private func writeGenericAgentSidecar(nextTo transcriptURL: URL) throws {
        let jsonURL = transcriptURL.deletingPathExtension().appendingPathExtension("json")
        let transcript = AgentTranscript(
            version: "1.0",
            transcriptId: nil,
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
    func testResolveTranscriptURLFindsRenamedTranscriptByStableId() throws {
        let transcriptId = UUID()
        let originalURL = tempDirectory.appendingPathComponent("Call_2026-04-10_15-01-23.md")
        let renamedURL = tempDirectory.appendingPathComponent("Meeting with Sarah Graham.md")

        try sampleTranscript(
            transcriptId: transcriptId,
            speakers: [
                MarkdownSpeaker(
                    id: "1",
                    persistentSpeakerId: UUID(),
                    name: "Speaker 1",
                    confidence: "unknown",
                    source: "db_pending"
                )
            ],
            utterances: [
                MarkdownUtterance(
                    timestamp: "00:01",
                    source: "System",
                    label: "Speaker 1",
                    text: "Thanks for joining."
                )
            ],
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 5, duration: "00:03")
            ]
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
            speakers: [
                MarkdownSpeaker(
                    id: "1",
                    persistentSpeakerId: UUID(),
                    name: "Speaker 1",
                    confidence: "unknown",
                    source: "db_pending"
                )
            ],
            utterances: [
                MarkdownUtterance(
                    timestamp: "00:01",
                    source: "System",
                    label: "Speaker 1",
                    text: "Thanks for joining."
                )
            ],
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        ).write(to: wrongURL, atomically: true, encoding: .utf8)

        let resolved = TranscriptSaver.resolveTranscriptURL(originalURL, transcriptId: transcriptId)

        XCTAssertNil(resolved)
    }

    func testUpdateSpeakerNamesRewritesPreviousSuggestedNameAndPersistentId() throws {
        let transcriptId = UUID()
        let originalPersistentId = UUID()
        let correctedPersistentId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("Meeting with Matt Vlasach.md")
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: originalPersistentId,
                name: "Matt Vlasach",
                confidence: "medium",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Matt Vlasach",
                text: "Thanks for joining.",
                speakingSeconds: 12.0
            )
        ]

        try sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Matt Vlasach", utterances: 1, wordCount: 5, duration: "00:12")
            ]
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)

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
            ],
            transcriptionResult: transcriptionResult
        )

        XCTAssertTrue(didUpdate)

        let updatedMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(updatedMarkdown.contains(#"transcript_id: "\#(transcriptId.uuidString)""#))
        XCTAssertTrue(updatedMarkdown.contains(#"db_id: "\#(correctedPersistentId.uuidString)""#))
        XCTAssertTrue(updatedMarkdown.contains(#"name: "Sarah Graham""#))
        XCTAssertTrue(updatedMarkdown.contains("source: user_manual"))
        XCTAssertTrue(updatedMarkdown.contains("[System/Sarah Graham]"))
        XCTAssertTrue(updatedMarkdown.contains("- **Sarah Graham:** 1 utterances, ~3 words, 00:12"))
    }

    func testUpdateSpeakerNamesSucceedsWithoutJSONSidecar() throws {
        let transcriptId = UUID()
        let persistentSpeakerId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("Meeting with Speaker 1.md")
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: persistentSpeakerId,
                name: "Speaker 1",
                confidence: "unknown",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Speaker 1",
                text: "Thanks for joining."
            )
        ]
        let originalMarkdown = sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        )
        try originalMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)

        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(
                    persistentSpeakerId: persistentSpeakerId,
                    sortformerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: "Speaker 1",
                    action: .named
                )
            ],
            transcriptionResult: transcriptionResult
        )

        XCTAssertTrue(didUpdate)
        let updatedMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertNotEqual(updatedMarkdown, originalMarkdown)
        XCTAssertTrue(updatedMarkdown.contains("Sarah Graham"))
    }

    func testUpdateSpeakerNamesIgnoresCorruptAdjacentJSON() throws {
        let transcriptId = UUID()
        let persistentSpeakerId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("Meeting with Speaker 1.md")
        let jsonURL = transcriptURL.deletingPathExtension().appendingPathExtension("json")
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: persistentSpeakerId,
                name: "Speaker 1",
                confidence: "unknown",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Speaker 1",
                text: "Thanks for joining."
            )
        ]
        let originalMarkdown = sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        )
        try originalMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try "{not-json".write(to: jsonURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)

        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(
                    persistentSpeakerId: persistentSpeakerId,
                    sortformerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: "Speaker 1",
                    action: .named
                )
            ],
            transcriptionResult: transcriptionResult
        )

        XCTAssertTrue(didUpdate)
        let updatedMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertNotEqual(updatedMarkdown, originalMarkdown)
        XCTAssertTrue(updatedMarkdown.contains("Sarah Graham"))
        XCTAssertEqual(try String(contentsOf: jsonURL, encoding: .utf8), "{not-json")
    }

    func testUpdateSpeakerNamesIgnoresMismatchedAdjacentJSON() throws {
        let transcriptId = UUID()
        let persistentSpeakerId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("Meeting with Speaker 1.md")
        let jsonURL = transcriptURL.deletingPathExtension().appendingPathExtension("json")
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: persistentSpeakerId,
                name: "Speaker 1",
                confidence: "unknown",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Speaker 1",
                text: "Thanks for joining."
            )
        ]
        let originalMarkdown = sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        )
        try originalMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try #"{"transcript_id":"other","speakers":[{"id":"system_2"}]}"#.write(to: jsonURL, atomically: true, encoding: .utf8)

        let originalJSON = try String(contentsOf: jsonURL, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)
        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(
                    persistentSpeakerId: persistentSpeakerId,
                    sortformerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: "Speaker 1",
                    action: .named
                )
            ],
            transcriptionResult: transcriptionResult
        )

        XCTAssertTrue(didUpdate)
        let updatedMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertNotEqual(updatedMarkdown, originalMarkdown)
        XCTAssertTrue(updatedMarkdown.contains("Sarah Graham"))
        XCTAssertEqual(try String(contentsOf: jsonURL, encoding: .utf8), originalJSON)
    }

    func testUpdateSpeakerNamesIgnoresAdjacentJSONWithWrongTranscriptId() throws {
        let transcriptId = UUID()
        let persistentSpeakerId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("Meeting with Speaker 1.md")
        let jsonURL = transcriptURL.deletingPathExtension().appendingPathExtension("json")
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: persistentSpeakerId,
                name: "Speaker 1",
                confidence: "unknown",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Speaker 1",
                text: "Thanks for joining."
            )
        ]
        let originalMarkdown = sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        )
        try originalMarkdown.write(to: transcriptURL, atomically: true, encoding: .utf8)
        try #"{"transcript_id":"wrong-id"}"#.write(to: jsonURL, atomically: true, encoding: .utf8)

        let originalJSON = try String(contentsOf: jsonURL, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)
        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(
                    persistentSpeakerId: persistentSpeakerId,
                    sortformerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: "Speaker 1",
                    action: .named
                )
            ],
            transcriptionResult: transcriptionResult
        )

        XCTAssertTrue(didUpdate)
        let updatedMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertNotEqual(updatedMarkdown, originalMarkdown)
        XCTAssertTrue(updatedMarkdown.contains("Sarah Graham"))
        XCTAssertEqual(try String(contentsOf: jsonURL, encoding: .utf8), originalJSON)
    }

    func testUpdateSpeakerNamesOnlyRewritesTargetSpeakerLinesWhenNamesCollide() throws {
        let transcriptId = UUID()
        let firstPersistentId = UUID()
        let secondPersistentId = UUID()
        let correctedPersistentId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("Meeting with Matt Vlasach.md")
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: firstPersistentId,
                name: "Matt Vlasach",
                confidence: "medium",
                source: "db_pending"
            ),
            MarkdownSpeaker(
                id: "2",
                persistentSpeakerId: secondPersistentId,
                name: "Matt Vlasach",
                confidence: "medium",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Matt Vlasach",
                text: "Sarah is actually joining today.",
                sortformerSpeakerId: 1,
                speakingSeconds: 3.0
            ),
            MarkdownUtterance(
                timestamp: "00:05",
                source: "System",
                label: "Matt Vlasach",
                text: "Matt Vlasach is still the label on this other speaker.",
                sortformerSpeakerId: 2,
                speakingSeconds: 4.0
            )
        ]

        try sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Matt Vlasach", utterances: 1, wordCount: 5, duration: "00:03"),
                BreakdownEntry(name: "Matt Vlasach", utterances: 1, wordCount: 7, duration: "00:04")
            ]
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)

        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: transcriptURL,
            updates: [
                SpeakerNameUpdate(
                    persistentSpeakerId: firstPersistentId,
                    sortformerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: "Matt Vlasach",
                    action: .corrected,
                    resolvedPersistentSpeakerId: correctedPersistentId
                )
            ],
            transcriptionResult: transcriptionResult
        )

        XCTAssertTrue(didUpdate)

        let updatedMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(updatedMarkdown.contains(#"  - id: "1""#))
        XCTAssertTrue(updatedMarkdown.contains(#"    db_id: "\#(correctedPersistentId.uuidString)""#))
        XCTAssertTrue(updatedMarkdown.contains("[00:01] [System/Sarah Graham] Sarah is actually joining today."))
        XCTAssertTrue(updatedMarkdown.contains("[00:05] [System/Matt Vlasach] Matt Vlasach is still the label on this other speaker."))
        XCTAssertTrue(updatedMarkdown.contains("- **Sarah Graham:** 1 utterances, ~5 words, 00:03"))
        XCTAssertTrue(updatedMarkdown.contains("- **Matt Vlasach:** 1 utterances, ~10 words, 00:04"))
    }

    func testUpdateSpeakerNamesDoesNotRewriteLiteralTextMentions() throws {
        let transcriptId = UUID()
        let originalPersistentId = UUID()
        let correctedPersistentId = UUID()
        let transcriptURL = tempDirectory.appendingPathComponent("Meeting with Matt Vlasach.md")
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: originalPersistentId,
                name: "Matt Vlasach",
                confidence: "medium",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "[[Matt Vlasach]]",
                text: #"Literal tokens: [[Matt Vlasach]] [System/Matt Vlasach] **Matt Vlasach:** name: "Matt Vlasach""#,
                sortformerSpeakerId: 1,
                speakingSeconds: 3.0
            )
        ]

        try sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Matt Vlasach", utterances: 1, wordCount: 10, duration: "00:03")
            ]
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)

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
            ],
            transcriptionResult: transcriptionResult
        )

        XCTAssertTrue(didUpdate)

        let updatedMarkdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(updatedMarkdown.contains(#"name: "Sarah Graham""#))
        XCTAssertTrue(updatedMarkdown.contains("[00:01] [System/[[Sarah Graham]]] Literal tokens: [[Matt Vlasach]] [System/Matt Vlasach] **Matt Vlasach:** name: \"Matt Vlasach\""))
        XCTAssertTrue(updatedMarkdown.contains("- **Sarah Graham:** 1 utterances, ~11 words, 00:03"))
    }

    private func sampleTranscript(
        transcriptId: UUID,
        speakers: [MarkdownSpeaker],
        utterances: [MarkdownUtterance],
        breakdownEntries: [BreakdownEntry],
        title: String = "Meeting Recording - Apr 10, 2026 at 3:01 PM",
        duration: String = "1:30",
        totalWords: Int = 5
    ) -> String {
        let speakersYAML = speakers.map { speaker in
            """
              - id: "\(speaker.id)"
                db_id: "\(speaker.persistentSpeakerId.uuidString)"
                name: "\(speaker.name)"
                confidence: \(speaker.confidence)
                source: \(speaker.source)
            """
        }.joined(separator: "\n")
        let transcriptBody = utterances.map { utterance in
            "[\(utterance.timestamp)] [\(utterance.source)/\(utterance.label)] \(utterance.text)"
        }.joined(separator: "\n\n")
        let breakdownBody = breakdownEntries.map { entry in
            "- **\(entry.name):** \(entry.utterances) utterances, ~\(entry.wordCount) words, \(entry.duration)"
        }.joined(separator: "\n")

        return """
        ---
        transcript_id: "\(transcriptId.uuidString)"
        date: 2026-04-10
        time: 15:01:23
        duration: "\(duration)"
        processing_time: "3.0s"
        transcription_engine: parakeet_local
        diarization_engine: pyannote_offline
        sources: [mic, system_audio]
        mic_utterances: 0
        system_utterances: \(utterances.count)
        mic_speakers: 0
        system_speakers: \(speakers.count)
        total_word_count: \(totalWords)
        speakers:
        \(speakersYAML)
        ---

        # \(title)

        **Duration:** \(duration) | **Words:** \(totalWords) | **Utterances:** \(utterances.count)

        ---

        ## Summary

        *Paste into your favorite AI tool for summary generation*

        ---

        ## Channel & Speaker Analytics

        ### Microphone (You)
        - **Utterances:** 0
        - **Words:** ~0
        - **Speaking Time:** 00:00

        ### Meeting Audio (Remote Participants)
        - **Utterances:** \(utterances.count)
        - **Words:** ~\(totalWords)
        - **Speaking Time:** 00:12
        - **Speakers Detected:** \(speakers.count)

        #### Remote Speaker Breakdown

        \(breakdownBody)

        ---

        ## Full Transcript

        \(transcriptBody)

        ---

        *Generated by Transcripted with Parakeet + PyAnnote (local) | Duration: \(duration) | \(totalWords) words | \(speakers.count) speakers*
        """
    }

    private func sampleTranscriptionResult(
        speakers: [MarkdownSpeaker],
        utterances: [MarkdownUtterance],
        duration: TimeInterval = 90
    ) -> TranscriptionResult {
        let speakersById = Dictionary(uniqueKeysWithValues: speakers.compactMap { speaker in
            Int(speaker.id).map { ($0, speaker) }
        })
        let speakersByName = Dictionary(grouping: speakers) { normalizeSpeakerLabel($0.name) }

        let mappedUtterances = utterances.map { utterance -> TranscriptionUtterance in
            let channel = utterance.source.caseInsensitiveCompare("Mic") == .orderedSame ? 0 : 1
            let speakerId = utterance.sortformerSpeakerId
                ?? resolvedSpeakerId(
                    for: utterance,
                    channel: channel,
                    speakersByName: speakersByName
                )
            let persistentSpeakerId = speakersById[speakerId]?.persistentSpeakerId
            let start = timestampSeconds(for: utterance.timestamp)

            return TranscriptionUtterance(
                start: start,
                end: start + utterance.speakingSeconds,
                channel: channel,
                speakerId: speakerId,
                persistentSpeakerId: persistentSpeakerId,
                matchSimilarity: nil,
                transcript: utterance.text
            )
        }

        return TranscriptionResult(
            micUtterances: mappedUtterances.filter { $0.channel == 0 },
            systemUtterances: mappedUtterances.filter { $0.channel == 1 },
            duration: duration,
            processingTime: 3.0
        )
    }

    private func resolvedSpeakerId(
        for utterance: MarkdownUtterance,
        channel: Int,
        speakersByName: [String: [MarkdownSpeaker]]
    ) -> Int {
        if let parsedId = Int(utterance.label.replacingOccurrences(of: "Speaker ", with: "")) {
            return parsedId
        }

        let normalizedLabel = normalizeSpeakerLabel(utterance.label)
        if let match = speakersByName[normalizedLabel], match.count == 1, let id = Int(match[0].id) {
            return id
        }

        return channel == 0 ? 0 : 1
    }

    private func normalizeSpeakerLabel(_ value: String) -> String {
        value
            .replacingOccurrences(of: "[[", with: "")
            .replacingOccurrences(of: "]]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func timestampSeconds(for timestamp: String) -> Double {
        let parts = timestamp.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 else { return 0 }
        return (parts[0] * 60) + parts[1]
    }
}
