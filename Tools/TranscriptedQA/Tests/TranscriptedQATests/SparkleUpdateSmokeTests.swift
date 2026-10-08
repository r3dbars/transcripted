import XCTest
@testable import transcripted_qa

final class SparkleUpdateSmokeTests: XCTestCase {
    func testAvailableScenarioRequiresProminentInstallCallout() {
        let report = SparkleUpdateSmokeEvaluator.evaluate(
            state: "available",
            version: "9.9.9",
            launchReport: launchReport(
                updateCallout: row(
                    title: "Update available: 9.9.9",
                    detail: "A new version is ready to install",
                    trailingText: "Install",
                    isVisible: true,
                    isEnabled: true
                ),
                checkUpdates: row(title: "Check for Updates", isVisible: false)
            ),
            reportPath: nil,
            appLogPath: nil
        )

        XCTAssertEqual(report.status, .pass)
        XCTAssertTrue(report.checks.contains { $0.id == "available-callout-title" && $0.status == .pass })
    }

    func testDownloadingScenarioRequiresProgressRowNotInstallCallout() {
        let report = SparkleUpdateSmokeEvaluator.evaluate(
            state: "downloading",
            version: "9.9.9",
            launchReport: launchReport(
                updateCallout: row(isVisible: false),
                checkUpdates: row(
                    title: "Preparing Update",
                    detail: "Downloading 9.9.9",
                    isVisible: true,
                    isEnabled: false
                )
            ),
            reportPath: nil,
            appLogPath: nil
        )

        XCTAssertEqual(report.status, .pass)
        XCTAssertTrue(report.checks.contains { $0.id == "downloading-utility-disabled" && $0.status == .pass })
    }

    func testAvailableScenarioFailsStaleCopy() {
        let report = SparkleUpdateSmokeEvaluator.evaluate(
            state: "available",
            version: "9.9.9",
            launchReport: launchReport(
                updateCallout: row(
                    title: "Update ready",
                    detail: "A new version is ready to install",
                    trailingText: "Install",
                    isVisible: true
                ),
                checkUpdates: row(isVisible: false)
            ),
            reportPath: nil,
            appLogPath: nil
        )

        XCTAssertEqual(report.status, .fail)
        XCTAssertTrue(report.checks.contains { $0.id == "available-callout-title" && $0.status == .fail })
    }

    func testScenarioDoesNotPassOnLaunchReportLeftByEarlierRun() throws {
        let output = try temporaryDirectory()
        let scenario = output.appendingPathComponent("available", isDirectory: true)
        try FileManager.default.createDirectory(at: scenario, withIntermediateDirectories: true)
        try JSONEncoder().encode(passingAvailableReport())
            .write(to: scenario.appendingPathComponent("launch-ui-smoke.json"))
        let app = try fakeApp(in: output, body: "exit 1")

        let report = runner(output: output).runScenario(state: "available", appExecutableURL: app, outputURL: output)

        XCTAssertEqual(report.status, .fail)
        XCTAssertTrue(report.checks.contains { $0.id == "launch-report" && $0.status == .fail }, "\(report.checks)")
    }

    func testScenarioPassesOnLaunchReportWrittenByThisLaunch() throws {
        let output = try temporaryDirectory()
        let fixture = output.appendingPathComponent("fresh-report.json")
        try JSONEncoder().encode(passingAvailableReport()).write(to: fixture)
        let app = try fakeApp(in: output, body: "cp '\(fixture.path)' \"$TRANSCRIPTED_LAUNCH_UI_SMOKE_REPORT\"")

        let report = runner(output: output).runScenario(state: "available", appExecutableURL: app, outputURL: output)

        XCTAssertEqual(report.status, .pass, "\(report.checks)")
    }

    private func runner(output: URL) -> SparkleUpdateSmokeRunner {
        SparkleUpdateSmokeRunner(appBundlePath: "", outputDirectory: output.path, version: "9.9.9", timeout: 2)
    }

    private func passingAvailableReport() -> SparkleLaunchSmokeReport {
        launchReport(
            updateCallout: row(
                title: "Update available: 9.9.9",
                detail: "A new version is ready to install",
                trailingText: "Install",
                isVisible: true,
                isEnabled: true
            ),
            checkUpdates: row(title: "Check for Updates", isVisible: false)
        )
    }

    /// A stand-in app executable: a shell script, never the real app.
    private func fakeApp(in directory: URL, body: String) throws -> URL {
        let url = directory.appendingPathComponent("fake-app.sh")
        try "#!/bin/bash\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func launchReport(
        updateCallout: SparkleLaunchSmokeRow,
        checkUpdates: SparkleLaunchSmokeRow
    ) -> SparkleLaunchSmokeReport {
        SparkleLaunchSmokeReport(
            content: SparkleLaunchSmokeContent(
                updateCallout: updateCallout,
                utilityActions: SparkleLaunchSmokeUtilityActions(checkUpdates: checkUpdates)
            )
        )
    }

    private func row(
        title: String = "",
        detail: String = "",
        trailingText: String = "",
        isVisible: Bool = true,
        isEnabled: Bool = true
    ) -> SparkleLaunchSmokeRow {
        SparkleLaunchSmokeRow(
            title: title,
            detail: detail,
            trailingText: trailingText,
            isVisible: isVisible,
            isEnabled: isEnabled
        )
    }
}
