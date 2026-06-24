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
}
