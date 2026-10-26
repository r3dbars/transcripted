import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class ModelDownloadServiceTests: XCTestCase {
    func testClassifyErrorMapsOfflineURLErrors() {
        let errors: [URLError.Code] = [
            .notConnectedToInternet,
            .networkConnectionLost,
            .dataNotAllowed,
            .cannotFindHost,
            .cannotConnectToHost,
            .dnsLookupFailed
        ]

        for code in errors {
            XCTAssertEqual(ModelDownloadService.classifyError(URLError(code)), .networkOffline)
        }
        XCTAssertEqual(DownloadErrorKind.networkOffline.title, "No Internet Connection")
        XCTAssertEqual(DownloadErrorKind.networkOffline.detail, "Connect to the internet and try again.")
    }

    func testClassifyErrorMapsTLSAndTimeoutURLErrors() {
        XCTAssertEqual(
            ModelDownloadService.classifyError(URLError(.secureConnectionFailed)),
            .tlsFailure
        )
        XCTAssertEqual(
            ModelDownloadService.classifyError(URLError(.serverCertificateUntrusted)),
            .tlsFailure
        )
        XCTAssertEqual(
            ModelDownloadService.classifyError(URLError(.timedOut)),
            .timeout
        )
    }

    func testClassifyErrorMapsDiskSpaceBeforeGenericFallback() {
        XCTAssertEqual(
            ModelDownloadService.classifyError(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)),
            .diskSpace
        )
        XCTAssertEqual(
            ModelDownloadService.classifyError(NSError(domain: NSPOSIXErrorDomain, code: 28)),
            .diskSpace
        )
    }

    func testClassifyErrorPreservesUnknownLocalizedDescription() {
        let error = NSError(
            domain: "ModelDownloadServiceTests",
            code: 42,
            userInfo: [NSLocalizedDescriptionKey: "fixture download failed"]
        )

        XCTAssertEqual(
            ModelDownloadService.classifyError(error),
            .unknown("fixture download failed")
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
