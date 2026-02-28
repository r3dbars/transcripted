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

    func testFindingActionItemsProgress() {
        XCTAssertEqual(DisplayStatus.findingActionItems.progress, 0.85)
    }

    func testFinishingProgress() {
        XCTAssertEqual(DisplayStatus.finishing.progress, 0.97)
    }

    func testTranscriptSavedProgress() {
        XCTAssertEqual(DisplayStatus.transcriptSaved.progress, 1.0)
    }

    func testPendingReviewProgress() {
        XCTAssertEqual(DisplayStatus.pendingReview(itemCount: 3).progress, 1.0)
    }

    func testCompletedProgress() {
        XCTAssertEqual(DisplayStatus.completed(taskCount: 5).progress, 1.0)
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

    func testFindingActionItemsStatusText() {
        XCTAssertEqual(DisplayStatus.findingActionItems.statusText, "Finding tasks...")
    }

    func testFinishingStatusText() {
        XCTAssertEqual(DisplayStatus.finishing.statusText, "Almost done...")
    }

    func testPendingReviewSingular() {
        XCTAssertEqual(DisplayStatus.pendingReview(itemCount: 1).statusText, "1 item to review")
    }

    func testPendingReviewPlural() {
        XCTAssertEqual(DisplayStatus.pendingReview(itemCount: 3).statusText, "3 items to review")
    }

    func testCompletedSingular() {
        XCTAssertEqual(DisplayStatus.completed(taskCount: 1).statusText, "1 task added")
    }

    func testCompletedPlural() {
        XCTAssertEqual(DisplayStatus.completed(taskCount: 5).statusText, "5 tasks added")
    }

    func testFailedStatusText() {
        XCTAssertEqual(DisplayStatus.failed(message: "Network error").statusText, "Network error")
    }

    // MARK: - isProcessing

    func testIsProcessingForProcessingStates() {
        XCTAssertTrue(DisplayStatus.gettingReady.isProcessing)
        XCTAssertTrue(DisplayStatus.transcribing(progress: 0.5).isProcessing)
        XCTAssertTrue(DisplayStatus.findingActionItems.isProcessing)
        XCTAssertTrue(DisplayStatus.finishing.isProcessing)
    }

    func testIsProcessingFalseForCompletionStates() {
        XCTAssertFalse(DisplayStatus.idle.isProcessing)
        XCTAssertFalse(DisplayStatus.transcriptSaved.isProcessing)
        XCTAssertFalse(DisplayStatus.pendingReview(itemCount: 2).isProcessing)
        XCTAssertFalse(DisplayStatus.completed(taskCount: 1).isProcessing)
        XCTAssertFalse(DisplayStatus.failed(message: "Error").isProcessing)
    }
}
