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
        let ownedTemp = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let prefix = "ImportedAudioEnvironmentContract-"
        let root = ownedTemp.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            let parent = root.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
            if parent.path == ownedTemp.path,
               root.lastPathComponent.hasPrefix(prefix),
               UUID(uuidString: String(root.lastPathComponent.dropFirst(prefix.count))) != nil {
                do { try FileManager.default.removeItem(at: root) }
                catch { XCTFail("Could not clean the owned contract fixture: \(error)") }
            } else {
                XCTFail("Refusing to remove a contract fixture outside its owned temporary root")
            }
        }
        let program = root.appendingPathComponent("Contract.swift")
        try """
        import Foundation
        @main enum Contract {
            static func main() {
                var environment = ["TRANSCRIPTED_AUTOMATED_HARNESS": "0", "__CFBundleIdentifier": "parent.fixture"]
                applyIsolatedLaunchEnvironment(&environment, isolatedHome: URL(fileURLWithPath: "/owned/fixture-home"))
                let active = AutomatedLaunchEnvironment.isActive(environment: environment)
                print(active ? "automated" : "interactive")
                exit(active ? 0 : 1)
            }
        }
        """.write(to: program, atomically: true, encoding: .utf8)
        let executable = root.appendingPathComponent("contract")
        let compilation = try execute(URL(fileURLWithPath: "/usr/bin/xcrun"), [
            "swiftc", "-parse-as-library", "-module-cache-path", root.appendingPathComponent("modules").path,
            repo.appendingPathComponent("Sources/Support/AutomatedLaunchEnvironment.swift").path,
            repo.appendingPathComponent("Tools/TranscriptedQA/Sources/TranscriptedQA/Utilities/IsolatedLaunchEnvironment.swift").path,
            program.path, "-o", executable.path,
        ])
        XCTAssertEqual(compilation.0, 0, compilation.1)
        guard compilation.0 == 0 else { return }
        let outcome = try execute(executable, [])
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
