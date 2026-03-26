import XCTest
@testable import Transcripted

final class PillDimensionsTests: XCTestCase {

    // MARK: - Idle State

    func testIdleWidth() {
        XCTAssertEqual(PillDimensions.idleWidth, 40)
    }

    func testIdleHeight() {
        XCTAssertEqual(PillDimensions.idleHeight, 20)
    }

    func testIdleExpandedWidth() {
        XCTAssertEqual(PillDimensions.idleExpandedWidth, 120)
    }

    func testIdleExpandedHeight() {
        XCTAssertEqual(PillDimensions.idleExpandedHeight, 28)
    }

    // MARK: - Recording State

    func testRecordingWidth() {
        XCTAssertEqual(PillDimensions.recordingWidth, 160)
    }

    func testRecordingHeight() {
        XCTAssertEqual(PillDimensions.recordingHeight, 36)
    }

    // MARK: - Saved State

    func testSavedWidth() {
        XCTAssertEqual(PillDimensions.savedWidth, 260)
    }

    func testSavedHeight() {
        XCTAssertEqual(PillDimensions.savedHeight, 56)
    }

    // MARK: - Tray

    func testTrayWidth() {
        XCTAssertEqual(PillDimensions.trayWidth, 280)
    }

    func testTrayMaxHeight() {
        XCTAssertEqual(PillDimensions.trayMaxHeight, 300)
    }

    // MARK: - Dock Padding

    func testDockPadding() {
        XCTAssertEqual(PillDimensions.dockPadding, 8)
    }

    // MARK: - Relationships

    func testRecordingLargerThanIdle() {
        XCTAssertGreaterThan(PillDimensions.recordingWidth, PillDimensions.idleWidth)
        XCTAssertGreaterThan(PillDimensions.recordingHeight, PillDimensions.idleHeight)
    }

    func testSavedLargerThanRecording() {
        XCTAssertGreaterThan(PillDimensions.savedWidth, PillDimensions.recordingWidth)
        XCTAssertGreaterThan(PillDimensions.savedHeight, PillDimensions.recordingHeight)
    }

    func testExpandedLargerThanCollapsed() {
        XCTAssertGreaterThan(PillDimensions.idleExpandedWidth, PillDimensions.idleWidth)
        XCTAssertGreaterThan(PillDimensions.idleExpandedHeight, PillDimensions.idleHeight)
    }

    // MARK: - Animation Timing

    func testMorphDuration() {
        XCTAssertEqual(PillAnimationTiming.morphDuration, 0.175, accuracy: 0.001)
    }

    func testCooldownDuration() {
        XCTAssertEqual(PillAnimationTiming.cooldownDuration, 0.175, accuracy: 0.001)
    }

    func testContentFadeDuration() {
        XCTAssertEqual(PillAnimationTiming.contentFade, 0.1, accuracy: 0.001)
    }

    func testToastDuration() {
        XCTAssertEqual(PillAnimationTiming.toastDuration, 8.0, accuracy: 0.1)
    }

    func testTrayDuration() {
        XCTAssertEqual(PillAnimationTiming.trayDuration, 0.2, accuracy: 0.01)
    }
}
