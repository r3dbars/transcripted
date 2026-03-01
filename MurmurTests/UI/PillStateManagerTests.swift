import XCTest
@testable import Transcripted

@available(macOS 26.0, *)
@MainActor
final class PillStateManagerTests: XCTestCase {

    private var manager: PillStateManager!

    override func setUp() {
        super.setUp()
        manager = PillStateManager(transitionCooldown: 0)
    }

    // MARK: - Initial state

    func testInitialStateIsIdle() {
        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(manager.isLocked)
        XCTAssertFalse(manager.isTransitioning)
    }

    // MARK: - Dimensions per state

    func testIdleDimensions() {
        XCTAssertEqual(manager.pillWidth, PillDimensions.idleWidth)
        XCTAssertEqual(manager.pillHeight, PillDimensions.idleHeight)
    }

    func testRecordingDimensions() {
        manager.transition(to: .recording)
        XCTAssertEqual(manager.pillWidth, PillDimensions.recordingWidth)
        XCTAssertEqual(manager.pillHeight, PillDimensions.recordingHeight)
    }

    func testProcessingDimensions() {
        manager.transition(to: .processing)
        XCTAssertEqual(manager.pillWidth, PillDimensions.recordingWidth)
        XCTAssertEqual(manager.pillHeight, PillDimensions.recordingHeight)
    }

    func testReviewingDimensions() {
        manager.transition(to: .reviewing)
        XCTAssertEqual(manager.pillWidth, PillDimensions.trayWidth)
        XCTAssertEqual(manager.pillHeight, PillDimensions.recordingHeight)
    }

    // MARK: - Transition guards

    func testSameStateTransitionIsNoOp() {
        manager.transition(to: .idle)
        // Should still be idle, no transition flag set
        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(manager.isTransitioning)
    }

    func testLockedBlocksTransition() {
        manager.transition(to: .recording)
        manager.lock()
        manager.transition(to: .processing)
        // Should still be recording since locked
        XCTAssertEqual(manager.state, .recording)
    }

    func testLockedAllowsIdleTransition() {
        manager.transition(to: .recording)
        manager.lock()
        manager.transition(to: .idle)
        // Emergency escape to idle should work even when locked
        XCTAssertEqual(manager.state, .idle)
    }

    // MARK: - Lock / Unlock

    func testLockSetsFlag() {
        manager.lock()
        XCTAssertTrue(manager.isLocked)
    }

    func testUnlockClearsFlag() {
        manager.lock()
        manager.unlock(transitionToIdle: false)
        XCTAssertFalse(manager.isLocked)
    }

    func testUnlockTransitionsToIdleByDefault() {
        manager.transition(to: .recording)
        manager.lock()
        manager.unlock()
        XCTAssertEqual(manager.state, .idle)
    }

    // MARK: - Force unlock

    func testForceUnlockResetsAllFlags() {
        manager.transition(to: .recording)
        manager.lock()
        manager.forceUnlock()

        XCTAssertEqual(manager.state, .idle)
        XCTAssertFalse(manager.isLocked)
        XCTAssertFalse(manager.isTransitioning)
    }

    // MARK: - Window height

    func testReviewingWindowHeightIncludesTray() {
        manager.transition(to: .reviewing)
        let expectedHeight = PillDimensions.recordingHeight + PillDimensions.trayMaxHeight
        XCTAssertEqual(manager.windowHeight, expectedHeight)
    }
}
