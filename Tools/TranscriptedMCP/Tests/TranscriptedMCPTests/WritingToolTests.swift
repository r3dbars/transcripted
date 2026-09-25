import MCP
import XCTest
@testable import transcripted_mcp

/// Writing day files (`Writing_<date>.md`) through the index and the agent
/// tools: classification (never a meeting, even in the flat shared-folder
/// fallback), list/read/search/recent, status counts, and telemetry. Every
/// fixture lives in a temp directory.
final class WritingToolTests: XCTestCase {
    private var tempDir: URL!
    private var index: TranscriptIndex!
    private var telemetry: WritingRecordingTelemetry!

    override func setUp() {
        super.setUp()
        tempDir = makeTempDir()
        index = try! TranscriptIndex(indexDir: tempDir.appendingPathComponent("index", isDirectory: true).creatingDirectory())
        telemetry = WritingRecordingTelemetry()
        AgentCaptureQueryTelemetryRuntime.recorder = telemetry
    }

    override func tearDown() {
        AgentCaptureQueryTelemetryRuntime.recorder = AgentCaptureQueryTelemetry.shared
        telemetry = nil
        index = nil
        removeTempDir(tempDir)
        super.tearDown()
    }

    // MARK: - Classification / shared-folder fallback

    func testWritingFileInFlatSharedDataDirIsIndexedAsWritingNotMeeting() throws {
        let sharedRoot = tempDir.appendingPathComponent("flat-shared", isDirectory: true).creatingDirectory()
        try writeFixture(makeFixtureJSON(date: "2026-09-24T10:00:00-0500"), filename: "Call_2026-09-24_10-00-00", to: sharedRoot)
        try writeFixture(makeDictationDayJSON(), filename: "Dictations_2026-04-07", to: sharedRoot)
        try writeFixture(makeWritingDayMarkdown(), filename: "Writing_2026-09-25", to: sharedRoot)
        // Renamed copy: no prefix, only `capture_type: writing_day` marks it.
        try writeFixture(
            makeWritingDayMarkdown(date: "2026-09-26", entries: [sampleWritingEntries[0]]),
            filename: "exported-writing",
            to: sharedRoot
        )

        let directories = TranscriptedDataDirectories.resolve(
            environment: ["TRANSCRIPTED_DATA_DIR": sharedRoot.path],
            homeDirectory: tempDir
        )
        XCTAssertEqual(directories.writingDirs.map(\.standardizedFileURL.path), [sharedRoot.standardizedFileURL.path])

        try index.reconcile(
            meetingDirs: directories.meetingDirs,
            dictationDirs: directories.dictationDirs,
            writingDirs: directories.writingDirs
        )

        let counts = try index.counts()
        XCTAssertEqual(counts.meetings, 1, "writing files must not be indexed as meetings")
        XCTAssertEqual(counts.dictationDays, 1)
        XCTAssertEqual(counts.writingDays, 2)
        XCTAssertEqual(counts.writingEntries, 3)

        let meetings = try index.listMeetings(count: 50)
        XCTAssertEqual(meetings.map(\.filename), ["Call_2026-09-24_10-00-00"])
        XCTAssertEqual(
            Set(try index.listWritingDays(count: 50).map(\.filename)),
            ["Writing_2026-09-25", "exported-writing"]
        )
    }

    func testArtifactKindRecognizesWritingBeforeMeetingDefault() throws {
        let prefixed = tempDir.appendingPathComponent("Writing_2026-09-25.md")
        try makeWritingDayMarkdown().write(to: prefixed, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptLoader.artifactKind(for: prefixed), .writingDay)

        let unprefixed = tempDir.appendingPathComponent("copy.md")
        try makeWritingDayMarkdown().write(to: unprefixed, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptLoader.artifactKind(for: unprefixed), .writingDay)

        let meeting = tempDir.appendingPathComponent("Call_2026-09-24_10-00-00.md")
        try makeFixtureJSON().write(to: meeting, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptLoader.artifactKind(for: meeting), .meeting)
    }

    func testDeletedWritingFileLeavesTheIndex() throws {
        let writingDir = try makeWritingDir()
        try index.reconcile(meetingDirs: [], dictationDirs: [], writingDirs: [writingDir])
        XCTAssertEqual(try index.counts().writingDays, 1)

        try FileManager.default.removeItem(at: writingDir.appendingPathComponent("Writing_2026-09-25.md"))
        try index.reconcile(meetingDirs: [], dictationDirs: [], writingDirs: [writingDir])

        XCTAssertEqual(try index.counts().writingDays, 0)
        XCTAssertEqual(try index.counts().writingEntries, 0)
    }

    // MARK: - list_writing

    func testListWritingReturnsDaySummaries() throws {
        let writingDir = try makeWritingDir()
        try index.reconcile(meetingDirs: [], dictationDirs: [], writingDirs: [writingDir])

        let result = try handleListWriting(
            params: CallTool.Parameters(name: "list_writing", arguments: ["count": .int(5)]),
            index: index,
            writingDirs: [writingDir]
        )

        XCTAssertNotEqual(result.isError, true)
        let days = try JSONDecoder().decode([WritingDaySummary].self, from: Data(try text(result).utf8))
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].filename, "Writing_2026-09-25")
        XCTAssertEqual(days[0].date, "2026-09-25")
        XCTAssertEqual(days[0].entryCount, 2)
        XCTAssertEqual(days[0].acceptedWordCount, 3)
        XCTAssertEqual(days[0].sourceApps, ["Notes", "Slack"])
        XCTAssertEqual(telemetry.observations.last?.toolKind, "list")
        XCTAssertEqual(telemetry.observations.last?.captureKind, "writing")
    }

    func testListWritingEmptyResultDescribesWritingFolder() throws {
        let writingDir = tempDir.appendingPathComponent("writing", isDirectory: true).creatingDirectory()
        try index.reconcile(meetingDirs: [], dictationDirs: [], writingDirs: [writingDir])

        let params = CallTool.Parameters(name: "list_writing", arguments: [:])
        let result = try withAgentCaptureQueryTelemetry(params: params) {
            try handleListWriting(params: params, index: index, writingDirs: [writingDir])
        }

        let payload = try JSONDecoder().decode(EmptyQueryResult.self, from: Data(try text(result).utf8))
        XCTAssertEqual(payload.searchedDirectories, [writingDir.path])
        XCTAssertEqual(payload.indexedWritingDays, 0)
        XCTAssertNil(payload.indexedMeetings)
        XCTAssertTrue(payload.hint.contains("No writing is indexed"))
        XCTAssertEqual(telemetry.observations.last?.result, "empty_not_found")
    }

    func testMixedEmptyResultCountsWritingDaysAndEntries() throws {
        let writingDir = try makeWritingDir()
        let dictationDir = tempDir.appendingPathComponent("dictations", isDirectory: true).creatingDirectory()
        try index.reconcile(meetingDirs: [], dictationDirs: [dictationDir], writingDirs: [writingDir])

        // `kind` all with nothing matching: the empty answer covers every kind.
        let result = try handleSearchContext(
            params: CallTool.Parameters(name: "search_context", arguments: ["query": .string("no-such-phrase-anywhere")]),
            index: index,
            meetingDirs: [],
            dictationDirs: [dictationDir],
            writingDirs: [writingDir]
        )
        let json = try text(result)
        let payload = try JSONDecoder().decode(EmptyQueryResult.self, from: Data(json.utf8))
        XCTAssertEqual(payload.indexedWritingDays, 1)
        XCTAssertEqual(payload.indexedWritingEntries, 2)
        XCTAssertTrue(json.contains("\"indexed_writing_entries\""))
    }

    // MARK: - read_writing

    func testReadWritingSmallDayIsByteIdenticalMarkdown() throws {
        let writingDir = try makeWritingDir()

        let result = try handleReadWriting(
            params: CallTool.Parameters(name: "read_writing", arguments: ["filename": .string("Writing_2026-09-25")]),
            writingDirs: [writingDir]
        )

        XCTAssertNotEqual(result.isError, true)
        XCTAssertEqual(try text(result), makeWritingDayMarkdown())
        XCTAssertEqual(telemetry.observations.last?.captureKind, "writing")
        XCTAssertEqual(telemetry.observations.last?.resultCountBucket, "2_3")
    }

    func testReadWritingOneEntryById() throws {
        let writingDir = try makeWritingDir()

        let result = try handleReadWriting(
            params: CallTool.Parameters(name: "read_writing", arguments: [
                "filename": .string("Writing_2026-09-25"),
                "entry_id": .string("writing-20260925-104211-387-4f2a9c1e"),
            ]),
            writingDirs: [writingDir]
        )

        let body = try text(result)
        XCTAssertTrue(body.hasPrefix("# Pushing the launch to Thursday so QA\n"))
        XCTAssertTrue(body.contains("Source app: Slack"))
        XCTAssertTrue(body.contains("Accepted words: 3"))
        XCTAssertTrue(body.hasSuffix("Pushing the launch to Thursday so QA can finish the AirPods pass."))
    }

    func testReadWritingPaginatesWhenAsked() throws {
        let writingDir = try makeWritingDir()

        let result = try handleReadWriting(
            params: CallTool.Parameters(name: "read_writing", arguments: [
                "filename": .string("Writing_2026-09-25"),
                "limit": .int(1),
            ]),
            writingDirs: [writingDir]
        )

        let page = try JSONDecoder().decode(WritingDayPage.self, from: Data(try text(result).utf8))
        XCTAssertEqual(page.totalEntries, 2)
        XCTAssertEqual(page.returned, 1)
        XCTAssertTrue(page.truncated)
        XCTAssertEqual(page.nextOffset, 1)
        XCTAssertEqual(page.entries.first?.id, "writing-20260925-104211-387-4f2a9c1e")
        XCTAssertTrue(page.hint.contains("read_writing"))
    }

    func testReadWritingRejectsMissingTraversalAndNonWritingFiles() throws {
        let writingDir = try makeWritingDir()
        try writeFixture(makeFixtureJSON(), filename: "Call_2026-09-24_10-00-00", to: writingDir)

        let missing = try handleReadWriting(
            params: CallTool.Parameters(name: "read_writing", arguments: ["filename": .string("Writing_2020-01-01")]),
            writingDirs: [writingDir]
        )
        XCTAssertEqual(missing.isError, true)
        XCTAssertTrue(try text(missing).contains("Writing not found"))

        let traversal = try handleReadWriting(
            params: CallTool.Parameters(name: "read_writing", arguments: ["filename": .string("../etc/passwd")]),
            writingDirs: [writingDir]
        )
        XCTAssertEqual(traversal.isError, true)

        let meeting = try handleReadWriting(
            params: CallTool.Parameters(name: "read_writing", arguments: ["filename": .string("Call_2026-09-24_10-00-00")]),
            writingDirs: [writingDir]
        )
        XCTAssertEqual(meeting.isError, true, "a meeting sharing the folder is not readable as writing")
    }

    // MARK: - search_context / recent_context

    func testSearchContextFindsWritingAndRespectsKind() throws {
        let writingDir = try makeWritingDir()
        let dictationDir = tempDir.appendingPathComponent("dictations", isDirectory: true).creatingDirectory()
        try writeFixture(makeDictationDayJSON(), filename: "Dictations_2026-04-07", to: dictationDir)
        try index.reconcile(meetingDirs: [], dictationDirs: [dictationDir], writingDirs: [writingDir])

        let writingOnly = try searchContext(["query": .string("AirPods"), "kind": .string("writing")], dictationDir: dictationDir, writingDir: writingDir)
        XCTAssertEqual(writingOnly.results.map(\.kind), [.writing])
        XCTAssertEqual(writingOnly.results.first?.entryId, "writing-20260925-104211-387-4f2a9c1e")
        XCTAssertEqual(writingOnly.results.first?.snippets.first?.sourceAppName, "Slack")
        XCTAssertNil(writingOnly.results.first?.snippets.first?.delivery)
        XCTAssertEqual(telemetry.observations.last?.captureKind, "writing")

        let all = try searchContext(["query": .string("AirPods")], dictationDir: dictationDir, writingDir: writingDir)
        XCTAssertEqual(all.results.map(\.kind), [.writing], "kind all includes writing")

        let dictationOnly = try handleSearchContext(
            params: CallTool.Parameters(name: "search_context", arguments: ["query": .string("AirPods"), "kind": .string("dictation")]),
            index: index,
            meetingDirs: [],
            dictationDirs: [dictationDir],
            writingDirs: [writingDir]
        )
        let dictationPayload = try JSONDecoder().decode(EmptyQueryResult.self, from: Data(try text(dictationOnly).utf8))
        XCTAssertEqual(dictationPayload.searchedDirectories, [dictationDir.path], "a dictation-only query doesn't search the writing folder")

        let withSpeaker = try handleSearchContext(
            params: CallTool.Parameters(name: "search_context", arguments: ["query": .string("AirPods"), "speaker": .string("Jenny")]),
            index: index,
            meetingDirs: [],
            dictationDirs: [dictationDir],
            writingDirs: [writingDir]
        )
        let speakerPayload = try JSONDecoder().decode(EmptyQueryResult.self, from: Data(try text(withSpeaker).utf8))
        XCTAssertEqual(speakerPayload.indexedWritingDays, 1, "a speaker filter skips writing, which has no speakers")
    }

    func testRecentContextIncludesWritingAndFiltersByKind() throws {
        let writingDir = try makeWritingDir()
        let dictationDir = tempDir.appendingPathComponent("dictations", isDirectory: true).creatingDirectory()
        try writeFixture(makeDictationDayJSON(), filename: "Dictations_2026-04-07", to: dictationDir)
        try index.reconcile(meetingDirs: [], dictationDirs: [dictationDir], writingDirs: [writingDir])

        let all = try recentContext(["count": .int(10)], dictationDir: dictationDir, writingDir: writingDir)
        XCTAssertEqual(Set(all.items.map(\.kind)), [.dictation, .writing])
        XCTAssertEqual(all.items.first?.kind, .writing, "newest first: the writing entries are later than the dictations")
        XCTAssertEqual(telemetry.observations.last?.captureKind, "mixed")

        let writingOnly = try recentContext(["kind": .string("writing")], dictationDir: dictationDir, writingDir: writingDir)
        XCTAssertEqual(writingOnly.items.map(\.entryId), [
            "writing-20260925-160501-002-0b1c2d3e",
            "writing-20260925-104211-387-4f2a9c1e",
        ])
        XCTAssertEqual(writingOnly.items.first?.sourceAppName, "Notes")
        XCTAssertNil(writingOnly.items.first?.delivery)
        XCTAssertEqual(telemetry.observations.last?.captureKind, "writing")

        let dictationOnly = try recentContext(["kind": .string("dictation")], dictationDir: dictationDir, writingDir: writingDir)
        XCTAssertFalse(dictationOnly.items.contains { $0.kind == .writing })
    }

    // MARK: - status / telemetry policy

    func testStatusReportsWritingDirectoriesAndCounts() throws {
        let writingDir = try makeWritingDir()
        let directories = TranscriptedDataDirectories(
            meetingsDir: tempDir,
            dictationsDir: tempDir,
            writingDir: writingDir,
            indexDir: tempDir
        )
        try index.reconcile(meetingDirs: [], dictationDirs: [], writingDirs: directories.writingDirs)

        let result = try handleStatus(index: index, directories: directories)
        let status = try JSONDecoder().decode(StatusResult.self, from: Data(try text(result).utf8))

        XCTAssertEqual(status.writingDirectories, [writingDir.path])
        XCTAssertEqual(status.indexedWritingDays, 1)
        XCTAssertEqual(status.indexedWritingEntries, 2)
    }

    func testWritingCaptureKindSurvivesTelemetryPolicy() {
        let sanitized = AgentCaptureQueryTelemetryPolicy.sanitize([
            "client_family": "mcp",
            "capture_kind": "writing",
            "tool_kind": "read",
        ])
        XCTAssertEqual(sanitized["capture_kind"], "writing")
    }

    func testWritingToolsCarryWritingTelemetryDescriptor() throws {
        for (tool, toolKind) in [("list_writing", "list"), ("read_writing", "read")] {
            _ = withAgentCaptureQueryTelemetry(params: CallTool.Parameters(name: tool, arguments: [:])) {
                textResult("ok")
            }
            XCTAssertEqual(telemetry.observations.last?.toolKind, toolKind)
            XCTAssertEqual(telemetry.observations.last?.captureKind, "writing")
        }

        _ = withAgentCaptureQueryTelemetry(
            params: CallTool.Parameters(name: "recent_context", arguments: ["kind": .string("writing")])
        ) {
            textResult("ok")
        }
        XCTAssertEqual(telemetry.observations.last?.captureKind, "writing")
    }

    // MARK: - Helpers

    private func makeWritingDir() throws -> URL {
        let writingDir = tempDir.appendingPathComponent("writing", isDirectory: true).creatingDirectory()
        try writeFixture(makeWritingDayMarkdown(), filename: "Writing_2026-09-25", to: writingDir)
        return writingDir
    }

    private func searchContext(_ arguments: [String: Value], dictationDir: URL, writingDir: URL) throws -> ContextSearchResult {
        let result = try handleSearchContext(
            params: CallTool.Parameters(name: "search_context", arguments: arguments),
            index: index,
            meetingDirs: [],
            dictationDirs: [dictationDir],
            writingDirs: [writingDir]
        )
        return try JSONDecoder().decode(ContextSearchResult.self, from: Data(try text(result).utf8))
    }

    private func recentContext(_ arguments: [String: Value], dictationDir: URL, writingDir: URL) throws -> RecentContextResult {
        let result = try handleRecentContext(
            params: CallTool.Parameters(name: "recent_context", arguments: arguments),
            index: index,
            meetingDirs: [],
            dictationDirs: [dictationDir],
            writingDirs: [writingDir]
        )
        return try JSONDecoder().decode(RecentContextResult.self, from: Data(try text(result).utf8))
    }

    private func text(_ result: CallTool.Result) throws -> String {
        guard case .text(let text, _, _) = try XCTUnwrap(result.content.first) else {
            XCTFail("Expected text content")
            return ""
        }
        return text
    }
}

private final class WritingRecordingTelemetry: AgentCaptureQueryTelemetryRecording {
    private(set) var observations: [AgentCaptureQueryObservation] = []

    func track(_ observation: AgentCaptureQueryObservation) {
        observations.append(observation)
    }
}

private extension URL {
    func creatingDirectory() -> URL {
        try! FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}
