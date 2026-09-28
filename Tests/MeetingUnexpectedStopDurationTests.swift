import Foundation

func testMeetingUnexpectedStopDuration() {
    let startedAt = Date(timeIntervalSince1970: 1_000_000)

    runSuite("MeetingCaptureHealthTelemetry — unexpected stop uses wall clock when the mirror reset") {
        let seconds = MeetingCaptureHealthTelemetry.unexpectedStopDurationSeconds(
            mirroredDuration: 0,
            recordingStartedAt: startedAt,
            now: startedAt.addingTimeInterval(45 * 60)
        )
        assertEqual(seconds, 45 * 60, "a 45-minute meeting whose timer already reset reports 45 minutes")
        assertEqual(
            AnalyticsReporter.durationBucket(seconds: seconds), "30m_plus",
            "the bucket follows the wall-clock length, not the reset mirror (was lt_10s)"
        )
    }

    runSuite("MeetingCaptureHealthTelemetry — unexpected stop keeps a larger mirrored duration") {
        assertEqual(
            MeetingCaptureHealthTelemetry.unexpectedStopDurationSeconds(
                mirroredDuration: 120,
                recordingStartedAt: startedAt,
                now: startedAt.addingTimeInterval(90)
            ),
            120,
            "the mirror wins when it is still populated and longer"
        )
        assertEqual(
            MeetingCaptureHealthTelemetry.unexpectedStopDurationSeconds(
                mirroredDuration: 30,
                recordingStartedAt: startedAt,
                now: startedAt.addingTimeInterval(-5)
            ),
            30,
            "a clock that moved backwards never shrinks the duration below the mirror"
        )
    }

    runSuite("MeetingCaptureHealthTelemetry — unexpected stop without a start time falls back to the mirror") {
        assertEqual(
            MeetingCaptureHealthTelemetry.unexpectedStopDurationSeconds(
                mirroredDuration: 0,
                recordingStartedAt: nil,
                now: startedAt
            ),
            0
        )
        assertEqual(
            MeetingCaptureHealthTelemetry.unexpectedStopDurationSeconds(
                mirroredDuration: 12,
                recordingStartedAt: nil,
                now: startedAt
            ),
            12
        )
    }
}
