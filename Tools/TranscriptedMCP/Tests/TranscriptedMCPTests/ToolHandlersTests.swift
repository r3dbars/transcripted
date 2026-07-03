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

    func testDecisionsToolReturnsStructuredReceipts() throws {
        try writeFixture(
            makeMeetingWithInlineSummary(
                decisions: ["Keep pricing simple", "Ship the beta on Friday"]
            ),
            filename: "Call_2026-04-18_09-15-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let result = try handleDecisions(
            params: CallTool.Parameters(
                name: "decisions",
                arguments: ["topic": .string("pricing"), "range": .string("2026-04-18")]
            ),
            index: index,
            meetingDirs: [tempDir]
        )

        let decoded = try decodeCrossMeetingResult(result)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.results.first?.meetingId, "Call_2026-04-18_09-15-00")
        XCTAssertEqual(decoded.results.first?.timestamp, nil)
        XCTAssertEqual(decoded.results.first?.quote, "Keep pricing simple")
    }

    func testCommitmentsToolFiltersByPerson() throws {
        try writeFixture(
            makeMeetingWithInlineSummary(
                actionItems: ["Jenny: send the revised spec", "Sam: draft the launch note"]
            ),
            filename: "Call_2026-04-18_09-15-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let result = try handleCommitments(
            params: CallTool.Parameters(
                name: "commitments",
                arguments: ["person": .string("Jenny"), "range": .string("2026-04-01..2026-04-30")]
            ),
            index: index,
            meetingDirs: [tempDir]
        )

        let decoded = try decodeCrossMeetingResult(result)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.results.first?.person, "Jenny")
        XCTAssertEqual(decoded.results.first?.quote, "Jenny: send the revised spec")
    }

    func testOpenQuestionsToolFiltersByProject() throws {
        try writeFixture(
            makeMeetingWithInlineSummary(
                openQuestions: ["Should the pricing page mention credits?", "Do we need a migration window?"]
            ),
            filename: "Call_2026-04-18_09-15-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let result = try handleOpenQuestions(
            params: CallTool.Parameters(
                name: "open_questions",
                arguments: ["project": .string("pricing credits")]
            ),
            index: index,
            meetingDirs: [tempDir]
        )

        let decoded = try decodeCrossMeetingResult(result)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.results.first?.kind, "open_question")
        XCTAssertEqual(decoded.results.first?.quote, "Should the pricing page mention credits?")
    }

    func testSearchMeetingsToolReturnsUtteranceReceiptsWithTimestamps() throws {
        try writeFixture(
            makeFixtureJSON(
                utterances: [
                    ("mic_0", 0.0, 5.0, "Good morning everyone"),
                    ("system_0", 125.0, 135.0, "The pricing decision needs a receipt"),
                ]
            ),
            filename: "Call_2026-04-18_09-15-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let result = try handleSearchMeetings(
            params: CallTool.Parameters(name: "search_meetings", arguments: ["query": .string("pricing receipt")]),
            index: index,
            meetingDirs: [tempDir]
        )

        let decoded = try decodeCrossMeetingResult(result)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.results.first?.meetingId, "Call_2026-04-18_09-15-00")
        XCTAssertEqual(decoded.results.first?.timestamp, "2:05")
        XCTAssertEqual(decoded.results.first?.quote, "The pricing decision needs a receipt")
    }

    func testCrossMeetingToolsReturnStructuredEmptyCorpusResults() throws {
        let decisions = try decodeCrossMeetingResult(try handleDecisions(
            params: CallTool.Parameters(name: "decisions", arguments: ["topic": .string("pricing")]),
            index: index,
            meetingDirs: [tempDir]
        ))
        let commitments = try decodeCrossMeetingResult(try handleCommitments(
            params: CallTool.Parameters(name: "commitments", arguments: ["person": .string("Jenny")]),
            index: index,
            meetingDirs: [tempDir]
        ))
        let questions = try decodeCrossMeetingResult(try handleOpenQuestions(
            params: CallTool.Parameters(name: "open_questions", arguments: ["project": .string("pricing")]),
            index: index,
            meetingDirs: [tempDir]
        ))
        let search = try decodeCrossMeetingResult(try handleSearchMeetings(
            params: CallTool.Parameters(name: "search_meetings", arguments: ["query": .string("pricing")]),
            index: index,
            meetingDirs: [tempDir]
        ))

        XCTAssertEqual(decisions.count, 0)
        XCTAssertEqual(commitments.count, 0)
        XCTAssertEqual(questions.count, 0)
        XCTAssertEqual(search.count, 0)
    }

    func testCrossMeetingToolsIgnoreMeetingsWithoutSummaries() throws {
        try writeFixture(makeFixtureJSON(), filename: "Call_2026-04-18_09-15-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let result = try handleDecisions(
            params: CallTool.Parameters(name: "decisions", arguments: ["topic": .string("pricing")]),
            index: index,
            meetingDirs: [tempDir]
        )

        let decoded = try decodeCrossMeetingResult(result)
        XCTAssertEqual(decoded.count, 0)
        XCTAssertTrue(decoded.results.isEmpty)
    }

    func testCrossMeetingToolResultLimitsAreCappedAndTruncated() throws {
        try writeFixture(
            makeMeetingWithInlineSummary(
                decisions: ["Decision one", "Decision two", "Decision three"]
            ),
            filename: "Call_2026-04-18_09-15-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let result = try handleDecisions(
            params: CallTool.Parameters(name: "decisions", arguments: ["count": .int(2)]),
            index: index,
            meetingDirs: [tempDir]
        )

        let decoded = try decodeCrossMeetingResult(result)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertTrue(decoded.truncated)
        XCTAssertEqual(decoded.results.map(\.quote), ["Decision one", "Decision two"])
    }
}

private final class RecordingAgentCaptureQueryTelemetry: AgentCaptureQueryTelemetryRecording {
    private(set) var observations: [AgentCaptureQueryObservation] = []

    func track(_ observation: AgentCaptureQueryObservation) {
        observations.append(observation)
    }
}

private func decodeCrossMeetingResult(_ result: CallTool.Result) throws -> CrossMeetingToolResult {
    guard case .text(let text, _, _) = result.content.first else {
        XCTFail("Expected text tool result")
        throw NSError(domain: "ToolHandlersTests", code: 1)
    }
    return try JSONDecoder().decode(CrossMeetingToolResult.self, from: Data(text.utf8))
}
