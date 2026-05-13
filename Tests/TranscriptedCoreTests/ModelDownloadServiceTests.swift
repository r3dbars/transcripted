import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class ModelDownloadServiceTests: XCTestCase {

    func testSafeModelFilenameAllowsNestedModelFiles() {
        XCTAssertTrue(ModelDownloadService.isSafeModelFilename("config.json"))
        XCTAssertTrue(ModelDownloadService.isSafeModelFilename("onnx/model.onnx"))
        XCTAssertTrue(ModelDownloadService.isSafeModelFilename("snapshots/abc123/model.safetensors"))
    }

    func testSafeModelFilenameRejectsEscapesAndControlCharacters() {
        XCTAssertFalse(ModelDownloadService.isSafeModelFilename(""))
        XCTAssertFalse(ModelDownloadService.isSafeModelFilename("/config.json"))
        XCTAssertFalse(ModelDownloadService.isSafeModelFilename("../secret"))
        XCTAssertFalse(ModelDownloadService.isSafeModelFilename("weights/../secret"))
        XCTAssertFalse(ModelDownloadService.isSafeModelFilename("weights/./config.json"))
        XCTAssertFalse(ModelDownloadService.isSafeModelFilename("config\n.json"))
    }

    func testSHA256HexStreamsFileContents() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ModelDownloadServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let fileURL = tempRoot.appendingPathComponent("fixture.bin")
        try Data("abc".utf8).write(to: fileURL)

        XCTAssertEqual(
            try ModelDownloadService.sha256Hex(of: fileURL),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testWithRetryDoesNotRetryDiskSpaceFailures() async {
        var attempts = 0

        do {
            _ = try await ModelDownloadService.withRetry(maxAttempts: 3) {
                attempts += 1
                throw NSError(domain: NSPOSIXErrorDomain, code: 28)
            } as String
            XCTFail("Expected disk space failure")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error.kind, .diskSpace)
            XCTAssertEqual(attempts, 1)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testWithRetryRejectsZeroAttemptsWithoutRunningOperation() async {
        var attempts = 0

        do {
            _ = try await ModelDownloadService.withRetry(maxAttempts: 0) {
                attempts += 1
                return "should-not-run"
            }
            XCTFail("Expected zero-attempt guard failure")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(
                error.kind,
                .unknown("No download was attempted (maxAttempts was 0)")
            )
            XCTAssertNil(error.underlyingError)
            XCTAssertEqual(attempts, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
