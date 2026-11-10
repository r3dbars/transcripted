import Foundation
import XCTest
@testable import TranscriptedCore

/// Exercises retry cancellation with synthetic operations only. No download or model is created.
final class ModelDownloadRetryCancellationTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] == "1" else {
            XCTFail("This fixture requires the file logger to be disabled before any retry call")
            throw RetryFixtureSafetyError.fileLoggerEnabled
        }
    }

    func testAlreadyCancelledTaskDoesNotInvokeOperation() async {
        let gate = RetryCancellationGate()
        let calls = RetryCallCounter()
        let task = Task {
            await gate.wait()
            return await observeRetry {
                calls.increment()
                return "unexpected operation"
            }
        }

        // The continuation gate cannot finish until cancellation has been requested.
        task.cancel()
        gate.open()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(calls.value, 0)
    }

    func testOperationCancellationEscapesWithoutWrappingOrRetry() async {
        let calls = RetryCallCounter()
        let outcome = await observeRetry {
            calls.increment()
            throw CancellationError()
        }

        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(calls.value, 1)
    }

    func testCancellationAfterTransientFailureDoesNotInvokeAnotherAttempt() async {
        let calls = RetryCallCounter()
        let task = Task {
            await observeRetry {
                calls.increment()
                // Cancel the actual retry task before handing it a retryable failure.
                // Its backoff must propagate cancellation, rather than swallow it.
                withUnsafeCurrentTask { $0?.cancel() }
                throw URLError(.timedOut)
            }
        }

        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(calls.value, 1)
    }

    func testImmediateSuccessReturnsValueWithoutRetry() async {
        let calls = RetryCallCounter()
        let outcome = await observeRetry {
            calls.increment()
            return "synthetic success"
        }

        XCTAssertEqual(outcome, .success("synthetic success"))
        XCTAssertEqual(calls.value, 1)
    }

    func testNonCancelledPermanentFailureRemainsClassifiedWithoutRetry() async {
        let calls = RetryCallCounter()
        let outcome = await observeRetry {
            calls.increment()
            throw NSError(domain: NSPOSIXErrorDomain, code: 28)
        }

        XCTAssertEqual(outcome, .diskSpaceFailure)
        XCTAssertEqual(calls.value, 1)
    }
}

private enum RetryFixtureSafetyError: Error {
    case fileLoggerEnabled
}

private enum RetryOutcome: Equatable, Sendable {
    case success(String)
    case cancelled
    case diskSpaceFailure
    case unexpectedFailure
}

private func observeRetry(
    operation: @escaping () async throws -> String
) async -> RetryOutcome {
    do {
        return .success(try await ModelDownloadService.withRetry(maxAttempts: 3, operation: operation))
    } catch is CancellationError {
        return .cancelled
    } catch let error as ModelDownloadError where error.kind == .diskSpace {
        return .diskSpaceFailure
    } catch {
        // No diagnostic error descriptions are printed by this fixture.
        return .unexpectedFailure
    }
}

private final class RetryCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// A cancellation-insensitive, one-shot gate: opening before waiter registration is safe.
private final class RetryCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation { waiter in
            lock.lock()
            if isOpen {
                lock.unlock()
                waiter.resume()
            } else {
                continuation = waiter
                lock.unlock()
            }
        }
    }

    func open() {
        lock.lock()
        isOpen = true
        let waiter = continuation
        continuation = nil
        lock.unlock()
        waiter?.resume()
    }
}
