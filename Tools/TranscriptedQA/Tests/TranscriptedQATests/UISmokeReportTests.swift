import ArgumentParser
import XCTest
@testable import transcripted_qa

/// `ui-smoke` is the repo-owned AX smoke. These check the CLI surface and the
/// report it returns; driving a real app through Accessibility still needs
/// `bash scripts/ops/transcripted-qa-bench.sh --mode ui` on a Mac.
final class UISmokeReportTests: XCTestCase {
    func testUISmokeIsRegisteredAsUiSmoke() {
        XCTAssertEqual(UISmoke.configuration.commandName, "ui-smoke")
        XCTAssertTrue(
            TranscriptedQA.configuration.subcommands.contains { $0 == UISmoke.self },
            "transcripted-qa should expose ui-smoke"
        )
    }

    func testUISmokeOptionsParse() throws {
        let command = try UISmoke.parse([
            "--app", "build/Transcripted.app",
            "--report", "/tmp/ui-automation-smoke.json",
            "--allow-existing-instance",
        ])
        XCTAssertEqual(command.app, "build/Transcripted.app")
        XCTAssertEqual(command.report, "/tmp/ui-automation-smoke.json")
        XCTAssertTrue(command.allowExistingInstance)
        XCTAssertFalse(command.promptForAccessibility, "the smoke should not prompt for Accessibility unless asked")

        let defaults = try UISmoke.parse([])
        XCTAssertFalse(defaults.allowExistingInstance, "an existing Transcripted process should be INCOMPLETE by default")
    }

    func testAllPassingChecksPassWithExitZero() {
        var builder = UIAutomationSmokeReportBuilder(runID: "run", appBundlePath: "build/Transcripted.app", reportPath: nil)
        builder.add(.pass("app-bundle", "Built app bundle exists", target: "build/Transcripted.app"))
        let report = builder.build()
        XCTAssertEqual(report.status, .pass)
        XCTAssertEqual(report.exitCode, 0)
    }

    func testABlockedCheckIsIncompleteWithExitThree() {
        var builder = UIAutomationSmokeReportBuilder(runID: "run", appBundlePath: "build/Transcripted.app", reportPath: nil)
        builder.add(.pass("app-bundle", "Built app bundle exists", target: "build/Transcripted.app"))
        builder.add(.incomplete("accessibility-permission", "Runner has Accessibility access", target: "runner", detail: "blocked"))
        let report = builder.build()
        XCTAssertEqual(report.status, .incomplete)
        XCTAssertEqual(report.status.rawValue, "INCOMPLETE")
        XCTAssertEqual(report.exitCode, 3, "a TCC blocker should exit 3, not pass and not fail")
    }

    func testAFailedCheckFailsEvenWhenAnotherIsIncomplete() {
        var builder = UIAutomationSmokeReportBuilder(runID: "run", appBundlePath: "build/Transcripted.app", reportPath: nil)
        builder.add(.incomplete("accessibility-permission", "Runner has Accessibility access", target: "runner", detail: "blocked"))
        builder.add(.fail("menubar-rows", "Menu bar rows are scriptable", target: "transcripted.menubar.utility.quit", detail: "missing"))
        let report = builder.build()
        XCTAssertEqual(report.status, .fail)
        XCTAssertEqual(report.exitCode, 1)
    }

    func testReportCarriesTheOnboardingEvidence() throws {
        var builder = UIAutomationSmokeReportBuilder(runID: "run", appBundlePath: "build/Transcripted.app", reportPath: nil)
        builder.onboardingIsolatedHomePath = "/tmp/onboarding-home"
        builder.onboardingAppLogPath = "/tmp/onboarding-home/app.log"
        builder.add(.pass("onboarding-isolated-home", "First-run onboarding home is writable", target: "/tmp/onboarding-home"))

        let data = try JSONEncoder().encode(builder.build())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["status"] as? String, "PASS")
        XCTAssertEqual(json["onboardingIsolatedHomePath"] as? String, "/tmp/onboarding-home")
        XCTAssertEqual(json["onboardingAppLogPath"] as? String, "/tmp/onboarding-home/app.log")
        let checks = try XCTUnwrap(json["checks"] as? [[String: Any]])
        XCTAssertEqual(checks.first?["id"] as? String, "onboarding-isolated-home")
    }
}
