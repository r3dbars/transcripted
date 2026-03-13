import XCTest
@testable import Transcripted

final class DisplayStatusTests: XCTestCase {

    // MARK: - Progress values

    func testIdleProgress() {
        XCTAssertEqual(DisplayStatus.idle.progress, 0.0)
    }

    func testGettingReadyProgress() {
        XCTAssertEqual(DisplayStatus.gettingReady.progress, 0.10)
    }

    func testTranscribingZeroProgress() {
        XCTAssertEqual(DisplayStatus.transcribing(progress: 0.0).progress, 0.15, accuracy: 0.001)
    }

    func testTranscribingHalfProgress() {
        // 0.15 + (0.5 * 0.60) = 0.15 + 0.30 = 0.45
        XCTAssertEqual(DisplayStatus.transcribing(progress: 0.5).progress, 0.45, accuracy: 0.001)
    }

    func testTranscribingFullProgress() {
        // 0.15 + (1.0 * 0.60) = 0.75
        XCTAssertEqual(DisplayStatus.transcribing(progress: 1.0).progress, 0.75, accuracy: 0.001)
    }

    func testFinishingProgress() {
        XCTAssertEqual(DisplayStatus.finishing.progress, 0.97)
    }

    func testTranscriptSavedProgress() {
        XCTAssertEqual(DisplayStatus.transcriptSaved.progress, 1.0)
    }

    func testFailedProgress() {
        XCTAssertEqual(DisplayStatus.failed(message: "Error").progress, 0.0)
    }

    // MARK: - Status text

    func testIdleStatusText() {
        XCTAssertEqual(DisplayStatus.idle.statusText, "Ready")
    }

    func testGettingReadyStatusText() {
        XCTAssertEqual(DisplayStatus.gettingReady.statusText, "Preparing...")
    }

    func testTranscribingStatusText() {
        XCTAssertEqual(DisplayStatus.transcribing(progress: 0.5).statusText, "Transcribing...")
    }

    func testFinishingStatusText() {
        XCTAssertEqual(DisplayStatus.finishing.statusText, "Almost done...")
    }

    func testFailedStatusText() {
        XCTAssertEqual(DisplayStatus.failed(message: "Network error").statusText, "Network error")
    }

    // MARK: - isProcessing

    func testIsProcessingForProcessingStates() {
        XCTAssertTrue(DisplayStatus.gettingReady.isProcessing)
        XCTAssertTrue(DisplayStatus.transcribing(progress: 0.5).isProcessing)
        XCTAssertTrue(DisplayStatus.finishing.isProcessing)
    }

    func testIsProcessingFalseForCompletionStates() {
        XCTAssertFalse(DisplayStatus.idle.isProcessing)
        XCTAssertFalse(DisplayStatus.transcriptSaved.isProcessing)
        XCTAssertFalse(DisplayStatus.failed(message: "Error").isProcessing)
    }
}
