import XCTest
@testable import Transcripted

final class RecordingValidatorTests: XCTestCase {

    // MARK: - ValidationResult.isValid

    func testSuccessIsValid() {
        let result = RecordingValidator.ValidationResult.success
        XCTAssertTrue(result.isValid)
    }

    func testFailureIsNotValid() {
        let result = RecordingValidator.ValidationResult.failure("disk full")
        XCTAssertFalse(result.isValid)
    }

    // MARK: - ValidationResult.errorMessage

    func testSuccessHasNoErrorMessage() {
        let result = RecordingValidator.ValidationResult.success
        XCTAssertNil(result.errorMessage)
    }

    func testFailureHasErrorMessage() {
        let result = RecordingValidator.ValidationResult.failure("No microphone found")
        XCTAssertEqual(result.errorMessage, "No microphone found")
    }

    func testFailurePreservesExactMessage() {
        let message = "Insufficient disk space: Only 50MB available. Please free up space and try again."
        let result = RecordingValidator.ValidationResult.failure(message)
        XCTAssertEqual(result.errorMessage, message)
    }

    // MARK: - MinimumDiskSpace constant

    func testMinimumDiskSpaceIs100MB() {
        XCTAssertEqual(RecordingValidator.minimumDiskSpace, 100 * 1024 * 1024)
    }
}
