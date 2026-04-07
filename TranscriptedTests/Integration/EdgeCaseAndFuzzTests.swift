import XCTest
@testable import Transcripted
@testable import TranscriptedCore

/// Tests that throw weird, hostile, and boundary data at the transcript save pipeline
/// and speaker name variant logic to verify no crashes or corruption.
@available(macOS 14.0, *)
final class EdgeCaseAndFuzzTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EdgeCaseAndFuzzTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        // Restore permissions before cleanup (in case testSaveToReadOnlyDirectory left a 444 dir)
        if let tempDir = tempDir {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tempDir.path)
            let fm = FileManager.default
            if let contents = try? fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
                for item in contents {
                    try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: item.path)
                }
            }
            try? fm.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    private func saveAndReadBack(
        result: TranscriptionResult,
        speakerMappings: [String: SpeakerMapping] = [:],
        directory: URL? = nil
    ) -> (mdURL: URL, mdContent: String, json: AgentTranscript)? {
        let dir = directory ?? tempDir!
        guard let mdURL = TranscriptSaver.saveTranscript(result, speakerMappings: speakerMappings, directory: dir) else {
            return nil
        }
        do {
            let mdContent = try String(contentsOf: mdURL, encoding: .utf8)
            let stem = mdURL.deletingPathExtension().lastPathComponent
            let jsonURL = dir.appendingPathComponent("\(stem).json")
            let jsonData = try Data(contentsOf: jsonURL)
            let json = try JSONDecoder().decode(AgentTranscript.self, from: jsonData)
            return (mdURL, mdContent, json)
        } catch {
            XCTFail("Failed to read back artifacts: \(error)")
            return nil
        }
    }

    // MARK: - Unicode Tests

    func testSaveWithUnicodeUtterances() {
        let utterances = [
            TranscriptionUtterance.mock(start: 0.0, end: 5.0, channel: 0, speakerId: 0,
                transcript: "Emoji test: \u{1F3A4}\u{1F50A} microphone and speaker"),
            TranscriptionUtterance.mock(start: 6.0, end: 11.0, channel: 1, speakerId: 0,
                transcript: "CJK characters: \u{4F1A}\u{8BAE}\u{8BB0}\u{5F55} meeting notes"),
            TranscriptionUtterance.mock(start: 12.0, end: 17.0, channel: 1, speakerId: 1,
                transcript: "RTL text: \u{0645}\u{0631}\u{062D}\u{0628}\u{0627} hello"),
            TranscriptionUtterance.mock(start: 18.0, end: 23.0, channel: 1, speakerId: 2,
                transcript: "Combining: e\u{0301} re\u{0301}sume\u{0301} nai\u{0308}ve")
        ]

        let result = TranscriptionResult(
            micUtterances: [utterances[0]],
            systemUtterances: Array(utterances[1...]),
            duration: 30.0,
            processingTime: 2.0
        )

        guard let artifacts = saveAndReadBack(result: result) else {
            XCTFail("Save returned nil")
            return
        }

        // Verify text preserved in markdown
        XCTAssertTrue(artifacts.mdContent.contains("\u{1F3A4}\u{1F50A}"),
            "Emoji should be preserved in markdown")
        XCTAssertTrue(artifacts.mdContent.contains("\u{4F1A}\u{8BAE}\u{8BB0}\u{5F55}"),
            "CJK characters should be preserved in markdown")
        XCTAssertTrue(artifacts.mdContent.contains("\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}"),
            "RTL text should be preserved in markdown")

        // Verify text preserved in JSON
        let jsonTexts = artifacts.json.utterances.map { $0.text }
        XCTAssertTrue(jsonTexts.contains(where: { $0.contains("\u{1F3A4}") }),
            "Emoji should be preserved in JSON")
        XCTAssertTrue(jsonTexts.contains(where: { $0.contains("\u{4F1A}\u{8BAE}") }),
            "CJK characters should be preserved in JSON")
        XCTAssertTrue(jsonTexts.contains(where: { $0.contains("\u{0645}\u{0631}\u{062D}") }),
            "RTL text should be preserved in JSON")
        XCTAssertTrue(jsonTexts.contains(where: { $0.contains("e\u{0301}") }),
            "Combining characters should be preserved in JSON")
    }

    func testSaveWithVeryLongUtteranceText() {
        let longText = (0..<10000).map { "word\($0)" }.joined(separator: " ")
        let utterance = TranscriptionUtterance.mock(
            start: 0.0, end: 600.0, channel: 0, speakerId: 0,
            transcript: longText
        )
        let result = TranscriptionResult(
            micUtterances: [utterance],
            systemUtterances: [],
            duration: 600.0,
            processingTime: 5.0
        )

        guard let artifacts = saveAndReadBack(result: result) else {
            XCTFail("Save returned nil for very long utterance")
            return
        }

        // Verify the text is preserved in JSON (exact match)
        XCTAssertEqual(artifacts.json.utterances.first?.text, longText,
            "10,000-word utterance should be preserved exactly in JSON")

        // Verify it appears in the markdown
        XCTAssertTrue(artifacts.mdContent.contains("word9999"),
            "Last word of long utterance should appear in markdown")
    }

    // MARK: - Duration Edge Cases

    func testSaveWithZeroDuration() {
        let utterance = TranscriptionUtterance.mock(
            start: 0.0, end: 0.0, channel: 0, speakerId: 0,
            transcript: "Zero duration test"
        )
        let result = TranscriptionResult(
            micUtterances: [utterance],
            systemUtterances: [],
            duration: 0.0,
            processingTime: 0.1
        )

        let artifacts = saveAndReadBack(result: result)
        // Should not crash. Verify files are valid.
        XCTAssertNotNil(artifacts, "Save with zero duration should not crash")
        if let artifacts = artifacts {
            XCTAssertEqual(artifacts.json.recording.durationSeconds, 0,
                "JSON should record 0 duration")
            XCTAssertTrue(artifacts.mdContent.contains("duration:"),
                "Markdown should still have duration field")
        }
    }

    func testSaveWithNegativeDuration() {
        let result = TranscriptionResult(
            micUtterances: [.mock(start: 0.0, end: 1.0, channel: 0, transcript: "Negative duration")],
            systemUtterances: [],
            duration: -1.0,
            processingTime: 0.1
        )

        // Should not crash
        let mdURL = TranscriptSaver.saveTranscript(result, directory: tempDir)
        // We don't require it to succeed, just that it doesn't crash
        // If it does save, the file should be readable
        if let mdURL = mdURL {
            let content = try? String(contentsOf: mdURL, encoding: .utf8)
            XCTAssertNotNil(content, "If saved, the file should be readable")
        }
    }

    // MARK: - Scale Tests

    func testSaveWithMaxSpeakers() {
        // 100 different speaker IDs in system utterances
        var sysUtterances: [TranscriptionUtterance] = []
        for i in 0..<100 {
            sysUtterances.append(TranscriptionUtterance.mock(
                start: Double(i) * 3.0,
                end: Double(i) * 3.0 + 2.0,
                channel: 1,
                speakerId: i,
                transcript: "Speaker \(i) says something"
            ))
        }

        let result = TranscriptionResult(
            micUtterances: [],
            systemUtterances: sysUtterances,
            duration: 300.0,
            processingTime: 10.0
        )

        guard let artifacts = saveAndReadBack(result: result) else {
            XCTFail("Save with 100 speakers should not fail")
            return
        }

        // JSON should have all 100 system speakers
        let systemSpeakers = artifacts.json.speakers.filter { $0.id.hasPrefix("system_") }
        XCTAssertEqual(systemSpeakers.count, 100,
            "JSON should contain all 100 system speakers, got \(systemSpeakers.count)")

        // All utterances should reference valid speakers
        let speakerIds = Set(artifacts.json.speakers.map { $0.id })
        for utterance in artifacts.json.utterances {
            XCTAssertTrue(speakerIds.contains(utterance.speakerId),
                "Utterance speaker_id '\(utterance.speakerId)' should be in speakers array")
        }
    }

    func testSaveWith1000Utterances() {
        var micUtterances: [TranscriptionUtterance] = []
        var sysUtterances: [TranscriptionUtterance] = []

        for i in 0..<500 {
            micUtterances.append(TranscriptionUtterance.mock(
                start: Double(i) * 2.0,
                end: Double(i) * 2.0 + 1.5,
                channel: 0,
                speakerId: 0,
                transcript: "Mic utterance \(i)"
            ))
        }

        for i in 0..<500 {
            sysUtterances.append(TranscriptionUtterance.mock(
                start: Double(i) * 2.0 + 0.5,
                end: Double(i) * 2.0 + 1.8,
                channel: 1,
                speakerId: i % 3,
                transcript: "System utterance \(i)"
            ))
        }

        let result = TranscriptionResult(
            micUtterances: micUtterances,
            systemUtterances: sysUtterances,
            duration: 1000.0,
            processingTime: 30.0
        )

        guard let artifacts = saveAndReadBack(result: result) else {
            XCTFail("Save with 1000 utterances should not fail")
            return
        }

        XCTAssertEqual(artifacts.json.utterances.count, 1000,
            "JSON should contain all 1000 utterances")
        XCTAssertTrue(artifacts.mdContent.contains("Mic utterance 499"),
            "Markdown should contain last mic utterance")
    }

    // MARK: - Special Character Tests

    func testSpeakerNameWithSpecialChars() {
        let specialNames: [(key: String, name: String)] = [
            ("system_0", "O'Brien \"The Boss\""),
            ("system_1", "Name: With-Colons"),
            ("system_2", "Line\nBreak")
        ]

        var mappings: [String: SpeakerMapping] = [:]
        var sysUtterances: [TranscriptionUtterance] = []

        for (i, spec) in specialNames.enumerated() {
            mappings[spec.key] = SpeakerMapping(speakerId: "\(i)", identifiedName: spec.name, confidence: .high)
            sysUtterances.append(TranscriptionUtterance.mock(
                start: Double(i) * 10.0,
                end: Double(i) * 10.0 + 8.0,
                channel: 1,
                speakerId: i,
                transcript: "Hello from speaker \(i)"
            ))
        }

        let result = TranscriptionResult(
            micUtterances: [],
            systemUtterances: sysUtterances,
            duration: 30.0,
            processingTime: 1.0
        )

        // Should not crash
        let artifacts = saveAndReadBack(result: result, speakerMappings: mappings)
        XCTAssertNotNil(artifacts, "Save with special-character speaker names should not crash")

        // Verify JSON round-trips the names (JSON handles escaping natively)
        if let artifacts = artifacts {
            let jsonNames = Set(artifacts.json.speakers.map { $0.name })
            // The displayName includes the name as-is for high confidence
            XCTAssertTrue(jsonNames.contains("O'Brien \"The Boss\""),
                "JSON should preserve speaker name with quotes")
            XCTAssertTrue(jsonNames.contains("Name: With-Colons"),
                "JSON should preserve speaker name with colons")
        }
    }

    func testSpeakerNameWithHTMLInjection() {
        let xssName = "<script>alert('xss')</script>"
        let mappings: [String: SpeakerMapping] = [
            "system_0": SpeakerMapping(speakerId: "0", identifiedName: xssName, confidence: .high)
        ]

        let result = TranscriptionResult(
            micUtterances: [],
            systemUtterances: [.mock(start: 0.0, end: 5.0, channel: 1, speakerId: 0, transcript: "Test")],
            duration: 10.0,
            processingTime: 0.5
        )

        guard let artifacts = saveAndReadBack(result: result, speakerMappings: mappings) else {
            XCTFail("Save with HTML injection name should not crash")
            return
        }

        // Verify the name is preserved literally (not interpreted)
        let jsonSpeaker = artifacts.json.speakers.first { $0.id == "system_0" }
        XCTAssertEqual(jsonSpeaker?.name, xssName,
            "HTML injection name should be preserved literally in JSON, not interpreted")

        // In markdown, it should appear in the YAML (escaped or literal)
        XCTAssertTrue(artifacts.mdContent.contains("script") || artifacts.mdContent.contains("alert"),
            "HTML content should appear in some form in markdown (escaped or literal)")
    }

    // MARK: - Directory Edge Cases

    func testSaveToNonExistentDirectory() {
        let nonExistent = tempDir.appendingPathComponent("deep/nested/path/that/does/not/exist")

        let result = TranscriptionResult(
            micUtterances: [.mock(start: 0.0, end: 3.0, channel: 0, transcript: "Test")],
            systemUtterances: [],
            duration: 5.0,
            processingTime: 0.5
        )

        // TranscriptSaver.saveTranscript creates directories with withIntermediateDirectories: true
        // so this should succeed
        let mdURL = TranscriptSaver.saveTranscript(result, directory: nonExistent)
        XCTAssertNotNil(mdURL,
            "Save to non-existent directory should succeed (directory creation)")

        if let mdURL = mdURL {
            XCTAssertTrue(FileManager.default.fileExists(atPath: mdURL.path),
                "Saved file should exist on disk")
        }
    }

    func testSaveToReadOnlyDirectory() {
        let readOnlyDir = tempDir.appendingPathComponent("readonly")
        try? FileManager.default.createDirectory(at: readOnlyDir, withIntermediateDirectories: true)

        // Write a dummy file so the directory is non-empty
        try? "test".write(to: readOnlyDir.appendingPathComponent("dummy.txt"), atomically: true, encoding: .utf8)

        // Make directory read-only
        try? FileManager.default.setAttributes([.posixPermissions: 0o444], ofItemAtPath: readOnlyDir.path)

        let result = TranscriptionResult(
            micUtterances: [.mock(start: 0.0, end: 3.0, channel: 0, transcript: "Test")],
            systemUtterances: [],
            duration: 5.0,
            processingTime: 0.5
        )

        // Should fail gracefully (return nil), not crash
        let mdURL = TranscriptSaver.saveTranscript(result, directory: readOnlyDir)
        XCTAssertNil(mdURL,
            "Save to read-only directory should return nil (graceful failure)")

        // Restore permissions for tearDown cleanup
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: readOnlyDir.path)
    }

    // MARK: - Name Variant Tests

    func testNameVariantsWithUnicode() {
        // Accented names are NOT in the lookup table, so areNameVariants should return false
        // (unless substring matching kicks in)
        let result1 = SpeakerDatabase.areNameVariants("Jos\u{00E9}", "Jose")
        // "Jose" is a substring of "Jos\u{00E9}"? No -- they differ in the last char.
        // "Jos\u{00E9}".contains("Jose") is false because \u{00E9} != 'e'
        // Document current behavior: accented variants are not matched
        XCTAssertFalse(result1,
            "Jos\u{00E9} vs Jose: should return false -- accented names are not in the lookup table and substring matching does not equate \u{00E9} with e")

        let result2 = SpeakerDatabase.areNameVariants("M\u{00FC}ller", "Muller")
        XCTAssertFalse(result2,
            "M\u{00FC}ller vs Muller: should return false -- umlaut names are not in the lookup table")

        // But exact match with different case should still work
        let result3 = SpeakerDatabase.areNameVariants("JOS\u{00C9}", "Jos\u{00E9}")
        XCTAssertTrue(result3,
            "JOS\u{00C9} vs Jos\u{00E9}: should return true via case-insensitive exact match")
    }

    func testNameVariantsWithWhitespace() {
        // Leading/trailing spaces should be trimmed
        XCTAssertTrue(SpeakerDatabase.areNameVariants("  Mike  ", "Michael"),
            "Leading/trailing spaces should be trimmed before variant lookup")

        XCTAssertTrue(SpeakerDatabase.areNameVariants("Nate", "  Nate  "),
            "Trailing spaces should be trimmed for exact match")

        // Empty strings after trimming should return false
        XCTAssertFalse(SpeakerDatabase.areNameVariants("   ", "Mike"),
            "Whitespace-only string should not match any name")

        XCTAssertFalse(SpeakerDatabase.areNameVariants("", ""),
            "Two empty strings should not be considered name variants")

        // Tab and newline trimming
        XCTAssertTrue(SpeakerDatabase.areNameVariants("\tDave\n", "David"),
            "Tab and newline characters should be trimmed")
    }

    // MARK: - FailedTranscription Persistence Round-Trip

    func testFailedTranscriptionManagerRoundTrip() throws {
        // Test the FailedTranscription codec directly since the manager
        // hardcodes its storage path and auto-cleans on init
        let storagePath = tempDir.appendingPathComponent("failed_transcriptions.json")

        // Create some failed transcriptions with audio files that "exist"
        let micAudioURL1 = tempDir.appendingPathComponent("mic1.wav")
        let micAudioURL2 = tempDir.appendingPathComponent("mic2.wav")
        let sysAudioURL1 = tempDir.appendingPathComponent("sys1.wav")

        // Create dummy audio files so audioFilesExist() returns true
        for url in [micAudioURL1, micAudioURL2, sysAudioURL1] {
            try "fake audio data".write(to: url, atomically: true, encoding: .utf8)
        }

        let failed1 = FailedTranscription(
            micAudioURL: micAudioURL1,
            systemAudioURL: sysAudioURL1,
            errorMessage: "Model inference failed: timeout"
        )

        let failed2 = FailedTranscription(
            micAudioURL: micAudioURL2,
            systemAudioURL: nil,
            errorMessage: "Unknown error occurred"
        )

        let originals = [failed1, failed2]

        // Encode and write
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(originals)
        try data.write(to: storagePath, options: .atomic)

        // Read back and decode
        let readData = try Data(contentsOf: storagePath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let loaded = try decoder.decode([FailedTranscription].self, from: readData)

        XCTAssertEqual(loaded.count, 2, "Should load 2 failed transcriptions")

        // Verify first entry
        XCTAssertEqual(loaded[0].id, failed1.id)
        XCTAssertEqual(loaded[0].micAudioURL, failed1.micAudioURL)
        XCTAssertEqual(loaded[0].systemAudioURL, failed1.systemAudioURL)
        XCTAssertEqual(loaded[0].errorMessage, "Model inference failed: timeout")
        XCTAssertEqual(loaded[0].retryCount, 0)
        XCTAssertNil(loaded[0].lastRetryDate)
        XCTAssertTrue(loaded[0].isRetryable, "'Model inference failed' should be retryable")

        // Verify second entry
        XCTAssertEqual(loaded[1].id, failed2.id)
        XCTAssertEqual(loaded[1].micAudioURL, failed2.micAudioURL)
        XCTAssertNil(loaded[1].systemAudioURL, "Second entry has no system audio")
        XCTAssertEqual(loaded[1].errorMessage, "Unknown error occurred")
        XCTAssertTrue(loaded[1].isRetryable, "'Unknown error' should be retryable")

        // Verify audioFilesExist works
        XCTAssertTrue(loaded[0].audioFilesExist(), "First entry's audio files should exist")
        XCTAssertTrue(loaded[1].audioFilesExist(), "Second entry's audio file should exist")

        // Verify timestamp survives round-trip (within 1 second tolerance for encoding)
        XCTAssertEqual(
            loaded[0].timestamp.timeIntervalSince1970,
            failed1.timestamp.timeIntervalSince1970,
            accuracy: 1.0,
            "Timestamp should survive round-trip"
        )

        // Test mutation: simulate retry
        var mutable = loaded[0]
        mutable.retryCount += 1
        mutable.lastRetryDate = Date()
        XCTAssertEqual(mutable.retryCount, 1)
        XCTAssertNotNil(mutable.lastRetryDate)

        // Re-encode the mutated array and verify
        let mutatedArray = [mutable, loaded[1]]
        let reEncodedData = try encoder.encode(mutatedArray)
        try reEncodedData.write(to: storagePath, options: .atomic)

        let reLoaded = try decoder.decode([FailedTranscription].self, from: Data(contentsOf: storagePath))
        XCTAssertEqual(reLoaded[0].retryCount, 1, "Retry count should persist after re-encoding")
        XCTAssertNotNil(reLoaded[0].lastRetryDate, "Last retry date should persist")
    }
}
