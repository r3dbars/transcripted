import Foundation

func testTimelineQAContract() {
    let fixture = loadJSONFixture(
        "Tests/Fixtures/timeline-qa-contract-fixture.json",
        as: TimelineQAContractFixture.self
    )

    runSuite("Timeline QA contract - fake capture provider does not use real screen recording") {
        let provider = FixtureTimelineCaptureProvider(captures: fixture.captures)
        let captures = provider.drain()

        assertEqual(captures.count, 3, "fixture provider should expose the expected synthetic captures")
        assertTrue(captures.allSatisfy { !$0.screenRecordingWasUsed }, "fake provider must not depend on real ScreenCaptureKit or TCC")
        assertTrue(
            captures.allSatisfy { $0.relativeScreenshotPath.hasPrefix("recordings/screenshots/") },
            "timeline screenshot fixture paths should stay relative to the app-owned screenshots root"
        )
        assertFalse(
            captures.contains { $0.relativeScreenshotPath.hasPrefix("/") || $0.relativeScreenshotPath.contains("file://") },
            "timeline fixture paths must not carry absolute paths or file URLs"
        )
        assertTrue(
            captures.allSatisfy { $0.appName == "[redacted-source-app]" && $0.windowTitle == "[redacted-title]" },
            "screen-derived app/window metadata should be redacted in fixture and QA surfaces"
        )
    }

    runSuite("Timeline QA contract - fake DB fixture covers merged day rows") {
        let store = FixtureTimelineDatabase(cards: fixture.cards)
        let cards = store.cards(forDay: "2026-09-01")

        assertEqual(cards.map(\.kind), ["activity", "meeting", "idle", "dictation"], "fixture should cover activity, meeting, idle, and dictation timeline rows")
        assertEqual(cards.first?.category, "Work", "activity cards should keep normal category coverage")
        assertTrue(cards.contains { $0.category == "Meetings" && $0.captureID != nil }, "meeting/dictation projections should carry capture ids")
        assertFalse(cards.contains { $0.startTS >= $0.endTS }, "fixture cards should have positive durations")
        assertEqual(timelineOverlapCount(cards), 0, "fixture cards should not overlap inside one day")
    }

    runSuite("Timeline QA contract - privacy sweep names screen-derived leak classes") {
        let sweep = timelineQAReadRepoTextFile("scripts/ops/privacy-leak-sweep.py")
        for fragment in [
            "screen_derived_text",
            "window_title",
            "screenshot_path",
            "timeline-card.md",
            "timeline_day"
        ] {
            assertTrue(
                sweep.contains(fragment),
                "privacy leak sweep should cover timeline screen-derived fragment: \(fragment)"
            )
        }
    }

    runSuite("Timeline QA contract - test matrix and manual checklist route Phase 10 proof") {
        let matrix = timelineQAReadRepoTextFile(".agents/test-matrix.yml")
        assertTrue(matrix.contains("Sources/Timeline/**"), "test matrix should route engine timeline edits")
        assertTrue(matrix.contains("Sources/UI/Timeline/**"), "test matrix should route timeline UI edits")
        assertTrue(matrix.contains("TimelineQAContractTests.swift"), "test matrix should route timeline QA contract fixture edits")
        assertTrue(matrix.contains("privacy-leak-sweep.py --write-report"), "timeline QA edits should keep privacy sweep in the mapped checks")

        let checklist = timelineQAReadRepoTextFile("docs/qa/dayflow-timeline-manual-qa.md")
        for item in fixture.manualChecklist {
            assertTrue(checklist.contains(item), "manual QA checklist should include fixture-backed item: \(item)")
        }
        assertTrue(
            checklist.contains("Automated green is not real screen-recording proof."),
            "manual checklist should keep automated and real TCC proof separate"
        )
    }
}

private struct TimelineQAContractFixture: Decodable {
    let captures: [FixtureTimelineCapture]
    let cards: [FixtureTimelineCard]
    let manualChecklist: [String]

    enum CodingKeys: String, CodingKey {
        case captures
        case cards
        case manualChecklist = "manual_checklist"
    }
}

private struct FixtureTimelineCapture: Decodable {
    let id: String
    let capturedAt: Int
    let relativeScreenshotPath: String
    let appBundleID: String
    let appName: String
    let windowTitle: String
    let screenDerivedText: String
    let screenRecordingWasUsed: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case capturedAt = "captured_at"
        case relativeScreenshotPath = "relative_screenshot_path"
        case appBundleID = "app_bundle_id"
        case appName = "app_name"
        case windowTitle = "window_title"
        case screenDerivedText = "screen_derived_text"
        case screenRecordingWasUsed = "screen_recording_was_used"
    }
}

private struct FixtureTimelineCard: Decodable {
    let id: String
    let day: String
    let startTS: Int
    let endTS: Int
    let kind: String
    let captureID: String?
    let title: String
    let summary: String
    let category: String
    let screenshotIDs: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case day
        case startTS = "start_ts"
        case endTS = "end_ts"
        case kind
        case captureID = "capture_id"
        case title
        case summary
        case category
        case screenshotIDs = "screenshot_ids"
    }
}

private struct FixtureTimelineCaptureProvider {
    private var captures: [FixtureTimelineCapture]

    init(captures: [FixtureTimelineCapture]) {
        self.captures = captures
    }

    func drain() -> [FixtureTimelineCapture] {
        captures
    }
}

private struct FixtureTimelineDatabase {
    private let cards: [FixtureTimelineCard]

    init(cards: [FixtureTimelineCard]) {
        self.cards = cards
    }

    func cards(forDay day: String) -> [FixtureTimelineCard] {
        cards
            .filter { $0.day == day }
            .sorted { lhs, rhs in
                if lhs.startTS == rhs.startTS {
                    return lhs.id < rhs.id
                }
                return lhs.startTS < rhs.startTS
            }
    }
}

private func timelineOverlapCount(_ cards: [FixtureTimelineCard]) -> Int {
    let sorted = cards.sorted { $0.startTS < $1.startTS }
    var overlaps = 0
    for index in sorted.indices.dropFirst() {
        if sorted[index].startTS < sorted[sorted.index(before: index)].endTS {
            overlaps += 1
        }
    }
    return overlaps
}

private func timelineQAReadRepoTextFile(_ relativePath: String) -> String {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(relativePath)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}
