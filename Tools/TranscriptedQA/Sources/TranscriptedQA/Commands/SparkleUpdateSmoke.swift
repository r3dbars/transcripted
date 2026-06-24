import ArgumentParser
import Foundation

struct SparkleUpdateSmoke: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sparkle-update-smoke",
        abstract: "Run a no-publish Sparkle update UI smoke with fake update-available and downloading states."
    )

    @Option(name: .long, help: "Path to the built Transcripted.app bundle.")
    var app: String = "build/Transcripted.app"

    @Option(name: .long, help: "Output directory for JSON evidence and the fake appcast fixture.")
    var output: String = "/tmp/transcripted-sparkle-update-smoke"

    @Option(name: .long, help: "Fake display version shown in the update UI.")
    var version: String = "9.9.9"

    @Option(name: .long, help: "Seconds to wait for each launch-smoke report.")
    var timeout: Double = 12

    func run() throws {
        let runner = SparkleUpdateSmokeRunner(
            appBundlePath: app,
            outputDirectory: output,
            version: version,
            timeout: timeout
        )
        let report = runner.run()
        try report.write(to: URL(fileURLWithPath: output, isDirectory: true))
        report.printText()
        if report.exitCode != 0 {
            throw ExitCode(report.exitCode)
        }
    }
}

struct SparkleUpdateSmokeRunner {
    let appBundlePath: String
    let outputDirectory: String
    let version: String
    let timeout: TimeInterval
    var fileManager: FileManager = .default

    func run() -> SparkleUpdateSmokeReport {
        let runID = UUID().uuidString
        let outputURL = URL(fileURLWithPath: outputDirectory, isDirectory: true).standardizedFileURL
        var scenarios: [SparkleUpdateSmokeScenarioReport] = []
        let appURL = URL(fileURLWithPath: appBundlePath).standardizedFileURL
        let executableURL = appURL.appendingPathComponent("Contents/MacOS/Transcripted", isDirectory: false)

        do {
            try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)
            try writeFakeAppcast(to: outputURL.appendingPathComponent("fake-appcast.xml", isDirectory: false))
        } catch {
            return SparkleUpdateSmokeReport(
                runID: runID,
                status: .fail,
                exitCode: 1,
                generatedAt: ISO8601DateFormatter().string(from: Date()),
                appBundlePath: appURL.path,
                outputDirectory: outputURL.path,
                fakeAppcastPath: outputURL.appendingPathComponent("fake-appcast.xml", isDirectory: false).path,
                scenarios: [
                    SparkleUpdateSmokeScenarioReport(
                        state: "setup",
                        status: .fail,
                        reportPath: nil,
                        appLogPath: nil,
                        checks: [
                            SparkleUpdateSmokeCheck(
                                id: "output-directory",
                                status: .fail,
                                detail: "Could not prepare output directory: \(error.localizedDescription)"
                            ),
                        ]
                    ),
                ],
                limitations: Self.limitations
            )
        }

        guard fileManager.fileExists(atPath: appURL.path) else {
            scenarios.append(.singleFailure(
                state: "setup",
                id: "app-bundle",
                detail: "Run bash build.sh --no-open first, or pass --app."
            ))
            return buildReport(runID: runID, appURL: appURL, outputURL: outputURL, scenarios: scenarios)
        }

        guard fileManager.isExecutableFile(atPath: executableURL.path) else {
            scenarios.append(.singleFailure(
                state: "setup",
                id: "app-executable",
                detail: "Transcripted.app is missing Contents/MacOS/Transcripted."
            ))
            return buildReport(runID: runID, appURL: appURL, outputURL: outputURL, scenarios: scenarios)
        }

        scenarios.append(runScenario(
            state: "available",
            appExecutableURL: executableURL,
            outputURL: outputURL
        ))
        scenarios.append(runScenario(
            state: "downloading",
            appExecutableURL: executableURL,
            outputURL: outputURL
        ))

        return buildReport(runID: runID, appURL: appURL, outputURL: outputURL, scenarios: scenarios)
    }

    private func runScenario(
        state: String,
        appExecutableURL: URL,
        outputURL: URL
    ) -> SparkleUpdateSmokeScenarioReport {
        let scenarioDirectory = outputURL.appendingPathComponent(state, isDirectory: true)
        let reportURL = scenarioDirectory.appendingPathComponent("launch-ui-smoke.json", isDirectory: false)
        let logURL = scenarioDirectory.appendingPathComponent("app.log", isDirectory: false)
        do {
            try fileManager.createDirectory(at: scenarioDirectory, withIntermediateDirectories: true)
        } catch {
            return .singleFailure(
                state: state,
                id: "scenario-directory",
                detail: "Could not create scenario directory: \(error.localizedDescription)"
            )
        }

        let process = Process()
        process.executableURL = appExecutableURL
        process.arguments = [
            "-permissionsOnboardingCompleted", "YES",
            "-forcePermissionsOnboarding", "NO",
            "-observability-anonymous-analytics-enabled", "NO",
            "-observability-crash-reporting-enabled", "NO",
        ]

        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "__CFBundleIdentifier")
        environment["HOME"] = scenarioDirectory.path
        environment["CFFIXED_USER_HOME"] = scenarioDirectory.path
        environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] = "1"
        environment["TRANSCRIPTED_DISABLE_RUNTIME_DIAGNOSTICS"] = "1"
        environment["TRANSCRIPTED_DISABLE_SINGLE_INSTANCE_GUARD"] = "1"
        environment["TRANSCRIPTED_LAUNCH_UI_SMOKE_REPORT"] = reportURL.path
        environment["TRANSCRIPTED_LAUNCH_UI_SMOKE_TERMINATE_AFTER_REPORT"] = "1"
        environment["TRANSCRIPTED_LAUNCH_UI_SMOKE_TERMINATE_DELAY_SECONDS"] = "0.1"
        environment["TRANSCRIPTED_LAUNCH_UI_SMOKE_UPDATE_STATE"] = state
        environment["TRANSCRIPTED_LAUNCH_UI_SMOKE_UPDATE_VERSION"] = version
        process.environment = environment

        fileManager.createFile(atPath: logURL.path, contents: nil)
        let logHandle = try? FileHandle(forWritingTo: logURL)
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
        } catch {
            try? logHandle?.close()
            return .singleFailure(
                state: state,
                id: "launch-app",
                detail: "Could not launch app: \(error.localizedDescription)",
                reportPath: reportURL.path,
                appLogPath: logURL.path
            )
        }

        let deadline = Date().addingTimeInterval(max(2, timeout))
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.2)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        try? logHandle?.close()

        guard fileManager.fileExists(atPath: reportURL.path) else {
            return .singleFailure(
                state: state,
                id: "launch-report",
                detail: "App launched, but did not write the launch UI smoke report.",
                reportPath: reportURL.path,
                appLogPath: logURL.path
            )
        }

        do {
            let data = try Data(contentsOf: reportURL)
            let launchReport = try JSONDecoder().decode(SparkleLaunchSmokeReport.self, from: data)
            return SparkleUpdateSmokeEvaluator.evaluate(
                state: state,
                version: version,
                launchReport: launchReport,
                reportPath: reportURL.path,
                appLogPath: logURL.path
            )
        } catch {
            return .singleFailure(
                state: state,
                id: "decode-launch-report",
                detail: "Could not decode launch report: \(error.localizedDescription)",
                reportPath: reportURL.path,
                appLogPath: logURL.path
            )
        }
    }

    private func writeFakeAppcast(to url: URL) throws {
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel>
            <title>Transcripted Local Sparkle UI Smoke</title>
            <item>
              <title>Version \(version)</title>
              <sparkle:version>\(version)</sparkle:version>
              <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
              <enclosure url="https://example.invalid/Transcripted-\(version).dmg" length="123" sparkle:edSignature="local-fixture-only" />
            </item>
          </channel>
        </rss>
        """.write(to: url, atomically: true, encoding: .utf8)
    }

    private func buildReport(
        runID: String,
        appURL: URL,
        outputURL: URL,
        scenarios: [SparkleUpdateSmokeScenarioReport]
    ) -> SparkleUpdateSmokeReport {
        let status: SparkleUpdateSmokeStatus = scenarios.contains { $0.status == .fail } ? .fail : .pass
        return SparkleUpdateSmokeReport(
            runID: runID,
            status: status,
            exitCode: status == .pass ? 0 : 1,
            generatedAt: ISO8601DateFormatter().string(from: Date()),
            appBundlePath: appURL.path,
            outputDirectory: outputURL.path,
            fakeAppcastPath: outputURL.appendingPathComponent("fake-appcast.xml", isDirectory: false).path,
            scenarios: scenarios,
            limitations: Self.limitations
        )
    }

    static let limitations = [
        "Uses a launch-smoke-only fake Sparkle state; it does not contact the live appcast.",
        "Does not download, verify, install, relaunch, notarize, publish, update Homebrew, or prove an existing installed app can upgrade.",
    ]
}

enum SparkleUpdateSmokeEvaluator {
    static func evaluate(
        state: String,
        version: String,
        launchReport: SparkleLaunchSmokeReport,
        reportPath: String?,
        appLogPath: String?
    ) -> SparkleUpdateSmokeScenarioReport {
        var checks: [SparkleUpdateSmokeCheck] = [
            .pass("launch-report", "App wrote launch UI smoke report."),
        ]

        switch state {
        case "available":
            checks.append(checkEqual(
                id: "available-callout-title",
                actual: launchReport.content.updateCallout.title,
                expected: "Update available: \(version)"
            ))
            checks.append(checkEqual(
                id: "available-callout-detail",
                actual: launchReport.content.updateCallout.detail,
                expected: "A new version is ready to install"
            ))
            checks.append(checkEqual(
                id: "available-callout-trailing",
                actual: launchReport.content.updateCallout.trailingText,
                expected: "Install"
            ))
            checks.append(checkTrue(
                id: "available-callout-visible",
                condition: launchReport.content.updateCallout.isVisible,
                detail: "Expected the prominent menu update callout to be visible."
            ))
            checks.append(checkTrue(
                id: "available-utility-hidden",
                condition: !launchReport.content.utilityActions.checkUpdates.isVisible,
                detail: "Expected the utility update row to be hidden while the prominent available-update callout is shown."
            ))
        case "downloading":
            checks.append(checkEqual(
                id: "downloading-utility-title",
                actual: launchReport.content.utilityActions.checkUpdates.title,
                expected: "Preparing Update"
            ))
            checks.append(checkEqual(
                id: "downloading-utility-detail",
                actual: launchReport.content.utilityActions.checkUpdates.detail,
                expected: "Transcripted will ask you to restart when \(version) is ready"
            ))
            checks.append(checkTrue(
                id: "downloading-utility-visible",
                condition: launchReport.content.utilityActions.checkUpdates.isVisible,
                detail: "Expected the utility update-progress row to be visible."
            ))
            checks.append(checkTrue(
                id: "downloading-utility-disabled",
                condition: !launchReport.content.utilityActions.checkUpdates.isEnabled,
                detail: "Expected the update-progress row to be disabled while Sparkle is downloading."
            ))
            checks.append(checkTrue(
                id: "downloading-callout-hidden",
                condition: !launchReport.content.updateCallout.isVisible,
                detail: "Expected no prominent install callout while the update is still downloading."
            ))
        default:
            checks.append(.fail("unknown-state", "Unknown fake Sparkle state: \(state)."))
        }

        let status: SparkleUpdateSmokeStatus = checks.contains { $0.status == .fail } ? .fail : .pass
        return SparkleUpdateSmokeScenarioReport(
            state: state,
            status: status,
            reportPath: reportPath,
            appLogPath: appLogPath,
            checks: checks
        )
    }

    private static func checkEqual(id: String, actual: String, expected: String) -> SparkleUpdateSmokeCheck {
        actual == expected
            ? .pass(id, "Observed \(expected).")
            : .fail(id, "Expected \(expected), got \(actual).")
    }

    private static func checkTrue(id: String, condition: Bool, detail: String) -> SparkleUpdateSmokeCheck {
        condition ? .pass(id, detail) : .fail(id, detail)
    }
}

enum SparkleUpdateSmokeStatus: String, Codable, Equatable {
    case pass = "PASS"
    case fail = "FAIL"
}

struct SparkleUpdateSmokeCheck: Codable, Equatable {
    let id: String
    let status: SparkleUpdateSmokeStatus
    let detail: String

    static func pass(_ id: String, _ detail: String) -> SparkleUpdateSmokeCheck {
        SparkleUpdateSmokeCheck(id: id, status: .pass, detail: detail)
    }

    static func fail(_ id: String, _ detail: String) -> SparkleUpdateSmokeCheck {
        SparkleUpdateSmokeCheck(id: id, status: .fail, detail: detail)
    }
}

struct SparkleUpdateSmokeScenarioReport: Codable, Equatable {
    let state: String
    let status: SparkleUpdateSmokeStatus
    let reportPath: String?
    let appLogPath: String?
    let checks: [SparkleUpdateSmokeCheck]

    static func singleFailure(
        state: String,
        id: String,
        detail: String,
        reportPath: String? = nil,
        appLogPath: String? = nil
    ) -> SparkleUpdateSmokeScenarioReport {
        SparkleUpdateSmokeScenarioReport(
            state: state,
            status: .fail,
            reportPath: reportPath,
            appLogPath: appLogPath,
            checks: [.fail(id, detail)]
        )
    }
}

struct SparkleUpdateSmokeReport: Codable, Equatable {
    let runID: String
    let status: SparkleUpdateSmokeStatus
    let exitCode: Int32
    let generatedAt: String
    let appBundlePath: String
    let outputDirectory: String
    let fakeAppcastPath: String
    let scenarios: [SparkleUpdateSmokeScenarioReport]
    let limitations: [String]

    func printText() {
        print("\(status.rawValue): Sparkle update UI smoke")
        print("Report: \(outputDirectory)/sparkle-update-smoke.json")
        print("Fake appcast fixture: \(fakeAppcastPath)")
        for scenario in scenarios {
            print("- \(scenario.status.rawValue): \(scenario.state)")
            for check in scenario.checks where check.status == .fail {
                print("  - \(check.id): \(check.detail)")
            }
        }
        print("Limitations: \(limitations.joined(separator: " "))")
    }

    func write(to outputURL: URL) throws {
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: outputURL.appendingPathComponent("sparkle-update-smoke.json", isDirectory: false), options: .atomic)
    }
}

struct SparkleLaunchSmokeReport: Codable, Equatable {
    let content: SparkleLaunchSmokeContent
}

struct SparkleLaunchSmokeContent: Codable, Equatable {
    let updateCallout: SparkleLaunchSmokeRow
    let utilityActions: SparkleLaunchSmokeUtilityActions
}

struct SparkleLaunchSmokeUtilityActions: Codable, Equatable {
    let checkUpdates: SparkleLaunchSmokeRow
}

struct SparkleLaunchSmokeRow: Codable, Equatable {
    let title: String
    let detail: String
    let trailingText: String
    let isVisible: Bool
    let isEnabled: Bool
}
