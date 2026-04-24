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
}
