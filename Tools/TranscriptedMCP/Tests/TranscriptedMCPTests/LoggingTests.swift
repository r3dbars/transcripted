import Foundation
import XCTest
@testable import transcripted_mcp

final class LoggingTests: XCTestCase {
    func testLogWritesToStderrByDefault() {
        let output = captureStandardError {
            log("default logging still works")
        }

        XCTAssertTrue(output.contains("default logging still works"))
    }

    func testWithLogsSuppressedSkipsStderrOutput() {
        let output = captureStandardError {
            withLogsSuppressed {
                log("self-test should stay quiet")
            }
        }

        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testLogPrefixAndLineEndingStayStable() {
        let output = captureStandardError {
            log("indexed fixture")
        }

        XCTAssertEqual(output, "[transcripted-mcp] indexed fixture\n")
    }

    func testStartupDiagnosticsUseOnlyAllowlistedPhasesAndBuckets() {
        XCTAssertEqual(
            MCPStartupDiagnostics.message(phase: .transportReady, elapsedSeconds: 23.44),
            "Startup phase=transport_ready elapsed_bucket=15s_to_30s"
        )
        XCTAssertEqual(MCPStartupDiagnostics.elapsedBucket(0.24), "under_250ms")
        XCTAssertEqual(MCPStartupDiagnostics.elapsedBucket(0.25), "250ms_to_1s")
        XCTAssertEqual(MCPStartupDiagnostics.elapsedBucket(60), "over_60s")
    }

    func testCountDiagnosticsAreBucketed() {
        XCTAssertEqual(MCPLogPrivacy.countBucket(0), "0")
        XCTAssertEqual(MCPLogPrivacy.countBucket(1), "1")
        XCTAssertEqual(MCPLogPrivacy.countBucket(9), "2_to_10")
        XCTAssertEqual(MCPLogPrivacy.countBucket(50), "11_to_100")
        XCTAssertEqual(MCPLogPrivacy.countBucket(500), "101_to_1000")
        XCTAssertEqual(MCPLogPrivacy.countBucket(5_000), "over_1000")
    }

    func testUnreadableCaptureLogOmitsCustomerFilenameAndPath() {
        let privateLookingName = "customer@example.com confidential meeting.md"
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("private-customer-folder", isDirectory: true)
            .appendingPathComponent(privateLookingName, isDirectory: false)

        let output = captureStandardError {
            XCTAssertNil(TranscriptLoader.loadMeeting(url))
        }

        XCTAssertEqual(output, "[transcripted-mcp] Cannot read meeting markdown\n")
        XCTAssertFalse(output.contains("customer@example.com"))
        XCTAssertFalse(output.contains("private-customer-folder"))
    }

    private func captureStandardError(_ body: () -> Void) -> String {
        let pipe = Pipe()
        let original = dup(STDERR_FILENO)
        XCTAssertNotEqual(original, -1)

        fflush(stderr)
        dup2(pipe.fileHandleForWriting.fileDescriptor, STDERR_FILENO)

        body()

        fflush(stderr)
        dup2(original, STDERR_FILENO)
        close(original)
        pipe.fileHandleForWriting.closeFile()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(decoding: data, as: UTF8.self)
    }
}
