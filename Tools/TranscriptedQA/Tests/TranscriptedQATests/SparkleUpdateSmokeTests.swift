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
                    detail: "Transcripted will ask you to restart when 9.9.9 is ready",
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
