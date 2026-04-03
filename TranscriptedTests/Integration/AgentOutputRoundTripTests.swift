import XCTest
@testable import Transcripted

/// Integration test: AgentOutput round-trip -- write JSON sidecar and index, read back, verify structure.
@available(macOS 14.0, *)
final class AgentOutputRoundTripTests: XCTestCase {

    private var tempDir: URL!
    private var speakerDB: SpeakerDatabase!
    private var speakerDBPath: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentOutputRoundTripTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        // Create an isolated speaker DB for index generation
        speakerDBPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentOutputRoundTrip-speakers-\(UUID().uuidString).sqlite")
        speakerDB = SpeakerDatabase(path: speakerDBPath.path)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        speakerDB = nil
        for ext in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: speakerDBPath.path + ext)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    private func sampleResult(
        micTranscript: String = "Hello from the microphone",
        systemTranscripts: [(speakerId: Int, text: String)] = [
            (0, "System speaker zero says hello to everyone"),
            (1, "And speaker one joins the conversation now")
        ],
        duration: TimeInterval = 120.0,
        droppedSegments: Int = 0
    ) -> TranscriptionResult {
        let mic = [
            TranscriptionUtterance.mock(start: 0.0, end: 5.0, channel: 0, speakerId: 0, transcript: micTranscript)
        ]
        var sys: [TranscriptionUtterance] = []
        var startTime = 6.0
        for (speakerId, text) in systemTranscripts {
            sys.append(TranscriptionUtterance.mock(
                start: startTime,
                end: startTime + 5.0,
                channel: 1,
                speakerId: speakerId,
                transcript: text
            ))
            startTime += 7.0
        }
        return TranscriptionResult(
            micUtterances: mic,
            systemUtterances: sys,
            duration: duration,
            processingTime: 8.0,
            droppedSegments: droppedSegments
        )
    }

    private func sampleMappings() -> [String: SpeakerMapping] {
        [
            "mic_0": SpeakerMapping(speakerId: "0", identifiedName: "You"),
            "system_0": SpeakerMapping(speakerId: "0", identifiedName: "Sarah", confidence: .high),
            "system_1": SpeakerMapping(speakerId: "1", identifiedName: "Jake", confidence: .medium)
        ]
    }

    // MARK: - Write + Read JSON Sidecar

    func testWriteTranscriptJSONThenReadBackAllFields() throws {
        let result = sampleResult()
        let mappings = sampleMappings()
        let dbIds: [String: UUID] = ["0": UUID(), "1": UUID()]

        try AgentOutput.writeTranscriptJSON(
            from: result,
            speakerMappings: mappings,
            speakerDbIds: dbIds,
            to: tempDir,
            stem: "Call_RoundTrip"
        )

        let jsonURL = tempDir.appendingPathComponent("Call_RoundTrip.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))

        let data = try Data(contentsOf: jsonURL)
        let decoded = try JSONDecoder().decode(AgentTranscript.self, from: data)

        // version
        XCTAssertEqual(decoded.version, "1.0")

        // recording
        XCTAssertEqual(decoded.recording.durationSeconds, 120)
        XCTAssertEqual(decoded.recording.droppedSegments, 0)
        XCTAssertEqual(decoded.recording.engines.stt, "parakeet-tdt-v3")
        XCTAssertEqual(decoded.recording.engines.diarization, "pyannote-offline")
        XCTAssertFalse(decoded.recording.date.isEmpty, "Recording date should not be empty")

        // speakers: 1 mic + 2 system = 3
        XCTAssertEqual(decoded.speakers.count, 3)
        let speakerIds = Set(decoded.speakers.map { $0.id })
        XCTAssertTrue(speakerIds.contains("mic_0"))
        XCTAssertTrue(speakerIds.contains("system_0"))
        XCTAssertTrue(speakerIds.contains("system_1"))

        // Speaker names from mappings
        let sarahSpeaker = decoded.speakers.first { $0.id == "system_0" }
        XCTAssertEqual(sarahSpeaker?.name, "Sarah")
        XCTAssertEqual(sarahSpeaker?.confidence, "high")

        // Persistent speaker IDs
        let system0 = decoded.speakers.first { $0.id == "system_0" }
        XCTAssertEqual(system0?.persistentSpeakerId, dbIds["0"]?.uuidString)

        // utterances
        XCTAssertEqual(decoded.utterances.count, 3, "Should have 1 mic + 2 system utterances")
    }

    // MARK: - Utterances Sorted by Start Time

    func testUtterancesAreSortedByStartTime() throws {
        // Create utterances that are intentionally out of order in their channels
        let mic = [
            TranscriptionUtterance.mock(start: 10.0, end: 15.0, channel: 0, speakerId: 0, transcript: "Mic later")
        ]
        let sys = [
            TranscriptionUtterance.mock(start: 2.0, end: 5.0, channel: 1, speakerId: 0, transcript: "Sys early"),
            TranscriptionUtterance.mock(start: 7.0, end: 9.0, channel: 1, speakerId: 1, transcript: "Sys middle"),
            TranscriptionUtterance.mock(start: 20.0, end: 25.0, channel: 1, speakerId: 0, transcript: "Sys late")
        ]
        let result = TranscriptionResult(
            micUtterances: mic,
            systemUtterances: sys,
            duration: 30.0,
            processingTime: 3.0
        )

        try AgentOutput.writeTranscriptJSON(
            from: result,
            speakerMappings: [:],
            speakerDbIds: [:],
            to: tempDir,
            stem: "Call_Sorted"
        )

        let data = try Data(contentsOf: tempDir.appendingPathComponent("Call_Sorted.json"))
        let decoded = try JSONDecoder().decode(AgentTranscript.self, from: data)

        XCTAssertEqual(decoded.utterances.count, 4)
        for i in 1..<decoded.utterances.count {
            XCTAssertLessThanOrEqual(
                decoded.utterances[i - 1].start,
                decoded.utterances[i].start,
                "Utterances must be sorted by start time: \(decoded.utterances[i-1].start) should be <= \(decoded.utterances[i].start)"
            )
        }
    }

    // MARK: - Write Index + Verify Structure

    func testWriteIndexCreatesValidStructure() throws {
        // Write a sidecar first
        let result = sampleResult()
        try AgentOutput.writeTranscriptJSON(
            from: result,
            speakerMappings: sampleMappings(),
            speakerDbIds: [:],
            to: tempDir,
            stem: "Call_IndexTest"
        )

        // Write the index
        try AgentOutput.writeIndex(to: tempDir, speakerDB: speakerDB)

        let indexURL = tempDir.appendingPathComponent("transcripted.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))

        let data = try Data(contentsOf: indexURL)
        let index = try JSONDecoder().decode(AgentIndex.self, from: data)

        XCTAssertEqual(index.version, "1.0")
        XCTAssertEqual(index.transcriptCount, 1)
        XCTAssertEqual(index.transcripts.count, 1)
        XCTAssertFalse(index.updatedAt.isEmpty, "updated_at should be populated")

        let entry = index.transcripts[0]
        XCTAssertEqual(entry.filename, "Call_IndexTest")
        XCTAssertEqual(entry.durationSeconds, 120)
        XCTAssertGreaterThan(entry.wordCount, 0)
        XCTAssertGreaterThan(entry.speakerCount, 0)
    }

    // MARK: - Two Transcripts in Index

    func testIndexHasTwoEntriesAfterTwoSaves() throws {
        let result1 = sampleResult(micTranscript: "First meeting transcript")
        let result2 = sampleResult(
            micTranscript: "Second meeting transcript",
            systemTranscripts: [(0, "Only one remote speaker this time")],
            duration: 60.0
        )

        // Write first sidecar
        try AgentOutput.writeTranscriptJSON(
            from: result1,
            speakerMappings: [:],
            speakerDbIds: [:],
            to: tempDir,
            stem: "Call_First"
        )

        // Write second sidecar
        try AgentOutput.writeTranscriptJSON(
            from: result2,
            speakerMappings: [:],
            speakerDbIds: [:],
            to: tempDir,
            stem: "Call_Second"
        )

        // Rebuild the index
        try AgentOutput.writeIndex(to: tempDir, speakerDB: speakerDB)

        let data = try Data(contentsOf: tempDir.appendingPathComponent("transcripted.json"))
        let index = try JSONDecoder().decode(AgentIndex.self, from: data)

        XCTAssertEqual(index.transcriptCount, 2, "Index should contain 2 transcripts")
        XCTAssertEqual(index.transcripts.count, 2)

        let filenames = Set(index.transcripts.map { $0.filename })
        XCTAssertTrue(filenames.contains("Call_First"))
        XCTAssertTrue(filenames.contains("Call_Second"))

        // Verify different durations
        let first = index.transcripts.first { $0.filename == "Call_First" }
        let second = index.transcripts.first { $0.filename == "Call_Second" }
        XCTAssertEqual(first?.durationSeconds, 120)
        XCTAssertEqual(second?.durationSeconds, 60)
    }

    // MARK: - Dropped Segments Persisted

    func testDroppedSegmentsRoundTrip() throws {
        let result = sampleResult(droppedSegments: 7)

        try AgentOutput.writeTranscriptJSON(
            from: result,
            speakerMappings: [:],
            speakerDbIds: [:],
            to: tempDir,
            stem: "Call_Dropped"
        )

        let data = try Data(contentsOf: tempDir.appendingPathComponent("Call_Dropped.json"))
        let decoded = try JSONDecoder().decode(AgentTranscript.self, from: data)

        XCTAssertEqual(decoded.recording.droppedSegments, 7)
    }

    // MARK: - Speaker Word Count and Speaking Time

    func testSpeakerWordCountAndSpeakingTimeAccurate() throws {
        let mic = [
            TranscriptionUtterance.mock(start: 0.0, end: 5.0, channel: 0, speakerId: 0, transcript: "one two three four five")
        ]
        let sys = [
            TranscriptionUtterance.mock(start: 6.0, end: 10.0, channel: 1, speakerId: 0, transcript: "six seven eight")
        ]
        let result = TranscriptionResult(
            micUtterances: mic,
            systemUtterances: sys,
            duration: 15.0,
            processingTime: 2.0
        )

        try AgentOutput.writeTranscriptJSON(
            from: result,
            speakerMappings: [:],
            speakerDbIds: [:],
            to: tempDir,
            stem: "Call_Words"
        )

        let data = try Data(contentsOf: tempDir.appendingPathComponent("Call_Words.json"))
        let decoded = try JSONDecoder().decode(AgentTranscript.self, from: data)

        let micSpeaker = decoded.speakers.first { $0.id == "mic_0" }
        XCTAssertEqual(micSpeaker?.wordCount, 5, "Mic speaker should have 5 words")
        XCTAssertEqual(micSpeaker?.speakingSeconds ?? 0, 5.0, accuracy: 0.1, "Mic speaking time should be ~5.0s")

        let sysSpeaker = decoded.speakers.first { $0.id == "system_0" }
        XCTAssertEqual(sysSpeaker?.wordCount, 3, "System speaker should have 3 words")
        XCTAssertEqual(sysSpeaker?.speakingSeconds ?? 0, 4.0, accuracy: 0.1, "System speaking time should be ~4.0s")
    }

    // MARK: - Empty Result

    func testEmptyResultProducesValidJSON() throws {
        let result = TranscriptionResult.mock()

        try AgentOutput.writeTranscriptJSON(
            from: result,
            speakerMappings: [:],
            speakerDbIds: [:],
            to: tempDir,
            stem: "Call_Empty"
        )

        let data = try Data(contentsOf: tempDir.appendingPathComponent("Call_Empty.json"))
        let decoded = try JSONDecoder().decode(AgentTranscript.self, from: data)

        XCTAssertEqual(decoded.version, "1.0")
        XCTAssertTrue(decoded.speakers.isEmpty, "No speakers for empty result")
        XCTAssertTrue(decoded.utterances.isEmpty, "No utterances for empty result")
        XCTAssertEqual(decoded.recording.durationSeconds, 60) // mock default
    }

    // MARK: - Index Excludes Non-Sidecar JSON

    func testIndexIgnoresTranscriptedJsonItself() throws {
        // Write a real sidecar
        let result = sampleResult()
        try AgentOutput.writeTranscriptJSON(
            from: result,
            speakerMappings: [:],
            speakerDbIds: [:],
            to: tempDir,
            stem: "Call_Real"
        )

        // Write the index (creates transcripted.json)
        try AgentOutput.writeIndex(to: tempDir, speakerDB: speakerDB)

        // Also write a dummy failed_transcriptions.json (should be excluded)
        let dummyJSON = "{}".data(using: .utf8)!
        try dummyJSON.write(to: tempDir.appendingPathComponent("failed_transcriptions.json"))

        // Rebuild index again
        try AgentOutput.writeIndex(to: tempDir, speakerDB: speakerDB)

        let data = try Data(contentsOf: tempDir.appendingPathComponent("transcripted.json"))
        let index = try JSONDecoder().decode(AgentIndex.self, from: data)

        // Should only include Call_Real.json, not transcripted.json or failed_transcriptions.json
        XCTAssertEqual(index.transcriptCount, 1)
        XCTAssertEqual(index.transcripts.first?.filename, "Call_Real")
    }

    // MARK: - Known Speakers in Index from Speaker DB

    func testIndexIncludesKnownSpeakersFromDB() throws {
        // Add a named speaker to the isolated DB
        let embedding = (0..<256).map { _ in Float.random(in: -1...1) }
        let profile = speakerDB.addOrUpdateSpeaker(embedding: embedding)
        speakerDB.setDisplayName(id: profile.id, name: "TestSpeaker", source: "test")

        // Write a sidecar so the index has something
        let result = sampleResult()
        try AgentOutput.writeTranscriptJSON(
            from: result,
            speakerMappings: [:],
            speakerDbIds: [:],
            to: tempDir,
            stem: "Call_WithSpeaker"
        )

        try AgentOutput.writeIndex(to: tempDir, speakerDB: speakerDB)

        let data = try Data(contentsOf: tempDir.appendingPathComponent("transcripted.json"))
        let index = try JSONDecoder().decode(AgentIndex.self, from: data)

        XCTAssertFalse(index.knownSpeakers.isEmpty, "Index should include known speakers from the DB")
        let testSpeaker = index.knownSpeakers.first { $0.name == "TestSpeaker" }
        XCTAssertNotNil(testSpeaker, "Should find TestSpeaker in known speakers")
        XCTAssertEqual(testSpeaker?.callCount, 1)
        XCTAssertEqual(testSpeaker?.persistentId, profile.id.uuidString)
    }

    // MARK: - Utterance Text Preserved Exactly

    func testUtteranceTextPreservedExactly() throws {
        let specialText = "Hello, this has \"quotes\" and special chars: <>&"
        let result = TranscriptionResult(
            micUtterances: [.mock(start: 0, end: 3, channel: 0, transcript: specialText)],
            systemUtterances: [],
            duration: 5.0,
            processingTime: 1.0
        )

        try AgentOutput.writeTranscriptJSON(
            from: result,
            speakerMappings: [:],
            speakerDbIds: [:],
            to: tempDir,
            stem: "Call_Special"
        )

        let data = try Data(contentsOf: tempDir.appendingPathComponent("Call_Special.json"))
        let decoded = try JSONDecoder().decode(AgentTranscript.self, from: data)

        XCTAssertEqual(decoded.utterances.first?.text, specialText, "Utterance text should survive JSON round-trip exactly")
    }
}
