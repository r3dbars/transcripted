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
        XCTAssertEqual(observation.toolKind, "list")
        XCTAssertEqual(observation.captureKind, "meeting")
        XCTAssertEqual(observation.sourceCountBucket, "1")
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
        XCTAssertEqual(observation.toolKind, "list")
        XCTAssertEqual(observation.captureKind, "dictation")
        XCTAssertEqual(observation.sourceCountBucket, "1")
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
        XCTAssertEqual(observation.toolKind, "recent")
        XCTAssertEqual(observation.captureKind, "mixed")
        XCTAssertEqual(observation.sourceCountBucket, "2_3")
    }

    func testSummaryRollupsTrackSourcedAgentQueryTelemetry() throws {
        try writeFixture(
            makeMeetingWithInlineSummary(
                date: "2026-04-18",
                time: "09:15:00",
                decisions: ["Ship the beta on Friday", "Keep onboarding unchanged"],
                actionItems: ["Jenny: send the revised spec", "Robin: prep launch notes"],
                openQuestions: ["Do we need a migration window?", "Who owns the support note?"]
            ),
            filename: "Call_2026-04-18_09-15-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        _ = try handleListActionItems(
            params: CallTool.Parameters(name: "list_action_items", arguments: ["count": .int(10)]),
            index: index,
            meetingDirs: [tempDir]
        )
        XCTAssertEqual(telemetry.observations.last?.toolKind, "action_items")
        XCTAssertEqual(telemetry.observations.last?.captureKind, "meeting")
        XCTAssertEqual(telemetry.observations.last?.sourceCountBucket, "1")

        _ = try handleListDecisions(
            params: CallTool.Parameters(name: "list_decisions", arguments: ["count": .int(10)]),
            index: index,
            meetingDirs: [tempDir]
        )
        XCTAssertEqual(telemetry.observations.last?.toolKind, "decisions")
        XCTAssertEqual(telemetry.observations.last?.sourceCountBucket, "1")

        _ = try handleDigest(
            params: CallTool.Parameters(name: "digest", arguments: ["date_from": .string("2026-04-18"), "date_to": .string("2026-04-18")]),
            index: index,
            meetingDirs: [tempDir]
        )
        XCTAssertEqual(telemetry.observations.last?.toolKind, "digest")
        XCTAssertEqual(telemetry.observations.last?.sourceCountBucket, "1")
    }

    func testReceiptToolsTrackSourcedAgentQueryTelemetry() throws {
        try writeFixture(
            makeMeetingWithInlineSummary(
                date: "2026-04-18",
                time: "09:15:00",
                decisions: ["Ship the beta on Friday", "Keep onboarding unchanged"],
                actionItems: ["Jenny: send the revised spec", "Robin: prep launch notes"],
                openQuestions: ["Do we need a migration window?", "Who owns the support note?"]
            ),
            filename: "Call_2026-04-18_09-15-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        _ = try handleDecisions(
            params: CallTool.Parameters(name: "decisions", arguments: ["count": .int(10)]),
            index: index,
            meetingDirs: [tempDir]
        )
        XCTAssertEqual(telemetry.observations.last?.toolKind, "decisions")
        XCTAssertEqual(telemetry.observations.last?.sourceCountBucket, "1")

        _ = try handleCommitments(
            params: CallTool.Parameters(name: "commitments", arguments: ["count": .int(10)]),
            index: index,
            meetingDirs: [tempDir]
        )
        XCTAssertEqual(telemetry.observations.last?.toolKind, "commitments")
        XCTAssertEqual(telemetry.observations.last?.sourceCountBucket, "1")

        _ = try handleOpenQuestions(
            params: CallTool.Parameters(name: "open_questions", arguments: ["count": .int(10)]),
            index: index,
            meetingDirs: [tempDir]
        )
        XCTAssertEqual(telemetry.observations.last?.toolKind, "open_questions")
        XCTAssertEqual(telemetry.observations.last?.sourceCountBucket, "1")

        try writeFixture(
            makeFixtureJSON(
                date: "2026-04-19T09:15:00-0500",
                utterances: [
                    ("mic_0", 0.0, 5.0, "Pricing receipt needs a product follow-up"),
                    ("mic_0", 10.0, 15.0, "Pricing receipt also needs a support follow-up"),
                ]
            ),
            filename: "Call_2026-04-19_09-15-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        _ = try handleSearchMeetings(
            params: CallTool.Parameters(name: "search_meetings", arguments: ["query": .string("pricing receipt")]),
            index: index,
            meetingDirs: [tempDir]
        )
        XCTAssertEqual(telemetry.observations.last?.toolKind, "search")
        XCTAssertEqual(telemetry.observations.last?.sourceCountBucket, "1")
    }

    func testRecapReturnsStructuredSummaryWhenPresent() throws {
        try writeFixture(
            makeMeetingWithInlineSummary(
                date: "2026-04-18",
                time: "09:15:00",
                decisions: ["Ship the beta on Friday"],
                actionItems: ["Jenny: send the revised spec (due: Friday)"],
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
        XCTAssertEqual(meeting.actionItems, [
            RecapActionItem(owner: "Jenny", text: "send the revised spec", due: "Friday")
        ])
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

    func testReadMeetingSmallFullReadStaysByteIdenticalRawMarkdown() throws {
        let content = makeFixtureJSON(title: "Roadmap Sync", date: "2026-03-26T16:04:11-0500")
        try writeFixture(content, filename: "Call_2026-03-26_16-04-11", to: tempDir)

        let result = try handleReadMeeting(
            params: CallTool.Parameters(name: "read_meeting", arguments: ["filename": .string("Call_2026-03-26_16-04-11")]),
            meetingDirs: [tempDir]
        )

        XCTAssertNotEqual(result.isError, true)
        XCTAssertEqual(try resultText(result), content)
        XCTAssertEqual(telemetry.observations.last?.toolKind, "read")
        XCTAssertEqual(telemetry.observations.last?.captureKind, "meeting")
        XCTAssertEqual(telemetry.observations.last?.sourceCountBucket, "1")
    }

    func testReadMeetingBuildsPostHogPayloadFromRealSavedArtifactLookup() throws {
        let payloadTelemetry = RequestCapturingAgentCaptureQueryTelemetry()
        AgentCaptureQueryTelemetryRuntime.recorder = payloadTelemetry

        try writeFixture(
            makeFixtureJSON(title: "Roadmap Sync", date: "2026-03-26T16:04:11-0500"),
            filename: "Call_2026-03-26_16-04-11",
            to: tempDir
        )

        _ = try handleReadMeeting(
            params: CallTool.Parameters(name: "read_meeting", arguments: ["filename": .string("Call_2026-03-26_16-04-11")]),
            meetingDirs: [tempDir]
        )

        let properties = try XCTUnwrap(payloadTelemetry.properties)
        XCTAssertEqual(properties["client_family"], "mcp")
        XCTAssertEqual(properties["tool_kind"], "read")
        XCTAssertEqual(properties["capture_kind"], "meeting")
        XCTAssertEqual(properties["result"], "success")
        XCTAssertEqual(properties["source_count_bucket"], "1")
        XCTAssertEqual(Set(properties.keys), AgentCaptureQueryTelemetryPolicy.allowedProperties.union(["distinct_id"]))
        XCTAssertNil(properties["agent_target"])
        XCTAssertNil(properties["query_kind"])
        XCTAssertNil(properties["artifact_kind"])
        XCTAssertNil(properties["capture_age_bucket"])
        XCTAssertNil(properties["return_window_bucket"])
        XCTAssertNil(properties["surface"])
        XCTAssertNil(properties["query_text"])
        XCTAssertNil(properties["transcript_text"])
        XCTAssertNil(properties["meeting_title"])
        XCTAssertNil(properties["file_path"])
    }

    func testReadMeetingWindowedReadReturnsRequestedUtterances() throws {
        let utterances = makeSequentialUtterances(count: 6) { "Utterance number \($0)" }
        try writeFixture(
            makeFixtureJSON(title: "Roadmap Sync", date: "2026-03-26T16:04:11-0500", utterances: utterances),
            filename: "Call_2026-03-26_16-04-11",
            to: tempDir
        )

        let result = try handleReadMeeting(
            params: CallTool.Parameters(name: "read_meeting", arguments: [
                "filename": .string("Call_2026-03-26_16-04-11"),
                "offset": .int(2),
                "limit": .int(2),
            ]),
            meetingDirs: [tempDir]
        )

        XCTAssertNotEqual(result.isError, true)
        let page = try JSONDecoder().decode(MeetingTranscriptPage.self, from: Data(resultText(result).utf8))
        XCTAssertEqual(page.totalUtterances, 6)
        XCTAssertEqual(page.offset, 2)
        XCTAssertEqual(page.returned, 2)
        XCTAssertTrue(page.truncated)
        XCTAssertEqual(page.nextOffset, 4)
        XCTAssertEqual(page.utterances.map(\.text), ["Utterance number 2", "Utterance number 3"])
        XCTAssertEqual(page.utterances.first?.speaker, "Jenny Wen")
        // Full-section pages keep the frontmatter metadata.
        let frontmatter = try XCTUnwrap(page.frontmatter)
        XCTAssertTrue(frontmatter.contains("title: \"Roadmap Sync\""))
        XCTAssertTrue(page.hint.contains("offset=4"))
        XCTAssertEqual(telemetry.observations.last?.toolKind, "read")
        XCTAssertEqual(telemetry.observations.last?.captureKind, "meeting")
        XCTAssertEqual(telemetry.observations.last?.sourceCountBucket, "1")
    }

    func testReadMeetingTranscriptSectionWindowOmitsFrontmatter() throws {
        let utterances = makeSequentialUtterances(count: 6) { "Utterance number \($0)" }
        try writeFixture(
            makeFixtureJSON(date: "2026-03-26T16:04:11-0500", utterances: utterances),
            filename: "Call_2026-03-26_16-04-11",
            to: tempDir
        )

        let result = try handleReadMeeting(
            params: CallTool.Parameters(name: "read_meeting", arguments: [
                "filename": .string("Call_2026-03-26_16-04-11"),
                "section": .string("transcript"),
                "limit": .int(3),
            ]),
            meetingDirs: [tempDir]
        )

        let page = try JSONDecoder().decode(MeetingTranscriptPage.self, from: Data(resultText(result).utf8))
        XCTAssertNil(page.frontmatter)
        XCTAssertEqual(page.totalUtterances, 6)
        XCTAssertEqual(page.offset, 0)
        XCTAssertEqual(page.returned, 3)
        XCTAssertEqual(page.nextOffset, 3)
        XCTAssertEqual(telemetry.observations.last?.toolKind, "read")
        XCTAssertEqual(telemetry.observations.last?.captureKind, "meeting")
    }

    func testReadMeetingOffsetBeyondEndReturnsEmptyWindowWithTotals() throws {
        try writeFixture(
            makeFixtureJSON(date: "2026-03-26T16:04:11-0500"),
            filename: "Call_2026-03-26_16-04-11",
            to: tempDir
        )

        let result = try handleReadMeeting(
            params: CallTool.Parameters(name: "read_meeting", arguments: [
                "filename": .string("Call_2026-03-26_16-04-11"),
                "offset": .int(50),
                "limit": .int(5),
            ]),
            meetingDirs: [tempDir]
        )

        XCTAssertNotEqual(result.isError, true)
        let page = try JSONDecoder().decode(MeetingTranscriptPage.self, from: Data(resultText(result).utf8))
        // Default fixture has 2 utterances.
        XCTAssertEqual(page.totalUtterances, 2)
        XCTAssertEqual(page.offset, 50)
        XCTAssertEqual(page.returned, 0)
        XCTAssertTrue(page.utterances.isEmpty)
        XCTAssertFalse(page.truncated)
        XCTAssertNil(page.nextOffset)
        XCTAssertTrue(page.hint.contains("past the end"))
        XCTAssertEqual(telemetry.observations.last?.toolKind, "read")
        XCTAssertEqual(telemetry.observations.last?.captureKind, "meeting")
    }

    func testReadMeetingOversizedTranscriptAutoTruncatesWithNextOffset() throws {
        let filler = String(repeating: "budget planning detail ", count: 14)
        let utterances = makeSequentialUtterances(count: 200) { "Utterance \($0): \(filler)" }
        try writeFixture(
            makeFixtureJSON(date: "2026-03-26T16:04:11-0500", utterances: utterances),
            filename: "Call_2026-03-26_16-04-11",
            to: tempDir
        )

        // No offset/limit — the size guard alone must trigger pagination.
        let result = try handleReadMeeting(
            params: CallTool.Parameters(name: "read_meeting", arguments: ["filename": .string("Call_2026-03-26_16-04-11")]),
            meetingDirs: [tempDir]
        )

        XCTAssertNotEqual(result.isError, true)
        let page = try JSONDecoder().decode(MeetingTranscriptPage.self, from: Data(resultText(result).utf8))
        XCTAssertEqual(page.totalUtterances, 200)
        XCTAssertEqual(page.offset, 0)
        XCTAssertTrue(page.truncated)
        XCTAssertGreaterThan(page.returned, 0)
        XCTAssertLessThan(page.returned, 200)
        let nextOffset = try XCTUnwrap(page.nextOffset)
        XCTAssertEqual(nextOffset, page.returned)
        XCTAssertTrue(page.hint.contains("offset=\(nextOffset)"))
        XCTAssertEqual(telemetry.observations.last?.toolKind, "read")
        XCTAssertEqual(telemetry.observations.last?.captureKind, "meeting")
    }

    func testReadDictationSmallDayFullReadStaysByteIdenticalRawMarkdown() throws {
        let content = makeDictationDayJSON()
        try writeFixture(content, filename: "Dictations_2026-04-07", to: tempDir)

        let result = try handleReadDictation(
            params: CallTool.Parameters(name: "read_dictation", arguments: ["filename": .string("Dictations_2026-04-07")]),
            dictationDirs: [tempDir]
        )

        XCTAssertNotEqual(result.isError, true)
        XCTAssertEqual(try resultText(result), content)
        XCTAssertEqual(telemetry.observations.last?.toolKind, "read")
        XCTAssertEqual(telemetry.observations.last?.captureKind, "dictation")
        XCTAssertEqual(telemetry.observations.last?.sourceCountBucket, "2_3")
    }

    func testReadDictationEntryWindowing() throws {
        let entries: [(id: String, createdAt: String, title: String, text: String, sourceAppName: String, delivery: String)] = [
            ("dictation-20260407-091500-000", "2026-04-07T09:15:00-0500", "First note", "Alpha text for the morning", "Slack", "copied"),
            ("dictation-20260407-120000-000", "2026-04-07T12:00:00-0500", "Second note", "Beta text for midday", "Mail", "pasted"),
            ("dictation-20260407-183000-000", "2026-04-07T18:30:00-0500", "Third note", "Gamma text for the evening", "Notes", "copied"),
        ]
        try writeFixture(makeDictationDayJSON(entries: entries), filename: "Dictations_2026-04-07", to: tempDir)

        let result = try handleReadDictation(
            params: CallTool.Parameters(name: "read_dictation", arguments: [
                "filename": .string("Dictations_2026-04-07"),
                "offset": .int(1),
                "limit": .int(1),
            ]),
            dictationDirs: [tempDir]
        )

        XCTAssertNotEqual(result.isError, true)
        let page = try JSONDecoder().decode(DictationDayPage.self, from: Data(resultText(result).utf8))
        XCTAssertEqual(page.totalEntries, 3)
        XCTAssertEqual(page.offset, 1)
        XCTAssertEqual(page.returned, 1)
        XCTAssertTrue(page.truncated)
        XCTAssertEqual(page.nextOffset, 2)
        XCTAssertEqual(page.entries.map(\.title), ["Second note"])
        XCTAssertTrue(page.hint.contains("offset=2"))
        XCTAssertEqual(telemetry.observations.last?.toolKind, "read")
        XCTAssertEqual(telemetry.observations.last?.captureKind, "dictation")
        XCTAssertEqual(telemetry.observations.last?.sourceCountBucket, "2_3")
    }

    func testReadDictationEntryIdBehaviorUnchangedByPaginationParams() throws {
        try writeFixture(makeDictationDayJSON(), filename: "Dictations_2026-04-07", to: tempDir)

        let result = try handleReadDictation(
            params: CallTool.Parameters(name: "read_dictation", arguments: [
                "filename": .string("Dictations_2026-04-07"),
                "entry_id": .string("dictation-20260407-091500-000"),
                "offset": .int(1),
                "limit": .int(1),
            ]),
            dictationDirs: [tempDir]
        )

        XCTAssertNotEqual(result.isError, true)
        let text = try resultText(result)
        XCTAssertTrue(text.hasPrefix("# Morning note"))
        XCTAssertTrue(text.contains("Ship the follow-up note to product today"))
        XCTAssertFalse(text.contains("total_entries"))
        XCTAssertEqual(telemetry.observations.last?.toolKind, "read")
        XCTAssertEqual(telemetry.observations.last?.captureKind, "dictation")
        XCTAssertEqual(telemetry.observations.last?.sourceCountBucket, "1")
    }

    func testListActionItemsDoneStatusReturnsStructuredEmptyResult() throws {
        try writeFixture(
            makeMeetingWithInlineSummary(
                actionItems: ["Jenny: Confirm the venue (done)"]
            ),
            filename: "Call_2026-04-18_09-15-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let result = try handleListActionItems(
            params: CallTool.Parameters(name: "list_action_items", arguments: ["status": .string("done")]),
            index: index,
            meetingDirs: [tempDir]
        )

        XCTAssertNotEqual(result.isError, true)
        let text = try resultText(result)
        let decoded = try JSONDecoder().decode(ActionItemsResult.self, from: Data(text.utf8))
        XCTAssertEqual(decoded.status, "done")
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.items.first?.text, "Confirm the venue")
        XCTAssertEqual(decoded.items.first?.status, "done")
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
        XCTAssertEqual(telemetry.observations.last?.toolKind, "search")
        XCTAssertEqual(telemetry.observations.last?.captureKind, "meeting")
        XCTAssertEqual(telemetry.observations.last?.sourceCountBucket, "1")
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

    private func resultText(_ result: CallTool.Result) throws -> String {
        guard case .text(let text, _, _) = try XCTUnwrap(result.content.first) else {
            XCTFail("Expected text content")
            return ""
        }
        return text
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

private final class RequestCapturingAgentCaptureQueryTelemetry: AgentCaptureQueryTelemetryRecording {
    private(set) var properties: [String: String]?

    private let reporter = AgentCaptureQueryTelemetry(
        configuration: AgentCaptureQueryTelemetryConfiguration(
            apiKey: "phc_test",
            host: URL(string: "https://us.i.posthog.com")!,
            distinctID: "anonymous-device"
        )
    )

    func track(_ observation: AgentCaptureQueryObservation) {
        guard let request = reporter.makeRequest(for: observation),
              let body = request.httpBody,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let event = object["event"] as? String,
              event == AgentCaptureQueryTelemetryPolicy.eventName,
              let properties = object["properties"] as? [String: String] else {
            return
        }
        self.properties = properties
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

private func decodeCrossMeetingResult(_ result: CallTool.Result) throws -> CrossMeetingToolResult {
    guard case .text(let text, _, _) = result.content.first else {
        XCTFail("Expected text tool result")
        throw NSError(domain: "ToolHandlersTests", code: 1)
    }
    return try JSONDecoder().decode(CrossMeetingToolResult.self, from: Data(text.utf8))
}
