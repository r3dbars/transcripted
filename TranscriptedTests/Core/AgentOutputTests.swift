import XCTest
@testable import Transcripted

final class AgentOutputTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func sampleResult(droppedSegments: Int = 0) -> TranscriptionResult {
        let mic = [
            TranscriptionUtterance.mock(start: 0.0, end: 5.0, channel: 0, speakerId: 0, transcript: "Hello from mic")
        ]
        let sys = [
            TranscriptionUtterance.mock(start: 1.0, end: 4.0, channel: 1, speakerId: 0, persistentSpeakerId: UUID(), transcript: "Hello from system speaker zero"),
            TranscriptionUtterance.mock(start: 6.0, end: 10.0, channel: 1, speakerId: 1, persistentSpeakerId: UUID(), transcript: "And speaker one here")
        ]
        return TranscriptionResult(
            micUtterances: mic,
            systemUtterances: sys,
            duration: 120.0,
            processingTime: 8.0,
            droppedSegments: droppedSegments
        )
    }

    private func sampleMappings() -> [String: SpeakerMapping] {
        [
            "mic_0": SpeakerMapping(speakerId: "0", identifiedName: "You"),
            "system_0": SpeakerMapping(speakerId: "0", identifiedName: "Sarah Chen", confidence: .high),
            "system_1": SpeakerMapping(speakerId: "1", identifiedName: "Speaker 1")
        ]
    }

    // MARK: - Tests

    func testWriteTranscriptJSONRoundTrip() throws {
        let result = sampleResult()
        let mappings = sampleMappings()

        try AgentOutput.writeTranscriptJSON(
            from: result,
            speakerMappings: mappings,
            speakerDbIds: [:],
            to: tempDir,
            stem: "Call_Test"
        )

        let jsonURL = tempDir.appendingPathComponent("Call_Test.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))

        let data = try Data(contentsOf: jsonURL)
        let decoded = try JSONDecoder().decode(AgentTranscript.self, from: data)

        XCTAssertEqual(decoded.version, "1.0")
        XCTAssertEqual(decoded.recording.durationSeconds, 120)
        XCTAssertEqual(decoded.recording.engines.stt, "parakeet-tdt-v3")
        XCTAssertEqual(decoded.recording.engines.diarization, "pyannote-offline")
    }

    func testJSONContainsAllSpeakers() throws {
        let result = sampleResult()
        let mappings = sampleMappings()

        try AgentOutput.writeTranscriptJSON(
            from: result,
            speakerMappings: mappings,
            speakerDbIds: [:],
            to: tempDir,
            stem: "Call_Speakers"
        )

        let data = try Data(contentsOf: tempDir.appendingPathComponent("Call_Speakers.json"))
        let decoded = try JSONDecoder().decode(AgentTranscript.self, from: data)

        // 1 mic speaker + 2 system speakers = 3
        XCTAssertEqual(decoded.speakers.count, 3)

        let speakerIds = Set(decoded.speakers.map { $0.id })
        XCTAssertTrue(speakerIds.contains("mic_0"))
        XCTAssertTrue(speakerIds.contains("system_0"))
        XCTAssertTrue(speakerIds.contains("system_1"))
    }

    func testJSONUtterancesChronological() throws {
        let result = sampleResult()

        try AgentOutput.writeTranscriptJSON(
            from: result,
            speakerMappings: [:],
            speakerDbIds: [:],
            to: tempDir,
            stem: "Call_Chrono"
        )

        let data = try Data(contentsOf: tempDir.appendingPathComponent("Call_Chrono.json"))
        let decoded = try JSONDecoder().decode(AgentTranscript.self, from: data)

        for i in 1..<decoded.utterances.count {
            XCTAssertLessThanOrEqual(decoded.utterances[i - 1].start, decoded.utterances[i].start,
                "Utterances should be sorted chronologically")
        }
    }

    func testDroppedSegmentsInJSON() throws {
        let result = sampleResult(droppedSegments: 5)

        try AgentOutput.writeTranscriptJSON(
            from: result,
            speakerMappings: [:],
            speakerDbIds: [:],
            to: tempDir,
            stem: "Call_Dropped"
        )

        let data = try Data(contentsOf: tempDir.appendingPathComponent("Call_Dropped.json"))
        let decoded = try JSONDecoder().decode(AgentTranscript.self, from: data)

        XCTAssertEqual(decoded.recording.droppedSegments, 5)
    }

    func testAgentReadmeWrittenOnce() {
        AgentOutput.writeAgentReadme(to: tempDir)
        let fileURL = tempDir.appendingPathComponent("AGENT.md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))

        // Get modification date
        let attrs1 = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let date1 = attrs1?[.modificationDate] as? Date

        // Write again — should NOT overwrite
        AgentOutput.writeAgentReadme(to: tempDir)
        let attrs2 = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        let date2 = attrs2?[.modificationDate] as? Date

        XCTAssertEqual(date1, date2, "AGENT.md should not be overwritten on second call")
    }

    func testClipboardPromptContainsPath() {
        let prompt = AgentOutput.clipboardPrompt(folder: tempDir, filename: nil)
        XCTAssertTrue(prompt.contains(tempDir.path), "Prompt should contain the folder path")
        XCTAssertTrue(prompt.contains("AGENT.md"), "Prompt should reference AGENT.md")
        XCTAssertTrue(prompt.contains("transcripted.json"), "Prompt should reference the index file")
    }

    func testClipboardPromptWithFilename() {
        let prompt = AgentOutput.clipboardPrompt(folder: tempDir, filename: "Call_2026-03-12")
        XCTAssertTrue(prompt.contains("Call_2026-03-12.json"), "Per-transcript prompt should include the filename")
    }

    func testWriteIndexCreatesFile() throws {
        // Write a sidecar first so there's something to index
        let result = sampleResult()
        try AgentOutput.writeTranscriptJSON(
            from: result,
            speakerMappings: sampleMappings(),
            speakerDbIds: [:],
            to: tempDir,
            stem: "Call_IndexTest"
        )

        try AgentOutput.writeIndex(to: tempDir, speakerDB: SpeakerDatabase.shared)

        let indexURL = tempDir.appendingPathComponent("transcripted.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))

        let data = try Data(contentsOf: indexURL)
        let decoded = try JSONDecoder().decode(AgentIndex.self, from: data)

        XCTAssertEqual(decoded.version, "1.0")
        XCTAssertEqual(decoded.transcriptCount, 1)
        XCTAssertEqual(decoded.transcripts.count, 1)
        XCTAssertEqual(decoded.transcripts[0].filename, "Call_IndexTest")
    }

    func testJSONUpdatedOnSpeakerRename() throws {
        let result = sampleResult()
        let mappings: [String: SpeakerMapping] = [
            "system_0": SpeakerMapping(speakerId: "0", identifiedName: "Speaker 0"),
            "system_1": SpeakerMapping(speakerId: "1", identifiedName: "Speaker 1")
        ]

        try AgentOutput.writeTranscriptJSON(
            from: result,
            speakerMappings: mappings,
            speakerDbIds: [:],
            to: tempDir,
            stem: "Call_Rename"
        )

        // Read original
        let jsonURL = tempDir.appendingPathComponent("Call_Rename.json")
        var data = try Data(contentsOf: jsonURL)
        var decoded = try JSONDecoder().decode(AgentTranscript.self, from: data)
        let originalName = decoded.speakers.first { $0.id == "system_0" }?.name
        XCTAssertEqual(originalName, "Speaker 0")

        // Simulate rename: re-read, update speaker, write back
        var updatedSpeakers = decoded.speakers
        if let idx = updatedSpeakers.firstIndex(where: { $0.id == "system_0" }) {
            let old = updatedSpeakers[idx]
            updatedSpeakers[idx] = AgentSpeaker(
                id: old.id,
                persistentSpeakerId: old.persistentSpeakerId,
                name: "Sarah Chen",
                confidence: old.confidence,
                wordCount: old.wordCount,
                speakingSeconds: old.speakingSeconds
            )
        }
        let updated = AgentTranscript(
            version: decoded.version,
            recording: decoded.recording,
            speakers: updatedSpeakers,
            utterances: decoded.utterances
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let newData = try encoder.encode(updated)
        try newData.write(to: jsonURL, options: .atomic)

        // Verify rename persisted
        data = try Data(contentsOf: jsonURL)
        decoded = try JSONDecoder().decode(AgentTranscript.self, from: data)
        let renamedName = decoded.speakers.first { $0.id == "system_0" }?.name
        XCTAssertEqual(renamedName, "Sarah Chen")
    }
}
