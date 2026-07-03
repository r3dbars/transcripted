import MCP
import XCTest
@testable import transcripted_mcp

final class ToolHandlersTests: XCTestCase {
    var index: TranscriptIndex!
    var tempDir: URL!
    private var telemetry: RecordingAgentCaptureQueryTelemetry!

    override func setUp() {
        super.setUp()
        tempDir = makeTempDir()
        index = try! TranscriptIndex(indexDir: tempDir)
        telemetry = RecordingAgentCaptureQueryTelemetry()
        AgentCaptureQueryTelemetryRuntime.recorder = telemetry
    }

    override func tearDown() {
        AgentCaptureQueryTelemetryRuntime.recorder = AgentCaptureQueryTelemetry.shared
        telemetry = nil
        index = nil
        removeTempDir(tempDir)
        super.tearDown()
    }

    func testHydrateMeetingSearchTitlesUsesFrontmatterTitle() throws {
        try writeFixture(
            makeFixtureJSON(title: "Roadmap Sync", date: "2026-03-26T16:04:11-0500"),
            filename: "Call_2026-03-26_16-04-11",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        var results = try index.searchUtterances(query: "roadmap", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(results.results.count, 1)
        // Before hydration the index reports the filename-derived title.
        XCTAssertEqual(results.results[0].meetingTitle, "2026:03:26 16:04:11")

        hydrateMeetingSearchTitles(in: &results, meetingDirs: [tempDir])

        XCTAssertEqual(results.results[0].meetingTitle, "Roadmap Sync")
    }

    func testHydrateMeetingSearchTitlesKeepsFilenameDerivedTitleWithoutFrontmatterTitle() throws {
        try writeFixture(
            makeFixtureJSON(date: "2026-03-26T16:04:11-0500"),
            filename: "Call_2026-03-26_16-04-11",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        var results = try index.searchUtterances(query: "roadmap", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(results.results.count, 1)

        hydrateMeetingSearchTitles(in: &results, meetingDirs: [tempDir])

        XCTAssertEqual(results.results[0].meetingTitle, "2026:03:26 16:04:11")
    }

    func testHydrateMeetingSearchTitlesKeepsFilenameDerivedTitleWhenMarkdownIsMissing() throws {
        try writeFixture(
            makeFixtureJSON(title: "Roadmap Sync", date: "2026-03-26T16:04:11-0500"),
            filename: "Call_2026-03-26_16-04-11",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        var results = try index.searchUtterances(query: "roadmap", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(results.results.count, 1)

        // Hydrating against a directory that has no matching markdown file
        // must leave the filename-derived title intact.
        let emptyDir = makeTempDir()
        defer { removeTempDir(emptyDir) }
        hydrateMeetingSearchTitles(in: &results, meetingDirs: [emptyDir])

        XCTAssertEqual(results.results[0].meetingTitle, "2026:03:26 16:04:11")
    }

    func testListMeetingsTracksBucketedAgentQueryTelemetry() throws {
        try writeFixture(
            makeFixtureJSON(title: "Roadmap Sync", date: "2026-03-26T16:04:11-0500"),
            filename: "Call_2026-03-26_16-04-11",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        _ = try handleListMeetings(
            params: CallTool.Parameters(name: "list_meetings", arguments: ["count": .int(10)]),
            index: index,
            meetingDirs: [tempDir]
        )

        let observation = try XCTUnwrap(telemetry.observations.last)
        XCTAssertEqual(observation.queryKind, "list")
        XCTAssertEqual(observation.artifactKind, "meeting")
        XCTAssertEqual(observation.sourceCountBucket, "1")
        XCTAssertNotEqual(observation.captureAgeBucket, "unknown")
    }

    func testListDictationsTracksBucketedAgentQueryTelemetry() throws {
        try writeFixture(makeDictationDayJSON(), filename: "Dictations_2026-04-07", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        _ = try handleListDictations(
            params: CallTool.Parameters(name: "list_dictations", arguments: ["count": .int(10)]),
            index: index
        )

        let observation = try XCTUnwrap(telemetry.observations.last)
        XCTAssertEqual(observation.queryKind, "list")
        XCTAssertEqual(observation.artifactKind, "dictation")
        XCTAssertEqual(observation.sourceCountBucket, "1")
        XCTAssertNotEqual(observation.captureAgeBucket, "unknown")
    }

    func testRecentContextTracksMixedAgentQueryTelemetry() throws {
        try writeFixture(
            makeFixtureJSON(date: "2026-03-29T10:00:00-0500"),
            filename: "Call_2026-03-29_10-00-00",
            to: tempDir
        )
        try writeFixture(makeDictationDayJSON(), filename: "Dictations_2026-04-07", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        _ = try handleRecentContext(
            params: CallTool.Parameters(name: "recent_context", arguments: ["count": .int(10)]),
            index: index,
            meetingDirs: [tempDir]
        )

        let observation = try XCTUnwrap(telemetry.observations.last)
        XCTAssertEqual(observation.queryKind, "recent")
        XCTAssertEqual(observation.artifactKind, "mixed")
        XCTAssertEqual(observation.sourceCountBucket, "2_3")
        XCTAssertNotEqual(observation.captureAgeBucket, "unknown")
    }

    func testRecapReturnsStructuredSummaryWhenPresent() throws {
        try writeFixture(
            makeMeetingWithInlineSummary(
                date: "2026-04-18",
                time: "09:15:00",
                decisions: ["Ship the beta on Friday"],
                actionItems: ["Jenny: send the revised spec"],
                openQuestions: ["Do we need a migration window?"]
            ),
            filename: "Call_2026-04-18_09-15-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let recap = try decodedRecap(date: "2026-04-18")
        let meeting = try XCTUnwrap(recap.meetings.first)

        XCTAssertEqual(meeting.title, "Beta launch sync")
        XCTAssertEqual(meeting.summarySource, "summary")
        XCTAssertEqual(meeting.decisions, ["Ship the beta on Friday"])
        XCTAssertEqual(meeting.actionItems, [RecapActionItem(owner: "Jenny", text: "send the revised spec")])
        XCTAssertEqual(meeting.openQuestions, ["Do we need a migration window?"])
        XCTAssertTrue(meeting.preview.contains("## Decisions"))
        XCTAssertFalse(meeting.preview.contains("[00:00]"), "recap should not leak raw dialogue when a summary exists")
    }

    func testRecapFallsBackToRawLinesWhenSummaryIsMissing() throws {
        try writeFixture(
            makeFixtureJSON(
                title: "Fallback Sync",
                date: "2026-04-19T10:00:00-0500",
                utterances: [
                    ("mic_0", 0.0, 5.0, "This raw line is only for fallback"),
                    ("system_0", 5.0, 10.0, "Second fallback line"),
                ]
            ),
            filename: "Call_2026-04-19_10-00-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let meeting = try XCTUnwrap(decodedRecap(date: "2026-04-19").meetings.first)
        XCTAssertEqual(meeting.summarySource, "transcript_fallback")
        XCTAssertTrue(meeting.decisions.isEmpty)
        XCTAssertTrue(meeting.actionItems.isEmpty)
        XCTAssertTrue(meeting.openQuestions.isEmpty)
        XCTAssertTrue(meeting.preview.contains("This raw line is only for fallback"))
    }

    func testRecapFallsBackForMalformedEmptySummary() throws {
        try writeFixture(
            makeMeetingWithInlineSummary(
                date: "2026-04-20",
                time: "11:00:00",
                decisions: [],
                actionItems: [],
                openQuestions: []
            ),
            filename: "Call_2026-04-20_11-00-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let meeting = try XCTUnwrap(decodedRecap(date: "2026-04-20").meetings.first)
        XCTAssertEqual(meeting.summarySource, "transcript_fallback")
        XCTAssertTrue(meeting.decisions.isEmpty)
        XCTAssertTrue(meeting.actionItems.isEmpty)
        XCTAssertTrue(meeting.openQuestions.isEmpty)
        XCTAssertTrue(meeting.preview.contains("Let's lock the launch."))
    }

    func testEmptyListDoesNotTrackAgentQueryTelemetry() throws {
        _ = try handleListMeetings(
            params: CallTool.Parameters(name: "list_meetings", arguments: ["count": .int(10)]),
            index: index,
            meetingDirs: [tempDir]
        )

        XCTAssertTrue(telemetry.observations.isEmpty)
    }

    private func decodedRecap(date: String) throws -> RecapResult {
        let result = try handleRecap(
            params: CallTool.Parameters(name: "recap", arguments: ["date_from": .string(date), "date_to": .string(date)]),
            index: index,
            meetingDirs: [tempDir]
        )
        let text = try XCTUnwrap(result.textContent)
        let data = try XCTUnwrap(text.data(using: .utf8))
        return try JSONDecoder().decode(RecapResult.self, from: data)
    }
}

private final class RecordingAgentCaptureQueryTelemetry: AgentCaptureQueryTelemetryRecording {
    private(set) var observations: [AgentCaptureQueryObservation] = []

    func track(_ observation: AgentCaptureQueryObservation) {
        observations.append(observation)
    }
}

private extension CallTool.Result {
    var textContent: String? {
        guard let first = content.first,
              case .text(let text, _, _) = first else {
            return nil
        }
        return text
    }
}
