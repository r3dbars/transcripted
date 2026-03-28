import XCTest
@testable import Transcripted

@available(macOS 14.0, *)
final class TranscriptFormatterTests: XCTestCase {

    // MARK: - YAML Escaping

    func testEscapeYAMLBackslash() {
        let result = TranscriptSaver.escapeYAML("path\\to\\file")
        XCTAssertEqual(result, "path\\\\to\\\\file")
    }

    func testEscapeYAMLDoubleQuotes() {
        let result = TranscriptSaver.escapeYAML("She said \"hello\"")
        XCTAssertEqual(result, "She said \\\"hello\\\"")
    }

    func testEscapeYAMLNoSpecialChars() {
        let result = TranscriptSaver.escapeYAML("Normal text")
        XCTAssertEqual(result, "Normal text")
    }

    func testEscapeYAMLEmptyString() {
        let result = TranscriptSaver.escapeYAML("")
        XCTAssertEqual(result, "")
    }

    func testEscapeYAMLCombinedSpecialChars() {
        let result = TranscriptSaver.escapeYAML("\"back\\slash\"")
        XCTAssertEqual(result, "\\\"back\\\\slash\\\"")
    }

    // MARK: - Source Label Formatting

    func testFormatSourceLabelSystemAudio() {
        let result = TranscriptSaver.formatSourceLabel("System Audio")
        XCTAssertEqual(result, "SysAudio")
    }

    func testFormatSourceLabelMic() {
        let result = TranscriptSaver.formatSourceLabel("Mic")
        XCTAssertEqual(result, "Mic")
    }

    func testFormatSourceLabelArbitraryString() {
        let result = TranscriptSaver.formatSourceLabel("Other Source")
        XCTAssertEqual(result, "Other Source")
    }

    // MARK: - Simple Markdown Format

    func testFormatMarkdownIncludesDuration() {
        let result = TranscriptSaver.formatMarkdown(text: "Hello world", duration: 125, date: Date())
        XCTAssertTrue(result.contains("2:05"), "Expected duration 2:05 in output")
    }

    func testFormatMarkdownIncludesWordCount() {
        let result = TranscriptSaver.formatMarkdown(text: "Hello world today", duration: 60, date: Date())
        XCTAssertTrue(result.contains("3"), "Expected word count 3 in output")
    }

    func testFormatMarkdownEmptyTextShowsPlaceholder() {
        let result = TranscriptSaver.formatMarkdown(text: "", duration: 60, date: Date())
        XCTAssertTrue(result.contains("No transcript available"))
    }

    // MARK: - Full Transcript Markdown

    func testFormatTranscriptMarkdownContainsYAMLFrontmatter() {
        let result = TranscriptSaver.formatTranscriptMarkdown(
            result: .mock(),
            date: Date()
        )
        XCTAssertTrue(result.hasPrefix("---\n"))
        XCTAssertTrue(result.contains("---\n"), "Must have closing YAML delimiter")
    }

    func testFormatTranscriptMarkdownContainsRequiredYAMLKeys() {
        let result = TranscriptSaver.formatTranscriptMarkdown(
            result: .mock(),
            date: Date()
        )
        XCTAssertTrue(result.contains("date:"))
        XCTAssertTrue(result.contains("time:"))
        XCTAssertTrue(result.contains("duration:"))
        XCTAssertTrue(result.contains("transcription_engine: parakeet_local"))
        XCTAssertTrue(result.contains("diarization_engine: pyannote_offline"))
        XCTAssertTrue(result.contains("sources: [mic, system_audio]"))
    }

    func testFormatTranscriptMarkdownContainsUtteranceCounts() {
        let result = TranscriptSaver.formatTranscriptMarkdown(
            result: TranscriptionResult.mock(
                micUtterances: [.mock(channel: 0)],
                systemUtterances: [.mock(channel: 1), .mock(channel: 1)]
            ),
            date: Date()
        )
        XCTAssertTrue(result.contains("mic_utterances: 1"))
        XCTAssertTrue(result.contains("system_utterances: 2"))
    }

    func testFormatTranscriptMarkdownIncludesMeetingTitle() {
        let result = TranscriptSaver.formatTranscriptMarkdown(
            result: .mock(),
            date: Date(),
            meetingTitle: "Sprint Planning"
        )
        XCTAssertTrue(result.contains("title: \"Sprint Planning\""))
    }

    func testFormatTranscriptMarkdownExcludesEmptyMeetingTitle() {
        let result = TranscriptSaver.formatTranscriptMarkdown(
            result: .mock(),
            date: Date(),
            meetingTitle: ""
        )
        XCTAssertFalse(result.contains("title:"))
    }

    func testFormatTranscriptMarkdownExcludesNilMeetingTitle() {
        let result = TranscriptSaver.formatTranscriptMarkdown(
            result: .mock(),
            date: Date(),
            meetingTitle: nil
        )
        XCTAssertFalse(result.contains("title:"))
    }

    func testFormatTranscriptMarkdownEscapesTitleQuotes() {
        let result = TranscriptSaver.formatTranscriptMarkdown(
            result: .mock(),
            date: Date(),
            meetingTitle: "\"Quarterly\" Review"
        )
        XCTAssertTrue(result.contains("\\\"Quarterly\\\""))
    }

    // MARK: - Health Info in YAML

    func testFormatTranscriptMarkdownIncludesHealthInfo() {
        let health = RecordingHealthInfo(
            captureQuality: .good,
            audioGaps: 2,
            deviceSwitches: 1,
            gapDescriptions: ["Sleep 3.2s", "Device switch 0.5s"]
        )
        let result = TranscriptSaver.formatTranscriptMarkdown(
            result: .mock(),
            date: Date(),
            healthInfo: health
        )
        XCTAssertTrue(result.contains("capture_quality: good"))
        XCTAssertTrue(result.contains("audio_gaps: 2"))
        XCTAssertTrue(result.contains("device_switches: 1"))
        XCTAssertTrue(result.contains("gap_events:"))
        XCTAssertTrue(result.contains("Sleep 3.2s"))
    }

    func testFormatTranscriptMarkdownPerfectHealthInfo() {
        let result = TranscriptSaver.formatTranscriptMarkdown(
            result: .mock(),
            date: Date(),
            healthInfo: .perfect
        )
        XCTAssertTrue(result.contains("capture_quality: excellent"))
        XCTAssertTrue(result.contains("audio_gaps: 0"))
        XCTAssertTrue(result.contains("device_switches: 0"))
        XCTAssertFalse(result.contains("gap_events:"))
    }

    // MARK: - Speaker Mappings

    func testFormatTranscriptMarkdownIncludesSpeakers() {
        let mappings: [String: SpeakerMapping] = [
            "system_0": SpeakerMapping(speakerId: "0", identifiedName: "Alice", confidence: .high)
        ]
        let dbIds: [String: UUID] = ["0": UUID()]
        let result = TranscriptSaver.formatTranscriptMarkdown(
            result: .mock(systemUtterances: [.mock(channel: 1, speakerId: 0)]),
            speakerMappings: mappings,
            speakerDbIds: dbIds,
            date: Date()
        )
        XCTAssertTrue(result.contains("speakers:"))
        XCTAssertTrue(result.contains("name: \"Alice\""))
        XCTAssertTrue(result.contains("confidence: high"))
    }

    // MARK: - Utterance Formatting

    func testFormatTranscriptMarkdownMicUtteranceLabeledAsYou() {
        let result = TranscriptSaver.formatTranscriptMarkdown(
            result: .mock(micUtterances: [.mock(start: 0, end: 5, channel: 0, transcript: "Hello")]),
            date: Date()
        )
        XCTAssertTrue(result.contains("[Mic/You]"))
    }

    func testFormatTranscriptMarkdownSystemUtteranceLabeledAsSpeaker() {
        let result = TranscriptSaver.formatTranscriptMarkdown(
            result: .mock(systemUtterances: [.mock(start: 0, end: 5, channel: 1, speakerId: 0, transcript: "Hi")]),
            date: Date()
        )
        XCTAssertTrue(result.contains("[System/Speaker 0]"))
    }

    func testFormatTranscriptMarkdownTimestampFormat() {
        let result = TranscriptSaver.formatTranscriptMarkdown(
            result: .mock(micUtterances: [.mock(start: 125.0, end: 130.0, channel: 0, transcript: "test")]),
            date: Date()
        )
        XCTAssertTrue(result.contains("[02:05]"))
    }

    // MARK: - Document Sections

    func testFormatTranscriptMarkdownContainsAllSections() {
        let result = TranscriptSaver.formatTranscriptMarkdown(
            result: .mock(
                micUtterances: [.mock(channel: 0)],
                systemUtterances: [.mock(channel: 1)]
            ),
            date: Date()
        )
        XCTAssertTrue(result.contains("## Summary"))
        XCTAssertTrue(result.contains("## Channel & Speaker Analytics"))
        XCTAssertTrue(result.contains("## Full Transcript"))
        XCTAssertTrue(result.contains("Generated by Transcripted"))
    }
}
