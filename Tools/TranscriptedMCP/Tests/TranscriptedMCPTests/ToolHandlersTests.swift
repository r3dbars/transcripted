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
        // A standalone helper with no saved build info, whatever is installed
        // on this Mac.
        let emptyAppSupport = tempDir!
        AgentCaptureQueryTelemetryRuntime.buildIdentity = {
            .resolve(environment: [:], bundleInfo: nil, appSupportDirectory: emptyAppSupport)
        }
    }

    override func tearDown() {
        AgentCaptureQueryTelemetryRuntime.recorder = AgentCaptureQueryTelemetry.shared
        AgentCaptureQueryTelemetryRuntime.buildIdentity = { .resolve() }
        telemetry = nil
        index = nil
        removeTempDir(tempDir)
        super.tearDown()
    }

    func testSearchHydratesMeetingFrontmatterTitlesAndFiltersByKind() throws {
        let meetingDir = tempDir.appendingPathComponent("meetings", isDirectory: true)
        let dictationDir = tempDir.appendingPathComponent("dictations", isDirectory: true)
        let writingDir = tempDir.appendingPathComponent("writing", isDirectory: true)
        for dir in [meetingDir, dictationDir, writingDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        try writeFixture(
            makeFixtureJSON(
                title: "Roadmap Sync",
                date: "2026-03-26T16:04:11-0500",
                utterances: [("system_0", 0.0, 5.0, "Let's finalize the roadmap pricing plan")]
            ),
            filename: "Call_2026-03-26_16-04-11",
            to: meetingDir
        )
        try writeFixture(
            makeFixtureJSON(
                date: "2026-03-27T11:00:00-0500",
                utterances: [("mic_0", 0.0, 5.0, "Quick untitled roadmap check-in")]
            ),
            filename: "Call_2026-03-27_11-00-00",
            to: meetingDir
        )
        try writeFixture(
            makeDictationDayJSON(entries: [
                ("dictation-20260407-091500-000", "2026-04-07T09:15:00-0500", "Roadmap memo", "Send roadmap follow-up notes", "Slack", "copied"),
            ]),
            filename: "Dictations_2026-04-07",
            to: dictationDir
        )
        try writeFixture(
            makeWritingDayMarkdown(date: "2026-09-25", entries: [
                ("writing-20260925-104211-001", "2026-09-25T15:42:11.000Z", "10:42 AM - Roadmap draft", "Notes", nil, 5, 32, 0, "Drafting the Q4 roadmap update"),
            ]),
            filename: "Writing_2026-09-25",
            to: writingDir
        )
        try index.reconcile(meetingDirs: [meetingDir], dictationDirs: [dictationDir], writingDirs: [writingDir])

        // Unified search across all three capture kinds.
        let allResult = try handleSearch(
            params: CallTool.Parameters(name: "search", arguments: ["query": .string("roadmap")]),
            index: index,
            meetingDirs: [meetingDir],
            dictationDirs: [dictationDir],
            writingDirs: [writingDir]
        )
        XCTAssertNotEqual(allResult.isError, true)
        let allDecoded = try JSONDecoder().decode(ContextSearchResult.self, from: Data(resultText(allResult).utf8))
        XCTAssertEqual(Set(allDecoded.results.map(\.kind)), [.meeting, .dictation, .writing])
        XCTAssertEqual(telemetry.observations.last?.toolKind, "search")
        XCTAssertEqual(telemetry.observations.last?.captureKind, "mixed")

        let titled = try XCTUnwrap(allDecoded.results.first { $0.filename == "Call_2026-03-26_16-04-11" })
        XCTAssertEqual(titled.title, "Roadmap Sync")
        let untitled = try XCTUnwrap(allDecoded.results.first { $0.filename == "Call_2026-03-27_11-00-00" })
        XCTAssertEqual(untitled.title, "Call_2026-03-27_11-00-00")

        // Filter to meetings only.
        let meetingsOnly = try handleSearch(
            params: CallTool.Parameters(name: "search", arguments: ["query": .string("roadmap"), "kind": .string("meeting")]),
            index: index,
            meetingDirs: [meetingDir],
            dictationDirs: [dictationDir],
            writingDirs: [writingDir]
        )
        let meetingsDecoded = try JSONDecoder().decode(ContextSearchResult.self, from: Data(resultText(meetingsOnly).utf8))
        XCTAssertEqual(meetingsDecoded.results.count, 2)
        XCTAssertTrue(meetingsDecoded.results.allSatisfy { $0.kind == .meeting })
        XCTAssertEqual(telemetry.observations.last?.captureKind, "meeting")

        // Filter by speaker restricts to matching meeting utterances.
        let bySpeaker = try handleSearch(
            params: CallTool.Parameters(name: "search", arguments: ["query": .string("roadmap"), "speaker": .string("Jenny")]),
            index: index,
            meetingDirs: [meetingDir],
            dictationDirs: [dictationDir],
            writingDirs: [writingDir]
        )
        let speakerDecoded = try JSONDecoder().decode(ContextSearchResult.self, from: Data(resultText(bySpeaker).utf8))
        XCTAssertEqual(speakerDecoded.results.map(\.filename), ["Call_2026-03-26_16-04-11"])

        // Filter to writing only.
        let writingOnly = try handleSearch(
            params: CallTool.Parameters(name: "search", arguments: ["query": .string("roadmap"), "kind": .string("writing")]),
            index: index,
            meetingDirs: [meetingDir],
            dictationDirs: [dictationDir],
            writingDirs: [writingDir]
        )
        let writingDecoded = try JSONDecoder().decode(ContextSearchResult.self, from: Data(resultText(writingOnly).utf8))
        XCTAssertEqual(writingDecoded.results.map(\.kind), [.writing])
        XCTAssertEqual(telemetry.observations.last?.captureKind, "writing")

        // Filter to dictation only.
        let dictationOnly = try handleSearch(
            params: CallTool.Parameters(name: "search", arguments: ["query": .string("roadmap"), "kind": .string("dictation")]),
            index: index,
            meetingDirs: [meetingDir],
            dictationDirs: [dictationDir],
            writingDirs: [writingDir]
        )
        XCTAssertNotEqual(dictationOnly.isError, true)
        let dictationDecoded = try JSONDecoder().decode(ContextSearchResult.self, from: Data(resultText(dictationOnly).utf8))
        XCTAssertEqual(dictationDecoded.results.map(\.kind), [.dictation])
        XCTAssertEqual(dictationDecoded.results.map(\.filename), ["Dictations_2026-04-07"])
        XCTAssertEqual(telemetry.observations.last?.captureKind, "dictation")

        // Speaker filter with a non-meeting kind skips non-meeting tables cleanly
        // and returns a kind-scoped empty response (not an error).
        let dictationWithSpeaker = try handleSearch(
            params: CallTool.Parameters(
                name: "search",
                arguments: [
                    "query": .string("roadmap"),
                    "kind": .string("dictation"),
                    "speaker": .string("Jenny"),
                ]
            ),
            index: index,
            meetingDirs: [meetingDir],
            dictationDirs: [dictationDir],
            writingDirs: [writingDir]
        )
        XCTAssertNotEqual(dictationWithSpeaker.isError, true)
        let dictationWithSpeakerPayload = try JSONDecoder().decode(
            EmptyQueryResult.self,
            from: Data(resultText(dictationWithSpeaker).utf8)
        )
        XCTAssertEqual(dictationWithSpeakerPayload.searchedDirectories, [dictationDir.path])
        XCTAssertEqual(dictationWithSpeakerPayload.indexedDictationDays, 1)
        XCTAssertNil(dictationWithSpeakerPayload.indexedMeetings)
        XCTAssertTrue(dictationWithSpeakerPayload.hint.contains("No dictations matched"))

        let writingWithSpeaker = try handleSearch(
            params: CallTool.Parameters(
                name: "search",
                arguments: [
                    "query": .string("roadmap"),
                    "kind": .string("writing"),
                    "speaker": .string("Jenny"),
                ]
            ),
            index: index,
            meetingDirs: [meetingDir],
            dictationDirs: [dictationDir],
            writingDirs: [writingDir]
        )
        XCTAssertNotEqual(writingWithSpeaker.isError, true)
        let writingWithSpeakerPayload = try JSONDecoder().decode(
            EmptyQueryResult.self,
            from: Data(resultText(writingWithSpeaker).utf8)
        )
        XCTAssertEqual(writingWithSpeakerPayload.searchedDirectories, [writingDir.path])
        XCTAssertEqual(writingWithSpeakerPayload.indexedWritingDays, 1)
        XCTAssertNil(writingWithSpeakerPayload.indexedMeetings)
        XCTAssertTrue(writingWithSpeakerPayload.hint.contains("No writing matched"))
    }

    func testSearchSemanticModeMatchesParaphraseThroughHandler() throws {
        let semanticDir = makeTempDir()
        defer { removeTempDir(semanticDir) }
        let semanticIndex = try TranscriptIndex(
            indexDir: semanticDir,
            embeddingProvider: ToolHandlerStubEmbeddingProvider()
        )
        try writeFixture(
            makeFixtureJSON(
                title: "Pricing Review",
                date: "2026-03-26T16:04:11-0500",
                utterances: [
                    ("system_0", 0.0, 5.0, "Honestly they balked at the cost"),
                    ("mic_0", 5.0, 10.0, "The weather looks sunny tomorrow"),
                ]
            ),
            filename: "Call_2026-03-26_16-04-11",
            to: semanticDir
        )
        try semanticIndex.reconcile(meetingsDir: semanticDir, dictationsDir: semanticDir)

        let lexicalResult = try handleSearch(
            params: CallTool.Parameters(
                name: "search",
                arguments: ["query": .string("pricing pushback"), "mode": .string("lexical")]
            ),
            index: semanticIndex,
            meetingDirs: [semanticDir],
            dictationDirs: [semanticDir]
        )
        XCTAssertNotEqual(lexicalResult.isError, true)
        let lexicalEmpty = try JSONDecoder().decode(EmptyQueryResult.self, from: Data(resultText(lexicalResult).utf8))
        XCTAssertEqual(lexicalEmpty.indexedMeetings, 1)

        let semanticResult = try handleSearch(
            params: CallTool.Parameters(
                name: "search",
                arguments: ["query": .string("pricing pushback"), "mode": .string("semantic")]
            ),
            index: semanticIndex,
            meetingDirs: [semanticDir],
            dictationDirs: [semanticDir]
        )
        XCTAssertNotEqual(semanticResult.isError, true)
        let decoded = try JSONDecoder().decode(ContextSearchResult.self, from: Data(resultText(semanticResult).utf8))
        XCTAssertEqual(decoded.results.map(\.filename), ["Call_2026-03-26_16-04-11"])
        XCTAssertEqual(decoded.results.first?.title, "Pricing Review")
        XCTAssertEqual(telemetry.observations.last?.toolKind, "search")
        XCTAssertEqual(telemetry.observations.last?.captureKind, "meeting")
    }

    func testSearchRespectsDateFromOnlyAndDateToOnlyWindows() throws {
        try writeFixture(
            makeFixtureJSON(
                title: "Early Sync",
                date: "2026-03-10T10:00:00-0500",
                utterances: [("system_0", 0.0, 5.0, "Discussing launch readiness")]
            ),
            filename: "Call_2026-03-10_10-00-00",
            to: tempDir
        )
        try writeFixture(
            makeFixtureJSON(
                title: "Mid Sync",
                date: "2026-03-20T10:00:00-0500",
                utterances: [("system_0", 0.0, 5.0, "Discussing launch readiness")]
            ),
            filename: "Call_2026-03-20_10-00-00",
            to: tempDir
        )
        try writeFixture(
            makeFixtureJSON(
                title: "Late Sync",
                date: "2026-03-30T10:00:00-0500",
                utterances: [("system_0", 0.0, 5.0, "Discussing launch readiness")]
            ),
            filename: "Call_2026-03-30_10-00-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let fromOnly = try handleSearch(
            params: CallTool.Parameters(
                name: "search",
                arguments: ["query": .string("launch"), "date_from": .string("2026-03-20")]
            ),
            index: index,
            meetingDirs: [tempDir]
        )
        let fromDecoded = try JSONDecoder().decode(ContextSearchResult.self, from: Data(resultText(fromOnly).utf8))
        XCTAssertEqual(
            Set(fromDecoded.results.map(\.filename)),
            ["Call_2026-03-20_10-00-00", "Call_2026-03-30_10-00-00"]
        )

        let toOnly = try handleSearch(
            params: CallTool.Parameters(
                name: "search",
                arguments: ["query": .string("launch"), "date_to": .string("2026-03-20")]
            ),
            index: index,
            meetingDirs: [tempDir]
        )
        let toDecoded = try JSONDecoder().decode(ContextSearchResult.self, from: Data(resultText(toOnly).utf8))
        XCTAssertEqual(
            Set(toDecoded.results.map(\.filename)),
            ["Call_2026-03-10_10-00-00", "Call_2026-03-20_10-00-00"]
        )
    }

    func testSearchSingleKindEmptyRepliesReportOnlyRequestedKindScope() throws {
        let meetingDir = tempDir.appendingPathComponent("meetings", isDirectory: true)
        let dictationDir = tempDir.appendingPathComponent("dictations", isDirectory: true)
        let writingDir = tempDir.appendingPathComponent("writing", isDirectory: true)
        for dir in [meetingDir, dictationDir, writingDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        let meetingEmpty = try handleSearch(
            params: CallTool.Parameters(name: "search", arguments: ["query": .string("missing"), "kind": .string("meeting")]),
            index: index,
            meetingDirs: [meetingDir],
            dictationDirs: [dictationDir],
            writingDirs: [writingDir]
        )
        let meetingPayload = try JSONDecoder().decode(EmptyQueryResult.self, from: Data(resultText(meetingEmpty).utf8))
        XCTAssertEqual(meetingPayload.searchedDirectories, [meetingDir.path])
        XCTAssertEqual(meetingPayload.indexedMeetings, 0)
        XCTAssertNil(meetingPayload.indexedDictationDays)
        XCTAssertNil(meetingPayload.indexedWritingDays)
        XCTAssertTrue(meetingPayload.hint.contains("No meetings are indexed"))

        let dictationEmpty = try handleSearch(
            params: CallTool.Parameters(name: "search", arguments: ["query": .string("missing"), "kind": .string("dictation")]),
            index: index,
            meetingDirs: [meetingDir],
            dictationDirs: [dictationDir],
            writingDirs: [writingDir]
        )
        let dictationPayload = try JSONDecoder().decode(EmptyQueryResult.self, from: Data(resultText(dictationEmpty).utf8))
        XCTAssertEqual(dictationPayload.searchedDirectories, [dictationDir.path])
        XCTAssertNil(dictationPayload.indexedMeetings)
        XCTAssertEqual(dictationPayload.indexedDictationDays, 0)
        XCTAssertEqual(dictationPayload.indexedDictationEntries, 0)
        XCTAssertNil(dictationPayload.indexedWritingDays)
        XCTAssertTrue(dictationPayload.hint.contains("No dictations are indexed"))

        let writingEmpty = try handleSearch(
            params: CallTool.Parameters(name: "search", arguments: ["query": .string("missing"), "kind": .string("writing")]),
            index: index,
            meetingDirs: [meetingDir],
            dictationDirs: [dictationDir],
            writingDirs: [writingDir]
        )
        let writingPayload = try JSONDecoder().decode(EmptyQueryResult.self, from: Data(resultText(writingEmpty).utf8))
        XCTAssertEqual(writingPayload.searchedDirectories, [writingDir.path])
        XCTAssertNil(writingPayload.indexedMeetings)
        XCTAssertNil(writingPayload.indexedDictationDays)
        XCTAssertEqual(writingPayload.indexedWritingDays, 0)
        XCTAssertEqual(writingPayload.indexedWritingEntries, 0)
        XCTAssertTrue(writingPayload.hint.contains("No writing is indexed"))
        XCTAssertTrue(writingPayload.hint.contains("Capture my writing is on (Transcripted › Agent page)"))
    }

    func testSearchContextAliasTracksSearchTelemetry() throws {
        try writeFixture(
            makeFixtureJSON(
                title: "Roadmap Sync",
                date: "2026-03-26T16:04:11-0500",
                utterances: [("system_0", 0.0, 5.0, "Legacy alias roadmap discussion")]
            ),
            filename: "Call_2026-03-26_16-04-11",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let params = CallTool.Parameters(name: "search_context", arguments: ["query": .string("roadmap")])
        let result = try withAgentCaptureQueryTelemetry(params: params) {
            try handleSearch(params: params, index: index, meetingDirs: [tempDir])
        }
        XCTAssertNotEqual(result.isError, true)
        XCTAssertEqual(telemetry.observations.last?.toolKind, "search")
        XCTAssertEqual(telemetry.observations.last?.captureKind, "meeting")
        XCTAssertEqual(telemetry.observations.last?.result, "success")
    }

    func testWhoIsReturnsSpeakerProfileAndTracksTelemetry() throws {
        try writeFixture(
            makeFixtureJSON(title: "Roadmap Sync", date: "2026-03-26T16:04:11-0500"),
            filename: "Call_2026-03-26_16-04-11",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let foundParams = CallTool.Parameters(name: "who_is", arguments: ["speaker": .string("Jenny")])
        let foundResult = try withAgentCaptureQueryTelemetry(params: foundParams) {
            try handleWhoIs(params: foundParams, index: index)
        }
        XCTAssertNotEqual(foundResult.isError, true)
        let profile = try JSONDecoder().decode(PersonProfile.self, from: Data(resultText(foundResult).utf8))
        XCTAssertEqual(profile.name, "Jenny Wen")
        XCTAssertEqual(profile.meetingCount, 1)
        XCTAssertEqual(telemetry.observations.last?.toolKind, "speaker_lookup")
        XCTAssertEqual(telemetry.observations.last?.captureKind, "meeting")
        XCTAssertEqual(telemetry.observations.last?.result, "success")

        let missingParams = CallTool.Parameters(name: "who_is", arguments: ["speaker": .string("Nobody Known")])
        let missingResult = try withAgentCaptureQueryTelemetry(params: missingParams) {
            try handleWhoIs(params: missingParams, index: index)
        }
        XCTAssertNotEqual(missingResult.isError, true)
        XCTAssertTrue(try resultText(missingResult).contains("No meetings found"))
        XCTAssertEqual(telemetry.observations.last?.result, "empty_not_found")
    }

    func testListMeetingsTracksBucketedAgentQueryTelemetry() throws {
        try writeFixture(
            makeFixtureJSON(title: "Roadmap Sync", date: "2026-03-26T16:04:11-0500"),
            filename: "Call_2026-03-26_16-04-11",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let params = CallTool.Parameters(name: "list_meetings", arguments: ["count": .int(10)])
        var clockValues: [TimeInterval] = [10, 10.32]
        _ = try withAgentCaptureQueryTelemetry(
            params: params,
            clock: { clockValues.removeFirst() },
            buildIdentity: AgentCaptureQueryBuildIdentity(
                appVersion: "1.2.3",
                buildChannel: "release",
                buildRevision: "abc123def456"
            )
        ) {
            try handleListMeetings(
                params: params,
                index: index,
                meetingDirs: [tempDir]
            )
        }

        XCTAssertEqual(telemetry.observations.count, 1)
        let observation = try XCTUnwrap(telemetry.observations.last)
        XCTAssertEqual(observation.toolKind, "list")
        XCTAssertEqual(observation.captureKind, "meeting")
        XCTAssertEqual(observation.result, "success")
        XCTAssertEqual(observation.sourceCountBucket, "1")
        XCTAssertEqual(observation.resultCountBucket, "1")
        XCTAssertEqual(observation.latencyBucket, "250_499ms")
        XCTAssertEqual(observation.buildIdentity.appVersion, "1.2.3")
        XCTAssertEqual(observation.buildIdentity.buildChannel, "release")
        XCTAssertEqual(observation.buildIdentity.buildRevision, "abc123def456")
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
        XCTAssertEqual(observation.resultCountBucket, "1")
    }

    func testEmptyQueryEmitsOneEmptyNotFoundTerminalEvent() throws {
        let params = CallTool.Parameters(name: "list_meetings", arguments: ["count": .int(10)])
        let result = try withAgentCaptureQueryTelemetry(params: params) {
            try handleListMeetings(params: params, index: index, meetingDirs: [tempDir])
        }

        XCTAssertNotEqual(result.isError, true)
        XCTAssertEqual(telemetry.observations.count, 1)
        let observation = try XCTUnwrap(telemetry.observations.first)
        XCTAssertEqual(observation.toolKind, "list")
        XCTAssertEqual(observation.captureKind, "meeting")
        XCTAssertEqual(observation.result, "empty_not_found")
        XCTAssertEqual(observation.sourceCountBucket, "0")
        XCTAssertEqual(observation.resultCountBucket, "0")
    }

    func testInvalidQueryEmitsOneInvalidInputTerminalEvent() throws {
        let params = CallTool.Parameters(name: "search", arguments: ["query": .string("   ")])
        let result = try withAgentCaptureQueryTelemetry(params: params) {
            try handleSearch(params: params, index: index, meetingDirs: [tempDir])
        }

        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(telemetry.observations.count, 1)
        let observation = try XCTUnwrap(telemetry.observations.first)
        XCTAssertEqual(observation.toolKind, "search")
        XCTAssertEqual(observation.captureKind, "mixed")
        XCTAssertEqual(observation.result, "invalid_input")
        XCTAssertEqual(observation.sourceCountBucket, "unknown")
        XCTAssertEqual(observation.resultCountBucket, "unknown")
    }

    func testMissingCaptureEmitsOneEmptyNotFoundTerminalEvent() throws {
        let params = CallTool.Parameters(
            name: "read_meeting",
            arguments: ["filename": .string("Call_missing")]
        )
        let result = try withAgentCaptureQueryTelemetry(params: params) {
            try handleReadMeeting(params: params, meetingDirs: [tempDir])
        }

        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(telemetry.observations.count, 1)
        let observation = try XCTUnwrap(telemetry.observations.first)
        XCTAssertEqual(observation.toolKind, "read")
        XCTAssertEqual(observation.captureKind, "meeting")
        XCTAssertEqual(observation.result, "empty_not_found")
        XCTAssertEqual(observation.sourceCountBucket, "0")
        XCTAssertEqual(observation.resultCountBucket, "0")
    }

    func testThrownQueryEmitsOneInternalErrorTerminalEvent() throws {
        let params = CallTool.Parameters(name: "search", arguments: ["query": .string("topic"), "kind": .string("meeting")])

        XCTAssertThrowsError(
            try withAgentCaptureQueryTelemetry(params: params) {
                throw SyntheticAgentCaptureQueryError.failure
            }
        )

        XCTAssertEqual(telemetry.observations.count, 1)
        let observation = try XCTUnwrap(telemetry.observations.first)
        XCTAssertEqual(observation.toolKind, "search")
        XCTAssertEqual(observation.captureKind, "meeting")
        XCTAssertEqual(observation.result, "internal_error")
        XCTAssertEqual(observation.sourceCountBucket, "unknown")
        XCTAssertEqual(observation.resultCountBucket, "unknown")
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
        XCTAssertEqual(observation.resultCountBucket, "2_3")
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
        XCTAssertEqual(payload.indexedWritingDays, 0)
        XCTAssertEqual(payload.indexedWritingEntries, 0)
    }

    func testStatusToolReportsZeroCountsOnEmptyIndex() throws {
        let directories = TranscriptedDataDirectories(meetingsDir: tempDir, dictationsDir: tempDir, indexDir: tempDir)
        let result = try handleStatus(index: index, directories: directories)

        let payload = try JSONDecoder().decode(StatusResult.self, from: Data(resultText(result).utf8))
        XCTAssertEqual(payload.indexedMeetings, 0)
        XCTAssertEqual(payload.indexedDictationDays, 0)
        XCTAssertEqual(payload.indexedDictationEntries, 0)
        XCTAssertEqual(payload.indexedWritingDays, 0)
        XCTAssertEqual(payload.indexedWritingEntries, 0)
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
        XCTAssertEqual(telemetry.observations.last?.resultCountBucket, "2_3")
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
        XCTAssertEqual(properties["result_count_bucket"], "2_3")
        XCTAssertEqual(properties["latency_bucket"], "unknown")
        XCTAssertNil(properties["app_version"], "standalone helper version must never masquerade as the app version")
        XCTAssertNil(properties["build_channel"])
        XCTAssertNil(properties["build_revision"])
        let propertyKeys = Set(properties.keys)
        XCTAssertTrue(
            AgentCaptureQueryTelemetryPolicy.requiredProperties
                .union(["distinct_id"])
                .isSubset(of: propertyKeys)
        )
        XCTAssertTrue(
            propertyKeys.isSubset(of: AgentCaptureQueryTelemetryPolicy.allowedProperties.union(["distinct_id"]))
        )
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
        XCTAssertEqual(telemetry.observations.last?.resultCountBucket, "2_3")
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
        XCTAssertEqual(telemetry.observations.last?.sourceCountBucket, "1")
        XCTAssertEqual(telemetry.observations.last?.resultCountBucket, "2_3")
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
        XCTAssertEqual(telemetry.observations.last?.sourceCountBucket, "1")
        XCTAssertEqual(telemetry.observations.last?.resultCountBucket, "1")
    }

    /// A huge `limit` from an agent must return the rest of the day, not trap
    /// the server on integer overflow.
    func testReadDictationHugeLimitReturnsRemainingEntriesWithoutTrapping() throws {
        let entries: [(id: String, createdAt: String, title: String, text: String, sourceAppName: String, delivery: String)] = [
            ("dictation-20260407-091500-000", "2026-04-07T09:15:00-0500", "First note", "Alpha text", "Slack", "copied"),
            ("dictation-20260407-120000-000", "2026-04-07T12:00:00-0500", "Second note", "Beta text", "Mail", "pasted"),
            ("dictation-20260407-183000-000", "2026-04-07T18:30:00-0500", "Third note", "Gamma text", "Notes", "copied"),
        ]
        try writeFixture(makeDictationDayJSON(entries: entries), filename: "Dictations_2026-04-07", to: tempDir)

        let result = try handleReadDictation(
            params: CallTool.Parameters(name: "read_dictation", arguments: [
                "filename": .string("Dictations_2026-04-07"),
                "offset": .int(1),
                "limit": .int(Int.max),
            ]),
            dictationDirs: [tempDir]
        )

        XCTAssertNotEqual(result.isError, true)
        let page = try JSONDecoder().decode(DictationDayPage.self, from: Data(resultText(result).utf8))
        XCTAssertEqual(page.totalEntries, 3)
        XCTAssertEqual(page.returned, 2)
        XCTAssertFalse(page.truncated)
        XCTAssertNil(page.nextOffset)
        XCTAssertEqual(page.entries.map(\.title), ["Second note", "Third note"])
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
        XCTAssertEqual(telemetry.observations.last?.resultCountBucket, "1")
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

private enum SyntheticAgentCaptureQueryError: Error {
    case failure
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
              let properties = object["properties"] as? [String: Any] else {
            return
        }
        self.properties = properties.compactMapValues { $0 as? String }
    }
}

private struct ToolHandlerStubEmbeddingProvider: EmbeddingProvider {
    let modelID = "tool-handler-stub.v1"
    var dimension: Int { Self.concepts.count }
    var isAvailable: Bool { true }

    private static let concepts: [[String]] = [
        ["cost", "pricing", "price", "expensive", "balked", "pushback", "budget"],
        ["weather", "sunny", "rain", "cloudy", "forecast"],
    ]

    func embed(_ text: String) -> [Float]? {
        var lex: [String: Int] = [:]
        for (idx, words) in Self.concepts.enumerated() {
            for word in words { lex[word] = idx }
        }
        var vec = [Float](repeating: 0, count: Self.concepts.count)
        var hits = 0
        for token in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            if let idx = lex[String(token)] {
                vec[idx] += 1
                hits += 1
            }
        }
        guard hits > 0 else { return nil }
        return VectorMath.normalized(vec)
    }
}
