import XCTest
@testable import Transcripted

/// Integration test: format a TranscriptionResult to markdown and parse it back,
/// verifying YAML frontmatter values match the input data.
@available(macOS 14.0, *)
final class TranscriptFormatterRoundTripTests: XCTestCase {

    // MARK: - Helpers

    /// Extract the YAML block between the first pair of "---" delimiters.
    private func extractYAML(from markdown: String) -> String? {
        let delimiter = "---"
        guard markdown.hasPrefix(delimiter) else { return nil }

        let afterFirst = markdown.dropFirst(delimiter.count)
        guard let endRange = afterFirst.range(of: "\n\(delimiter)\n") else { return nil }
        return String(afterFirst[afterFirst.startIndex..<endRange.lowerBound])
    }

    /// Parse a simple YAML string into a dictionary (flat keys only).
    /// Sufficient for verifying scalar YAML frontmatter values.
    private func parseYAMLFlat(_ yaml: String) -> [String: String] {
        var dict: [String: String] = [:]
        for line in yaml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip list items, empty lines, and nested keys
            guard !trimmed.isEmpty, !trimmed.hasPrefix("-"), !trimmed.hasPrefix("#") else { continue }
            if let colonIndex = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[trimmed.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                // Skip nested YAML (keys that introduce a list or map with no inline value)
                if !value.isEmpty {
                    dict[key] = value
                }
            }
        }
        return dict
    }

    private func sampleResult(
        micUtterances: [TranscriptionUtterance]? = nil,
        systemUtterances: [TranscriptionUtterance]? = nil,
        duration: TimeInterval = 180.0,
        processingTime: TimeInterval = 12.0
    ) -> TranscriptionResult {
        let defaultMic = [
            TranscriptionUtterance.mock(start: 0.0, end: 4.0, channel: 0, speakerId: 0, transcript: "Hello from the microphone side"),
            TranscriptionUtterance.mock(start: 15.0, end: 20.0, channel: 0, speakerId: 0, transcript: "Another mic utterance here")
        ]
        let defaultSys = [
            TranscriptionUtterance.mock(start: 5.0, end: 10.0, channel: 1, speakerId: 0, transcript: "System speaker zero says hello to everyone"),
            TranscriptionUtterance.mock(start: 22.0, end: 28.0, channel: 1, speakerId: 1, transcript: "Speaker one joins the conversation now")
        ]
        return TranscriptionResult.mock(
            micUtterances: micUtterances ?? defaultMic,
            systemUtterances: systemUtterances ?? defaultSys,
            duration: duration,
            processingTime: processingTime
        )
    }

    // MARK: - YAML Key Round-Trip Verification

    func testYAMLKeysMatchInputData() {
        let result = sampleResult()
        let markdown = TranscriptSaver.formatTranscriptMarkdown(result: result, date: Date())

        let yaml = extractYAML(from: markdown)
        XCTAssertNotNil(yaml, "Should be able to extract YAML block")

        let dict = parseYAMLFlat(yaml!)

        // Duration: 180s = 3:00
        XCTAssertEqual(dict["duration"], "\"3:00\"", "Duration should match 180 seconds formatted as 3:00")
        XCTAssertEqual(dict["transcription_engine"], "parakeet_local")
        XCTAssertEqual(dict["diarization_engine"], "pyannote_offline")
        XCTAssertEqual(dict["sources"], "[mic, system_audio]")
    }

    // MARK: - Mic Utterance Count

    func testMicUtterancesCountMatchesActual() {
        let micUtterances = [
            TranscriptionUtterance.mock(start: 0.0, end: 3.0, channel: 0, speakerId: 0, transcript: "One"),
            TranscriptionUtterance.mock(start: 5.0, end: 8.0, channel: 0, speakerId: 0, transcript: "Two"),
            TranscriptionUtterance.mock(start: 10.0, end: 13.0, channel: 0, speakerId: 0, transcript: "Three")
        ]
        let result = sampleResult(micUtterances: micUtterances, systemUtterances: [])
        let markdown = TranscriptSaver.formatTranscriptMarkdown(result: result, date: Date())

        let yaml = extractYAML(from: markdown)!
        let dict = parseYAMLFlat(yaml)

        XCTAssertEqual(dict["mic_utterances"], "3", "mic_utterances should match actual count")
    }

    // MARK: - System Utterance Count

    func testSystemUtterancesCountMatchesActual() {
        let sysUtterances = [
            TranscriptionUtterance.mock(start: 0.0, end: 3.0, channel: 1, speakerId: 0, transcript: "Alpha"),
            TranscriptionUtterance.mock(start: 5.0, end: 8.0, channel: 1, speakerId: 1, transcript: "Beta")
        ]
        let result = sampleResult(micUtterances: [], systemUtterances: sysUtterances)
        let markdown = TranscriptSaver.formatTranscriptMarkdown(result: result, date: Date())

        let yaml = extractYAML(from: markdown)!
        let dict = parseYAMLFlat(yaml)

        XCTAssertEqual(dict["system_utterances"], "2", "system_utterances should match actual count")
    }

    // MARK: - Total Word Count

    func testTotalWordCountMatchesActual() {
        let mic = [
            TranscriptionUtterance.mock(start: 0.0, end: 3.0, channel: 0, speakerId: 0, transcript: "one two three")
        ]
        let sys = [
            TranscriptionUtterance.mock(start: 5.0, end: 8.0, channel: 1, speakerId: 0, transcript: "four five six seven")
        ]
        let result = sampleResult(micUtterances: mic, systemUtterances: sys)
        let markdown = TranscriptSaver.formatTranscriptMarkdown(result: result, date: Date())

        // Expected: 3 mic words + 4 system words = 7
        let expectedTotal = result.micWordCount + result.systemWordCount
        XCTAssertEqual(expectedTotal, 7)

        let yaml = extractYAML(from: markdown)!
        let dict = parseYAMLFlat(yaml)

        XCTAssertEqual(dict["total_word_count"], "\(expectedTotal)", "total_word_count should be sum of mic + system words")
    }

    // MARK: - Speaker Mappings in Body Text

    func testSpeakerMappingsAppearInBodyText() {
        let sys = [
            TranscriptionUtterance.mock(start: 0.0, end: 5.0, channel: 1, speakerId: 0, transcript: "Hello from Alice"),
            TranscriptionUtterance.mock(start: 6.0, end: 11.0, channel: 1, speakerId: 1, transcript: "Hello from Bob")
        ]
        let result = sampleResult(micUtterances: [], systemUtterances: sys)
        let mappings: [String: SpeakerMapping] = [
            "system_0": SpeakerMapping(speakerId: "0", identifiedName: "Alice", confidence: .high),
            "system_1": SpeakerMapping(speakerId: "1", identifiedName: "Bob", confidence: .high)
        ]

        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: result,
            speakerMappings: mappings,
            date: Date()
        )

        XCTAssertTrue(markdown.contains("[System/Alice]"), "Body should contain Alice's speaker label")
        XCTAssertTrue(markdown.contains("[System/Bob]"), "Body should contain Bob's speaker label")
        XCTAssertFalse(markdown.contains("[System/Speaker 0]"), "Generic speaker label should be replaced by Alice")
        XCTAssertFalse(markdown.contains("[System/Speaker 1]"), "Generic speaker label should be replaced by Bob")
    }

    // MARK: - Without Speaker Mappings

    func testWithoutSpeakerMappingsUsesGenericLabels() {
        let sys = [
            TranscriptionUtterance.mock(start: 0.0, end: 5.0, channel: 1, speakerId: 0, transcript: "Hi there"),
            TranscriptionUtterance.mock(start: 6.0, end: 11.0, channel: 1, speakerId: 1, transcript: "Goodbye now")
        ]
        let mic = [
            TranscriptionUtterance.mock(start: 3.0, end: 4.0, channel: 0, speakerId: 0, transcript: "Okay")
        ]
        let result = sampleResult(micUtterances: mic, systemUtterances: sys)

        let markdown = TranscriptSaver.formatTranscriptMarkdown(result: result, date: Date())

        XCTAssertTrue(markdown.contains("[System/Speaker 0]"), "Should use generic Speaker 0 label")
        XCTAssertTrue(markdown.contains("[System/Speaker 1]"), "Should use generic Speaker 1 label")
        XCTAssertTrue(markdown.contains("[Mic/You]"), "Mic speaker should be labeled 'You'")
    }

    // MARK: - YAML Date Matches Input Date

    func testYAMLDateMatchesInputDate() {
        let result = sampleResult()
        let testDate = Date()

        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd"
        let expectedDate = isoFormatter.string(from: testDate)

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        let expectedTime = timeFormatter.string(from: testDate)

        let markdown = TranscriptSaver.formatTranscriptMarkdown(result: result, date: testDate)

        let yaml = extractYAML(from: markdown)!
        let dict = parseYAMLFlat(yaml)

        XCTAssertEqual(dict["date"], expectedDate, "YAML date should match the input date")
        XCTAssertEqual(dict["time"], expectedTime, "YAML time should match the input time")
    }

    // MARK: - Processing Time

    func testProcessingTimeFormatted() {
        let result = sampleResult(processingTime: 45.3)
        let markdown = TranscriptSaver.formatTranscriptMarkdown(result: result, date: Date())

        let yaml = extractYAML(from: markdown)!
        let dict = parseYAMLFlat(yaml)

        XCTAssertEqual(dict["processing_time"], "\"45.3s\"", "Processing time should be formatted with 1 decimal place")
    }

    // MARK: - Speaker Counts

    func testMicAndSystemSpeakerCounts() {
        let mic = [
            TranscriptionUtterance.mock(start: 0.0, end: 2.0, channel: 0, speakerId: 0, transcript: "a"),
            TranscriptionUtterance.mock(start: 3.0, end: 5.0, channel: 0, speakerId: 1, transcript: "b")
        ]
        let sys = [
            TranscriptionUtterance.mock(start: 1.0, end: 3.0, channel: 1, speakerId: 0, transcript: "c"),
            TranscriptionUtterance.mock(start: 4.0, end: 6.0, channel: 1, speakerId: 1, transcript: "d"),
            TranscriptionUtterance.mock(start: 7.0, end: 9.0, channel: 1, speakerId: 2, transcript: "e")
        ]
        let result = sampleResult(micUtterances: mic, systemUtterances: sys)
        let markdown = TranscriptSaver.formatTranscriptMarkdown(result: result, date: Date())

        let yaml = extractYAML(from: markdown)!
        let dict = parseYAMLFlat(yaml)

        XCTAssertEqual(dict["mic_speakers"], "2", "Should detect 2 distinct mic speakers")
        XCTAssertEqual(dict["system_speakers"], "3", "Should detect 3 distinct system speakers")
    }

    // MARK: - Meeting Title in YAML

    func testMeetingTitleIncludedInYAML() {
        let result = sampleResult()
        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: result,
            date: Date(),
            meetingTitle: "Q4 Review"
        )

        let yaml = extractYAML(from: markdown)!
        XCTAssertTrue(yaml.contains("title: \"Q4 Review\""), "Meeting title should appear in YAML")
    }

    func testEmptyMeetingTitleOmitted() {
        let result = sampleResult()
        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: result,
            date: Date(),
            meetingTitle: ""
        )

        let yaml = extractYAML(from: markdown)!
        XCTAssertFalse(yaml.contains("title:"), "Empty meeting title should be omitted from YAML")
    }
}
