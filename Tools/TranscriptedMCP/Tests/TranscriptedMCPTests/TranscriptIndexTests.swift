import SQLite3
import XCTest
@testable import transcripted_mcp

final class TranscriptIndexTests: XCTestCase {
    var index: TranscriptIndex!
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = makeTempDir()
        index = try! TranscriptIndex(indexDir: tempDir)
    }

    override func tearDown() {
        index = nil
        removeTempDir(tempDir)
        super.tearDown()
    }

    func testEmptyIndexReturnsNoResults() throws {
        let results = try index.searchUtterances(query: "hello", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertTrue(results.results.isEmpty)
    }

    func testEmptyIndexListsNoMeetings() throws {
        let meetings = try index.listRecentMeetings(count: 10)
        XCTAssertTrue(meetings.isEmpty)
    }

    func testIndexAndSearchSingleUtterance() throws {
        let fixture = makeFixtureJSON(utterances: [
            ("system_0", 0.0, 5.0, "Let's discuss the product roadmap"),
        ])
        try writeFixture(fixture, filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let results = try index.searchUtterances(query: "roadmap", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(results.results.count, 1)
        XCTAssertEqual(results.results[0].snippets.count, 1)
        XCTAssertTrue(results.results[0].snippets[0].text.contains("roadmap"))
    }

    func testPorterStemming() throws {
        let fixture = makeFixtureJSON(utterances: [
            ("mic_0", 0.0, 3.0, "We were designing the new feature"),
        ])
        try writeFixture(fixture, filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        // "design" should match "designing" via porter stemming
        let results = try index.searchUtterances(query: "design", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertFalse(results.results.isEmpty)
    }

    func testSpeakerFilter() throws {
        let fixture = makeFixtureJSON(utterances: [
            ("system_0", 0.0, 5.0, "Product is looking great"),
            ("mic_0", 5.0, 10.0, "I agree about the product"),
        ])
        try writeFixture(fixture, filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let results = try index.searchUtterances(query: "product", speaker: "Jenny", dateFrom: nil, dateTo: nil)
        XCTAssertEqual(results.results.count, 1)
        XCTAssertEqual(results.results[0].snippets.count, 1)
        XCTAssertEqual(results.results[0].snippets[0].speaker, "Jenny Wen")
    }

    func testDateRangeFilter() throws {
        let fixture1 = makeFixtureJSON(date: "2026-03-28T10:00:00-0500", utterances: [
            ("mic_0", 0.0, 3.0, "Old meeting discussion"),
        ])
        let fixture2 = makeFixtureJSON(date: "2026-03-30T10:00:00-0500", utterances: [
            ("mic_0", 0.0, 3.0, "New meeting discussion"),
        ])
        try writeFixture(fixture1, filename: "Call_2026-03-28_10-00-00", to: tempDir)
        try writeFixture(fixture2, filename: "Call_2026-03-30_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let results = try index.searchUtterances(query: "meeting", speaker: nil, dateFrom: "2026-03-29", dateTo: nil)
        XCTAssertEqual(results.results.count, 1)
        XCTAssertTrue(results.results[0].snippets[0].text.contains("New"))
    }

    func testReconcileRemovesDeletedFiles() throws {
        let fixture = makeFixtureJSON(utterances: [("mic_0", 0.0, 3.0, "Temporary")])
        try writeFixture(fixture, filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        XCTAssertEqual(try index.listRecentMeetings(count: 10).count, 1)

        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("Call_2026-03-29_10-00-00.md"))
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        XCTAssertEqual(try index.listRecentMeetings(count: 10).count, 0)
    }

    func testIndexSingleFileKeepsHigherPriorityDuplicateBasename() throws {
        let currentDir = makeTempDir()
        let legacyDir = makeTempDir()
        defer {
            removeTempDir(currentDir)
            removeTempDir(legacyDir)
        }

        let filename = "Call_2026-03-29_10-00-00"
        try writeFixture(
            makeFixtureJSON(utterances: [("mic_0", 0.0, 3.0, "Current root content")]),
            filename: filename,
            to: currentDir
        )
        try writeFixture(
            makeFixtureJSON(utterances: [("mic_0", 0.0, 3.0, "Legacy root content")]),
            filename: filename,
            to: legacyDir
        )

        try index.reconcile(meetingDirs: [currentDir, legacyDir], dictationDirs: [])
        try index.indexSingleFile(
            legacyDir.appendingPathComponent("\(filename).md"),
            allowedRoots: [currentDir, legacyDir]
        )

        let currentResults = try index.searchUtterances(query: "Current", speaker: nil, dateFrom: nil, dateTo: nil)
        let legacyResults = try index.searchUtterances(query: "Legacy", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(currentResults.results.count, 1)
        XCTAssertTrue(legacyResults.results.isEmpty)
    }

    func testFileWatcherSignalsDeletes() throws {
        let directory = makeTempDir()
        defer { removeTempDir(directory) }

        var changeCount = 0
        let watcher = FileWatcher(directory: directory) {
            changeCount += 1
        }

        try writeFixture(makeFixtureJSON(), filename: "Call_2026-03-29_10-00-00", to: directory)
        watcher.scanForChanges()
        XCTAssertEqual(changeCount, 1)

        try FileManager.default.removeItem(at: directory.appendingPathComponent("Call_2026-03-29_10-00-00.md"))
        watcher.scanForChanges()
        XCTAssertEqual(changeCount, 2)
    }

    func testMalformedMarkdownIsSkipped() throws {
        try "not markdown".write(to: tempDir.appendingPathComponent("Call_2026-03-29_10-00-00.md"), atomically: true, encoding: .utf8)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let results = try index.listRecentMeetings(count: 10)
        XCTAssertTrue(results.isEmpty)
    }

    func testMalformedDictationMarkdownIsSkipped() throws {
        try "# Dictations with no frontmatter".write(
            to: tempDir.appendingPathComponent("Dictations_2026-04-07.md"),
            atomically: true,
            encoding: .utf8
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        XCTAssertTrue(try index.listDictationDays(count: 10).isEmpty)
        XCTAssertTrue(try index.listRecentContext(kind: .all, count: 10).items.isEmpty)
    }

    func testIndexSingleFileRejectsSymlinkEscape() throws {
        let outsideDir = makeTempDir()
        defer { removeTempDir(outsideDir) }

        let outsideFile = outsideDir.appendingPathComponent("Call_2026-03-29_10-00-00.md")
        try makeFixtureJSON().write(to: outsideFile, atomically: true, encoding: .utf8)

        let symlinkURL = tempDir.appendingPathComponent("Call_2026-03-29_10-00-00.md")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: outsideFile)

        try index.indexSingleFile(symlinkURL, allowedRoots: [tempDir])
        XCTAssertTrue(try index.listRecentMeetings(count: 10).isEmpty)
    }

    func testReconcileIndexesSymlinkedMeetingsRoot() throws {
        let realMeetingsDir = makeTempDir()
        defer { removeTempDir(realMeetingsDir) }

        try writeFixture(
            makeFixtureJSON(utterances: [("mic_0", 0.0, 3.0, "Symlink root roadmap")]),
            filename: "Call_2026-03-29_10-00-00",
            to: realMeetingsDir
        )

        let symlinkRoot = tempDir.appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: realMeetingsDir)

        try index.reconcile(meetingDirs: [symlinkRoot], dictationDirs: [])

        XCTAssertEqual(try index.listRecentMeetings(count: 10).count, 1)
        XCTAssertEqual(
            try index.searchUtterances(query: "roadmap", speaker: nil, dateFrom: nil, dateTo: nil).results.count,
            1
        )
    }

    func testIndexSingleFileAllowsCanonicalSymlinkRootEvent() throws {
        let realMeetingsDir = makeTempDir()
        defer { removeTempDir(realMeetingsDir) }

        let filename = "Call_2026-03-29_10-00-00"
        try writeFixture(makeFixtureJSON(), filename: filename, to: realMeetingsDir)

        let symlinkRoot = tempDir.appendingPathComponent("meetings", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: realMeetingsDir)

        try index.indexSingleFile(
            realMeetingsDir.appendingPathComponent("\(filename).md"),
            allowedRoots: [symlinkRoot]
        )

        XCTAssertEqual(try index.listRecentMeetings(count: 10).count, 1)
    }

    func testFTS5SpecialCharacters() throws {
        let fixture = makeFixtureJSON(utterances: [
            ("mic_0", 0.0, 5.0, "The C++ implementation is ready"),
        ])
        try writeFixture(fixture, filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        // These should not crash even with FTS5 special chars
        _ = try index.searchUtterances(query: "C++", speaker: nil, dateFrom: nil, dateTo: nil)
        _ = try index.searchUtterances(query: "\"quoted phrase\"", speaker: nil, dateFrom: nil, dateTo: nil)
        _ = try index.searchUtterances(query: "AND OR NEAR", speaker: nil, dateFrom: nil, dateTo: nil)
        _ = try index.searchUtterances(query: "(parentheses)", speaker: nil, dateFrom: nil, dateTo: nil)
        _ = try index.searchUtterances(query: "test*wildcard", speaker: nil, dateFrom: nil, dateTo: nil)
    }

    func testSearchGroupsByMeeting() throws {
        // One meeting with many matching utterances
        let fixture = makeFixtureJSON(utterances: [
            ("system_0", 0.0, 5.0, "Let's talk about the roadmap"),
            ("mic_0", 5.0, 10.0, "The roadmap needs updating"),
            ("system_0", 10.0, 15.0, "I agree the roadmap is stale"),
            ("mic_0", 15.0, 20.0, "We should revise the roadmap"),
            ("system_0", 20.0, 25.0, "The roadmap review is next week"),
        ])
        try writeFixture(fixture, filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let results = try index.searchUtterances(query: "roadmap", speaker: nil, dateFrom: nil, dateTo: nil, snippetsPerMeeting: 3)
        XCTAssertEqual(results.results.count, 1) // One meeting
        XCTAssertLessThanOrEqual(results.results[0].snippets.count, 3) // Max 3 snippets
    }

    func testListRecentMeetingsClampsTo50() throws {
        let meetings = try index.listRecentMeetings(count: 999)
        XCTAssertTrue(meetings.isEmpty) // Empty but didn't crash
    }

    func testListRecentMeetingsIncludesSpeakers() throws {
        let fixture = makeFixtureJSON()
        try writeFixture(fixture, filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let meetings = try index.listRecentMeetings(count: 10)
        XCTAssertEqual(meetings.count, 1)
        XCTAssertFalse(meetings[0].speakers.isEmpty)
    }

    func testGetSpeakerHistoryByName() throws {
        let fixture = makeFixtureJSON()
        try writeFixture(fixture, filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let history = try index.getSpeakerHistory(speaker: "Jenny")
        XCTAssertEqual(history.meetingCount, 1)
        XCTAssertEqual(history.matchedName, "Jenny Wen")
    }

    func testGetSpeakerHistoryByUUID() throws {
        let fixture = makeFixtureJSON()
        try writeFixture(fixture, filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let history = try index.getSpeakerHistory(speaker: "80FB272B-6061-4FC4-8408-3F7A974C59DB")
        XCTAssertEqual(history.meetingCount, 1)
    }

    func testGetSpeakerHistoryUnknownSpeaker() throws {
        let history = try index.getSpeakerHistory(speaker: "Nonexistent Person")
        XCTAssertEqual(history.meetingCount, 0)
    }

    func testListDictationDays() throws {
        try writeFixture(makeDictationDayJSON(), filename: "Dictations_2026-04-07", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let days = try index.listDictationDays(count: 10)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].entryCount, 2)
        XCTAssertTrue(days[0].sourceApps.contains("Slack"))
    }

    func testSearchContextReturnsMeetingsAndDictations() throws {
        try writeFixture(makeFixtureJSON(utterances: [
            ("system_0", 0.0, 5.0, "Roadmap meeting update"),
        ]), filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try writeFixture(makeDictationDayJSON(entries: [
            ("dictation-20260407-091500-000", "2026-04-07T09:15:00-0500", "Roadmap note", "Remember the roadmap follow-up after the meeting", "Slack", "copied"),
        ]), filename: "Dictations_2026-04-07", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let results = try index.searchContext(query: "roadmap", speaker: nil, kind: .all, dateFrom: nil, dateTo: nil, maxItems: 10)
        XCTAssertEqual(results.results.count, 2)
        XCTAssertEqual(results.results.first?.kind, .dictation)
        XCTAssertEqual(results.results.last?.kind, .meeting)
    }

    func testSearchContextWithSpeakerFilterDoesNotReturnDictations() throws {
        try writeFixture(makeFixtureJSON(utterances: [
            ("system_0", 0.0, 5.0, "Roadmap meeting update"),
        ]), filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try writeFixture(makeDictationDayJSON(entries: [
            ("dictation-20260407-091500-000", "2026-04-07T09:15:00-0500", "Roadmap note", "Roadmap dictation note", "Slack", "copied"),
        ]), filename: "Dictations_2026-04-07", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let results = try index.searchContext(
            query: "roadmap",
            speaker: "Jenny",
            kind: .all,
            dateFrom: nil,
            dateTo: nil,
            maxItems: 10
        )

        XCTAssertEqual(results.results.count, 1)
        XCTAssertEqual(results.results.first?.kind, .meeting)
    }

    func testRecentContextIncludesDictationEntries() throws {
        try writeFixture(makeFixtureJSON(date: "2026-03-29T10:00:00-0500"), filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try writeFixture(makeDictationDayJSON(), filename: "Dictations_2026-04-07", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let result = try index.listRecentContext(kind: .all, count: 10)
        XCTAssertEqual(result.items.count, 3)
        XCTAssertEqual(result.items.first?.kind, .dictation)
    }

    func testRecentContextMeetingPreviewUsesFirstUtterance() throws {
        try writeFixture(makeFixtureJSON(date: "2026-03-29T10:00:00-0500"), filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let result = try index.listRecentContext(kind: .meeting, count: 10)

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.preview, "Good morning everyone")
    }

    func testRecentContextDeduplicatesSpeakerNames() throws {
        try writeFixture(
            makeFixtureJSON(
                date: "2026-03-29T10:00:00-0500",
                speakers: [
                    ("system_0", "Alex", "80FB272B-6061-4FC4-8408-3F7A974C59DB"),
                    ("system_1", "Alex", "4F57C98D-B6B7-449F-95B9-3521FA99D7DA"),
                ],
                utterances: [
                    ("system_0", 0.0, 5.0, "First shared name"),
                    ("system_1", 5.0, 10.0, "Second shared name"),
                ]
            ),
            filename: "Call_2026-03-29_10-00-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let result = try index.listRecentContext(kind: .meeting, count: 10)

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.speakers, ["Alex"])
    }

    func testRecentContextEmptyMeetingUsesExplicitPreview() throws {
        try writeFixture(
            makeFixtureJSON(
                date: "2026-03-29T10:00:00-0500",
                speakers: [],
                utterances: []
            ),
            filename: "Call_2026-03-29_10-00-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let result = try index.listRecentContext(kind: .meeting, count: 10)

        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.preview, "No transcript captured.")
    }

    // MARK: - Write-transaction failure behavior

    /// Runs raw SQL against the index database through a second connection,
    /// letting tests sabotage the schema underneath a live TranscriptIndex.
    private func execRawSQL(_ sql: String) throws {
        var db: OpaquePointer?
        let path = tempDir.appendingPathComponent("mcp_index.sqlite").path
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            defer { sqlite3_close(db) }
            throw MCPIndexError.databaseOpenFailed("test connection failed for \(path)")
        }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw MCPIndexError.queryFailed(String(cString: sqlite3_errmsg(db)))
        }
    }

    func testFailedUtteranceInsertRollsBackMeetingAndAllowsRetry() throws {
        try writeFixture(makeFixtureJSON(), filename: "Call_2026-03-29_10-00-00", to: tempDir)

        // Sabotage the write path: drop the utterances table so the per-utterance
        // insert fails after the meetings row was already written in-transaction.
        try execRawSQL("DROP TABLE utterances")

        XCTAssertThrowsError(try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir))

        // The transaction must roll back: no half-indexed meeting marked indexed.
        XCTAssertTrue(try index.listRecentMeetings(count: 10).isEmpty)

        // A fresh index (createTables restores the dropped table and triggers)
        // retries the meeting because json_modified_at was never committed.
        index = try TranscriptIndex(indexDir: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        XCTAssertEqual(try index.listRecentMeetings(count: 10).count, 1)
        let results = try index.searchUtterances(query: "roadmap", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(results.results.count, 1)
    }

    func testFailedDictationEntryInsertRollsBackDayAndAllowsRetry() throws {
        try writeFixture(makeDictationDayJSON(), filename: "Dictations_2026-04-07", to: tempDir)

        try execRawSQL("DROP TABLE dictation_entries")

        XCTAssertThrowsError(try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir))

        // The dictation_days row written before the failing entry insert must roll back.
        XCTAssertTrue(try index.listDictationDays(count: 10).isEmpty)

        index = try TranscriptIndex(indexDir: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let days = try index.listDictationDays(count: 10)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(days[0].entryCount, 2)
    }

    func testFailedRemovalRollsBackAndKeepsMeetingSearchable() throws {
        try writeFixture(makeFixtureJSON(), filename: "Call_2026-03-29_10-00-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        XCTAssertEqual(try index.listRecentMeetings(count: 10).count, 1)

        // Sabotage removal mid-transaction: the utterances delete succeeds, then
        // the meeting_speakers delete fails. The whole removal must roll back.
        try execRawSQL("DROP TABLE meeting_speakers")
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("Call_2026-03-29_10-00-00.md"))

        XCTAssertThrowsError(try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir))

        let results = try index.searchUtterances(query: "roadmap", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(results.results.count, 1)
    }

    func testContextSearchResultEncodesStableAgentKeys() throws {
        let result = ContextSearchResult(
            results: [
                ContextSearchGroup(
                    kind: .dictation,
                    title: "Morning note",
                    filename: "Dictations_2026-04-07",
                    entryId: "dictation-20260407-091500-000",
                    date: "2026-04-07",
                    datetime: "2026-04-07T09:15:00-0500",
                    snippets: [
                        ContextSearchSnippet(
                            text: "Ship the follow-up note.",
                            speaker: nil,
                            speakerId: nil,
                            timestamp: nil,
                            sourceAppName: "Slack",
                            delivery: "copied"
                        )
                    ]
                )
            ],
            totalItemsMatched: 1,
            truncated: false
        )

        let json = String(data: try JSONEncoder.pretty.encode(result), encoding: .utf8)

        XCTAssertTrue(json?.contains("\"entry_id\" : \"dictation-20260407-091500-000\"") == true)
        XCTAssertTrue(json?.contains("\"source_app_name\" : \"Slack\"") == true)
        XCTAssertTrue(json?.contains("\"total_items_matched\" : 1") == true)
        XCTAssertTrue(json?.contains("\"truncated\" : false") == true)
    }
}
