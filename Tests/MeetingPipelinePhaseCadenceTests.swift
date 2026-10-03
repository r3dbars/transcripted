import Foundation

/// Promise: a transcribing `meeting_pipeline_phase` line is written when
/// transcribing starts and when raw pipeline progress enters a new quarter,
/// never on ordinary progress ticks.
func testMeetingPipelinePhaseCadence() {
    /// Feeds raw progress reports through the cadence the way the controller
    /// does (thinned to 0.1% steps, previous = last delivered value) and
    /// returns the quarters of the values that were recorded.
    func recordedQuarters(_ reports: [Double]) -> [Int] {
        var previous: Double?
        var lastDelivered: Double?
        var quarters: [Int] = []
        for value in reports {
            if let last = lastDelivered, abs(value - last) < 0.001, value < 1.0 { continue }
            lastDelivered = value
            if MeetingPipelinePhaseCadence.shouldRecord(previousTranscribingProgress: previous, progress: value) {
                quarters.append(MeetingPipelinePhaseCadence.quarter(of: value))
            }
            previous = value
        }
        return quarters
    }

    runSuite("MeetingPipelinePhaseCadence records each quarter once for a multichannel job") {
        var reports: [Double] = [0.0, 0.10, 0.30]
        reports += (1...4000).map { 0.30 + 0.35 * Double($0) / 4000 }
        reports += (1...4000).map { 0.65 + 0.25 * Double($0) / 4000 }
        reports += [0.95, 1.0]
        assertEqual(recordedQuarters(reports), [0, 1, 2, 3, 4], "multichannel progress should log one line per quarter")
    }

    runSuite("MeetingPipelinePhaseCadence records each quarter once for a mic-only or import job") {
        var reports: [Double] = [0.0]
        reports += (0...3000).map { 0.10 + 0.85 * Double($0) / 3000 }
        reports += [1.0]
        assertEqual(recordedQuarters(reports), [0, 1, 2, 3, 4], "mic-only progress should log one line per quarter")
    }

    runSuite("MeetingPipelinePhaseCadence always records on entering transcribing") {
        assertTrue(
            MeetingPipelinePhaseCadence.shouldRecord(previousTranscribingProgress: nil, progress: 0.6),
            "entering transcribing mid-range should record"
        )
    }

    runSuite("MeetingPipelinePhaseCadence stays quiet on ticks inside one quarter") {
        assertEqual(recordedQuarters([0.60, 0.61, 0.62]), [2], "ticks within a quarter should record only the first")
    }

    runSuite("MeetingPipelinePhaseCadence records a retry that goes backwards once") {
        assertTrue(
            MeetingPipelinePhaseCadence.shouldRecord(previousTranscribingProgress: 0.95, progress: 0.2),
            "progress dropping to an earlier quarter should record"
        )
        assertEqual(recordedQuarters([0.95, 0.2, 0.21, 0.22]), [3, 0], "a retry should record once, then stay quiet")
    }
}
