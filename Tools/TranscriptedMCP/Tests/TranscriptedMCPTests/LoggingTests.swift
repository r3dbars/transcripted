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
