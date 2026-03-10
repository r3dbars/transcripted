import XCTest
@testable import Transcripted

final class FailedTranscriptionTests: XCTestCase {

    // MARK: - shortErrorMessage

    func testShortErrorMessageUnderLimit() {
        let ft = makeFailedTranscription(errorMessage: "Model not loaded")
        XCTAssertEqual(ft.shortErrorMessage, "Model not loaded")
    }

    func testShortErrorMessageAtLimit() {
        let message = String(repeating: "x", count: 100)
        let ft = makeFailedTranscription(errorMessage: message)
        XCTAssertEqual(ft.shortErrorMessage, message)
    }

    func testShortErrorMessageOverLimit() {
        let message = String(repeating: "x", count: 150)
        let ft = makeFailedTranscription(errorMessage: message)
        XCTAssertEqual(ft.shortErrorMessage.count, 100)
        XCTAssertTrue(ft.shortErrorMessage.hasSuffix("..."))
    }

    // MARK: - isRetryable: Permanent errors

    func testIsRetryableEmptyAudioFile() {
        let ft = makeFailedTranscription(errorMessage: "Empty audio file — no samples recorded.")
        XCTAssertFalse(ft.isRetryable)
    }

    func testIsRetryableRecordingTooShort() {
        let ft = makeFailedTranscription(errorMessage: "Recording too short (1.0s). At least 2 seconds required.")
        XCTAssertFalse(ft.isRetryable)
    }

    func testIsRetryableInvalidAudioFormat() {
        let ft = makeFailedTranscription(errorMessage: "Invalid audio format: bad codec")
        XCTAssertFalse(ft.isRetryable)
    }

    func testIsRetryableMissingSystemAudio() {
        let ft = makeFailedTranscription(errorMessage: "System audio is required. Please grant Screen Recording permission.")
        XCTAssertFalse(ft.isRetryable)
    }

    // MARK: - isRetryable: Transient errors

    func testIsRetryableModelNotLoaded() {
        let ft = makeFailedTranscription(errorMessage: "Parakeet model not loaded")
        XCTAssertTrue(ft.isRetryable)
    }

    func testIsRetryableUnknownError() {
        let ft = makeFailedTranscription(errorMessage: "Something unexpected happened")
        XCTAssertTrue(ft.isRetryable)
    }

    func testIsRetryableSaveFailed() {
        let ft = makeFailedTranscription(errorMessage: "Failed to save transcript: disk full")
        XCTAssertTrue(ft.isRetryable)
    }

    // MARK: - formattedTimestamp

    func testFormattedTimestampNotEmpty() {
        let ft = makeFailedTranscription(errorMessage: "test")
        XCTAssertFalse(ft.formattedTimestamp.isEmpty)
    }

    // MARK: - Helpers

    private func makeFailedTranscription(errorMessage: String) -> FailedTranscription {
        FailedTranscription(
            micAudioURL: URL(fileURLWithPath: "/tmp/test_mic.wav"),
            systemAudioURL: URL(fileURLWithPath: "/tmp/test_system.wav"),
            errorMessage: errorMessage
        )
    }
}
