import Foundation
import SQLite3
import XCTest
@testable import transcripted_mcp

private final class BackfillProvider: EmbeddingProvider, @unchecked Sendable {
    let modelID = "synthetic.backfill.v1"
    let dimension = 4
    private let lock = NSLock()
    private var calls = 0
    var onEmbed: (@Sendable (Int, String) -> Void)?
    var rejectsText: (@Sendable (String) -> Bool)?

    var embedCalls: Int { lock.lock(); defer { lock.unlock() }; return calls }
    static func vector(_ text: String) -> [Float] {
        let number = Int(text.split(separator: " ").last ?? "0") ?? 0
        return VectorMath.normalized([Float(number % 251), 1, 2, 3])
    }
    func embed(_ text: String) -> [Float]? {
        lock.lock(); calls += 1; let call = calls; lock.unlock()
        onEmbed?(call, text)
        return rejectsText?(text) == true ? nil : Self.vector(text)
    }
}

private final class BackfillObservations: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var maximumRows = 0
    private(set) var maximumNewVectors = 0
    private(set) var maximumAllVectors = 0
    private(set) var totalRows = 0
    func record(_ batch: EmbeddingStore.BackfillBatchMetrics) {
        lock.lock(); defer { lock.unlock() }
        maximumRows = max(maximumRows, batch.rowCount)
        maximumNewVectors = max(maximumNewVectors, batch.newVectorCount)
        maximumAllVectors = max(maximumAllVectors, batch.newVectorCount + batch.cachedVectorCount)
        totalRows += batch.rowCount
    }
}

private final class BackfillCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func set(_ value: Bool) { lock.lock(); cancelled = value; lock.unlock() }
}

final class EmbeddingBackfillTests: XCTestCase {
    private var root: URL!
    private var db: OpaquePointer?
    private var index: TranscriptIndex!

    override func setUpWithError() throws {
        root = makeTempDir()
        index = try TranscriptIndex(indexDir: root)
        XCTAssertEqual(sqlite3_open(databaseURL.path, &db), SQLITE_OK)
        try execute("PRAGMA busy_timeout=5000")
        try execute("""
            INSERT INTO meetings VALUES ('synthetic', '2026-04-07', '2026-04-07T10:00:00', 60, 1, 1, 0);
            INSERT INTO dictation_days VALUES ('synthetic', '2026-04-07', '2026-04-07T10:00:00', 'synthetic.md', 1, 1, 0);
            """)
    }

    override func tearDown() {
        if let db { sqlite3_close(db) }
        db = nil
        index = nil
        removeTempDir(root)
        super.tearDown()
    }

    private var databaseURL: URL { root.appendingPathComponent("mcp_index.sqlite") }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SyntheticBackfillSQLite", code: Int(sqlite3_errcode(db)))
        }
    }

    private func insertRows(_ count: Int, table: String = "utterances", text: (Int) -> String = { "synthetic \($0)" }) throws {
        let sql: String
        if table == "utterances" {
            sql = "INSERT INTO utterances (filename, speaker_name, utterance_start, utterance_end, text) VALUES ('synthetic', 'Synthetic', 0, 1, ?)"
        } else {
            sql = "INSERT INTO dictation_entries (filename, entry_id, title, created_at, source_app_name, delivery, word_count, character_count, text) VALUES ('synthetic', 'entry', 'Synthetic', '2026-04-07T10:00:00', 'Synthetic', 'pasted', 1, 1, ?)"
        }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        try execute("BEGIN")
        for row in 1...count {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, (text(row) as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
        }
        try execute("COMMIT")
    }

    private func rowCount(_ table: String) -> Int {
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table)", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        return Int(sqlite3_column_int64(stmt, 0))
    }

    private func assertStoredVectors(table: String = "utterances", vectors: String = "utterance_vectors", expectedCount: Int) {
        var stmt: OpaquePointer?
        let sql = "SELECT t.text, v.vec FROM \(table) t JOIN \(vectors) v ON v.rowid = t.rowid ORDER BY t.rowid"
        XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        var count = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let text = String(cString: sqlite3_column_text(stmt, 0))
            guard let pointer = sqlite3_column_blob(stmt, 1) else { XCTFail("Missing synthetic vector"); return }
            let blob = Data(bytes: pointer, count: Int(sqlite3_column_bytes(stmt, 1)))
            XCTAssertEqual(VectorMath.vector(from: blob), BackfillProvider.vector(text))
            count += 1
        }
        XCTAssertEqual(count, expectedCount)
    }

    func testTenThousandAndHundredThousandRowsBoundTextPagesAndVectorBatches() throws {
        for count in [10_000, 100_000] {
            try execute("DELETE FROM utterances")
            // Separate model cache contents so both sizes exercise newly computed vectors.
            if count > 10_000 { try execute("DELETE FROM embedding_cache") }
            try insertRows(count)
            let provider = BackfillProvider()
            let observed = BackfillObservations()
            let store = try EmbeddingStore(dbPath: databaseURL, provider: provider, onBackfillBatch: { observed.record($0) })

            store.reconcileEmbeddings()

            XCTAssertEqual(provider.embedCalls, count)
            XCTAssertEqual(observed.totalRows, count)
            XCTAssertLessThanOrEqual(observed.maximumRows, 100)
            XCTAssertLessThanOrEqual(observed.maximumNewVectors, 100)
            XCTAssertLessThanOrEqual(observed.maximumAllVectors, 100)
            XCTAssertEqual(rowCount("embedding_cache"), count)
            assertStoredVectors(expectedCount: count)
        }
    }

    func testDuplicatesAcrossPagesTablesAndRestartReusePersistedVectors() throws {
        try insertRows(350, text: { "synthetic \($0 % 137)" })
        try insertRows(350, table: "dictation_entries", text: { "synthetic \($0 % 137)" })
        let provider = BackfillProvider()
        do {
            let store = try EmbeddingStore(dbPath: databaseURL, provider: provider)
            store.reconcileEmbeddings()
        }
        XCTAssertEqual(provider.embedCalls, 137)
        assertStoredVectors(expectedCount: 350)
        assertStoredVectors(table: "dictation_entries", vectors: "dictation_entry_vectors", expectedCount: 350)

        try execute("DELETE FROM utterance_vectors; DELETE FROM dictation_entry_vectors")
        let restarted = try EmbeddingStore(dbPath: databaseURL, provider: provider)
        restarted.reconcileEmbeddings()
        XCTAssertEqual(provider.embedCalls, 137, "successful earlier batches survive a server restart")
        assertStoredVectors(expectedCount: 350)
        assertStoredVectors(table: "dictation_entries", vectors: "dictation_entry_vectors", expectedCount: 350)
    }

    func testNilEmbeddingsAdvanceToLaterRowsAndTablesAndRetryNextPass() throws {
        try insertRows(260)
        try insertRows(5, table: "dictation_entries", text: { "available \($0)" })
        let reject = BackfillCancellation()
        reject.set(true)
        let provider = BackfillProvider()
        provider.rejectsText = { reject.isCancelled && $0.hasPrefix("synthetic") }
        let observed = BackfillObservations()
        let store = try EmbeddingStore(dbPath: databaseURL, provider: provider, onBackfillBatch: { observed.record($0) })

        store.reconcileEmbeddings()
        XCTAssertEqual(provider.embedCalls, 265)
        XCTAssertEqual(observed.totalRows, 265)
        XCTAssertEqual(rowCount("utterance_vectors"), 0)
        assertStoredVectors(table: "dictation_entries", vectors: "dictation_entry_vectors", expectedCount: 5)

        reject.set(false)
        store.reconcileEmbeddings()
        XCTAssertEqual(provider.embedCalls, 525)
        assertStoredVectors(expectedCount: 260)
    }

    func testCancellationKeepsCommittedBatchesAndResumesMissingRows() throws {
        try insertRows(205)
        let cancelled = BackfillCancellation()
        let provider = BackfillProvider()
        provider.onEmbed = { call, _ in if call == 101 { cancelled.set(true) } }
        let store = try EmbeddingStore(dbPath: databaseURL, provider: provider)

        store.reconcileEmbeddings(isCancelled: { cancelled.isCancelled })
        XCTAssertEqual(provider.embedCalls, 101)
        XCTAssertEqual(rowCount("utterance_vectors"), 100)
        XCTAssertEqual(rowCount("embedding_cache"), 100)

        cancelled.set(false)
        store.reconcileEmbeddings(isCancelled: { cancelled.isCancelled })
        XCTAssertEqual(provider.embedCalls, 206, "only the unfinished batch needs recomputation")
        assertStoredVectors(expectedCount: 205)
    }

    func testRejectedVectorWritesAdvanceAndCanRecoverFromCache() throws {
        try insertRows(205)
        let provider = BackfillProvider()
        let store = try EmbeddingStore(dbPath: databaseURL, provider: provider)
        try execute("""
            CREATE TRIGGER reject_synthetic_vector BEFORE INSERT ON utterance_vectors
            BEGIN SELECT RAISE(FAIL, 'synthetic write failure'); END;
            """)
        store.reconcileEmbeddings()
        XCTAssertEqual(provider.embedCalls, 205)
        XCTAssertEqual(rowCount("utterance_vectors"), 0)
        XCTAssertEqual(rowCount("embedding_cache"), 205)

        try execute("DROP TRIGGER reject_synthetic_vector")
        store.reconcileEmbeddings()
        XCTAssertEqual(provider.embedCalls, 205)
        assertStoredVectors(expectedCount: 205)
    }

    func testCancelledTaskStopsBeforeCommittingItsPartialBatch() async throws {
        try insertRows(205)
        let entered = expectation(description: "first provider call entered")
        let release = DispatchSemaphore(value: 0)
        let provider = BackfillProvider()
        provider.onEmbed = { call, _ in if call == 1 { entered.fulfill(); release.wait() } }
        let store = try EmbeddingStore(dbPath: databaseURL, provider: provider)
        let task = Task.detached { store.reconcileEmbeddings() }
        await fulfillment(of: [entered], timeout: 10)
        task.cancel()
        release.signal()
        await task.value
        XCTAssertEqual(provider.embedCalls, 1)
        XCTAssertEqual(rowCount("utterance_vectors"), 0)
        XCTAssertEqual(rowCount("embedding_cache"), 0)
    }

    func testLexicalChangesCanProceedDuringEmbeddingWithoutExtendingThePass() throws {
        try insertRows(205)
        let provider = BackfillProvider()
        provider.onEmbed = { [self] call, _ in
            guard call == 1 else { return }
            do {
                let lexical = try index.searchUtterances(query: "synthetic", speaker: nil, dateFrom: nil, dateTo: nil, mode: .lexical)
                XCTAssertEqual(lexical.totalMeetingsMatched, 1)
                try execute("DELETE FROM utterances WHERE rowid = 2")
                try insertRows(1, text: { _ in "newly imported 999" })
            } catch { XCTFail("Concurrent synthetic lexical read/write failed: \(error)") }
        }
        let store = try EmbeddingStore(dbPath: databaseURL, provider: provider)
        store.reconcileEmbeddings()
        XCTAssertEqual(provider.embedCalls, 205, "the pass stops at its initial rowid boundary")
        XCTAssertEqual(rowCount("utterance_vectors"), 204, "a row deleted while embedding must not leave an orphan")

        store.reconcileEmbeddings()
        XCTAssertEqual(provider.embedCalls, 206)
        assertStoredVectors(expectedCount: 205)
    }
}
