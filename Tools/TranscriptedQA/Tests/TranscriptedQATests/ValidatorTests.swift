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

    func testJSONSidecarValidatorReportsMalformedJSON() throws {
        try "{ not valid json".write(
            to: tempRoot.appendingPathComponent("Call_2026-04-18_14-43-40.json"),
            atomically: true,
            encoding: .utf8
        )

        let results = JSONSidecarValidator(directory: tempRoot).validate()

        XCTAssertTrue(results.contains {
            $0.status == .fail
                && $0.check == "artifact/json-valid"
                && $0.target == "Call_2026-04-18_14-43-40.json"
        })
    }

    func testTranscriptValidatorReportsMalformedMarkdownFrontmatter() throws {
        try "not markdown at all".write(
            to: tempRoot.appendingPathComponent("Call_2026-04-18_14-43-40.md"),
            atomically: true,
            encoding: .utf8
        )

        let results = TranscriptValidator(directory: tempRoot).validate()

        XCTAssertTrue(results.contains {
            $0.status == .fail
                && $0.check == "transcript/yaml-present"
                && ($0.detail ?? "").contains("No YAML frontmatter found")
        })
    }

    func testLogValidatorAcceptsStableJSONLFields() throws {
        let logURL = tempRoot.appendingPathComponent("app.jsonl")
        try """
        {"t":"2026-05-18T12:00:00Z","l":"info","s":"app","m":"started"}
        {"t":"2026-05-18T12:00:01Z","l":"debug","s":"audio.mic","m":"ready"}
        """.write(to: logURL, atomically: true, encoding: .utf8)

        let results = LogValidator(logPath: logURL.path).validate()

        XCTAssertTrue(results.contains { $0.status == .pass && $0.check == "logs/jsonl-valid" })
        XCTAssertTrue(results.contains { $0.status == .pass && $0.check == "logs/jsonl-required-keys" })
        XCTAssertTrue(results.contains { $0.status == .pass && $0.check == "logs/jsonl-valid-levels" })
        XCTAssertTrue(results.contains { $0.status == .pass && $0.check == "logs/jsonl-valid-subsystems" })
    }

    func testLogValidatorFailsMissingStableJSONLFields() throws {
        let logURL = tempRoot.appendingPathComponent("app.jsonl")
        try """
        {"t":"2026-05-18T12:00:00Z","l":"info","s":"app"}
        """.write(to: logURL, atomically: true, encoding: .utf8)

        let results = LogValidator(logPath: logURL.path).validate()

        XCTAssertTrue(results.contains {
            $0.status == .fail
                && $0.check == "logs/jsonl-required-keys"
                && ($0.detail ?? "").contains("t/l/s/m")
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

    func testValidationReportJSONIncludesAutomationSummaryAndFingerprints() throws {
        let generatedAt = Date(timeIntervalSince1970: 1_777_777_777)
        let report = ValidationReport(
            results: [
                .warn("transcript/yaml-capture-quality", target: "one.md", detail: "capture_quality key not present — check skipped"),
                .warn("transcript/yaml-capture-quality", target: "two.md", detail: "capture_quality key not present — check skipped"),
                .fail("artifact/md-match", target: "Call_2026-04-18_14-43-40.json", detail: "No corresponding .md file"),
            ],
            generatedAt: generatedAt
        )

        let data = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let automation = try XCTUnwrap(object["automation"] as? [String: Any])
        XCTAssertEqual(automation["status"] as? String, "FAIL")
        XCTAssertEqual(automation["exitCode"] as? Int, 1)
        XCTAssertEqual(automation["resultCount"] as? Int, 3)
        XCTAssertEqual(automation["failureFingerprintCount"] as? Int, 2)
        XCTAssertEqual(automation["generatedAt"] as? String, "2026-05-03T03:09:37Z")

        let fingerprints = try XCTUnwrap(object["failureFingerprints"] as? [[String: Any]])
        XCTAssertEqual(fingerprints.count, 2)

        let groupedWarning = try XCTUnwrap(
            fingerprints.first { $0["check"] as? String == "transcript/yaml-capture-quality" }
        )
        XCTAssertEqual(groupedWarning["status"] as? String, "WARN")
        XCTAssertEqual(groupedWarning["count"] as? Int, 2)
        XCTAssertEqual(
            Set((groupedWarning["targets"] as? [String]) ?? []),
            Set(["one.md", "two.md"])
        )
        XCTAssertNotNil(groupedWarning["id"] as? String)

        let groupedFailure = try XCTUnwrap(
            fingerprints.first { $0["check"] as? String == "artifact/md-match" }
        )
        XCTAssertEqual(groupedFailure["status"] as? String, "FAIL")
        XCTAssertEqual(groupedFailure["count"] as? Int, 1)
        XCTAssertEqual(groupedFailure["detail"] as? String, "No corresponding .md file")
    }

    func testValidationReportFingerprintIDDoesNotDependOnTargets() throws {
        let first = ValidationReport(results: [
            .fail("artifact/md-match", target: "one.json", detail: "No corresponding .md file"),
        ])
        let second = ValidationReport(results: [
            .fail("artifact/md-match", target: "two.json", detail: "No corresponding .md file"),
        ])

        XCTAssertEqual(
            try XCTUnwrap(first.failureFingerprints.first?.id),
            try XCTUnwrap(second.failureFingerprints.first?.id)
        )
    }
}
