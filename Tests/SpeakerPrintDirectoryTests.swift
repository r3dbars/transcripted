import Foundation

/// Promises of Settings › Speakers' voice-print layout:
///   - someone Transcripted names on its own sits under "Named automatically"
///     with a full print and no hint;
///   - everyone else who has a name is "Still learning", one lit ring per
///     confirmed meeting, never a full print, with "One more yes" (in their
///     color only when one yes really turns auto-naming on) or "N more";
///   - unnamed voices get an empty print in their own section;
///   - sections come in page order, keep the incoming order, and skip empties;
///   - the line under a name reads "14 meetings · today" / "· Tuesday";
///   - "One more yes" in the person's color is readable text (4.5:1) on every
///     light and dark Settings surface, for all eight palette colors.
func testSpeakerPrintDirectory() {
    func standing(_ tier: SpeakerNamingTier, confirmed: Int, required: Int = 5, trusted: Bool = true) -> SpeakerNamingStanding {
        SpeakerNamingStanding(tier: tier, isTrusted: trusted, confirmedMeetings: confirmed, requiredMeetings: required)
    }
    typealias Directory = SpeakerPrintDirectory

    runSuite("A person named on their own gets a full print under Named automatically") {
        let row = Directory.row(standing: standing(.auto, confirmed: 14))
        assertEqual(row.section, .namedAutomatically)
        assertEqual(row.litRings, 5, "a full print is all five rings")
        assertNil(row.hint, "no hint once the print is full")
    }

    runSuite("Still learning lights one ring per confirmed meeting and says what's left") {
        let marcus = Directory.row(standing: standing(.learning, confirmed: 4))
        assertEqual(marcus.section, .stillLearning)
        assertEqual(marcus.litRings, 4)
        assertEqual(marcus.hint, Directory.Hint(text: "One more yes", usesPersonColor: true), "one left is the person-colored splash")

        let dana = Directory.row(standing: standing(.new, confirmed: 1))
        assertEqual(dana.section, .stillLearning, "New people are still learning too")
        assertEqual(dana.litRings, 1)
        assertEqual(dana.hint, Directory.Hint(text: "4 more", usesPersonColor: false))

        let fresh = Directory.row(standing: standing(.new, confirmed: 0))
        assertEqual(fresh.litRings, 0)
        assertEqual(fresh.hint?.text, "5 more")
    }

    runSuite("After a correction, a well-confirmed person is still learning and the hint makes no color promise") {
        let paused = Directory.row(standing: standing(.learning, confirmed: 9, trusted: false))
        assertEqual(paused.section, .stillLearning)
        assertEqual(paused.litRings, 4, "probation past the bar never draws a full print")
        assertEqual(paused.hint, Directory.Hint(text: "Keep confirming", usesPersonColor: false))

        let pausedOneShort = Directory.row(standing: standing(.learning, confirmed: 4, trusted: false))
        assertEqual(pausedOneShort.hint?.text, "Keep confirming", "probation does not promise one yes")
        assertEqual(pausedOneShort.hint?.usesPersonColor, false, "the health check may still hold auto-naming back")
    }

    runSuite("A voice with no name has an empty print and sits apart from named people") {
        let row = Directory.row(standing: nil)
        assertEqual(row.section, .notNamedYet)
        assertEqual(row.litRings, 0)
        assertNil(row.hint)
    }

    runSuite("Sections come in page order, keep the list's order, and leave out empty ones") {
        let standings: [String: SpeakerNamingStanding?] = [
            "Priya": standing(.auto, confirmed: 14),
            "Marcus": standing(.learning, confirmed: 4),
            "Sam": standing(.auto, confirmed: 9),
            "Unknown": nil,
            "Dana": standing(.new, confirmed: 1),
        ]
        let order = ["Marcus", "Unknown", "Priya", "Dana", "Sam"]
        let sections = Directory.sections(order) { standings[$0] ?? nil }
        assertEqual(sections.map(\.section), [.namedAutomatically, .stillLearning, .notNamedYet])
        assertEqual(sections.map(\.items), [["Priya", "Sam"], ["Marcus", "Dana"], ["Unknown"]])

        let onlyLearning = Directory.sections(["Marcus"]) { standings[$0] ?? nil }
        assertEqual(onlyLearning.map(\.section), [.stillLearning], "no empty Named automatically header")
        assertTrue(Directory.sections([String]()) { _ in nil }.isEmpty)
    }

    runSuite("The line under a name says meetings and the day they were last heard") {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Chicago")!
        let locale = Locale(identifier: "en_US")
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        let now = date(2026, 10, 8, 9) // a Thursday morning
        func line(_ meetings: Int, _ heard: Date) -> String {
            Directory.metaLine(meetings: meetings, lastHeard: heard, now: now, calendar: calendar, locale: locale)
        }
        assertEqual(line(14, date(2026, 10, 8, 1)), "14 meetings · today")
        assertEqual(line(1, date(2026, 10, 7, 23)), "1 meeting · yesterday")
        assertEqual(line(9, date(2026, 10, 6)), "9 meetings · Tuesday")
        assertEqual(line(3, date(2026, 10, 2)), "3 meetings · Friday", "six days back is still a weekday")
        assertEqual(line(2, date(2026, 10, 1)), "2 meetings · Oct 1", "a week back gets a date")
        assertEqual(line(4, date(2025, 12, 30)), "4 meetings · Dec 30, 2025", "another year names it")
        assertEqual(line(5, date(2026, 10, 9)), "5 meetings · today", "a clock ahead of us still reads today")
    }

    runSuite("One more yes in the person's color is readable text in light and dark Settings") {
        // The Settings window, white content, and a hovered row in each appearance.
        let light: [UInt32] = [0xFFFFFF, 0xECECEC, 0xE1E1E1]
        let dark: [UInt32] = [0x1E1E1E, 0x323232, 0x3B3B3B]
        let ink = SpeakerPrintTextInk.self
        assertEqual(ink.lightText.count, VoicePrintStyle.palette.count, "one text shade per palette color")
        for index in VoicePrintStyle.palette.indices {
            let name = VoicePrintStyle.palette[index].name
            for background in light {
                let ratio = ink.contrastRatio(ink.hint(colorIndex: index, dark: false), VoicePrintRGBA(hex: background))
                assertTrue(ratio >= 4.5, "\(name) on light \(String(background, radix: 16)) is \(ratio):1")
            }
            for background in dark {
                let ratio = ink.contrastRatio(ink.hint(colorIndex: index, dark: true), VoicePrintRGBA(hex: background))
                assertTrue(ratio >= 4.5, "\(name) on dark \(String(background, radix: 16)) is \(ratio):1")
            }
        }
        assertEqual(Set(ink.lightText).count, VoicePrintStyle.palette.count, "everyone keeps their own color")
        assertEqual((ink.contrastRatio(VoicePrintRGBA(hex: 0x000000), VoicePrintRGBA(hex: 0xFFFFFF)) * 10).rounded(), 210, "WCAG's black on white")
    }

    runSuite("Section titles and the page's header line read as designed") {
        assertEqual(Directory.title(.namedAutomatically, count: 2), "Named automatically · 2")
        assertEqual(Directory.title(.stillLearning, count: 7), "Still learning")
        assertEqual(Directory.title(.notNamedYet, count: 3), "Not named yet")
        assertEqual(
            Directory.headerLine,
            "Confirm a voice in 5 meetings and its print fills in. Then Transcripted names that person on its own. Voices stay on this Mac."
        )
    }
}
