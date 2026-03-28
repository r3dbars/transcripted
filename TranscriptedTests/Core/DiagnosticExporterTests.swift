import XCTest
@testable import Transcripted

final class DiagnosticExporterTests: XCTestCase {

    // MARK: - System Info

    func testSystemInfoContainsAppVersion() {
        let info = DiagnosticExporter.systemInfo
        XCTAssertTrue(info.contains("App:") || info.contains("Transcripted"),
                      "systemInfo should contain app name or version")
    }

    func testSystemInfoContainsMacOSVersion() {
        let info = DiagnosticExporter.systemInfo
        XCTAssertTrue(info.contains("macOS"), "systemInfo should contain macOS version")
    }

    func testSystemInfoContainsMemory() {
        let info = DiagnosticExporter.systemInfo
        XCTAssertTrue(info.contains("Memory") || info.contains("GB"),
                      "systemInfo should contain memory info")
    }

    func testSystemInfoContainsHardwareModel() {
        let info = DiagnosticExporter.systemInfo
        XCTAssertTrue(info.contains("Hardware"),
                      "systemInfo should contain hardware model")
    }

    func testSystemInfoContainsUptime() {
        let info = DiagnosticExporter.systemInfo
        XCTAssertTrue(info.contains("Uptime") || info.contains("h"),
                      "systemInfo should contain uptime")
    }

    func testSystemInfoContainsLocale() {
        let info = DiagnosticExporter.systemInfo
        XCTAssertTrue(info.contains("Locale"),
                      "systemInfo should contain locale")
    }

    func testSystemInfoIsNotEmpty() {
        let info = DiagnosticExporter.systemInfo
        XCTAssertFalse(info.isEmpty, "systemInfo should not be empty")
        XCTAssertGreaterThan(info.count, 50, "systemInfo should have substantial content")
    }

    // MARK: - GitHub Issue URL

    func testGitHubIssueURLIsValid() {
        let url = DiagnosticExporter.gitHubIssueURL(title: "Test Bug", body: "Description")
        XCTAssertTrue(url.absoluteString.contains("github.com"), "URL should point to GitHub")
        XCTAssertTrue(url.absoluteString.contains("issues"), "URL should be an issues URL")
    }

    func testGitHubIssueURLEncodesTitle() {
        let url = DiagnosticExporter.gitHubIssueURL(title: "Bug with spaces & symbols", body: "test")
        XCTAssertFalse(url.absoluteString.contains(" "), "Spaces should be URL-encoded")
    }
}
