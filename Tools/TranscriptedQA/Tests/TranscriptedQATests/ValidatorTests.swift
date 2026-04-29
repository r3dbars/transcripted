import XCTest
@testable import transcripted_qa

final class ValidatorTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedQATests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
    }

    func testYAMLParserReadsInlineAndBlockLists() {
        let parser = YAMLParser(content: """
        ---
        title: "Release QA"
        transcription_engine: parakeet_local
        sources:
          - mic
          - system_audio
        tags: [release, qa]
        ---
        ## Transcript
        Body
        """)

        XCTAssertTrue(parser.hasFrontmatter)
        XCTAssertEqual(parser.value(for: "title"), "Release QA")
        XCTAssertEqual(parser.value(for: "sources"), "mic, system_audio")
        XCTAssertEqual(parser.value(for: "tags"), "release, qa")
        XCTAssertTrue(parser.body.contains("## Transcript"))
    }

    func testIndexValidatorFailsMissingMarkdownForLegacyIndexEntry() throws {
        try """
        {
          "transcript_count": 1,
          "transcripts": [
            { "filename": "Call_2026-04-18_14-43-40" }
          ],
          "known_speakers": []
        }
        """.write(
            to: tempRoot.appendingPathComponent("transcripted.json"),
            atomically: true,
            encoding: .utf8
        )
        try "{}".write(
            to: tempRoot.appendingPathComponent("Call_2026-04-18_14-43-40.json"),
            atomically: true,
            encoding: .utf8
        )

        let results = IndexValidator(directory: tempRoot).validate()

        XCTAssertTrue(results.contains {
            $0.status == .fail
                && $0.check == "index/markdown-on-disk"
                && ($0.detail ?? "").contains("Call_2026-04-18_14-43-40.md not found")
        })
    }

    func testJSONSidecarValidatorFailsEmptyUtterances() throws {
        try """
        {
          "version": "1.0",
          "recording": {
            "duration_seconds": 12,
            "engines": {
              "stt": "parakeet-tdt-v3",
              "diarization": "pyannote-offline"
            }
          },
          "speakers": [],
          "utterances": []
        }
        """.write(
            to: tempRoot.appendingPathComponent("Call_2026-04-18_14-43-40.json"),
            atomically: true,
            encoding: .utf8
        )

        let results = JSONSidecarValidator(directory: tempRoot).validate()

        XCTAssertTrue(results.contains {
            $0.status == .fail
                && $0.check == "artifact/json-utterances-present"
                && ($0.detail ?? "").contains("No utterances found")
        })
    }

    func testValidationReportExitsNonZeroOnlyForFailures() {
        XCTAssertEqual(
            ValidationReport(results: [.pass("ok", target: "fixture"), .warn("warn", target: "fixture", detail: "heads up")]).exitCode,
            0
        )
        XCTAssertEqual(
            ValidationReport(results: [.fail("bad", target: "fixture", detail: "broken")]).exitCode,
            1
        )
    }

    func testValidationReportBuildsStaleArtifactFingerprintForRepeatedLocalDriftShape() {
        let results: [ValidationResult] = [
            .fail("artifact/json-utterances-present", target: "Call_2026-04-18_14-43-40.json", detail: "No utterances found"),
            .fail("artifact/md-match", target: "Call_2026-04-18_14-43-40.json", detail: "No corresponding .md file"),
            .fail("index/markdown-on-disk", target: "transcripted.json", detail: "Call_2026-04-18_14-43-40.md not found on disk")
        ]

        let report = ValidationReport(results: results)

        XCTAssertEqual(report.automation.overallStatus, .localDataDrift)
        XCTAssertFalse(report.automation.repoFixCandidate)
        XCTAssertEqual(report.automation.failureFingerprints.count, 1)
        XCTAssertEqual(
            report.automation.failureFingerprints.first?.id,
            "stale_legacy_sidecar_missing_markdown_index_drift/Call_2026-04-18_14-43-40"
        )
    }

    func testValidationReportMarksContractFailuresAsRepoFixCandidates() {
        let results: [ValidationResult] = [
            .fail("transcript/yaml-required-keys", target: "Broken.md", detail: "Missing required YAML keys")
        ]

        let report = ValidationReport(results: results)

        XCTAssertEqual(report.automation.overallStatus, .repoFixCandidate)
        XCTAssertTrue(report.automation.repoFixCandidate)
        XCTAssertEqual(report.automation.failureFingerprints.first?.scope, .sharedContract)
    }

    func testValidationReportCarriesContextIntoJSON() throws {
        let report = ValidationReport(
            results: [.pass("ok", target: "fixture")],
            context: ValidationContext(
                command: "validate-all",
                generatedAt: "2026-04-29T10:00:00Z",
                meetingsDir: "/tmp/meetings",
                stateDir: "/tmp/state",
                logPath: "/tmp/logs/app.jsonl"
            )
        )

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(ValidationReport.self, from: data)

        XCTAssertEqual(decoded.context?.command, "validate-all")
        XCTAssertEqual(decoded.context?.meetingsDir, "/tmp/meetings")
        XCTAssertEqual(decoded.automation.overallStatus, .green)
    }
}
