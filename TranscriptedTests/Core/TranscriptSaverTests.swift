import XCTest
@testable import Transcripted

@available(macOS 14.0, *)
final class TranscriptSaverTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptSaverTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Basic save

    func testSaveCreatesFile() {
        let url = TranscriptSaver.save(text: "Hello world", duration: 60, directory: tempDir)
        XCTAssertNotNil(url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url!.path))
    }

    func testSaveContainsText() throws {
        let url = TranscriptSaver.save(text: "Testing transcript content", duration: 120, directory: tempDir)!
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("Testing transcript content"))
    }

    func testSaveContainsDuration() throws {
        let url = TranscriptSaver.save(text: "Test", duration: 125, directory: tempDir)!
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("2:05"))
    }

    func testSaveCreatesDirectoryIfNeeded() {
        let nestedDir = tempDir.appendingPathComponent("nested/deep")
        let url = TranscriptSaver.save(text: "Test", duration: 10, directory: nestedDir)
        XCTAssertNotNil(url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url!.path))
    }

    func testSaveHandlesFilenameCollision() {
        let url1 = TranscriptSaver.save(text: "First", duration: 10, directory: tempDir)
        let url2 = TranscriptSaver.save(text: "Second", duration: 10, directory: tempDir)

        XCTAssertNotNil(url1)
        XCTAssertNotNil(url2)
        XCTAssertNotEqual(url1!.path, url2!.path)
    }

    func testSaveEmptyTextShowsPlaceholder() throws {
        let url = TranscriptSaver.save(text: "", duration: 10, directory: tempDir)!
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("No transcript available"))
    }

    // MARK: - Local pipeline save (Parakeet + Sortformer format)

    func testSaveTranscriptCreatesMarkdown() {
        let result = TranscriptionResult.mock(
            micUtterances: [.mock(channel: 0, transcript: "Hello from mic")],
            systemUtterances: [.mock(channel: 1, transcript: "Hello from system")],
            duration: 90.0,
            processingTime: 5.0
        )

        let url = TranscriptSaver.saveTranscript(result, directory: tempDir)
        XCTAssertNotNil(url)
        XCTAssertEqual(url!.pathExtension, "md")
    }

    func testSaveTranscriptContainsYAMLFrontmatter() throws {
        let result = TranscriptionResult.mock(duration: 90.0, processingTime: 5.0)
        let url = TranscriptSaver.saveTranscript(result, directory: tempDir)!
        let content = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(content.hasPrefix("---\n"))
        XCTAssertTrue(content.contains("transcription_engine: parakeet_local"))
        XCTAssertTrue(content.contains("diarization_engine: pyannote_offline"))
    }

    func testSaveTranscriptContainsUtteranceCounts() throws {
        let result = TranscriptionResult.mock(
            micUtterances: [
                .mock(channel: 0, transcript: "One"),
                .mock(channel: 0, transcript: "Two")
            ],
            systemUtterances: [
                .mock(channel: 1, transcript: "Three")
            ]
        )
        let url = TranscriptSaver.saveTranscript(result, directory: tempDir)!
        let content = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(content.contains("mic_utterances: 2"))
        XCTAssertTrue(content.contains("system_utterances: 1"))
    }

    func testSaveTranscriptContainsSpeakerMappings() throws {
        let result = TranscriptionResult.mock(
            systemUtterances: [.mock(channel: 1, speakerId: 0, transcript: "Hi")]
        )
        let mappings: [String: SpeakerMapping] = [
            "system_0": SpeakerMapping(speakerId: "0", identifiedName: "Alice", confidence: .high)
        ]

        let url = TranscriptSaver.saveTranscript(result, speakerMappings: mappings, directory: tempDir)!
        let content = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(content.contains("name: \"Alice\""))
        XCTAssertTrue(content.contains("confidence: high"))
    }

    func testSaveTranscriptContainsHealthInfo() throws {
        let result = TranscriptionResult.mock()
        let health = RecordingHealthInfo(
            captureQuality: .good,
            audioGaps: 2,
            deviceSwitches: 1,
            gapDescriptions: ["Gap at 10s"]
        )

        let url = TranscriptSaver.saveTranscript(result, directory: tempDir, healthInfo: health)!
        let content = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(content.contains("capture_quality: good"))
        XCTAssertTrue(content.contains("audio_gaps: 2"))
        XCTAssertTrue(content.contains("device_switches: 1"))
    }

    func testSaveTranscriptTimelineFormat() throws {
        let result = TranscriptionResult.mock(
            micUtterances: [.mock(start: 65.0, end: 70.0, channel: 0, transcript: "Mic says hello")],
            systemUtterances: [.mock(start: 10.0, end: 15.0, channel: 1, speakerId: 0, transcript: "System says hi")]
        )

        let url = TranscriptSaver.saveTranscript(result, directory: tempDir)!
        let content = try String(contentsOf: url, encoding: .utf8)

        // Timeline uses [MM:SS] format
        XCTAssertTrue(content.contains("[00:10]"))
        XCTAssertTrue(content.contains("[01:05]"))
        // Channel labels
        XCTAssertTrue(content.contains("[Mic/You]"))
        XCTAssertTrue(content.contains("[System/Speaker 0]"))
    }

    // MARK: - Speaker name updates

    func testUpdateSpeakerNamesReplacesInFile() throws {
        let result = TranscriptionResult.mock(
            systemUtterances: [.mock(channel: 1, speakerId: 0, transcript: "Hello")]
        )
        let url = TranscriptSaver.saveTranscript(result, directory: tempDir)!

        let updates = [
            SpeakerNameUpdate(
                persistentSpeakerId: UUID(),
                sortformerSpeakerId: "0",
                newName: "Bob",
                action: .named
            )
        ]

        let success = TranscriptSaver.updateSpeakerNames(transcriptURL: url, updates: updates)
        XCTAssertTrue(success)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("[System/Bob]"))
        XCTAssertFalse(content.contains("[System/Speaker 0]"))
    }

    func testUpdateSpeakerNamesEmptyUpdatesSucceeds() {
        let result = TranscriptionResult.mock()
        let url = TranscriptSaver.saveTranscript(result, directory: tempDir)!

        let success = TranscriptSaver.updateSpeakerNames(transcriptURL: url, updates: [])
        XCTAssertTrue(success)
    }

    func testUpdateSpeakerNamesInvalidPathFails() {
        let badURL = URL(fileURLWithPath: "/nonexistent/path.md")
        let updates = [
            SpeakerNameUpdate(
                persistentSpeakerId: UUID(),
                sortformerSpeakerId: "0",
                newName: "Alice",
                action: .named
            )
        ]

        let success = TranscriptSaver.updateSpeakerNames(transcriptURL: badURL, updates: updates)
        XCTAssertFalse(success)
    }

    // MARK: - RecordingHealthInfo

    func testCaptureQualityFromSuccessRate() {
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: 1.0), .excellent)
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: 0.98), .excellent)
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: 0.95), .good)
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: 0.85), .fair)
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: 0.50), .degraded)
        XCTAssertEqual(RecordingHealthInfo.CaptureQuality.from(successRate: 0.0), .degraded)
    }

    func testPerfectHealthInfo() {
        let health = RecordingHealthInfo.perfect
        XCTAssertEqual(health.captureQuality, .excellent)
        XCTAssertEqual(health.audioGaps, 0)
        XCTAssertEqual(health.deviceSwitches, 0)
        XCTAssertTrue(health.gapDescriptions.isEmpty)
    }
}
