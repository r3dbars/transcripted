import XCTest
@testable import TranscriptedCore

/// Promise: thinning the pipeline's per-segment progress never changes what a
/// person sees. After every report, the last value let through shows the same
/// whole percent (menu bar and Notch island) as the report itself, stage marks
/// arrive exactly, and far fewer values reach the main actor.
final class TranscribingProgressGateTests: XCTestCase {

    private func shownPercent(_ progress: Double) -> Int {
        Int((DisplayStatus.transcribing(progress: progress).progress * 100).rounded(.down))
    }

    func testEveryReportLeavesTheSameShownPercentAndStageMarksArriveExactly() {
        let gate = TranscribingProgressGate()
        var reports: [Double] = [0.0, 0.10, 0.30]
        let segments = 4_000
        reports += (1...segments).map { 0.30 + 0.60 * Double($0) / Double(segments) }
        reports += [0.95, 1.0, 1.0]

        var lastDelivered: Double?
        var delivered: [Double] = []
        for report in reports {
            if gate.shouldDeliver(report) {
                lastDelivered = report
                delivered.append(report)
            }
            guard let shown = lastDelivered else { return XCTFail("first report must go through") }
            XCTAssertEqual(shownPercent(shown), shownPercent(report), "report \(report)")
            XCTAssertLessThan(abs(shown - report), 0.001, "report \(report)")
        }
        for mark in [0.0, 0.10, 0.30, 0.95, 1.0] {
            XCTAssertTrue(delivered.contains(mark), "stage mark \(mark)")
        }
        XCTAssertEqual(delivered.filter { $0 == 1.0 }.count, 1, "a repeat of the same value adds nothing")
        XCTAssertLessThan(delivered.count, reports.count / 5)
    }

    func testProgressGoingBackIsLetThrough() {
        let gate = TranscribingProgressGate()
        XCTAssertTrue(gate.shouldDeliver(0.5))
        XCTAssertTrue(gate.shouldDeliver(0.2))
        XCTAssertFalse(gate.shouldDeliver(0.2001))
    }
}
