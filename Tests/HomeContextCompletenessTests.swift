import Foundation

func testHomeContextCompleteness() {
    runSuite("HomeContextCompleteness.make — weights combine into the headline fraction") {
        let empty = HomeContextCompleteness.make(
            activeDaysInLastWeek: 0,
            namedSpeakerCount: 0,
            totalSpeakerCount: 0,
            agentConnected: false
        )
        assertEqual(empty.totalFraction, 0, "no capture, no speakers, no agent should score zero")
        assertEqual(empty.percentText, "0%", "zero score should format as 0%")
        assertTrue(empty.segments.isEmpty, "zero score should render no arc segments")

        let full = HomeContextCompleteness.make(
            activeDaysInLastWeek: 7,
            namedSpeakerCount: 4,
            totalSpeakerCount: 4,
            agentConnected: true
        )
        assertEqual(full.percentText, "100%", "max components should score 100%")
        assertEqual(full.segments.count, 3, "full score should render all three segments")

        let summed = full.segments.reduce(0) { $0 + $1.fraction }
        assertTrue(
            abs(summed - full.totalFraction) < 0.0001,
            "segment fractions should sum to the total fraction"
        )
    }

    runSuite("HomeContextCompleteness.make — capture momentum saturates at the day target") {
        let partial = HomeContextCompleteness.make(
            activeDaysInLastWeek: 2,
            namedSpeakerCount: 0,
            totalSpeakerCount: 0,
            agentConnected: false
        )
        assertEqual(
            partial.captureScore,
            2.0 / Double(HomeContextCompleteness.fullCaptureDayTarget),
            "capture score should scale linearly below the target"
        )

        let saturated = HomeContextCompleteness.make(
            activeDaysInLastWeek: 7,
            namedSpeakerCount: 0,
            totalSpeakerCount: 0,
            agentConnected: false
        )
        assertEqual(saturated.captureScore, 1, "capture score should cap at 1 past the target")
    }

    runSuite("HomeContextCompleteness.make — speaker score is the named ratio") {
        let half = HomeContextCompleteness.make(
            activeDaysInLastWeek: 0,
            namedSpeakerCount: 3,
            totalSpeakerCount: 6,
            agentConnected: false
        )
        assertEqual(half.speakerScore, 0.5, "3 of 6 named speakers should score 0.5")

        let noSpeakers = HomeContextCompleteness.make(
            activeDaysInLastWeek: 0,
            namedSpeakerCount: 0,
            totalSpeakerCount: 0,
            agentConnected: false
        )
        assertEqual(noSpeakers.speakerScore, 0, "an empty speaker library should not award the segment")
    }

    runSuite("HomeContextCompleteness.activeDayCount — trailing 7-day window with deduped days") {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Denver")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 6, day: 10, hour: 15))!

        func day(_ dayOfMonth: Int, hour: Int = 9) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 6, day: dayOfMonth, hour: hour))!
        }

        assertEqual(
            HomeContextCompleteness.activeDayCount(dayDates: [], now: now, calendar: calendar),
            0,
            "no activity dates should count zero days"
        )

        assertEqual(
            HomeContextCompleteness.activeDayCount(
                dayDates: [day(10), day(10, hour: 20), day(8), day(4)],
                now: now,
                calendar: calendar
            ),
            3,
            "same-day entries should dedupe and the 7-day window should include day 4"
        )

        assertEqual(
            HomeContextCompleteness.activeDayCount(
                dayDates: [day(3), day(1)],
                now: now,
                calendar: calendar
            ),
            0,
            "activity older than the trailing window should not count"
        )
    }

    runSuite("HomeCanvasGreeting.text — time-of-day salutation with the first name") {
        assertEqual(HomeCanvasGreeting.text(hour: 8, firstName: "Redbars"), "Good morning, Redbars")
        assertEqual(HomeCanvasGreeting.text(hour: 13, firstName: "Redbars"), "Good afternoon, Redbars")
        assertEqual(HomeCanvasGreeting.text(hour: 20, firstName: "Redbars"), "Good evening, Redbars")
        assertEqual(HomeCanvasGreeting.text(hour: 2, firstName: "Redbars"), "Good evening, Redbars")
        assertEqual(HomeCanvasGreeting.text(hour: 9, firstName: "  "), "Good morning", "blank names should drop the comma")
    }
}
