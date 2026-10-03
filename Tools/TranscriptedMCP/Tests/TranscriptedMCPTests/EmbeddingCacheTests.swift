import CryptoKit
import Darwin
import SQLite3
import XCTest
@testable import transcripted_mcp

/// Deterministic provider whose vector is derived from the text (and a salt), so
/// different texts get different vectors and the same text always gets the same
/// one. Counts every embed call.
private final class HashingCountingProvider: EmbeddingProvider, @unchecked Sendable {
    let modelID: String
    let dimension = 8
    let isAvailable = true
    private let salt: String
    private let lock = NSLock()
    private var calls = 0

    init(modelID: String = "hash.v1", salt: String = "a") {
        self.modelID = modelID
        self.salt = salt
    }

    var embedCalls: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func expectedVector(for text: String) -> [Float]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let digest = Array(SHA256.hash(data: Data((salt + "|" + trimmed).utf8)))
        let raw = (0..<dimension).map { Float(digest[$0]) - 127.5 }
        return VectorMath.normalized(raw)
    }

    func embed(_ text: String) -> [Float]? {
        lock.lock()
        calls += 1
        lock.unlock()
        return expectedVector(for: text)
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        current = current.addingTimeInterval(seconds)
        lock.unlock()
    }
}

private typealias DictationEntryFixture = (
    id: String, createdAt: String, title: String, text: String, sourceAppName: String, delivery: String
)

private func dictationEntries(_ texts: [String], hourOffset: Int = 9) -> [DictationEntryFixture] {
    texts.enumerated().map { index, text in
        let minute = String(format: "%02d", index)
        return (
            "dictation-20260407-\(String(format: "%02d", hourOffset))\(minute)00-000",
            "2026-04-07T\(String(format: "%02d", hourOffset)):\(minute):00-0500",
            "Note \(index)",
            text,
            "Notes",
            "pasted"
        )
    }
}

final class EmbeddingCacheTests: XCTestCase {
    private var root: URL!
    private var library: URL!
    private var indexDir: URL!

    override func setUp() {
        super.setUp()
        root = makeTempDir()
        library = root.appendingPathComponent("library", isDirectory: true)
        indexDir = root.appendingPathComponent("index", isDirectory: true)
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: indexDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        removeTempDir(root)
        super.tearDown()
    }

    private let baseTexts = [
        "Ship the follow-up note to product today",
        "Remember to send the recap before dinner",
        "Ask legal about the migration window",
        "Book the venue for the offsite",
        "Draft the pricing note for Friday",
    ]

    /// Writes a file and moves its mtime forward so reconcile always sees a change.
    private func write(_ content: String, filename: String, in dir: URL, bump: TimeInterval) throws {
        try writeFixture(content, filename: filename, to: dir)
        let url = dir.appendingPathComponent("\(filename).md")
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_700_000_000 + bump)],
            ofItemAtPath: url.path
        )
    }

    private func writeDictationDay(_ texts: [String], bump: TimeInterval) throws {
        try write(
            makeDictationDayJSON(entries: dictationEntries(texts)),
            filename: "Dictations_2026-04-07",
            in: library,
            bump: bump
        )
    }

    private func openDB(_ dir: URL) -> OpaquePointer? {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dir.appendingPathComponent("mcp_index.sqlite").path, &db), SQLITE_OK)
        return db
    }

    /// (text, stored vector) for every row of a lexical table joined to its vectors.
    private func storedVectors(table: String, vectors: String, in dir: URL) -> [(text: String, vec: [Float]?)] {
        guard let db = openDB(dir) else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT t.text, v.vec FROM \(table) t LEFT JOIN \(vectors) v ON v.rowid = t.rowid ORDER BY t.rowid"
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        var rows: [(String, [Float]?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let text = String(cString: sqlite3_column_text(stmt, 0))
            var vec: [Float]?
            if let blob = sqlite3_column_blob(stmt, 1) {
                vec = VectorMath.vector(from: Data(bytes: blob, count: Int(sqlite3_column_bytes(stmt, 1))))
            }
            rows.append((text, vec))
        }
        return rows
    }

    private func cacheRowCount(in dir: URL) -> Int {
        guard let db = openDB(dir) else { return -1 }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM embedding_cache", -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return -1
        }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : -1
    }

    private func assertEveryRowCarriesProviderVector(
        _ provider: HashingCountingProvider,
        table: String = "dictation_entries",
        vectors: String = "dictation_entry_vectors",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let rows = storedVectors(table: table, vectors: vectors, in: indexDir)
        XCTAssertFalse(rows.isEmpty, file: file, line: line)
        for row in rows {
            XCTAssertEqual(row.vec, provider.expectedVector(for: row.text), file: file, line: line)
        }
    }

    private func semanticDictationTexts(_ index: TranscriptIndex, query: String) throws -> [String] {
        try index.searchContext(
            query: query, speaker: nil, kind: .dictation, dateFrom: nil, dateTo: nil, maxItems: 20, mode: .semantic
        ).results.flatMap { $0.snippets.map(\.text) }
    }

    // MARK: - One dictation, two servers

    func testAppendingOneDictationEmbedsOnlyTheNewEntryAcrossTwoServers() throws {
        let provider = HashingCountingProvider()
        let serverA = try TranscriptIndex(indexDir: indexDir, embeddingProvider: provider)
        let serverB = try TranscriptIndex(indexDir: indexDir, embeddingProvider: provider)

        try writeDictationDay(baseTexts, bump: 0)
        try serverA.reconcile(meetingsDir: library, dictationsDir: library)
        try serverB.reconcile(meetingsDir: library, dictationsDir: library)
        let before = provider.embedCalls

        let appended = baseTexts + ["Pick up the dry cleaning on Tuesday"]
        try writeDictationDay(appended, bump: 10)
        try serverA.reconcile(meetingsDir: library, dictationsDir: library)
        try serverB.reconcile(meetingsDir: library, dictationsDir: library)

        XCTAssertEqual(provider.embedCalls - before, 1, "only the new entry needs a provider call")
        assertEveryRowCarriesProviderVector(provider)

        // Same answers as an index built from scratch without any cache.
        let freshDir = root.appendingPathComponent("fresh-index", isDirectory: true)
        try FileManager.default.createDirectory(at: freshDir, withIntermediateDirectories: true)
        let fresh = try TranscriptIndex(indexDir: freshDir, embeddingProvider: HashingCountingProvider())
        try fresh.reconcile(meetingsDir: library, dictationsDir: library)
        for query in appended {
            XCTAssertEqual(try semanticDictationTexts(serverA, query: query), try semanticDictationTexts(fresh, query: query))
            XCTAssertEqual(try semanticDictationTexts(serverB, query: query), try semanticDictationTexts(fresh, query: query))
        }
        XCTAssertEqual(try semanticDictationTexts(serverA, query: appended[5]).first, appended[5])
    }

    // MARK: - Text edit and speaker rename

    func testEditingOneEntryEmbedsExactlyThatEntry() throws {
        let provider = HashingCountingProvider()
        let index = try TranscriptIndex(indexDir: indexDir, embeddingProvider: provider)
        try writeDictationDay(baseTexts, bump: 0)
        try index.reconcile(meetingsDir: library, dictationsDir: library)
        let before = provider.embedCalls

        var edited = baseTexts
        edited[2] = "Ask legal about the rollout window instead"
        try writeDictationDay(edited, bump: 10)
        try index.reconcile(meetingsDir: library, dictationsDir: library)

        XCTAssertEqual(provider.embedCalls - before, 1)
        assertEveryRowCarriesProviderVector(provider)
        XCTAssertEqual(try semanticDictationTexts(index, query: edited[2]).first, edited[2])
    }

    func testSpeakerRenameReusesEveryUtteranceVector() throws {
        let provider = HashingCountingProvider()
        let index = try TranscriptIndex(indexDir: indexDir, embeddingProvider: provider)
        let utterances: [(speakerId: String, start: Double, end: Double, text: String)] = [
            ("mic_0", 0.0, 5.0, "Good morning everyone"),
            ("system_0", 5.0, 10.0, "Let's discuss the product roadmap"),
            ("system_0", 10.0, 15.0, "The pricing pushback came from finance"),
        ]
        func meeting(_ name: String) -> String {
            makeFixtureJSON(
                speakers: [("mic_0", "You", nil), ("system_0", name, "80FB272B-6061-4FC4-8408-3F7A974C59DB")],
                utterances: utterances
            )
        }
        try write(meeting("Jenny Wen"), filename: "Call_2026-03-29_10-00-00", in: library, bump: 0)
        try index.reconcile(meetingsDir: library, dictationsDir: library)
        let before = provider.embedCalls

        try write(meeting("Jenny Smith"), filename: "Call_2026-03-29_10-00-00", in: library, bump: 10)
        try index.reconcile(meetingsDir: library, dictationsDir: library)

        XCTAssertEqual(provider.embedCalls - before, 0, "a speaker rename doesn't change any embedded text")
        assertEveryRowCarriesProviderVector(provider, table: "utterances", vectors: "utterance_vectors")
        let renamed = try index.searchUtterances(
            query: utterances[2].text, speaker: "Jenny Smith", dateFrom: nil, dateTo: nil, mode: .semantic
        )
        XCTAssertEqual(renamed.results.first?.snippets.first?.text, utterances[2].text)
        XCTAssertEqual(renamed.results.first?.snippets.first?.speaker, "Jenny Smith")
    }

    // MARK: - Namespace

    func testDifferentModelNeverReusesCachedVectors() throws {
        let first = HashingCountingProvider(modelID: "hash.v1", salt: "a")
        let index1 = try TranscriptIndex(indexDir: indexDir, embeddingProvider: first)
        try writeDictationDay(baseTexts, bump: 0)
        try index1.reconcile(meetingsDir: library, dictationsDir: library)
        assertEveryRowCarriesProviderVector(first)

        let second = HashingCountingProvider(modelID: "hash.v2", salt: "b")
        let index2 = try TranscriptIndex(indexDir: indexDir, embeddingProvider: second)
        try index2.reconcile(meetingsDir: library, dictationsDir: library)

        XCTAssertEqual(second.embedCalls, baseTexts.count)
        assertEveryRowCarriesProviderVector(second)
    }

    // MARK: - Cross-process embed lock

    func testSemanticSearchKeepsAnsweringWhileAnotherProcessHoldsTheEmbedLock() throws {
        let provider = HashingCountingProvider()
        let index = try TranscriptIndex(indexDir: indexDir, embeddingProvider: provider)
        // An older day that stays untouched keeps its vectors throughout.
        let olderText = "Water the plants on the balcony"
        try write(
            makeDictationDayJSON(
                date: "2026-04-06",
                entries: [("dictation-20260406-100000-000", "2026-04-06T10:00:00-0500", "Older", olderText, "Notes", "pasted")]
            ),
            filename: "Dictations_2026-04-06",
            in: library,
            bump: 0
        )
        try writeDictationDay(baseTexts, bump: 0)
        try index.reconcile(meetingsDir: library, dictationsDir: library)

        // Stand in for another server mid-embed: hold the embed lock on a
        // separate open file description.
        let lockPath = indexDir.appendingPathComponent("mcp_index.embed.lock").path
        let lockFD = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(lockFD, 0)
        XCTAssertEqual(flock(lockFD, LOCK_EX), 0)
        var released = false
        defer {
            if !released { flock(lockFD, LOCK_UN) }
            close(lockFD)
        }

        let newText = "Pick up the dry cleaning on Tuesday"
        try writeDictationDay(baseTexts + [newText], bump: 10)
        try index.reconcile(meetingsDir: library, dictationsDir: library, updateEmbeddings: false)

        let passDone = expectation(description: "embedding pass finished after the lock was released")
        DispatchQueue.global(qos: .utility).async {
            index.reconcileEmbeddings()
            passDone.fulfill()
        }
        // Give the background pass time to reach the lock.
        Thread.sleep(forTimeInterval: 0.3)

        let store = try XCTUnwrap(index.embeddingStore)
        let whileWaiting = store.semanticSearchDictationEntriesIfAvailable(
            query: olderText, dateFrom: nil, dateTo: nil
        )
        XCTAssertNotNil(whileWaiting, "semantic search must stay admitted while the pass waits on another process")
        XCTAssertEqual(whileWaiting?.first?.snippets.first?.text, olderText)
        XCTAssertFalse(
            (whileWaiting ?? []).contains { $0.snippets.first?.text == newText },
            "the waiting pass hasn't embedded the new entry yet"
        )

        flock(lockFD, LOCK_UN)
        released = true
        wait(for: [passDone], timeout: 10)
        XCTAssertEqual(try semanticDictationTexts(index, query: newText).first, newText)
    }

    func testStoppedLockHolderDoesNotBlockTheEmbeddingPassForever() throws {
        let provider = HashingCountingProvider()
        let index = try TranscriptIndex(indexDir: indexDir)
        let store = try EmbeddingStore(
            dbPath: indexDir.appendingPathComponent("mcp_index.sqlite"),
            provider: provider,
            embedLockTimeout: 0.3
        )
        try writeDictationDay(baseTexts, bump: 0)
        try index.reconcile(meetingsDir: library, dictationsDir: library, updateEmbeddings: false)

        // Stand in for a stopped server: take the embed lock and never let go
        // while the pass runs.
        let lockPath = indexDir.appendingPathComponent("mcp_index.embed.lock").path
        let lockFD = open(lockPath, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        XCTAssertGreaterThanOrEqual(lockFD, 0)
        XCTAssertEqual(flock(lockFD, LOCK_EX), 0)
        defer {
            flock(lockFD, LOCK_UN)
            close(lockFD)
        }

        let passDone = expectation(description: "embedding pass gave up waiting and ran unlocked")
        DispatchQueue.global(qos: .utility).async {
            store.reconcileEmbeddings()
            passDone.fulfill()
        }
        wait(for: [passDone], timeout: 10)
        XCTAssertEqual(provider.embedCalls, baseTexts.count, "the unlocked pass still embedded every new row")
    }

    // MARK: - TTL garbage collection

    func testCacheDropsTextsUnusedForLongerThanTheTTL() throws {
        let clock = TestClock()
        let provider = HashingCountingProvider()
        let index = try TranscriptIndex(indexDir: indexDir)
        let store = try EmbeddingStore(
            dbPath: indexDir.appendingPathComponent("mcp_index.sqlite"),
            provider: provider,
            cacheTTL: 72 * 60 * 60,
            now: { clock.now }
        )
        let otherDay = ["Water the plants on the balcony", "Call the bank about the card"]
        func writeOtherDay(bump: TimeInterval) throws {
            try write(
                makeDictationDayJSON(
                    date: "2026-04-08",
                    entries: otherDay.enumerated().map { offset, text -> DictationEntryFixture in
                        ("dictation-20260408-10\(offset)000-000", "2026-04-08T10:0\(offset):00-0500", "Other \(offset)", text, "Notes", "pasted")
                    }
                ),
                filename: "Dictations_2026-04-08",
                in: library,
                bump: bump
            )
        }

        try writeDictationDay(baseTexts, bump: 0)
        try writeOtherDay(bump: 0)
        try index.reconcile(meetingsDir: library, dictationsDir: library, updateEmbeddings: false)
        store.reconcileEmbeddings()
        XCTAssertEqual(cacheRowCount(in: indexDir), baseTexts.count + otherDay.count)

        // Three days later only today's file is rewritten; its texts are reused
        // (and refreshed), the other day's go stale and are collected.
        clock.advance(by: 73 * 60 * 60)
        let appended = baseTexts + ["Pick up the dry cleaning on Tuesday"]
        try writeDictationDay(appended, bump: 10)
        try index.reconcile(meetingsDir: library, dictationsDir: library, updateEmbeddings: false)
        let before = provider.embedCalls
        store.reconcileEmbeddings()
        XCTAssertEqual(provider.embedCalls - before, 1)
        XCTAssertEqual(cacheRowCount(in: indexDir), appended.count)

        // A collected text is simply embedded again when it next churns.
        try writeOtherDay(bump: 20)
        try index.reconcile(meetingsDir: library, dictationsDir: library, updateEmbeddings: false)
        let beforeOther = provider.embedCalls
        store.reconcileEmbeddings()
        XCTAssertEqual(provider.embedCalls - beforeOther, otherDay.count)
        assertEveryRowCarriesProviderVector(provider)
    }

    // MARK: - Older helpers sharing the index

    func testOlderHelperPassSQLStaysCompatible() throws {
        let provider = HashingCountingProvider()
        let index = try TranscriptIndex(indexDir: indexDir, embeddingProvider: provider)
        try writeDictationDay(baseTexts, bump: 0)
        try index.reconcile(meetingsDir: library, dictationsDir: library)

        // An older helper without embedding_cache rewrites the day and runs its
        // own pass: orphan delete, then INSERT OR REPLACE (rowid, vec).
        let appended = baseTexts + ["Pick up the dry cleaning on Tuesday"]
        try writeDictationDay(appended, bump: 10)
        try index.reconcile(meetingsDir: library, dictationsDir: library, updateEmbeddings: false)
        let db = try XCTUnwrap(openDB(indexDir))
        XCTAssertEqual(
            sqlite3_exec(db, "DELETE FROM dictation_entry_vectors WHERE rowid NOT IN (SELECT rowid FROM dictation_entries)", nil, nil, nil),
            SQLITE_OK
        )
        var select: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT rowid, text FROM dictation_entries", -1, &select, nil), SQLITE_OK)
        var rows: [(Int64, String)] = []
        while sqlite3_step(select) == SQLITE_ROW {
            rows.append((sqlite3_column_int64(select, 0), String(cString: sqlite3_column_text(select, 1))))
        }
        sqlite3_finalize(select)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (rowid, text) in rows {
            var insert: OpaquePointer?
            XCTAssertEqual(
                sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO dictation_entry_vectors (rowid, vec) VALUES (?, ?)", -1, &insert, nil),
                SQLITE_OK
            )
            sqlite3_bind_int64(insert, 1, rowid)
            let blob = VectorMath.blob(from: provider.expectedVector(for: text) ?? [])
            _ = blob.withUnsafeBytes { raw in
                sqlite3_bind_blob(insert, 2, raw.baseAddress, Int32(blob.count), transient)
            }
            XCTAssertEqual(sqlite3_step(insert), SQLITE_DONE)
            sqlite3_finalize(insert)
        }
        sqlite3_close(db)

        // The new helper's next pass has nothing to embed and leaves the
        // vectors correct.
        let before = provider.embedCalls
        index.reconcileEmbeddings()
        XCTAssertEqual(provider.embedCalls, before)
        assertEveryRowCarriesProviderVector(provider)
    }
}
