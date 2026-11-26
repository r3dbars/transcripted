import SQLite3
import XCTest
@testable import transcripted_mcp

/// parse → index → query coverage for meeting summary search documents and
/// index schema migration / concurrency behavior.
final class SummaryItemIndexTests: XCTestCase {
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

    func testSearchIndexesSummaryTitleAttendeesAndSections() throws {
        try writeFixture(
            makeMeetingWithInlineSummary(
                attendees: ["Jenny", "Priya"],
                decisions: ["Adopt pricing decision memo"],
                actionItems: ["Priya: send launch checklist"],
                openQuestions: ["Should enterprise pricing wait?"]
            ),
            filename: "Call_2026-04-18_09-15-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let decision = try index.searchUtterances(query: "pricing decision", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(decision.results.first?.filename, "Call_2026-04-18_09-15-00")
        XCTAssertEqual(decision.results.first?.snippets.first?.speaker, "Summary")
        XCTAssertTrue(decision.results.first?.snippets.first?.text.contains("Decisions") == true)

        let attendee = try index.searchUtterances(query: "Priya", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(attendee.results.first?.filename, "Call_2026-04-18_09-15-00")
        XCTAssertTrue(attendee.results.first?.snippets.contains(where: { $0.timestamp == "Attendees" }) == true)

        let title = try index.searchUtterances(query: "Beta launch", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(title.results.first?.meetingTitle, "Beta launch sync")
    }

    func testSearchIndexesTitleAndAttendeesWhenFactSectionsAreEmpty() throws {
        try writeFixture(
            makeMeetingWithInlineSummary(
                attendees: ["Priya"],
                decisions: [],
                actionItems: [],
                openQuestions: []
            ),
            filename: "Call_2026-04-18_09-15-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let attendee = try index.searchUtterances(query: "Priya", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(attendee.results.first?.filename, "Call_2026-04-18_09-15-00")
        XCTAssertEqual(attendee.results.first?.snippets.first?.speaker, "Summary")

        let title = try index.searchUtterances(query: "Beta launch", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(title.results.first?.meetingTitle, "Beta launch sync")
    }

    func testSummarySearchRanksAboveRawUtteranceHits() throws {
        try writeFixture(
            makeMeetingWithInlineSummary(
                date: "2026-04-18",
                decisions: ["Pricing decision is to keep the beta free"],
                actionItems: [],
                openQuestions: []
            ).replacingOccurrences(
                of: "[00:00] [System/Jenny] Let's lock the launch.",
                with: "[00:00] [System/Jenny] Raw pricing decision transcript evidence"
            ),
            filename: "Call_2026-04-18_09-15-00",
            to: tempDir
        )
        try writeFixture(
            makeFixtureJSON(
                date: "2026-04-19T09:15:00-0500",
                utterances: [("system_0", 0.0, 5.0, "Raw pricing decision chatter")]
            ),
            filename: "Call_2026-04-19_09-15-00",
            to: tempDir
        )
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        let results = try index.searchUtterances(query: "pricing decision", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(results.results.map(\.filename), [
            "Call_2026-04-18_09-15-00",
            "Call_2026-04-19_09-15-00"
        ])
        XCTAssertEqual(results.results.first?.snippets.first?.speaker, "Summary")
        XCTAssertEqual(results.results.first?.snippets.count, 3)
        XCTAssertTrue(results.results.first?.snippets.contains(where: {
            $0.speaker == "Jenny" && $0.timestamp == "0:00" && $0.text.contains("transcript evidence")
        }) == true)
    }

    func testReindexReplacesSummarySearchDocument() throws {
        let filename = "Call_2026-04-18_09-15-00"
        try writeFixture(makeMeetingWithInlineSummary(decisions: ["Original decision token"]), filename: filename, to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        XCTAssertEqual(try index.searchUtterances(query: "Original decision token", speaker: nil, dateFrom: nil, dateTo: nil).results.count, 1)

        try writeFixture(makeMeetingWithInlineSummary(decisions: ["Replacement decision token"]), filename: filename, to: tempDir)
        let url = tempDir.appendingPathComponent("\(filename).md")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(5)], ofItemAtPath: url.path)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        XCTAssertTrue(try index.searchUtterances(query: "Original decision token", speaker: nil, dateFrom: nil, dateTo: nil).results.isEmpty)
        XCTAssertEqual(try index.searchUtterances(query: "Replacement decision token", speaker: nil, dateFrom: nil, dateTo: nil).results.count, 1)
    }

    func testRemovingMeetingClearsSummarySearchDocument() throws {
        let filename = "Call_2026-04-18_09-15-00"
        try writeFixture(makeMeetingWithInlineSummary(), filename: filename, to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        XCTAssertEqual(try rowCount("SELECT COUNT(*) FROM meeting_summary_documents"), 1)

        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("\(filename).md"))
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        XCTAssertEqual(try rowCount("SELECT COUNT(*) FROM meeting_summary_documents"), 0)
    }

    func testOldMisclassifiedDayIsRebuiltWithoutChangingItsMtime() throws {
        try writeFixture(makeFixtureJSON(), filename: "Renamed", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        XCTAssertEqual(try index.listMeetings(count: 10).count, 1)
        index = nil
        let file = tempDir.appendingPathComponent("Renamed.md")
        let originalDate = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        try makeDictationDayJSON().write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: file.path)
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(tempDir.appendingPathComponent("mcp_index.sqlite").path, &raw), SQLITE_OK)
        let database = try XCTUnwrap(raw)
        XCTAssertEqual(sqlite3_exec(database, "PRAGMA user_version=8", nil, nil, nil), SQLITE_OK)
        sqlite3_close(database)

        let reopened = try TranscriptIndex(indexDir: tempDir)
        try reopened.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        XCTAssertTrue(try reopened.listMeetings(count: 10).isEmpty)
        XCTAssertEqual(try reopened.listDictationDays(count: 10).map(\.filename), ["Renamed"])
    }

    func testOlderSchemaVersionForcesRebuild() throws {
        try writeFixture(makeMeetingWithInlineSummary(), filename: "Call_2026-04-18_09-15-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        XCTAssertEqual(try rowCount("SELECT COUNT(*) FROM meeting_summary_documents"), 1)
        index = nil // close the handle (deinit closes the db)

        let dbPath = tempDir.appendingPathComponent("mcp_index.sqlite").path
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "PRAGMA user_version=1", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        // Reopening trips the schema gate, which wipes the stale index.
        let reopened = try TranscriptIndex(indexDir: tempDir)
        XCTAssertTrue(try reopened.listMeetings(count: 10).isEmpty)

        // A reconcile rebuilds everything, now including summary search documents.
        try reopened.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        XCTAssertEqual(try reopened.listMeetings(count: 10).count, 1)
        XCTAssertEqual(try rowCount("SELECT COUNT(*) FROM meeting_summary_documents"), 1)
    }

    func testRebuildKeepsOtherServersConnectionsWorking() throws {
        // After an update, an agent's server from the old version still has the
        // index open when a new server trips the schema gate. The rebuild must
        // happen in place: deleting the file under that connection left it
        // failing every query with "disk I/O error".
        try writeFixture(makeMeetingWithInlineSummary(), filename: "Call_2026-04-18_09-15-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        let olderServer = try XCTUnwrap(index)

        let dbPath = tempDir.appendingPathComponent("mcp_index.sqlite").path
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "PRAGMA user_version=1", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        let newerServer = try TranscriptIndex(indexDir: tempDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath))
        XCTAssertTrue(try olderServer.listMeetings(count: 10).isEmpty)

        try newerServer.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        XCTAssertEqual(try olderServer.listMeetings(count: 10).count, 1)
        XCTAssertEqual(try newerServer.listMeetings(count: 10).count, 1)
    }

    func testV10UpgradeKeepsLegacySummaryItemsWorkingAndPreservesEmbeddings() throws {
        // Keeping schemaVersion at 10 preserves user embeddings on upgrade and
        // lets live v10 MCP helpers keep touching meeting_summary_items while
        // the current server ignores it except for row cleanup on reindex/remove.
        try writeFixture(makeMeetingWithInlineSummary(), filename: "Call_2026-04-18_09-15-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        index = nil

        let dbPath = tempDir.appendingPathComponent("mcp_index.sqlite").path
        var liveV10: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &liveV10), SQLITE_OK)
        defer { sqlite3_close(liveV10) }

        let seedSQL = """
            PRAGMA user_version=10;
            INSERT INTO meeting_summary_items (filename, kind, position, owner, text, status, due)
                VALUES ('Call_2026-04-18_09-15-00', 'action_item', 0, 'Priya', 'Send launch checklist', 'open', '2026-04-20');
            CREATE TABLE IF NOT EXISTS embedding_meta (
                id INTEGER PRIMARY KEY CHECK (id = 0),
                model_id TEXT NOT NULL,
                dimension INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS utterance_vectors (
                rowid INTEGER PRIMARY KEY,
                vec BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS dictation_entry_vectors (
                rowid INTEGER PRIMARY KEY,
                vec BLOB NOT NULL
            );
            CREATE TABLE IF NOT EXISTS embedding_cache (
                key BLOB PRIMARY KEY,
                vec BLOB NOT NULL,
                last_used INTEGER NOT NULL
            ) WITHOUT ROWID;
            INSERT OR REPLACE INTO embedding_meta (id, model_id, dimension) VALUES (0, 'stub.v1', 3);
            INSERT OR REPLACE INTO utterance_vectors (rowid, vec) VALUES (1, X'0000803F0000000000000000');
            INSERT OR REPLACE INTO dictation_entry_vectors (rowid, vec) VALUES (1, X'0000803F0000000000000000');
            INSERT OR REPLACE INTO embedding_cache (key, vec, last_used) VALUES (X'010203', X'0000803F', 100);
        """
        XCTAssertEqual(sqlite3_exec(liveV10, seedSQL, nil, nil, nil), SQLITE_OK)

        // Open the current index against the stamped v10 DB.
        let currentIndex = try TranscriptIndex(indexDir: tempDir)
        XCTAssertEqual(try currentIndex.listMeetings(count: 10).count, 1)

        // Pre-existing embeddings must NOT be wiped on open.
        XCTAssertEqual(try rowCount("SELECT COUNT(*) FROM embedding_meta"), 1)
        XCTAssertEqual(try rowCount("SELECT COUNT(*) FROM utterance_vectors"), 1)
        XCTAssertEqual(try rowCount("SELECT COUNT(*) FROM dictation_entry_vectors"), 1)
        XCTAssertEqual(try rowCount("SELECT COUNT(*) FROM embedding_cache"), 1)

        // Second (live v10) connection can still SELECT and DELETE on meeting_summary_items.
        var stmt: OpaquePointer?
        XCTAssertEqual(
            sqlite3_prepare_v2(liveV10, "SELECT COUNT(*) FROM meeting_summary_items", -1, &stmt, nil),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int64(stmt, 0), 1)
        sqlite3_finalize(stmt)

        XCTAssertEqual(
            sqlite3_exec(liveV10, "DELETE FROM meeting_summary_items WHERE filename = 'Call_2026-04-18_09-15-00'", nil, nil, nil),
            SQLITE_OK
        )
        XCTAssertEqual(try rowCount("SELECT COUNT(*) FROM meeting_summary_items"), 0)

        // Re-inserting a stale row and removing the meeting clears meeting_summary_items via deleteIndexedRows.
        XCTAssertEqual(
            sqlite3_exec(
                liveV10,
                "INSERT INTO meeting_summary_items (filename, kind, position, text) VALUES ('Call_2026-04-18_09-15-00', 'decision', 0, 'Stale decision')",
                nil, nil, nil
            ),
            SQLITE_OK
        )
        XCTAssertEqual(try rowCount("SELECT COUNT(*) FROM meeting_summary_items"), 1)
        try FileManager.default.removeItem(at: tempDir.appendingPathComponent("Call_2026-04-18_09-15-00.md"))
        try currentIndex.reconcile(meetingsDir: tempDir, dictationsDir: tempDir, updateEmbeddings: false)
        XCTAssertEqual(try rowCount("SELECT COUNT(*) FROM meeting_summary_items"), 0)
    }

    func testOpeningNeverLowersANewerSchemaVersion() throws {
        // An older helper opening an index a newer one already rebuilt must not
        // stamp its own, lower version back, or the newer helper would rebuild
        // again on its next start.
        index = nil
        let dbPath = tempDir.appendingPathComponent("mcp_index.sqlite").path
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "PRAGMA user_version=99", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        _ = try TranscriptIndex(indexDir: tempDir)

        XCTAssertEqual(sqlite3_open(dbPath, &raw), SQLITE_OK)
        defer { sqlite3_close(raw) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(raw, "PRAGMA user_version", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 99)
    }

    func testVersionTwoIndexBackfillsSummarySearchDocuments() throws {
        try writeFixture(makeMeetingWithInlineSummary(), filename: "Call_2026-04-18_09-15-00", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        index = nil

        let dbPath = tempDir.appendingPathComponent("mcp_index.sqlite").path
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "PRAGMA user_version=2", nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        let reopened = try TranscriptIndex(indexDir: tempDir)
        XCTAssertTrue(try reopened.searchUtterances(query: "beta", speaker: nil, dateFrom: nil, dateTo: nil).results.isEmpty)

        try reopened.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        XCTAssertEqual(
            try reopened.searchUtterances(query: "Beta launch", speaker: nil, dateFrom: nil, dateTo: nil).results.first?.filename,
            "Call_2026-04-18_09-15-00"
        )
    }

    func testFiveHundredMeetingSummaryBackfillIndexesEveryMeeting() throws {
        for index in 0..<500 {
            try writeFixture(
                makeMeetingWithInlineSummary(
                    decisions: ["Synthetic pricing decision \(index)"],
                    actionItems: ["Jenny: follow up on synthetic task \(index)"],
                    openQuestions: ["Should synthetic question \(index) stay open?"]
                ),
                filename: String(format: "Call_2026-04-18_09-15-%03d", index),
                to: tempDir
            )
        }

        try withLogsSuppressed {
            try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)
        }

        XCTAssertEqual(try index.listMeetings(count: 50).count, 50)

        for number in 0..<500 {
            let result = try index.searchUtterances(
                query: "Synthetic pricing decision \(number)",
                speaker: nil, dateFrom: nil, dateTo: nil
            )
            XCTAssertEqual(
                result.results.first?.filename,
                String(format: "Call_2026-04-18_09-15-%03d", number),
                "Summary search must index meeting \(number)"
            )
            XCTAssertEqual(result.results.first?.snippets.first?.speaker, "Summary")
        }
    }

    func testGeneratedSidecarIsNotIndexedAsMeetingButFeedsSummary() throws {
        // A transcript with no inline summary, plus a `<stem>.summary.md` sidecar.
        try writeFixture(makeFixtureJSON(), filename: "2026-04-18 Beta sync", to: tempDir)
        let sidecar = """
        ---
        capture_type: meeting_summary
        source_transcript: "2026-04-18 Beta sync.md"
        summary_title: "Beta sync"
        ---

        # Decisions
        - Adopt the sidecar plan

        # Action Items
        - Sam: wire the rollup

        # Open Questions
        - None found.
        """
        try writeFixture(sidecar, filename: "2026-04-18 Beta sync.summary", to: tempDir)
        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        // The sidecar must not appear as its own meeting row.
        let meetings = try index.listMeetings(count: 10)
        XCTAssertEqual(meetings.count, 1)
        XCTAssertEqual(meetings.first?.filename, "2026-04-18 Beta sync")

        // Its summary feeds the parent transcript's summary search document.
        let search = try index.searchUtterances(query: "Adopt the sidecar plan", speaker: nil, dateFrom: nil, dateTo: nil)
        XCTAssertEqual(search.results.first?.filename, "2026-04-18 Beta sync")
        XCTAssertEqual(search.results.first?.snippets.first?.speaker, "Summary")
    }

    // Two MCP clients (a desktop chat app and an IDE agent) each launch their own
    // server against one index. Their reconciles used to race: both inserted the
    // same meeting and the loser failed with "UNIQUE constraint failed:
    // meeting_summary_documents.filename", aborting its whole pass.
    func testConcurrentReconcilesFromTwoProcessesIndexEachMeetingOnce() throws {
        let meetingCount = 40
        for minute in 0..<meetingCount {
            try writeFixture(
                makeMeetingWithInlineSummary(),
                filename: String(format: "Call_2026-04-18_09-%02d-00", minute),
                to: tempDir
            )
        }
        // A second TranscriptIndex opens its own connection and its own lock file
        // descriptor, the same as a second server process.
        let secondProcess = try TranscriptIndex(indexDir: tempDir)
        let indexes: [TranscriptIndex] = [index, secondProcess]
        let errors = NSLock()
        var failures: [Error] = []

        DispatchQueue.concurrentPerform(iterations: indexes.count) { position in
            do {
                try indexes[position].reconcile(meetingsDir: tempDir, dictationsDir: tempDir, updateEmbeddings: false)
            } catch {
                errors.lock()
                failures.append(error)
                errors.unlock()
            }
        }

        XCTAssertTrue(failures.isEmpty, "reconcile failed: \(failures)")
        XCTAssertEqual(try index.listMeetings(count: 100).count, meetingCount)
        XCTAssertEqual(try rowCount("SELECT COUNT(*) FROM meeting_summary_documents"), meetingCount)
    }

    // An index left with a summary row from an earlier interrupted pass must heal
    // on the next reconcile instead of failing on that row forever.
    func testReconcileReplacesLeftoverSummaryDocumentForUnindexedMeeting() throws {
        try writeFixture(makeMeetingWithInlineSummary(), filename: "Call_2026-04-18_09-15-00", to: tempDir)
        let dbPath = tempDir.appendingPathComponent("mcp_index.sqlite").path
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbPath, &raw), SQLITE_OK)
        XCTAssertEqual(
            sqlite3_exec(
                raw,
                "INSERT INTO meeting_summary_documents (filename, title) VALUES ('Call_2026-04-18_09-15-00', 'stale')",
                nil, nil, nil
            ),
            SQLITE_OK
        )
        sqlite3_close(raw)

        try index.reconcile(meetingsDir: tempDir, dictationsDir: tempDir)

        XCTAssertEqual(try rowCount("SELECT COUNT(*) FROM meeting_summary_documents"), 1)
        XCTAssertEqual(
            try index.searchUtterances(query: "Beta launch", speaker: nil, dateFrom: nil, dateTo: nil).results.first?.meetingTitle,
            "Beta launch sync"
        )
    }

    private func rowCount(_ sql: String) throws -> Int {
        let dbPath = tempDir.appendingPathComponent("mcp_index.sqlite").path
        var raw: OpaquePointer?
        guard sqlite3_open(dbPath, &raw) == SQLITE_OK else { throw XCTSkip("could not open index") }
        defer { sqlite3_close(raw) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(raw, sql, -1, &stmt, nil) == SQLITE_OK else { throw XCTSkip("could not prepare \(sql)") }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(stmt, 0))
    }
}
