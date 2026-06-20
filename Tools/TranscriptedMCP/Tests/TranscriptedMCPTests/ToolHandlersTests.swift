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

    func testEmptyListDoesNotTrackAgentQueryTelemetry() throws {
        _ = try handleListMeetings(
            params: CallTool.Parameters(name: "list_meetings", arguments: ["count": .int(10)]),
            index: index,
            meetingDirs: [tempDir]
        )

        XCTAssertTrue(telemetry.observations.isEmpty)
    }
}

private final class RecordingAgentCaptureQueryTelemetry: AgentCaptureQueryTelemetryRecording {
    private(set) var observations: [AgentCaptureQueryObservation] = []

    func track(_ observation: AgentCaptureQueryObservation) {
        observations.append(observation)
    }
}
