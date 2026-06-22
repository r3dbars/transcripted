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

    func testTranscriptValidatorIgnoresLocalSummarySidecars() throws {
        try """
        ---
        capture_type: meeting_summary
        source_transcript: "Call_2026-04-18_14-43-40.md"
        summary_model: mlx-community/gemma-4-12B-it-4bit
        ---
        ## Summary
        Local summary text.
        """.write(
            to: tempRoot.appendingPathComponent("Call_2026-04-18_14-43-40.summary.md"),
            atomically: true,
            encoding: .utf8
        )
        try """
        ---
        title: "Call"
        date: "2026-04-18"
        time: "14:43:40"
        duration: "600"
        transcription_engine: "parakeet_local"
        diarization_engine: "pyannote_offline"
        sources: [mic, system_audio]
        capture_quality: "excellent"
        mic_utterances: "1"
        system_utterances: "1"
        total_word_count: "12"
        ---
        ## Transcript
        Speaker 1: Hello.
        """.write(
            to: tempRoot.appendingPathComponent("Call_2026-04-18_14-43-40.md"),
            atomically: true,
            encoding: .utf8
        )

        let results = TranscriptValidator(directory: tempRoot).validate()

        XCTAssertFalse(results.contains { $0.target == "Call_2026-04-18_14-43-40.summary.md" })
        XCTAssertFalse(results.contains { $0.status == .fail })
    }

    func testDictationValidatorRequiresDictationDayEvidence() throws {
        try """
        ---
        title: "Dictations for 2026-05-18"
        date: 2026-05-18
        capture_type: dictation_day
        ---

        # Dictations for May 18, 2026

        ## 8:45 AM - Verify the release checklist

        Entry ID: `dictation-20260518-084500-000`
        Captured: 2026-05-18T13:45:00.000Z
        Words: 9

        Verify the release checklist before touching the signed build.
        """.write(
            to: tempRoot.appendingPathComponent("Dictations_2026-05-18.md"),
            atomically: true,
            encoding: .utf8
        )

        let results = DictationValidator(directory: tempRoot).validate()

        XCTAssertTrue(results.contains { $0.status == .pass && $0.check == "dictation/files-exist" })
        XCTAssertTrue(results.contains { $0.status == .pass && $0.check == "dictation/capture-type" })
        XCTAssertTrue(results.contains { $0.status == .pass && $0.check == "dictation/entry-ids" })
        XCTAssertFalse(results.contains { $0.status == .fail })
    }

    func testDictationValidatorWarnsWhenNoDictationFilesExist() {
        let results = DictationValidator(directory: tempRoot).validate()

        XCTAssertTrue(results.contains {
            $0.status == .warn
                && $0.check == "dictation/files-exist"
                && ($0.detail ?? "").contains("No dictation markdown files found")
        })
    }

    func testDictationValidatorIgnoresMeetingMarkdownInSharedFolders() throws {
        try """
        ---
        title: "Shared legacy meeting"
        date: "2026-05-18"
        time: "14:43:40"
        duration: "600"
        transcription_engine: "parakeet_local"
        diarization_engine: "pyannote_offline"
        capture_type: meeting
        ---

        ## Transcript
        Speaker 1: Hello.
        """.write(
            to: tempRoot.appendingPathComponent("Shared_Meeting_2026-05-18.md"),
            atomically: true,
            encoding: .utf8
        )

        let results = DictationValidator(directory: tempRoot).validate()

        XCTAssertTrue(results.contains { $0.status == .warn && $0.check == "dictation/files-exist" })
        XCTAssertFalse(results.contains { $0.check == "dictation/capture-type" })
        XCTAssertFalse(results.contains { $0.status == .fail })
    }

    func testPathOptionsInferSiblingDictationsForExplicitMeetingsPath() throws {
        let captureRoot = tempRoot.appendingPathComponent("captures", isDirectory: true)
        let meetingsDir = captureRoot.appendingPathComponent("meetings", isDirectory: true)
        let dictationsDir = captureRoot.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: meetingsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dictationsDir, withIntermediateDirectories: true)

        let resolved = QADataDirectories.resolve(meetingsDir: meetingsDir.path, fileManager: .default)

        XCTAssertEqual(resolved.meetingsDir.path, meetingsDir.path)
        XCTAssertEqual(resolved.dictationsDir.path, dictationsDir.path)
    }

    func testPathOptionsInferChildDictationsForFixtureRootPath() throws {
        let dictationsDir = tempRoot.appendingPathComponent("dictations", isDirectory: true)
        try FileManager.default.createDirectory(at: dictationsDir, withIntermediateDirectories: true)

        let resolved = QADataDirectories.resolve(meetingsDir: tempRoot.path, fileManager: .default)

        XCTAssertEqual(resolved.meetingsDir.path, tempRoot.path)
        XCTAssertEqual(resolved.dictationsDir.path, dictationsDir.path)
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

    func testUIAutomationSmokeReportExitCodesSeparateIncompleteFromFailure() {
        var incompleteBuilder = UIAutomationSmokeReportBuilder(
            runID: "fixture",
            appBundlePath: "build/Transcripted.app",
            reportPath: nil
        )
        incompleteBuilder.add(.pass("app-bundle", "Built app bundle exists", target: "build/Transcripted.app"))
        incompleteBuilder.add(.incomplete(
            "accessibility-permission",
            "Automation runner has Accessibility access",
            target: "macOS Accessibility",
            detail: "blocked"
        ))

        let incompleteReport = incompleteBuilder.build(generatedAt: Date(timeIntervalSince1970: 1_777_777_777))
        XCTAssertEqual(incompleteReport.status, .incomplete)
        XCTAssertEqual(incompleteReport.exitCode, 3)

        var failedBuilder = UIAutomationSmokeReportBuilder(
            runID: "fixture",
            appBundlePath: "build/Transcripted.app",
            reportPath: nil
        )
        failedBuilder.add(.pass("app-bundle", "Built app bundle exists", target: "build/Transcripted.app"))
        failedBuilder.add(.fail(
            "menu-identifiers",
            "Menu bar popover exposes core controls",
            target: "menubar",
            detail: "missing controls"
        ))

        let failedReport = failedBuilder.build(generatedAt: Date(timeIntervalSince1970: 1_777_777_777))
        XCTAssertEqual(failedReport.status, .fail)
        XCTAssertEqual(failedReport.exitCode, 1)
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
