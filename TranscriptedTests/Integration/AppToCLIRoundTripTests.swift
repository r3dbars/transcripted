import XCTest
@testable import Transcripted

/// Integration test: Save transcripts through the app's real TranscriptSaver + AgentOutput code,
/// then validate the output using the same checks the CLI tool's validators perform.
/// This is the critical round-trip that ensures the app produces files the CLI can validate.
@available(macOS 14.0, *)
final class AppToCLIRoundTripTests: XCTestCase {

    var testDir: URL!
    var speakerDB: SpeakerDatabase!
    var speakerDBPath: URL!

    override func setUp() {
        super.setUp()
        testDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("app-cli-roundtrip-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: testDir, withIntermediateDirectories: true)

        speakerDBPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("roundtrip-speakers-\(UUID().uuidString).sqlite")
        speakerDB = SpeakerDatabase(path: speakerDBPath.path)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: testDir)
        speakerDB = nil
        for ext in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: speakerDBPath.path + ext)
        }
        super.tearDown()
    }

    // MARK: - Helpers

    /// Save a TranscriptionResult through the real app code path and return the saved .md URL.
    private func saveTranscriptViaPipeline(
        result: TranscriptionResult,
        speakerMappings: [String: SpeakerMapping] = [:],
        speakerDbIds: [String: UUID] = [:],
        meetingTitle: String? = nil,
        healthInfo: RecordingHealthInfo? = nil
    ) -> URL? {
        return TranscriptSaver.saveTranscript(
            result,
            speakerMappings: speakerMappings,
            speakerSources: [:],
            speakerDbIds: speakerDbIds,
            directory: testDir,
            meetingTitle: meetingTitle,
            healthInfo: healthInfo
        )
    }

    private func makeResult(
        micUtterances: [TranscriptionUtterance] = [],
        systemUtterances: [TranscriptionUtterance] = [],
        duration: TimeInterval = 60.0,
        processingTime: TimeInterval = 5.0,
        droppedSegments: Int = 0
    ) -> TranscriptionResult {
        TranscriptionResult(
            micUtterances: micUtterances,
            systemUtterances: systemUtterances,
            duration: duration,
            processingTime: processingTime,
            droppedSegments: droppedSegments
        )
    }

    /// Inline YAML parser that mirrors the CLI tool's YAMLParser logic.
    /// Extracts frontmatter fields from a Markdown string.
    private func parseYAML(from content: String) -> (fields: [String: String], body: String) {
        guard content.hasPrefix("---\n"),
              let endRange = content.range(
                  of: "\n---\n",
                  range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex
              ) else {
            return ([:], content)
        }

        let raw = String(content[content.index(content.startIndex, offsetBy: 4)..<endRange.lowerBound])
        let body = String(content[endRange.upperBound...])

        var parsed: [String: String] = [:]
        var currentKey: String?
        var listItems: [String] = []

        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            if trimmed.hasPrefix("- ") {
                let item = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                listItems.append(item)
                continue
            }

            if let key = currentKey, !listItems.isEmpty {
                parsed[key] = listItems.joined(separator: ", ")
                listItems = []
            }

            if let colonIdx = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)

                if value.isEmpty {
                    currentKey = key
                    continue
                }

                if value.hasPrefix("[") && value.hasSuffix("]") {
                    let inner = String(value.dropFirst().dropLast())
                    let items = inner.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    parsed[key] = items.joined(separator: ", ")
                    currentKey = key
                    continue
                }

                let stripped = value.hasPrefix("\"") && value.hasSuffix("\"")
                    ? String(value.dropFirst().dropLast())
                    : value
                parsed[key] = stripped
                currentKey = key
            }
        }

        if let key = currentKey, !listItems.isEmpty {
            parsed[key] = listItems.joined(separator: ", ")
        }

        return (parsed, body)
    }

    /// Read the JSON sidecar for a given .md file URL.
    private func readSidecar(for mdURL: URL) throws -> [String: Any] {
        let jsonURL = mdURL.deletingPathExtension().appendingPathExtension("json")
        let data = try Data(contentsOf: jsonURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "AppToCLIRoundTripTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON"])
        }
        return json
    }

    /// Read the index file from testDir.
    private func readIndex() throws -> [String: Any] {
        let indexURL = testDir.appendingPathComponent("transcripted.json")
        let data = try Data(contentsOf: indexURL)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "AppToCLIRoundTripTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid index JSON"])
        }
        return json
    }

    // MARK: - Tests

    /// Save via TranscriptSaver, read back .md, parse YAML frontmatter, verify ALL required keys
    /// and engine values match the expected constants.
    func testSavedTranscriptHasValidYAML() throws {
        let mic = [
            TranscriptionUtterance.mock(start: 0.0, end: 5.0, channel: 0, speakerId: 0, transcript: "Hello world")
        ]
        let sys = [
            TranscriptionUtterance.mock(start: 6.0, end: 10.0, channel: 1, speakerId: 0, transcript: "Greetings from system")
        ]
        let result = makeResult(micUtterances: mic, systemUtterances: sys, duration: 120.0)

        let savedURL = saveTranscriptViaPipeline(result: result, healthInfo: .perfect)
        XCTAssertNotNil(savedURL, "TranscriptSaver should return a valid URL")

        let content = try String(contentsOf: savedURL!, encoding: .utf8)
        let (fields, _) = parseYAML(from: content)

        // Required keys
        let requiredKeys = ["date", "time", "duration", "transcription_engine", "diarization_engine"]
        for key in requiredKeys {
            XCTAssertNotNil(fields[key], "YAML must contain required key: \(key)")
        }

        // Engine values
        XCTAssertEqual(fields["transcription_engine"], "parakeet_local",
                       "transcription_engine must be parakeet_local")
        XCTAssertEqual(fields["diarization_engine"], "pyannote_offline",
                       "diarization_engine must be pyannote_offline")

        // Sources
        if let sources = fields["sources"] {
            let sourceList = sources.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let validValues: Set<String> = ["mic", "system_audio"]
            XCTAssertTrue(sourceList.allSatisfy { validValues.contains($0) },
                          "sources must only contain mic and/or system_audio, got: \(sources)")
        }

        // Non-negative integer counts
        for key in ["mic_utterances", "system_utterances", "total_word_count"] {
            if let val = fields[key], let num = Int(val) {
                XCTAssertGreaterThanOrEqual(num, 0, "\(key) must be non-negative, got \(num)")
            }
        }
    }

    /// Save via TranscriptSaver, read both .md and .json, verify engine strings in JSON sidecar
    /// and that utterance count matches YAML mic_utterances + system_utterances.
    func testSavedSidecarMatchesTranscript() throws {
        let mic = [
            TranscriptionUtterance.mock(start: 0.0, end: 3.0, channel: 0, speakerId: 0, transcript: "Mic one")
        ]
        let sys = [
            TranscriptionUtterance.mock(start: 4.0, end: 7.0, channel: 1, speakerId: 0, transcript: "System one"),
            TranscriptionUtterance.mock(start: 8.0, end: 11.0, channel: 1, speakerId: 1, transcript: "System two")
        ]
        let result = makeResult(micUtterances: mic, systemUtterances: sys, duration: 60.0)

        let savedURL = saveTranscriptViaPipeline(result: result)
        XCTAssertNotNil(savedURL)

        // Read YAML
        let content = try String(contentsOf: savedURL!, encoding: .utf8)
        let (fields, _) = parseYAML(from: content)

        // Read JSON sidecar
        let json = try readSidecar(for: savedURL!)
        let recording = json["recording"] as? [String: Any]
        let engines = recording?["engines"] as? [String: String]

        XCTAssertEqual(engines?["stt"], "parakeet-tdt-v3",
                       "JSON sidecar stt engine must be parakeet-tdt-v3")
        XCTAssertEqual(engines?["diarization"], "pyannote-offline",
                       "JSON sidecar diarization engine must be pyannote-offline")

        // Utterance count cross-check
        let yamlMicUtterances = Int(fields["mic_utterances"] ?? "0") ?? 0
        let yamlSystemUtterances = Int(fields["system_utterances"] ?? "0") ?? 0
        let yamlTotal = yamlMicUtterances + yamlSystemUtterances

        let jsonUtterances = json["utterances"] as? [[String: Any]]
        XCTAssertEqual(jsonUtterances?.count, yamlTotal,
                       "JSON utterance count (\(jsonUtterances?.count ?? -1)) must match YAML total (\(yamlTotal))")
    }

    /// Save a transcript with deliberately unsorted timestamps, verify the JSON sidecar
    /// utterances are sorted by start time.
    func testSavedSidecarUtterancesAreSorted() throws {
        // Deliberately unsorted input timestamps
        let mic = [
            TranscriptionUtterance.mock(start: 5.0, end: 7.0, channel: 0, speakerId: 0, transcript: "Mic at five"),
            TranscriptionUtterance.mock(start: 0.0, end: 2.0, channel: 0, speakerId: 0, transcript: "Mic at zero"),
            TranscriptionUtterance.mock(start: 8.0, end: 10.0, channel: 0, speakerId: 0, transcript: "Mic at eight")
        ]
        let sys = [
            TranscriptionUtterance.mock(start: 2.0, end: 4.0, channel: 1, speakerId: 0, transcript: "Sys at two"),
            TranscriptionUtterance.mock(start: 1.0, end: 1.5, channel: 1, speakerId: 1, transcript: "Sys at one")
        ]
        let result = makeResult(micUtterances: mic, systemUtterances: sys, duration: 15.0)

        let savedURL = saveTranscriptViaPipeline(result: result)
        XCTAssertNotNil(savedURL)

        let json = try readSidecar(for: savedURL!)
        let utterances = json["utterances"] as? [[String: Any]] ?? []
        XCTAssertEqual(utterances.count, 5, "Should have all 5 utterances")

        var prevStart: Double = -1
        for (idx, utt) in utterances.enumerated() {
            guard let start = utt["start"] as? Double else {
                XCTFail("Utterance \(idx) missing start time")
                continue
            }
            XCTAssertGreaterThanOrEqual(start, prevStart,
                "Utterance \(idx) start=\(start) is before previous=\(prevStart) — not sorted")
            prevStart = start
        }
    }

    /// Save to testDir, read transcripted.json, verify it contains the correct filename
    /// and that transcript_count matches the array length.
    func testSavedIndexReferencesCorrectFile() throws {
        let result = makeResult(
            micUtterances: [.mock(start: 0, end: 3, channel: 0, transcript: "Hello")],
            systemUtterances: [],
            duration: 30.0
        )

        let savedURL = saveTranscriptViaPipeline(result: result)
        XCTAssertNotNil(savedURL)

        // The saveTranscript method writes the index via AgentOutput.writeIndex.
        // Read it back.
        let index = try readIndex()

        let transcriptCount = index["transcript_count"] as? Int
        let transcripts = index["transcripts"] as? [[String: Any]]

        XCTAssertNotNil(transcriptCount)
        XCTAssertNotNil(transcripts)
        XCTAssertEqual(transcriptCount, transcripts?.count,
                       "transcript_count must match transcripts array length")

        // Verify the saved file's stem appears in the index
        let savedStem = savedURL!.deletingPathExtension().lastPathComponent
        let filenames = transcripts?.compactMap { $0["filename"] as? String } ?? []
        XCTAssertTrue(filenames.contains(savedStem),
                      "Index must reference the saved filename \(savedStem), got: \(filenames)")
    }

    /// Create utterances with known text, save, parse YAML total_word_count, verify it equals
    /// the actual sum of words.
    func testWordCountConsistency() throws {
        // "Hello world" = 2 words, "This is a test" = 4 words, "One" = 1 word
        let mic = [
            TranscriptionUtterance.mock(start: 0, end: 2, channel: 0, speakerId: 0, transcript: "Hello world"),
            TranscriptionUtterance.mock(start: 3, end: 5, channel: 0, speakerId: 0, transcript: "One")
        ]
        let sys = [
            TranscriptionUtterance.mock(start: 6, end: 9, channel: 1, speakerId: 0, transcript: "This is a test")
        ]
        let expectedTotal = 2 + 1 + 4  // 7

        let result = makeResult(micUtterances: mic, systemUtterances: sys, duration: 30.0)
        let savedURL = saveTranscriptViaPipeline(result: result)
        XCTAssertNotNil(savedURL)

        let content = try String(contentsOf: savedURL!, encoding: .utf8)
        let (fields, _) = parseYAML(from: content)

        let yamlWordCount = Int(fields["total_word_count"] ?? "-1")
        XCTAssertEqual(yamlWordCount, expectedTotal,
                       "YAML total_word_count (\(yamlWordCount ?? -1)) must equal actual word sum (\(expectedTotal))")
    }

    /// Create utterances from 3 different speaker IDs on the system channel,
    /// verify YAML system_speakers matches.
    func testSpeakerCountConsistency() throws {
        let sys = [
            TranscriptionUtterance.mock(start: 0, end: 3, channel: 1, speakerId: 0, transcript: "Speaker zero"),
            TranscriptionUtterance.mock(start: 4, end: 7, channel: 1, speakerId: 1, transcript: "Speaker one"),
            TranscriptionUtterance.mock(start: 8, end: 11, channel: 1, speakerId: 2, transcript: "Speaker two"),
            TranscriptionUtterance.mock(start: 12, end: 15, channel: 1, speakerId: 0, transcript: "Speaker zero again")
        ]

        let result = makeResult(micUtterances: [], systemUtterances: sys, duration: 20.0)
        let savedURL = saveTranscriptViaPipeline(result: result)
        XCTAssertNotNil(savedURL)

        let content = try String(contentsOf: savedURL!, encoding: .utf8)
        let (fields, _) = parseYAML(from: content)

        let systemSpeakers = Int(fields["system_speakers"] ?? "-1")
        XCTAssertEqual(systemSpeakers, 3,
                       "system_speakers should be 3 (unique speaker IDs 0,1,2), got \(systemSpeakers ?? -1)")
    }

    /// Save 3 different transcripts to the same directory, read index, verify
    /// transcript_count == 3 and all filenames are present.
    func testMultipleSavesAccumulateInIndex() throws {
        var savedStems: [String] = []

        for i in 0..<3 {
            let result = makeResult(
                micUtterances: [.mock(start: 0, end: Double(i + 1), channel: 0, transcript: "Transcript \(i)")],
                systemUtterances: [],
                duration: TimeInterval(60 * (i + 1))
            )
            let savedURL = saveTranscriptViaPipeline(result: result)
            XCTAssertNotNil(savedURL, "Save \(i) must succeed")
            savedStems.append(savedURL!.deletingPathExtension().lastPathComponent)
            // Small delay to ensure unique filenames (timestamp-based naming)
            Thread.sleep(forTimeInterval: 1.1)
        }

        let index = try readIndex()
        let transcriptCount = index["transcript_count"] as? Int
        let transcripts = index["transcripts"] as? [[String: Any]]

        XCTAssertEqual(transcriptCount, 3, "Index should report 3 transcripts")
        XCTAssertEqual(transcripts?.count, 3, "Index array should have 3 entries")

        let filenames = Set(transcripts?.compactMap { $0["filename"] as? String } ?? [])
        for stem in savedStems {
            XCTAssertTrue(filenames.contains(stem),
                          "Index must contain \(stem), got: \(filenames)")
        }
    }

    /// Read back .md, verify it contains expected section headers.
    func testSavedFilesHaveExpectedSections() throws {
        let result = makeResult(
            micUtterances: [.mock(start: 0, end: 5, channel: 0, transcript: "Some text")],
            systemUtterances: [.mock(start: 6, end: 10, channel: 1, speakerId: 0, transcript: "More text")],
            duration: 60.0
        )

        let savedURL = saveTranscriptViaPipeline(result: result)
        XCTAssertNotNil(savedURL)

        let content = try String(contentsOf: savedURL!, encoding: .utf8)
        XCTAssertTrue(content.contains("## Summary"), "Saved transcript must contain ## Summary section")
        XCTAssertTrue(content.contains("## Full Transcript"), "Saved transcript must contain ## Full Transcript section")
    }

    /// Save with known duration, read both YAML and JSON, verify both report the same duration.
    func testCrossArtifactDurationMatch() throws {
        let knownDuration: TimeInterval = 300.0  // 5 minutes
        let result = makeResult(
            micUtterances: [.mock(start: 0, end: 5, channel: 0, transcript: "Five minute call")],
            systemUtterances: [],
            duration: knownDuration
        )

        let savedURL = saveTranscriptViaPipeline(result: result)
        XCTAssertNotNil(savedURL)

        // YAML duration is formatted as "M:SS"
        let content = try String(contentsOf: savedURL!, encoding: .utf8)
        let (fields, _) = parseYAML(from: content)
        XCTAssertEqual(fields["duration"], "5:00",
                       "YAML duration should be 5:00 for 300 seconds")

        // JSON duration_seconds
        let json = try readSidecar(for: savedURL!)
        let recording = json["recording"] as? [String: Any]
        let jsonDuration = recording?["duration_seconds"] as? Int
        XCTAssertEqual(jsonDuration, 300,
                       "JSON duration_seconds should be 300")
    }
}
