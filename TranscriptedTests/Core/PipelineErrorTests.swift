import XCTest
@testable import Transcripted

final class PipelineErrorTests: XCTestCase {

    // MARK: - isRetryable: Permanent errors

    func testEmptyAudioFileNotRetryable() {
        XCTAssertFalse(PipelineError.emptyAudioFile.isRetryable)
    }

    func testRecordingTooShortNotRetryable() {
        XCTAssertFalse(PipelineError.recordingTooShort(duration: 0.5).isRetryable)
    }

    func testInvalidAudioFormatNotRetryable() {
        XCTAssertFalse(PipelineError.invalidAudioFormat(detail: "bad format").isRetryable)
    }

    func testMissingSystemAudioNotRetryable() {
        XCTAssertFalse(PipelineError.missingSystemAudio.isRetryable)
    }

    // MARK: - isRetryable: Transient errors

    func testModelNotLoadedIsRetryable() {
        XCTAssertTrue(PipelineError.modelNotLoaded(model: "Parakeet").isRetryable)
    }

    func testModelInferenceFailedIsRetryable() {
        XCTAssertTrue(PipelineError.modelInferenceFailed(model: "Qwen", underlying: "OOM").isRetryable)
    }

    func testSaveFailedIsRetryable() {
        XCTAssertTrue(PipelineError.saveFailed(detail: "disk full").isRetryable)
    }

    func testUnknownErrorIsRetryable() {
        XCTAssertTrue(PipelineError.unknown(underlying: "something broke").isRetryable)
    }

    // MARK: - errorDescription

    func testAllCasesHaveDescription() {
        let cases: [PipelineError] = [
            .emptyAudioFile,
            .recordingTooShort(duration: 1.0),
            .invalidAudioFormat(detail: "test"),
            .missingSystemAudio,
            .modelNotLoaded(model: "Parakeet"),
            .modelInferenceFailed(model: "Qwen", underlying: "err"),
            .saveFailed(detail: "test"),
            .unknown(underlying: "test"),
        ]

        for error in cases {
            XCTAssertNotNil(error.errorDescription, "Missing description for \(error)")
            XCTAssertFalse(error.errorDescription!.isEmpty, "Empty description for \(error)")
        }
    }

    func testRecordingTooShortIncludesDuration() {
        let error = PipelineError.recordingTooShort(duration: 1.5)
        XCTAssertTrue(error.errorDescription!.contains("1.5"))
    }

    func testModelNotLoadedIncludesModelName() {
        let error = PipelineError.modelNotLoaded(model: "Parakeet")
        XCTAssertTrue(error.errorDescription!.contains("Parakeet"))
    }
}
