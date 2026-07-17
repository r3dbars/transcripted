import XCTest
@testable import TranscriptedCore

final class SCKAudioCaptureRecoveryTests: XCTestCase {
    func testStopBeforeQueuedRecoveryPreventsEveryPhase() throws {
        let gate = SCKRecoverySessionGate()
        let token = gate.beginSession()
        gate.invalidate()
        var phases: [String] = []

        XCTAssertThrowsError(try gate.runPhase(token: token) { phases.append("stop") })
        XCTAssertEqual(phases, [], "An official stop must cancel recovery before its first queued action.")
    }

    func testStopDuringRecoveryStopPreventsPrepareAndStart() throws {
        let gate = SCKRecoverySessionGate()
        let token = gate.beginSession()
        var phases: [String] = []

        XCTAssertThrowsError(
            try gate.runPhase(token: token) {
                phases.append("stop")
                gate.invalidate()
            }
        )
        XCTAssertThrowsError(try gate.runPhase(token: token) { phases.append("prepare") })
        XCTAssertThrowsError(try gate.runPhase(token: token) { phases.append("start") })
        XCTAssertEqual(phases, ["stop"], "Stop invalidation must prevent recovery from preparing or restarting SCK.")
    }

    func testStopDuringRecoveryPreparePreventsStart() throws {
        let gate = SCKRecoverySessionGate()
        let token = gate.beginSession()
        var phases: [String] = []

        try gate.runPhase(token: token) { phases.append("stop") }
        XCTAssertThrowsError(
            try gate.runPhase(token: token) {
                phases.append("prepare")
                gate.invalidate()
            }
        )
        XCTAssertThrowsError(try gate.runPhase(token: token) { phases.append("start") })
        XCTAssertEqual(phases, ["stop", "prepare"], "A stop racing prepare must prevent the later SCK start.")
    }

    func testStopDuringRecoveryStartPreventsSuccess() throws {
        let gate = SCKRecoverySessionGate()
        let token = gate.beginSession()
        var reportedRecovered = false

        XCTAssertThrowsError(
            try gate.runPhase(token: token) {
                gate.invalidate()
            }
        )
        if (try? gate.check(token)) != nil {
            reportedRecovered = true
        }

        XCTAssertFalse(reportedRecovered, "A stop racing start must keep recovery from reporting capture restarted.")
    }
}
