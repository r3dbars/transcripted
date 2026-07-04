import Foundation

func testTimelineHomePresentation() {
    runSuite("TimelineHomePreviewFlag stays off by default and honors explicit debug env") {
        let defaults = UserDefaults(suiteName: "TimelineHomePreviewFlagTests")!
        defaults.removePersistentDomain(forName: "TimelineHomePreviewFlagTests")

        assertFalse(
            TimelineHomePreviewFlag.isEnabled(userDefaults: defaults, environment: [:]),
            "Timeline Home preview should not replace Home by default"
        )
        assertTrue(
            TimelineHomePreviewFlag.isEnabled(
                userDefaults: defaults,
                environment: [TimelineHomePreviewFlag.environmentKey: "1"]
            ),
            "Timeline Home preview should be available through the debug environment flag"
        )

        defaults.set(true, forKey: TimelineHomePreviewFlag.userDefaultsKey)
        assertTrue(
            TimelineHomePreviewFlag.isEnabled(userDefaults: defaults, environment: [:]),
            "Timeline Home preview should support an explicit user defaults override"
        )
    }

    runSuite("TimelineHomeSampleData is ordered and includes Transcripted artifact cards") {
        let fixedNow = Date(timeIntervalSince1970: 1_783_036_800)
        let cards = TimelineHomeSampleData.cards(now: fixedNow)

        assertTrue(cards.count >= 5, "Sample timeline should have enough density to exercise the home canvas")
        assertEqual(cards.map(\.start), cards.map(\.start).sorted(), "Sample cards should be sorted by start time")
        assertTrue(cards.contains { $0.kind == .meeting }, "Sample timeline should include a meeting card")
        assertTrue(cards.contains { $0.kind == .dictation }, "Sample timeline should include a dictation card")
        assertTrue(cards.allSatisfy { $0.durationMinutes >= 1 }, "Every sample card should have a visible duration")
    }

    runSuite("TimelineCanvasLayout pins the 4 AM day and 60 px/hour scale") {
        let calendar = Calendar(identifier: .gregorian)
        let day = Date(timeIntervalSince1970: 1_783_036_800)
        let layout = TimelineCanvasLayout(day: day, calendar: calendar)

        assertEqual(Int(layout.height), 1_440, "24 hours at 60 px/hour should produce the planned canvas height")
        assertEqual(Int(layout.yOffset(for: layout.dayStart)), 0, "Day start should map to the top of the canvas")
        assertEqual(Int(layout.yOffset(for: layout.dayStart.addingTimeInterval(3_600))), 60, "One hour should map to 60 px")

        let tinyCard = TimelineCardPresentation(
            id: "tiny",
            kind: .dictation,
            category: .meetings,
            start: layout.dayStart,
            end: layout.dayStart.addingTimeInterval(60),
            title: "Tiny",
            summary: "Short dictation",
            detail: "Short dictation",
            appSites: [],
            decisions: []
        )
        assertEqual(Int(layout.height(for: tinyCard)), 18, "Tiny cards should still meet the minimum tap/visibility height")
    }
}
