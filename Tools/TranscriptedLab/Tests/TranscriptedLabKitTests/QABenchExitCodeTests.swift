import XCTest
@testable import TranscriptedLabKit

/// transcripted-qa-bench.sh writes its report and then exits 1 when a step
/// FAILed or 3 when a step was skipped or held. Those runs still have a report
/// worth scoring; only a run that never wrote one is a plain process failure.
final class QABenchExitCodeTests: XCTestCase {
    func testQABenchHoldExitStillScoresSkippedRun() async throws {
        let report = try await runQABench(rows: ["01-build\tBuild\tSKIP\t0\t0\t", "02-unit\tUnit tests\tPASS\t0\t4\t"], exitCode: 3)

        XCTAssertNotEqual(report.status, .failed, report.summary)
        XCTAssertEqual(metric("qa.pass", in: report), 1)
        XCTAssertEqual(metric("qa.skip", in: report), 1)
        XCTAssertNotNil(report.scorecard.overallScore)
        XCTAssertEqual(report.process?.exitCode, 3)
    }

    func testQABenchHoldExitIsNotReportedAsAPass() async throws {
        let report = try await runQABench(rows: ["01-build\tBuild\tSKIP\t0\t0\t", "02-unit\tUnit tests\tPASS\t0\t4\t"], exitCode: 3)

        XCTAssertEqual(report.status, .warning, report.summary)
    }

    func testQABenchFailExitKeepsStepBreakdown() async throws {
        let report = try await runQABench(rows: ["01-build\tBuild\tPASS\t0\t9\t", "02-unit\tUnit tests\tFAIL\t1\t4\t"], exitCode: 1)

        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(metric("qa.fail", in: report), 1)
        XCTAssertEqual(metric("qa.pass", in: report), 1)
    }

    func testQABenchCrashWithoutReportStillFails() async throws {
        let report = try await runQABench(rows: nil, exitCode: 1)

        XCTAssertEqual(report.status, .failed)
        XCTAssertTrue(report.metrics.isEmpty)
        XCTAssertTrue(report.scorecard.hardGateFailures.contains { $0.contains("exited with code 1") },
                      "\(report.scorecard.hardGateFailures)")
    }

    func testQABenchUnknownExitStillFailsEvenWithReport() async throws {
        let report = try await runQABench(rows: ["01-build\tBuild\tPASS\t0\t9\t"], exitCode: 2)

        XCTAssertEqual(report.status, .failed)
        XCTAssertTrue(report.scorecard.hardGateFailures.contains { $0.contains("exited with code 2") },
                      "\(report.scorecard.hardGateFailures)")
    }

    func testQABenchAbortAfterPassingStepsStillFails() async throws {
        // set -u abort mid-run: earlier steps appended PASS rows, write_report never ran.
        let report = try await runQABench(rows: ["01-build\tBuild\tPASS\t0\t9\t"], exitCode: 1, writesReport: false)

        XCTAssertEqual(report.status, .failed, report.summary)
        XCTAssertTrue(report.scorecard.hardGateFailures.contains { $0.contains("exited with code 1") },
                      "\(report.scorecard.hardGateFailures)")
    }

    func testQABenchAbortWithEmptyResultsStillFails() async throws {
        // Startup truncates results.tsv, then `cd "$REPO_ROOT" || exit 1` fails.
        let report = try await runQABench(rows: [], exitCode: 1, writesReport: false)

        XCTAssertEqual(report.status, .failed, report.summary)
        XCTAssertTrue(report.scorecard.hardGateFailures.contains { $0.contains("exited with code 1") },
                      "\(report.scorecard.hardGateFailures)")
    }

    func testQABenchFailExitWithoutFailRowsStillFails() async throws {
        let report = try await runQABench(rows: ["01-build\tBuild\tPASS\t0\t9\t"], exitCode: 1)

        XCTAssertEqual(report.status, .failed, report.summary)
        XCTAssertTrue(report.scorecard.hardGateFailures.contains { $0.contains("exited with code 1") },
                      "\(report.scorecard.hardGateFailures)")
    }

    // MARK: - Fixture

    /// Runs the QA bench against a fake repository whose qa-bench script writes
    /// `rows` (when given) to results.tsv, plus qa-report.md when `writesReport`
    /// (as write_report does), then exits with `exitCode`.
    private func runQABench(rows: [String]?, exitCode: Int32, writesReport: Bool = true) async throws -> LabRunReport {
        let root = try temporaryDirectory()
        let repo = root.appendingPathComponent("repo", isDirectory: true)
        let script = repo.appendingPathComponent("scripts/ops/transcripted-qa-bench.sh")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        for marker in ["AGENTS.md", "Tools/SpeakerEvalHarness/Package.swift"] {
            let url = repo.appendingPathComponent(marker)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "fixture".write(to: url, atomically: true, encoding: .utf8)
        }
        var writeRows = ""
        if let rows {
            let fixture = root.appendingPathComponent("results-fixture.tsv")
            try rows.map { $0 + "\n" }.joined().write(to: fixture, atomically: true, encoding: .utf8)
            writeRows = """
            mkdir -p "$out/$run"
            cp '\(fixture.path)' "$out/$run/results.tsv"
            \(writesReport ? "echo '# QA report' > \"$out/$run/qa-report.md\"" : "")
            """
        }
        let source = """
        #!/bin/bash
        run=""; out=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --run-id) run="$2"; shift 2 ;;
            --out-root) out="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        \(writeRows)
        exit \(exitCode)
        """
        try source.write(to: script, atomically: true, encoding: .utf8)

        var config = LabRunConfiguration(name: "QA exit", bench: .qa, repositoryPath: repo.path, timeoutSeconds: 60, skipBuild: true)
        config.qaMode = .quick
        let runner = LabExperimentRunner(
            reportStore: LabReportStore(rootDirectory: root.appendingPathComponent("reports", isDirectory: true)),
            artifactRoot: root.appendingPathComponent("artifacts", isDirectory: true)
        )
        return await runner.run(config)
    }

    private func metric(_ key: String, in report: LabRunReport) -> Double? {
        report.metrics.first { $0.key == key }?.value
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
}
