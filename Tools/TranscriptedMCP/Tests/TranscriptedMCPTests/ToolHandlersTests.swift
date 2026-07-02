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
            index: index,
            dictationDirs: [tempDir]
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
            meetingDirs: [tempDir],
            dictationDirs: [tempDir]
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

    func testStatusToolReportsDirectoriesAndIndexCounts() throws {
        try writeFixture(makeMeetingWithInlineSummary(), filename: "Call_2026-04-18_09-15-00", to: tempDir)
        try writeFixture(makeDictationDayJSON(), filename: "Dictations_2026-04-07", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let directories = TranscriptedDataDirectories(meetingsDir: tempDir, dictationsDir: tempDir, indexDir: tempDir)
        let result = try handleStatus(index: index, directories: directories)

        XCTAssertNotEqual(result.isError, true)
        let payload = try JSONDecoder().decode(StatusResult.self, from: Data(resultText(result).utf8))
        XCTAssertEqual(payload.serverVersion, TranscriptedMCP.serverVersion)
        XCTAssertEqual(payload.meetingDirectories, [tempDir.path])
        XCTAssertEqual(payload.dictationDirectories, [tempDir.path])
        XCTAssertEqual(payload.resolutionSource, "default")
        XCTAssertFalse(payload.legacyFallbackAppended)
        XCTAssertEqual(payload.indexDirectory, tempDir.path)
        XCTAssertEqual(payload.indexedMeetings, 1)
        XCTAssertEqual(payload.indexedDictationDays, 1)
        XCTAssertEqual(payload.indexedDictationEntries, 2)
        // Fixture summary: 2 decisions + 2 action items + 1 open question.
        XCTAssertEqual(payload.indexedSummaryItems, 5)
        XCTAssertEqual(payload.summarizedMeetings, 1)
        XCTAssertTrue(payload.summariesIndexed)
    }

    func testStatusToolReportsZeroCountsOnEmptyIndex() throws {
        let directories = TranscriptedDataDirectories(meetingsDir: tempDir, dictationsDir: tempDir, indexDir: tempDir)
        let result = try handleStatus(index: index, directories: directories)

        let payload = try JSONDecoder().decode(StatusResult.self, from: Data(resultText(result).utf8))
        XCTAssertEqual(payload.indexedMeetings, 0)
        XCTAssertEqual(payload.indexedDictationDays, 0)
        XCTAssertEqual(payload.indexedSummaryItems, 0)
        XCTAssertFalse(payload.summariesIndexed)
    }

    func testEmptyListMeetingsDescribesSearchedDirectoriesAndHint() throws {
        let result = try handleListMeetings(
            params: CallTool.Parameters(name: "list_meetings", arguments: ["count": .int(10)]),
            index: index,
            meetingDirs: [tempDir]
        )

        XCTAssertNotEqual(result.isError, true)
        let payload = try JSONDecoder().decode(EmptyQueryResult.self, from: Data(resultText(result).utf8))
        XCTAssertEqual(payload.searchedDirectories, [tempDir.path])
        XCTAssertEqual(payload.indexedMeetings, 0)
        XCTAssertTrue(payload.hint.contains("No meetings are indexed"))
        XCTAssertTrue(payload.hint.contains("status tool"))
    }

    func testEmptyListMeetingsWithIndexedDataHintsAtFilters() throws {
        try writeFixture(
            makeFixtureJSON(date: "2026-03-26T16:04:11-0500"),
            filename: "Call_2026-03-26_16-04-11",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let result = try handleListMeetings(
            params: CallTool.Parameters(name: "list_meetings", arguments: ["date": .string("2001-01-01")]),
            index: index,
            meetingDirs: [tempDir]
        )

        let payload = try JSONDecoder().decode(EmptyQueryResult.self, from: Data(resultText(result).utf8))
        XCTAssertEqual(payload.indexedMeetings, 1)
        XCTAssertTrue(payload.hint.contains("No meetings matched"))
    }

    func testEmptyListDictationsDescribesSearchedDirectoriesAndHint() throws {
        let result = try handleListDictations(
            params: CallTool.Parameters(name: "list_dictations", arguments: ["count": .int(10)]),
            index: index,
            dictationDirs: [tempDir]
        )

        let payload = try JSONDecoder().decode(EmptyQueryResult.self, from: Data(resultText(result).utf8))
        XCTAssertEqual(payload.searchedDirectories, [tempDir.path])
        XCTAssertEqual(payload.indexedDictationDays, 0)
        XCTAssertEqual(payload.indexedDictationEntries, 0)
        XCTAssertTrue(payload.hint.contains("No dictations are indexed"))
    }

    func testEmptyRecentContextDeduplicatesSearchedDirectories() throws {
        let result = try handleRecentContext(
            params: CallTool.Parameters(name: "recent_context", arguments: ["count": .int(10)]),
            index: index,
            meetingDirs: [tempDir],
            dictationDirs: [tempDir]
        )

        let payload = try JSONDecoder().decode(EmptyQueryResult.self, from: Data(resultText(result).utf8))
        XCTAssertEqual(payload.searchedDirectories, [tempDir.path])
        XCTAssertEqual(payload.indexedMeetings, 0)
        XCTAssertEqual(payload.indexedDictationDays, 0)
        XCTAssertTrue(payload.hint.contains("Nothing is indexed"))
    }

    func testEmptyActionItemsExplainMissingSummaries() throws {
        // Meeting without a saved summary: indexed, but no summary rows.
        try writeFixture(
            makeFixtureJSON(date: "2026-03-26T16:04:11-0500"),
            filename: "Call_2026-03-26_16-04-11",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let result = try handleListActionItems(
            params: CallTool.Parameters(name: "list_action_items", arguments: [:]),
            index: index,
            meetingDirs: [tempDir]
        )

        XCTAssertNotEqual(result.isError, true)
        let payload = try JSONDecoder().decode(EmptyQueryResult.self, from: Data(resultText(result).utf8))
        XCTAssertEqual(payload.indexedMeetings, 1)
        XCTAssertEqual(payload.indexedSummaryItems, 0)
        XCTAssertTrue(payload.hint.contains("No structured summaries are indexed"))
    }

    func testListActionItemsDoneStatusReturnsExplicitError() throws {
        let result = try handleListActionItems(
            params: CallTool.Parameters(name: "list_action_items", arguments: ["status": .string("done")]),
            index: index,
            meetingDirs: [tempDir]
        )

        XCTAssertEqual(result.isError, true)
        let text = try resultText(result)
        XCTAssertTrue(text.contains("done"))
        XCTAssertTrue(text.contains("\"all\""))
    }

    private func resultText(_ result: CallTool.Result) throws -> String {
        guard case .text(let text, _, _) = try XCTUnwrap(result.content.first) else {
            XCTFail("Expected text content")
            return ""
        }
        return text
    }
}

private final class RecordingAgentCaptureQueryTelemetry: AgentCaptureQueryTelemetryRecording {
    private(set) var observations: [AgentCaptureQueryObservation] = []

    func track(_ observation: AgentCaptureQueryObservation) {
        observations.append(observation)
    }
}
