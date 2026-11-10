import XCTest
@testable import transcripted_qa

final class ImportedAudioNativeSmokeTests: XCTestCase {
    func testNativeSmokeReportMarksIncompleteAsExitCodeThree() {
        let report = ImportedAudioNativeSmokeReport(
            runID: "native-smoke-test",
            generatedAt: "2026-06-24T00:00:00Z",
            appBundlePath: "/tmp/Transcripted.app",
            evidenceRoot: "/tmp/evidence",
            captureLibraryPath: "/tmp/evidence/captures",
            appLogPath: nil,
            selectedAudioPath: nil,
            transcriptPath: nil,
            reportPath: nil,
            checks: [
                .pass("app-bundle", "Built app bundle exists", target: "/tmp/Transcripted.app"),
                .incomplete("imported-transcript-saved", "Imported transcript saved", target: "/tmp/evidence/captures/meetings", detail: "Model runtime not proven.")
            ]
        )

        XCTAssertEqual(report.status, .incomplete)
        XCTAssertEqual(report.exitCode, 3)
    }

    func testNativeSmokeReportMarksAllPassesAsExitCodeZero() {
        let report = ImportedAudioNativeSmokeReport(
            runID: "native-smoke-test",
            generatedAt: "2026-06-24T00:00:00Z",
            appBundlePath: "/tmp/Transcripted.app",
            evidenceRoot: "/tmp/evidence",
            captureLibraryPath: "/tmp/evidence/captures",
            appLogPath: "/tmp/evidence/app.log",
            selectedAudioPath: "/tmp/evidence/audio.aiff",
            transcriptPath: "/tmp/evidence/captures/meetings/audio.md",
            reportPath: nil,
            checks: [
                .pass("native-picker-selection", "Native picker selected audio", target: "audio.aiff"),
                .pass("imported-transcript-saved", "Imported transcript saved", target: "audio.md")
            ]
        )

        XCTAssertEqual(report.status, .pass)
        XCTAssertEqual(report.exitCode, 0)
    }

    func testChildEnvironmentActivatesTheAppsActualAutomationGate() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let outcome = try execute(URL(fileURLWithPath: "/bin/bash"), [
            repo.appendingPathComponent("scripts/dev/test-isolated-launch-environment.sh").path,
        ])
        XCTAssertEqual(outcome.0, 0, outcome.1)
        XCTAssertEqual(outcome.1.trimmingCharacters(in: .whitespacesAndNewlines), "automated")
        XCTAssertFalse(NativeSmokeIsolation.allowed(uid: 501, euid: 501, consoleUID: 501,
                                                   ci: false, githubActions: false,
                                                   githubHosted: false, hostedRunnerAccount: false))
    }

    private func execute(_ executable: URL, _ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

}
