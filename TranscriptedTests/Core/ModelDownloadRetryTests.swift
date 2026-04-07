import XCTest
@testable import Transcripted
@testable import TranscriptedCore

final class ModelDownloadRetryTests: XCTestCase {

    // MARK: - Success on First Attempt

    func testSuccessOnFirstAttempt() async throws {
        let result = try await ModelDownloadService.withRetry(maxAttempts: 1) {
            return 42
        }
        XCTAssertEqual(result, 42)
    }

    // MARK: - Disk Space Error Is Not Retried

    func testDiskSpaceErrorThrowsImmediatelyWithoutRetry() async {
        var callCount = 0
        do {
            let _: Int = try await ModelDownloadService.withRetry(maxAttempts: 3) {
                callCount += 1
                // NSCocoaErrorDomain + NSFileWriteOutOfSpaceError classifies as .diskSpace
                throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
            }
            XCTFail("Should have thrown for disk space error")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(error.kind, .diskSpace, "Error should be classified as disk space")
            XCTAssertEqual(callCount, 1, "Disk space error should not be retried — operation should be called exactly once")
        } catch {
            XCTFail("Expected ModelDownloadError, got \(type(of: error))")
        }
    }

    // MARK: - Success on Second Attempt (Retry Happened)

    // Note: This test takes ~2s because the retry delay is hardcoded at 2s
    // (ModelDownloadService.retryDelays[0]). The delay is not injectable, so we
    // accept the slower test rather than adding test-only hooks to production code.
    func testSuccessOnSecondAttempt() async throws {
        var callCount = 0
        let result = try await ModelDownloadService.withRetry(maxAttempts: 2) {
            callCount += 1
            if callCount == 1 {
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            }
            return "recovered"
        }
        XCTAssertEqual(result, "recovered")
        XCTAssertEqual(callCount, 2, "Operation should have been called twice")
    }

    // MARK: - maxAttempts=1 with Always-Failing Operation

    func testSingleAttemptFailsImmediately() async {
        do {
            _ = try await ModelDownloadService.withRetry(maxAttempts: 1) {
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            }
            XCTFail("Should have thrown")
        } catch let error as ModelDownloadError {
            // After exhausting the single attempt, we get a ModelDownloadError
            XCTAssertNotNil(error.underlyingError)
        } catch {
            XCTFail("Expected ModelDownloadError, got \(type(of: error))")
        }
    }

    // MARK: - maxAttempts=0 — No Download Attempted

    func testZeroAttemptsThrowsNoDownloadAttempted() async {
        do {
            let _: Int = try await ModelDownloadService.withRetry(maxAttempts: 0) {
                XCTFail("Operation should never be called when maxAttempts is 0")
                return 0
            }
            XCTFail("Should have thrown")
        } catch let error as ModelDownloadError {
            XCTAssertNil(error.underlyingError, "No underlying error when no attempt was made")
            XCTAssertTrue(
                error.errorDescription?.contains("No download was attempted") == true,
                "Error should mention no download was attempted, got: \(error.errorDescription ?? "nil")"
            )
        } catch {
            XCTFail("Expected ModelDownloadError, got \(type(of: error))")
        }
    }

    // MARK: - All Retries Exhausted

    func testAllRetriesExhausted() async {
        var callCount = 0
        do {
            let _: Int = try await ModelDownloadService.withRetry(maxAttempts: 2) {
                callCount += 1
                throw NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
            }
            XCTFail("Should have thrown after exhausting retries")
        } catch let error as ModelDownloadError {
            XCTAssertEqual(callCount, 2, "Should have attempted exactly 2 times")
            XCTAssertNotNil(error.underlyingError, "Should preserve the last underlying error")
        } catch {
            XCTFail("Expected ModelDownloadError, got \(type(of: error))")
        }
    }
}
