import Foundation
import SQLite3

/// On-device vector store for semantic search.
///
/// Owns its own SQLite connection to the *same* `mcp_index.sqlite` file the
/// lexical `TranscriptIndex` uses, but only ever writes its own additive tables
/// (`embedding_meta`, `utterance_vectors`, `dictation_entry_vectors`). It reads
/// the lexical tables (`utterances`, `meetings`, `dictation_entries`,
/// `dictation_days`) to find rows that still need embedding and to hydrate search
/// results. Keeping it on a separate connection means the embedding work and the
/// vector schema stay fully decoupled from the lexical index's write path.
///
/// Everything here is best-effort: if the embedding provider is unavailable or a
/// write fails, lexical search keeps working untouched.
final class EmbeddingStore: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.transcripted.mcp.vectors", qos: .utility)
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let provider: EmbeddingProvider
    private let dbPath: URL

    /// Minimum cosine similarity for a row to count as a semantic match.
    /// NLEmbedding sentence vectors have a fairly high similarity floor (even
    /// unrelated short sentences land around ~0.30), so this trims the obvious
    /// tail rather than acting as a precise relevance cut. Hybrid mode is
    /// rank-based and still surfaces exact FTS hits regardless of this value.
    private let minimumSimilarity: Float = 0.30

    /// Cap on candidate rows scanned per query, newest first, to bound work on
    /// very large libraries. Personal-scale libraries stay well under this.
    private let maxCandidateRows = 50_000

    var isAvailable: Bool { provider.isAvailable }

    init(dbPath: URL, provider: EmbeddingProvider) throws {
        self.dbPath = dbPath
        self.provider = provider
        try queue.sync {
            if sqlite3_open(dbPath.path, &db) != SQLITE_OK {
                throw MCPIndexError.databaseOpenFailed(dbErrorLocked())
            }
            sqlite3_exec(db, "PRAGMA busy_timeout=5000", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
            sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)
            createTablesLocked()
        }
    }

    deinit {
        queue.sync {
            if let db = db { sqlite3_close(db) }
        }
    }

    private func createTablesLocked() {
        execLocked("""
            CREATE TABLE IF NOT EXISTS embedding_meta (
                id INTEGER PRIMARY KEY CHECK (id = 0),
                model_id TEXT NOT NULL,
                dimension INTEGER NOT NULL
            )
        """)
        // rowid mirrors utterances.rowid / dictation_entries.rowid. Those rows are
        // deleted and re-inserted on reindex, so vectors can be orphaned — the
        // reconcile pass cleans orphans and embeds the new rows.
        execLocked("""
            CREATE TABLE IF NOT EXISTS utterance_vectors (
                rowid INTEGER PRIMARY KEY,
                vec BLOB NOT NULL
            )
        """)
        execLocked("""
            CREATE TABLE IF NOT EXISTS dictation_entry_vectors (
                rowid INTEGER PRIMARY KEY,
                vec BLOB NOT NULL
            )
        """)
    }

    // MARK: - Embedding reconciliation

    /// Embed any indexed rows that don't yet have a vector, drop orphaned
    /// vectors, and re-embed everything if the model identity changed. Safe to
    /// call after every lexical reconcile; it only does work for new/changed rows.
    func reconcileEmbeddings() {
        guard provider.isAvailable else { return }
        queue.sync {
            invalidateOnModelChangeLocked()
            // Drop vectors whose backing rows are gone (reindex churns rowids).
            execLocked("DELETE FROM utterance_vectors WHERE rowid NOT IN (SELECT rowid FROM utterances)")
            execLocked("DELETE FROM dictation_entry_vectors WHERE rowid NOT IN (SELECT rowid FROM dictation_entries)")

            embedMissingLocked(
                selectSQL: """
                    SELECT u.rowid, u.text FROM utterances u
                    LEFT JOIN utterance_vectors v ON v.rowid = u.rowid
                    WHERE v.rowid IS NULL
                """,
                insertSQL: "INSERT OR REPLACE INTO utterance_vectors (rowid, vec) VALUES (?, ?)"
            )
            embedMissingLocked(
                selectSQL: """
                    SELECT e.rowid, e.text FROM dictation_entries e
                    LEFT JOIN dictation_entry_vectors v ON v.rowid = e.rowid
                    WHERE v.rowid IS NULL
                """,
                insertSQL: "INSERT OR REPLACE INTO dictation_entry_vectors (rowid, vec) VALUES (?, ?)"
            )
        }
    }

    private func invalidateOnModelChangeLocked() {
        var storedModel: String?
        var storedDim: Int = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT model_id, dimension FROM embedding_meta WHERE id = 0", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                storedModel = String(cString: sqlite3_column_text(stmt, 0))
                storedDim = Int(sqlite3_column_int64(stmt, 1))
            }
        }
        sqlite3_finalize(stmt)

        if storedModel == provider.modelID, storedDim == provider.dimension { return }

        if storedModel != nil {
            log("Embedding model changed (\(storedModel ?? "?")/\(storedDim) -> \(provider.modelID)/\(provider.dimension)); re-embedding")
            execLocked("DELETE FROM utterance_vectors")
            execLocked("DELETE FROM dictation_entry_vectors")
        }
        var upsert: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO embedding_meta (id, model_id, dimension) VALUES (0, ?, ?)", -1, &upsert, nil) == SQLITE_OK {
            sqlite3_bind_text(upsert, 1, (provider.modelID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(upsert, 2, Int64(provider.dimension))
            sqlite3_step(upsert)
        }
        sqlite3_finalize(upsert)
    }

    private func embedMissingLocked(selectSQL: String, insertSQL: String) {
        // Collect (rowid, text) first so the read cursor isn't open while we write.
        var pending: [(rowid: Int64, text: String)] = []
        var selectStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK {
            while sqlite3_step(selectStmt) == SQLITE_ROW {
                let rowid = sqlite3_column_int64(selectStmt, 0)
                let text = sqlite3_column_text(selectStmt, 1).map { String(cString: $0) } ?? ""
                pending.append((rowid, text))
            }
        }
        sqlite3_finalize(selectStmt)
        guard !pending.isEmpty else { return }

        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        var inserted = 0
        for item in pending {
            guard let vec = provider.embed(item.text) else { continue }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else { continue }
            sqlite3_bind_int64(stmt, 1, item.rowid)
            let blob = VectorMath.blob(from: vec)
            _ = blob.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(blob.count), SQLITE_TRANSIENT)
            }
            if sqlite3_step(stmt) == SQLITE_DONE { inserted += 1 }
            sqlite3_finalize(stmt)
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        if inserted > 0 { log("Embedded \(inserted) rows") }
    }

    // MARK: - Semantic search

    /// Cosine-ranked meeting utterance search, grouped per meeting (same shape as
    /// the lexical path). Returns empty when the query can't be embedded.
    func semanticSearchUtterances(
        query: String,
        speaker: String?,
        dateFrom: String?,
        dateTo: String?,
        maxMeetings: Int = 10,
        snippetsPerMeeting: Int = 3
    ) -> GroupedSearchResult {
        guard let qvec = provider.embed(query) else {
            return GroupedSearchResult(results: [], totalMeetingsMatched: 0, truncated: false)
        }

        return queue.sync {
            var sql = """
                SELECT u.filename, u.speaker_name, u.utterance_start, u.text,
                       m.date, m.datetime, m.duration_seconds, v.vec
                FROM utterance_vectors v
                JOIN utterances u ON u.rowid = v.rowid
                JOIN meetings m ON m.filename = u.filename
                WHERE 1 = 1
            """
            var binders: [(OpaquePointer?, Int32) -> Void] = []
            var nextIndex: Int32 = 1

            if let speaker = speaker {
                let names = NameVariants.expandName(speaker)
                let exact = names.map { _ in "u.speaker_name COLLATE NOCASE = ?" }
                let like = names.map { _ in "u.speaker_name COLLATE NOCASE LIKE ?" }
                sql += " AND (\((exact + like).joined(separator: " OR ")))"
                for name in names {
                    binders.append { stmt, idx in sqlite3_bind_text(stmt, idx, (name as NSString).utf8String, -1, self.SQLITE_TRANSIENT) }
                }
                for name in names {
                    let pattern = "%\(name)%"
                    binders.append { stmt, idx in sqlite3_bind_text(stmt, idx, (pattern as NSString).utf8String, -1, self.SQLITE_TRANSIENT) }
                }
            }
            if let dateFrom = dateFrom {
                sql += " AND m.date >= ?"
                binders.append { stmt, idx in sqlite3_bind_text(stmt, idx, (dateFrom as NSString).utf8String, -1, self.SQLITE_TRANSIENT) }
            }
            if let dateTo = dateTo {
                sql += " AND m.date <= ?"
                binders.append { stmt, idx in sqlite3_bind_text(stmt, idx, (dateTo as NSString).utf8String, -1, self.SQLITE_TRANSIENT) }
            }
            sql += " ORDER BY m.datetime DESC LIMIT \(maxCandidateRows)"

            struct Scored {
                let filename: String, speaker: String, start: Double, text: String
                let date: String, datetime: String, duration: Int, score: Float
            }
            var scored: [Scored] = []

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                return GroupedSearchResult(results: [], totalMeetingsMatched: 0, truncated: false)
            }
            for binder in binders { binder(stmt, nextIndex); nextIndex += 1 }

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let blobPtr = sqlite3_column_blob(stmt, 7) else { continue }
                let blobLen = Int(sqlite3_column_bytes(stmt, 7))
                let vec = VectorMath.vector(from: Data(bytes: blobPtr, count: blobLen))
                let score = VectorMath.dot(qvec, vec)
                guard score >= minimumSimilarity else { continue }
                scored.append(Scored(
                    filename: colText(stmt, 0),
                    speaker: colText(stmt, 1),
                    start: sqlite3_column_double(stmt, 2),
                    text: colText(stmt, 3),
                    date: colText(stmt, 4),
                    datetime: colText(stmt, 5),
                    duration: Int(sqlite3_column_int64(stmt, 6)),
                    score: score
                ))
            }
            sqlite3_finalize(stmt)

            scored.sort { $0.score > $1.score }

            // Group by meeting, ordered by best-scoring hit (first appearance).
            var grouped: [String: (date: String, datetime: String, snippets: [SearchSnippet])] = [:]
            var order: [String] = []
            for row in scored {
                if grouped[row.filename] == nil {
                    order.append(row.filename)
                    grouped[row.filename] = (row.date, row.datetime, [])
                }
                if (grouped[row.filename]?.snippets.count ?? 0) < snippetsPerMeeting {
                    let mins = Int(row.start) / 60
                    let secs = Int(row.start) % 60
                    grouped[row.filename]?.snippets.append(SearchSnippet(
                        speaker: row.speaker,
                        speakerId: nil,
                        timestamp: String(format: "%d:%02d", mins, secs),
                        text: row.text
                    ))
                }
            }

            let total = order.count
            let results = order.prefix(maxMeetings).compactMap { filename -> MeetingSearchGroup? in
                guard let g = grouped[filename] else { return nil }
                let title = filename
                    .replacingOccurrences(of: "Call_", with: "")
                    .replacingOccurrences(of: "_", with: " ")
                    .replacingOccurrences(of: "-", with: ":")
                return MeetingSearchGroup(
                    meetingTitle: title,
                    meetingDate: g.date,
                    meetingDateTime: g.datetime,
                    filename: filename,
                    snippets: g.snippets
                )
            }
            return GroupedSearchResult(
                results: Array(results),
                totalMeetingsMatched: total,
                truncated: total > maxMeetings
            )
        }
    }

    /// Cosine-ranked dictation entry search, one snippet per entry (same shape as
    /// the lexical path). Returns empty when the query can't be embedded.
    func semanticSearchDictationEntries(
        query: String,
        dateFrom: String?,
        dateTo: String?,
        maxItems: Int = 10
    ) -> [ContextSearchGroup] {
        guard let qvec = provider.embed(query) else { return [] }

        return queue.sync {
            var sql = """
                SELECT e.filename, e.entry_id, e.title, e.created_at, e.text,
                       e.source_app_name, e.delivery, d.date, v.vec
                FROM dictation_entry_vectors v
                JOIN dictation_entries e ON e.rowid = v.rowid
                JOIN dictation_days d ON d.filename = e.filename
                WHERE 1 = 1
            """
            var binders: [(OpaquePointer?, Int32) -> Void] = []
            var nextIndex: Int32 = 1
            if let dateFrom = dateFrom {
                sql += " AND d.date >= ?"
                binders.append { stmt, idx in sqlite3_bind_text(stmt, idx, (dateFrom as NSString).utf8String, -1, self.SQLITE_TRANSIENT) }
            }
            if let dateTo = dateTo {
                sql += " AND d.date <= ?"
                binders.append { stmt, idx in sqlite3_bind_text(stmt, idx, (dateTo as NSString).utf8String, -1, self.SQLITE_TRANSIENT) }
            }
            sql += " ORDER BY d.datetime DESC LIMIT \(maxCandidateRows)"

            struct Scored {
                let group: ContextSearchGroup
                let score: Float
            }
            var scored: [Scored] = []

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            for binder in binders { binder(stmt, nextIndex); nextIndex += 1 }

            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let blobPtr = sqlite3_column_blob(stmt, 8) else { continue }
                let blobLen = Int(sqlite3_column_bytes(stmt, 8))
                let vec = VectorMath.vector(from: Data(bytes: blobPtr, count: blobLen))
                let score = VectorMath.dot(qvec, vec)
                guard score >= minimumSimilarity else { continue }
                let group = ContextSearchGroup(
                    kind: .dictation,
                    title: colText(stmt, 2),
                    filename: colText(stmt, 0),
                    entryId: colText(stmt, 1),
                    date: colText(stmt, 7),
                    datetime: colText(stmt, 3),
                    snippets: [
                        ContextSearchSnippet(
                            text: colText(stmt, 4),
                            speaker: nil,
                            speakerId: nil,
                            timestamp: nil,
                            sourceAppName: colText(stmt, 5),
                            delivery: colText(stmt, 6)
                        )
                    ]
                )
                scored.append(Scored(group: group, score: score))
            }
            sqlite3_finalize(stmt)

            scored.sort { $0.score > $1.score }
            return Array(scored.prefix(maxItems).map(\.group))
        }
    }

    // MARK: - SQLite helpers (own connection)

    private func execLocked(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            log("Vector store SQL failed: \(dbErrorLocked()) for: \(sql)")
        }
    }

    private func colText(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: ptr)
    }

    private func dbErrorLocked() -> String {
        if let db = db { return String(cString: sqlite3_errmsg(db)) }
        return "database not open"
    }
}
