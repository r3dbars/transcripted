import XCTest
@testable import Transcripted

/// Integration tests verifying that different artifacts (.md, .json sidecar, index)
/// produced from the same save operation are CONSISTENT with each other.
/// Catches bugs where the .md says one thing and the .json says another.
@available(macOS 14.0, *)
final class CrossArtifactConsistencyTests: XCTestCase {

    private var tempDir: URL!
    private var speakerDB: SpeakerDatabase!
    private var speakerDBPath: URL!

    /// Shared save result used by most tests
    private var savedURL: URL!
    private var mdContent: String!
    private var jsonSidecar: AgentTranscript!
    private var indexData: AgentIndex!
    private var yamlDict: [String: String]!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrossArtifactConsistencyTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        speakerDBPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("CrossArtifact-speakers-\(UUID().uuidString).sqlite")
        speakerDB = SpeakerDatabase(path: speakerDBPath.path)

        // Build a transcript with known data:
        // 5 mic utterances, 10 system utterances from 3 speakers, ~100 words, duration 300s
        let micUtterances = (0..<5).map { i in
            TranscriptionUtterance.mock(
                start: Double(i) * 10.0,
                end: Double(i) * 10.0 + 8.0,
                channel: 0,
                speakerId: 0,
                transcript: "Mic utterance number \(i) with some extra words here today"
            )
        }

        var sysUtterances: [TranscriptionUtterance] = []
        for i in 0..<10 {
            let speakerId = i % 3  // 3 distinct system speakers: 0, 1, 2
            sysUtterances.append(TranscriptionUtterance.mock(
                start: 50.0 + Double(i) * 12.0,
                end: 50.0 + Double(i) * 12.0 + 10.0,
                channel: 1,
                speakerId: speakerId,
                transcript: "System speaker \(speakerId) saying utterance \(i) with additional content"
            ))
        }

        let result = TranscriptionResult(
            micUtterances: micUtterances,
            systemUtterances: sysUtterances,
            duration: 300.0,
            processingTime: 15.0
        )

        let speakerMappings: [String: SpeakerMapping] = [
            "mic_0": SpeakerMapping(speakerId: "0", identifiedName: "You"),
            "system_0": SpeakerMapping(speakerId: "0", identifiedName: "Alice", confidence: .high),
            "system_1": SpeakerMapping(speakerId: "1", identifiedName: "Bob", confidence: .medium),
            "system_2": SpeakerMapping(speakerId: "2", identifiedName: "Charlie", confidence: .high)
        ]

        let dbId0 = UUID()
        let dbId1 = UUID()
        let dbId2 = UUID()
        let speakerDbIds: [String: UUID] = ["0": dbId0, "1": dbId1, "2": dbId2]

        let healthInfo = RecordingHealthInfo(
            captureQuality: .good,
            audioGaps: 1,
            deviceSwitches: 0,
            gapDescriptions: ["Gap at 120s"]
        )

        savedURL = TranscriptSaver.saveTranscript(
            result,
            speakerMappings: speakerMappings,
            speakerDbIds: speakerDbIds,
            directory: tempDir,
            meetingTitle: "Cross-Artifact Consistency Test",
            healthInfo: healthInfo
        )

        guard let savedURL = savedURL else {
            XCTFail("saveTranscript returned nil")
            return
        }

        // Read back all artifacts
        do {
            mdContent = try String(contentsOf: savedURL, encoding: .utf8)

            let stem = savedURL.deletingPathExtension().lastPathComponent
            let jsonURL = tempDir.appendingPathComponent("\(stem).json")
            let jsonData = try Data(contentsOf: jsonURL)
            jsonSidecar = try JSONDecoder().decode(AgentTranscript.self, from: jsonData)

            let indexURL = tempDir.appendingPathComponent("transcripted.json")
            let indexRawData = try Data(contentsOf: indexURL)
            indexData = try JSONDecoder().decode(AgentIndex.self, from: indexRawData)

            yamlDict = parseYAMLFlat(extractYAML(from: mdContent) ?? "")
        } catch {
            XCTFail("Failed to read back artifacts: \(error)")
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        speakerDB = nil
        for ext in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: speakerDBPath.path + ext)
        }
        super.tearDown()
    }

    // MARK: - YAML Parsing Helpers

    private func extractYAML(from markdown: String) -> String? {
        let delimiter = "---"
        guard markdown.hasPrefix(delimiter) else { return nil }
        let afterFirst = markdown.dropFirst(delimiter.count)
        guard let endRange = afterFirst.range(of: "\n\(delimiter)\n") else { return nil }
        return String(afterFirst[afterFirst.startIndex..<endRange.lowerBound])
    }

    private func parseYAMLFlat(_ yaml: String) -> [String: String] {
        var dict: [String: String] = [:]
        for line in yaml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("-"), !trimmed.hasPrefix("#") else { continue }
            if let colonIndex = trimmed.firstIndex(of: ":") {
                let key = String(trimmed[trimmed.startIndex..<colonIndex]).trimmingCharacters(in: .whitespaces)
                let value = String(trimmed[trimmed.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
                if !value.isEmpty {
                    dict[key] = value
                }
            }
        }
        return dict
    }

    /// Parse YAML speakers block into array of dictionaries
    private func parseYAMLSpeakers(from markdown: String) -> [[String: String]] {
        guard let yaml = extractYAML(from: markdown) else { return [] }
        var speakers: [[String: String]] = []
        var currentSpeaker: [String: String]? = nil
        var inSpeakers = false

        for line in yaml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed == "speakers:" || trimmed.hasPrefix("speakers:") {
                inSpeakers = true
                continue
            }

            if inSpeakers {
                // A new top-level key that's not indented means speakers block ended
                if !trimmed.isEmpty && !trimmed.hasPrefix("-") && !trimmed.hasPrefix("id:") &&
                   !trimmed.hasPrefix("name:") && !trimmed.hasPrefix("confidence:") &&
                   !trimmed.hasPrefix("source:") && !trimmed.hasPrefix("db_id:") &&
                   !line.hasPrefix(" ") && !line.hasPrefix("\t") {
                    inSpeakers = false
                    if let s = currentSpeaker { speakers.append(s) }
                    currentSpeaker = nil
                    continue
                }

                if trimmed.hasPrefix("- id:") {
                    if let s = currentSpeaker { speakers.append(s) }
                    currentSpeaker = [:]
                    let value = trimmed.replacingOccurrences(of: "- id:", with: "").trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
                    currentSpeaker?["id"] = value
                } else if let colonIdx = trimmed.firstIndex(of: ":"), inSpeakers, currentSpeaker != nil {
                    let key = String(trimmed[trimmed.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                    let value = String(trimmed[trimmed.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
                    currentSpeaker?[key] = value
                }
            }
        }
        if let s = currentSpeaker { speakers.append(s) }
        return speakers
    }

    // MARK: - Tests

    func testMDAndJSONHaveSameDuration() {
        // YAML has duration as "M:SS" string, JSON has duration_seconds as Int
        guard let durationStr = yamlDict["duration"]?.replacingOccurrences(of: "\"", with: "") else {
            XCTFail("Could not find duration in YAML")
            return
        }
        let parts = durationStr.split(separator: ":")
        guard parts.count == 2,
              let minutes = Int(parts[0]),
              let seconds = Int(parts[1]) else {
            XCTFail("Could not parse duration string '\(durationStr)'")
            return
        }
        let yamlDurationSeconds = minutes * 60 + seconds
        let jsonDurationSeconds = jsonSidecar.recording.durationSeconds

        XCTAssertEqual(yamlDurationSeconds, jsonDurationSeconds,
            "YAML duration (\(yamlDurationSeconds)s from '\(durationStr)') should match JSON duration_seconds (\(jsonDurationSeconds))")
    }

    func testMDAndJSONHaveSameUtteranceCount() {
        guard let micStr = yamlDict["mic_utterances"],
              let sysStr = yamlDict["system_utterances"],
              let micCount = Int(micStr),
              let sysCount = Int(sysStr) else {
            XCTFail("Could not parse utterance counts from YAML")
            return
        }
        let yamlTotal = micCount + sysCount
        let jsonTotal = jsonSidecar.utterances.count

        XCTAssertEqual(yamlTotal, jsonTotal,
            "YAML utterance count (\(micCount) mic + \(sysCount) sys = \(yamlTotal)) should match JSON utterances array length (\(jsonTotal))")
    }

    func testMDAndJSONHaveSameEngineNames() {
        // YAML says "parakeet_local", JSON says "parakeet-tdt-v3" -- these are DIFFERENT strings
        // but both correct representations. YAML is the marketing/config name, JSON is the model name.
        // This test documents the intentional mapping.
        let yamlEngine = yamlDict["transcription_engine"]
        let jsonEngine = jsonSidecar.recording.engines.stt

        XCTAssertEqual(yamlEngine, "parakeet_local",
            "YAML transcription_engine should be 'parakeet_local'")
        XCTAssertEqual(jsonEngine, "parakeet-tdt-v3",
            "JSON stt engine should be 'parakeet-tdt-v3'")

        // Verify diarization engine names
        let yamlDiarization = yamlDict["diarization_engine"]
        let jsonDiarization = jsonSidecar.recording.engines.diarization

        XCTAssertEqual(yamlDiarization, "pyannote_offline",
            "YAML diarization_engine should be 'pyannote_offline'")
        XCTAssertEqual(jsonDiarization, "pyannote-offline",
            "JSON diarization engine should be 'pyannote-offline'")

        // Document: underscores in YAML, hyphens in JSON is the intentional convention
        XCTAssertNotEqual(yamlEngine, jsonEngine,
            "Engine names are intentionally different between YAML and JSON (underscore vs hyphen/model-name)")
    }

    func testMDAndJSONHaveSameSpeakers() {
        let jsonSpeakerIds = Set(jsonSidecar.speakers.map { $0.id })
        XCTAssertFalse(jsonSpeakerIds.isEmpty, "JSON should have speakers")

        // YAML should have a speakers block
        XCTAssertTrue(mdContent.contains("speakers:"), "YAML should contain a speakers block")

        // JSON speakers should include IDs from our utterances
        XCTAssertTrue(jsonSpeakerIds.contains("system_0"), "JSON should contain system_0 speaker")

        // Speaker names from mappings should appear in JSON
        let jsonNames = jsonSidecar.speakers.compactMap { $0.name }
        XCTAssertTrue(jsonNames.contains(where: { $0.contains("Alice") }),
            "JSON speakers should include Alice from our mapping")
    }

    func testIndexMatchesFileOnDisk() {
        guard let entry = indexData.transcripts.first else {
            XCTFail("Index should have at least one transcript entry")
            return
        }

        let stem = savedURL.deletingPathExtension().lastPathComponent
        XCTAssertEqual(entry.filename, stem,
            "Index filename '\(entry.filename)' should match the actual .md file stem '\(stem)'")

        // Verify the .md file actually exists on disk with that name
        let expectedMDPath = tempDir.appendingPathComponent("\(entry.filename).md")
        XCTAssertTrue(FileManager.default.fileExists(atPath: expectedMDPath.path),
            "The .md file referenced by the index should exist on disk at \(expectedMDPath.path)")
    }

    func testIndexWordCountMatchesMDWordCount() {
        guard let yamlWordCountStr = yamlDict["total_word_count"],
              let yamlWordCount = Int(yamlWordCountStr) else {
            XCTFail("Could not parse total_word_count from YAML")
            return
        }

        guard let entry = indexData.transcripts.first else {
            XCTFail("Index should have at least one transcript entry")
            return
        }

        XCTAssertEqual(entry.wordCount, yamlWordCount,
            "Index word_count (\(entry.wordCount)) should match YAML total_word_count (\(yamlWordCount))")
    }

    func testIndexSpeakerCountMatchesMDSpeakerCount() {
        guard let micSpeakersStr = yamlDict["mic_speakers"],
              let sysSpeakersStr = yamlDict["system_speakers"],
              let micSpeakers = Int(micSpeakersStr),
              let sysSpeakers = Int(sysSpeakersStr) else {
            XCTFail("Could not parse speaker counts from YAML")
            return
        }

        guard let entry = indexData.transcripts.first else {
            XCTFail("Index should have at least one transcript entry")
            return
        }

        // The index speaker count comes from the JSON sidecar's speakers array length
        // which includes both mic and system speakers
        let yamlTotalSpeakers = micSpeakers + sysSpeakers
        XCTAssertEqual(entry.speakerCount, yamlTotalSpeakers,
            "Index speaker_count (\(entry.speakerCount)) should match YAML mic_speakers + system_speakers (\(yamlTotalSpeakers))")
    }

    func testJSONUtteranceSpeakerIdsAllResolve() {
        let speakerIds = Set(jsonSidecar.speakers.map { $0.id })

        for utterance in jsonSidecar.utterances {
            XCTAssertTrue(speakerIds.contains(utterance.speakerId),
                "Utterance speaker_id '\(utterance.speakerId)' should appear in speakers array. Available: \(speakerIds)")
        }
    }

    func testJSONUtteranceTimestampsWithinDuration() {
        let duration = Double(jsonSidecar.recording.durationSeconds)

        for (i, utterance) in jsonSidecar.utterances.enumerated() {
            XCTAssertGreaterThanOrEqual(utterance.start, 0.0,
                "Utterance[\(i)] start (\(utterance.start)) should be >= 0")
            XCTAssertLessThanOrEqual(utterance.start, duration,
                "Utterance[\(i)] start (\(utterance.start)) should be <= duration (\(duration))")
            XCTAssertLessThanOrEqual(utterance.end, duration,
                "Utterance[\(i)] end (\(utterance.end)) should be <= duration (\(duration))")
            XCTAssertGreaterThanOrEqual(utterance.end, utterance.start,
                "Utterance[\(i)] end (\(utterance.end)) should be >= start (\(utterance.start))")
        }
    }

    func testNoOrphanSidecars() throws {
        let fm = FileManager.default
        let files = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)

        let mdFiles = Set(files.filter { $0.pathExtension == "md" && $0.lastPathComponent.hasPrefix("Call_") }
            .map { $0.deletingPathExtension().lastPathComponent })
        let jsonFiles = Set(files.filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("Call_") }
            .map { $0.deletingPathExtension().lastPathComponent })

        // Every .json sidecar should have a matching .md
        let orphanJsons = jsonFiles.subtracting(mdFiles)
        XCTAssertTrue(orphanJsons.isEmpty,
            "Found .json sidecar(s) without matching .md: \(orphanJsons)")

        // Every .md should have a matching .json sidecar
        let orphanMds = mdFiles.subtracting(jsonFiles)
        XCTAssertTrue(orphanMds.isEmpty,
            "Found .md file(s) without matching .json sidecar: \(orphanMds)")
    }
}
