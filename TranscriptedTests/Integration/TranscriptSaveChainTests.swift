import XCTest
@testable import Transcripted

/// Integration test: full save chain from TranscriptionResult through to .md, .json sidecar, and index.
@available(macOS 14.0, *)
final class TranscriptSaveChainTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptSaveChainTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeResult(
        micUtterances: [TranscriptionUtterance] = [],
        systemUtterances: [TranscriptionUtterance] = [],
        duration: TimeInterval = 120.0,
        processingTime: TimeInterval = 6.0
    ) -> TranscriptionResult {
        TranscriptionResult.mock(
            micUtterances: micUtterances,
            systemUtterances: systemUtterances,
            duration: duration,
            processingTime: processingTime
        )
    }

    private func realUtterances() -> (mic: [TranscriptionUtterance], sys: [TranscriptionUtterance]) {
        let mic = [
            TranscriptionUtterance.mock(start: 0.0, end: 5.0, channel: 0, speakerId: 0, transcript: "Hello this is the mic speaker"),
            TranscriptionUtterance.mock(start: 12.0, end: 18.0, channel: 0, speakerId: 0, transcript: "I have another thing to say on the mic")
        ]
        let sys = [
            TranscriptionUtterance.mock(start: 6.0, end: 11.0, channel: 1, speakerId: 0, transcript: "This is system speaker zero responding"),
            TranscriptionUtterance.mock(start: 20.0, end: 25.0, channel: 1, speakerId: 1, transcript: "And this is system speaker one joining in")
        ]
        return (mic, sys)
    }

    // MARK: - Full Chain: Save -> Read .md -> Read .json sidecar -> Read index

    func testFullSaveChainProducesAllFiles() throws {
        let (mic, sys) = realUtterances()
        let result = makeResult(micUtterances: mic, systemUtterances: sys)

        let savedURL = TranscriptSaver.saveTranscript(result, directory: tempDir)
        XCTAssertNotNil(savedURL, "saveTranscript should return a non-nil URL")

        guard let mdURL = savedURL else { return }

        // -- Verify .md file --
        let mdContent = try String(contentsOf: mdURL, encoding: .utf8)
        XCTAssertTrue(mdContent.hasPrefix("---\n"), "Markdown should start with YAML frontmatter delimiter")
        XCTAssertTrue(mdContent.contains("date:"), "YAML should contain 'date' key")
        XCTAssertTrue(mdContent.contains("time:"), "YAML should contain 'time' key")
        XCTAssertTrue(mdContent.contains("duration:"), "YAML should contain 'duration' key")
        XCTAssertTrue(mdContent.contains("transcription_engine:"), "YAML should contain 'transcription_engine' key")
        XCTAssertTrue(mdContent.contains("diarization_engine:"), "YAML should contain 'diarization_engine' key")
        XCTAssertTrue(mdContent.contains("## Full Transcript"), "Markdown should contain Full Transcript section")
        XCTAssertTrue(mdContent.contains("## Summary"), "Markdown should contain Summary section")

        // -- Verify .json sidecar --
        let stem = mdURL.deletingPathExtension().lastPathComponent
        let jsonURL = tempDir.appendingPathComponent("\(stem).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path), "JSON sidecar should exist alongside .md")

        let jsonData = try Data(contentsOf: jsonURL)
        let decoded = try JSONDecoder().decode(AgentTranscript.self, from: jsonData)
        XCTAssertEqual(decoded.version, "1.0")
        XCTAssertEqual(decoded.recording.durationSeconds, 120)
        XCTAssertFalse(decoded.utterances.isEmpty, "JSON sidecar should contain utterances")

        // -- Verify transcripted.json index --
        let indexURL = tempDir.appendingPathComponent("transcripted.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path), "transcripted.json index should exist")

        let indexData = try Data(contentsOf: indexURL)
        let index = try JSONDecoder().decode(AgentIndex.self, from: indexData)
        XCTAssertEqual(index.transcriptCount, 1, "Index should contain exactly 1 transcript")
        XCTAssertEqual(index.transcripts.first?.filename, stem)
    }

    // MARK: - YAML Key Verification in .md

    func testMarkdownYAMLContainsAllRequiredKeys() throws {
        let (mic, sys) = realUtterances()
        let result = makeResult(micUtterances: mic, systemUtterances: sys)

        let savedURL = TranscriptSaver.saveTranscript(result, directory: tempDir)!
        let content = try String(contentsOf: savedURL, encoding: .utf8)

        let requiredKeys = [
            "date:", "time:", "duration:", "processing_time:",
            "transcription_engine:", "diarization_engine:", "sources:",
            "mic_utterances:", "system_utterances:",
            "mic_speakers:", "system_speakers:", "total_word_count:"
        ]

        for key in requiredKeys {
            XCTAssertTrue(content.contains(key), "YAML frontmatter should contain '\(key)'")
        }
    }

    // MARK: - JSON Sidecar Structure

    func testJSONSidecarContainsRequiredKeys() throws {
        let (mic, sys) = realUtterances()
        let result = makeResult(micUtterances: mic, systemUtterances: sys)

        let savedURL = TranscriptSaver.saveTranscript(result, directory: tempDir)!
        let stem = savedURL.deletingPathExtension().lastPathComponent
        let jsonURL = tempDir.appendingPathComponent("\(stem).json")

        let jsonData = try Data(contentsOf: jsonURL)
        let jsonObject = try JSONSerialization.jsonObject(with: jsonData) as! [String: Any]

        XCTAssertNotNil(jsonObject["version"], "JSON should have 'version' key")
        XCTAssertNotNil(jsonObject["recording"], "JSON should have 'recording' key")
        XCTAssertNotNil(jsonObject["utterances"], "JSON should have 'utterances' key")

        let recording = jsonObject["recording"] as! [String: Any]
        XCTAssertNotNil(recording["date"])
        XCTAssertNotNil(recording["duration_seconds"])
        XCTAssertNotNil(recording["engines"])
    }

    // MARK: - Empty Utterances

    func testSaveWithEmptyUtterancesProducesValidFiles() throws {
        let result = makeResult()  // no utterances

        let savedURL = TranscriptSaver.saveTranscript(result, directory: tempDir)
        XCTAssertNotNil(savedURL, "Should succeed even with empty utterances")

        let content = try String(contentsOf: savedURL!, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("---\n"))
        XCTAssertTrue(content.contains("mic_utterances: 0"))
        XCTAssertTrue(content.contains("system_utterances: 0"))
        XCTAssertTrue(content.contains("total_word_count: 0"))

        // JSON sidecar should also exist
        let stem = savedURL!.deletingPathExtension().lastPathComponent
        let jsonURL = tempDir.appendingPathComponent("\(stem).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: jsonURL.path))

        let decoded = try JSONDecoder().decode(AgentTranscript.self, from: Data(contentsOf: jsonURL))
        XCTAssertTrue(decoded.utterances.isEmpty)
        XCTAssertTrue(decoded.speakers.isEmpty)
    }

    // MARK: - Speaker Mappings

    func testSaveWithSpeakerMappingsIncludesNamesInMarkdown() throws {
        let sys = [
            TranscriptionUtterance.mock(start: 0.0, end: 5.0, channel: 1, speakerId: 0, transcript: "Hello from Alice"),
            TranscriptionUtterance.mock(start: 6.0, end: 11.0, channel: 1, speakerId: 1, transcript: "Hello from Bob")
        ]
        let result = makeResult(systemUtterances: sys)
        let mappings: [String: SpeakerMapping] = [
            "system_0": SpeakerMapping(speakerId: "0", identifiedName: "Alice", confidence: .high),
            "system_1": SpeakerMapping(speakerId: "1", identifiedName: "Bob", confidence: .medium)
        ]

        let savedURL = TranscriptSaver.saveTranscript(result, speakerMappings: mappings, directory: tempDir)!
        let content = try String(contentsOf: savedURL, encoding: .utf8)

        // Speaker names appear in YAML frontmatter
        XCTAssertTrue(content.contains("name: \"Alice\""), "YAML should contain Alice's name")
        XCTAssertTrue(content.contains("name: \"Bob\""), "YAML should contain Bob's name")

        // Speaker names appear in transcript body
        XCTAssertTrue(content.contains("[System/Alice]"), "Transcript body should use Alice's name")
        // Bob has medium confidence, displayName appends "?"
        XCTAssertTrue(content.contains("[System/Bob?]"), "Transcript body should use Bob's name with ? for medium confidence")
    }

    // MARK: - Meeting Title

    func testSaveWithMeetingTitleIncludesTitleInYAML() throws {
        let (mic, sys) = realUtterances()
        let result = makeResult(micUtterances: mic, systemUtterances: sys)

        let savedURL = TranscriptSaver.saveTranscript(
            result,
            directory: tempDir,
            meetingTitle: "Sprint Planning Q2"
        )!
        let content = try String(contentsOf: savedURL, encoding: .utf8)

        XCTAssertTrue(content.contains("title: \"Sprint Planning Q2\""), "YAML should contain the meeting title")
    }

    // MARK: - Index Contains Transcript Entry

    func testIndexUpdatedWithTranscriptEntry() throws {
        let (mic, sys) = realUtterances()
        let result = makeResult(micUtterances: mic, systemUtterances: sys)

        let savedURL = TranscriptSaver.saveTranscript(result, directory: tempDir)!
        let stem = savedURL.deletingPathExtension().lastPathComponent

        let indexURL = tempDir.appendingPathComponent("transcripted.json")
        let indexData = try Data(contentsOf: indexURL)
        let index = try JSONDecoder().decode(AgentIndex.self, from: indexData)

        XCTAssertEqual(index.transcriptCount, 1)
        XCTAssertEqual(index.transcripts.count, 1)

        let entry = index.transcripts[0]
        XCTAssertEqual(entry.filename, stem)
        XCTAssertEqual(entry.durationSeconds, 120)
        XCTAssertGreaterThan(entry.wordCount, 0)
        XCTAssertGreaterThan(entry.speakerCount, 0)
    }

    // MARK: - Health Info in Markdown

    func testSaveWithHealthInfoIncludesMetrics() throws {
        let result = makeResult(
            micUtterances: [.mock(channel: 0, transcript: "test")],
            systemUtterances: [.mock(channel: 1, transcript: "test")]
        )
        let health = RecordingHealthInfo(
            captureQuality: .fair,
            audioGaps: 3,
            deviceSwitches: 1,
            gapDescriptions: ["Gap at 15s", "Gap at 42s", "Gap at 78s"]
        )

        let savedURL = TranscriptSaver.saveTranscript(result, directory: tempDir, healthInfo: health)!
        let content = try String(contentsOf: savedURL, encoding: .utf8)

        XCTAssertTrue(content.contains("capture_quality: fair"))
        XCTAssertTrue(content.contains("audio_gaps: 3"))
        XCTAssertTrue(content.contains("device_switches: 1"))
        XCTAssertTrue(content.contains("gap_events:"))
        XCTAssertTrue(content.contains("Gap at 15s"))
    }
}
