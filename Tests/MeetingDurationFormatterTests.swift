import Foundation

func testMeetingDurationFormatter() {
    runSuite("MeetingDurationFormatter — formatDuration renders mm:ss") {
        assertEqual(MeetingDurationFormatter.formatDuration(0), "00:00", "zero clamps to 00:00")
        assertEqual(MeetingDurationFormatter.formatDuration(65), "01:05", "65s is 1:05")
        assertEqual(MeetingDurationFormatter.formatDuration(3661), "61:01", "minutes are not wrapped past 60")
    }

    runSuite("MeetingDurationFormatter — formatDuration clamps and truncates") {
        assertEqual(MeetingDurationFormatter.formatDuration(-10), "00:00", "negative durations clamp to zero")
        assertEqual(MeetingDurationFormatter.formatDuration(59), "00:59")
        assertEqual(MeetingDurationFormatter.formatDuration(60), "01:00")
        assertEqual(
            MeetingDurationFormatter.formatDuration(65.9), "01:05",
            "fractional seconds truncate toward zero, they do not round up"
        )
    }

    runSuite("MeetingDurationFormatter — formatInactiveDuration pluralizes minutes") {
        assertEqual(MeetingDurationFormatter.formatInactiveDuration(30), "1 minute", "30s rounds to one minute")
        assertEqual(MeetingDurationFormatter.formatInactiveDuration(90), "2 minutes", "90s rounds to two minutes")
    }

    runSuite("MeetingDurationFormatter — formatInactiveDuration has a one-minute floor") {
        assertEqual(MeetingDurationFormatter.formatInactiveDuration(0), "1 minute", "never reports zero minutes")
        assertEqual(MeetingDurationFormatter.formatInactiveDuration(5), "1 minute")
        assertEqual(
            MeetingDurationFormatter.formatInactiveDuration(150), "3 minutes",
            "150s rounds to three minutes"
        )
    }
}
