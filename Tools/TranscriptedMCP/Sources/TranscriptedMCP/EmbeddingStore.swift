import CryptoKit
import Darwin
import Foundation
import NaturalLanguage
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
    private let admissionCondition = NSCondition()
    private var deferredStartupReconciliation = false
    private var reconciliationActive = false
    // A first pass deferred by the embed lock must not search old-model vectors.
    private var hasReconciledModel = false
    private var activeSemanticSearches = 0
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let provider: EmbeddingProvider
    private let dbPath: URL
    private let embedLockPath: URL
    /// A contended pass defers after this interval; it never duplicates a live
    /// holder's work. The next reconcile retries, and process exit releases flock.
    private let embedLockTimeout: TimeInterval
    /// Mixed into every `embedding_cache` key so vectors from a different model,
    /// dimension or OS model revision are never reused.
    private let cacheNamespace: Data
    private let now: @Sendable () -> Date
    private let cacheTTL: TimeInterval
    /// A cache hit only rewrites `last_used` when it is at least this stale, so
    /// a steady stream of hits doesn't turn into a stream of writes.
    private let cacheTouchInterval: TimeInterval = 60 * 60
    struct BackfillBatchMetrics: Sendable {
        let rowCount: Int
        let newVectorCount: Int
        let cachedVectorCount: Int
    }
    private let onBackfillBatch: (@Sendable (BackfillBatchMetrics) -> Void)?
    private let backfillBatchSize = 100

    /// Minimum cosine similarity for a row to count as a semantic match.
    /// NLEmbedding sentence vectors have a fairly high similarity floor (even
    /// unrelated short sentences land around ~0.30), so this trims the obvious
    /// tail rather than acting as a precise relevance cut. Hybrid mode is
    /// rank-based and still surfaces exact FTS hits regardless of this value.
    private let minimumSimilarity: Float = 0.30

    /// Cap on candidate rows scanned per query, newest first, to bound work on
    /// very large libraries. Personal-scale libraries stay well under this.
    private let maxCandidateRows = 50_000

    init(
        dbPath: URL,
        provider: EmbeddingProvider,
        cacheTTL: TimeInterval = 72 * 60 * 60,
        embedLockTimeout: TimeInterval = 30,
        now: @escaping @Sendable () -> Date = { Date() },
        onBackfillBatch: (@Sendable (BackfillBatchMetrics) -> Void)? = nil
    ) throws {
        self.dbPath = dbPath
        self.embedLockTimeout = embedLockTimeout
        self.provider = provider
        self.embedLockPath = dbPath.deletingLastPathComponent()
            .appendingPathComponent("mcp_index.embed.lock", isDirectory: false)
        self.cacheNamespace = Data(Self.cacheNamespace(for: provider).utf8)
        self.cacheTTL = cacheTTL
        self.now = now
        self.onBackfillBatch = onBackfillBatch
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
        // Content-keyed vector reuse. Lexical reindexing deletes and reinserts
        // every row of a rewritten file (a whole dictation day on each new
        // entry, a whole meeting on a speaker rename), so per-rowid vectors are
        // orphaned even when the text is unchanged. key = SHA-256 of
        // namespace + 0x00 + the exact text handed to the provider. Additive:
        // older helpers never read it, and the lexical schema gate leaves it
        // alone.
        execLocked("""
            CREATE TABLE IF NOT EXISTS embedding_cache (
                key BLOB PRIMARY KEY,
                vec BLOB NOT NULL,
                last_used INTEGER NOT NULL
            ) WITHOUT ROWID
        """)
        execLocked("CREATE INDEX IF NOT EXISTS embedding_cache_last_used ON embedding_cache(last_used)")
    }

    // MARK: - Embedding reconciliation

    func deferSemanticSearchUntilReconciled() {
        admissionCondition.lock()
        deferredStartupReconciliation = true
        admissionCondition.unlock()
    }

    func finishDeferredStartupReconciliation() {
        admissionCondition.lock()
        deferredStartupReconciliation = false
        admissionCondition.unlock()
    }

    /// Embed any indexed rows that don't yet have a vector, drop orphaned
    /// vectors, and re-embed everything if the model identity changed. Safe to
    /// call after every lexical reconcile; it only does work for new/changed rows.
    func reconcileEmbeddings(isCancelled: () -> Bool = { Task.isCancelled }) {
        guard provider.isAvailable, !isCancelled() else { return }

        // Every MCP client runs its own server on this index. Serialize the
        // embedding pass across them so one server embeds a new row and the rest
        // find it already done (or reuse it from embedding_cache). Taken before
        // `reconciliationActive` is set, so semantic search keeps answering here
        // while another process embeds. Never taken while holding the lexical
        // reconcile lock (TranscriptIndex.reconcile releases it first). If the
        // lock can't be acquired, leave semantic backfill for the next pass;
        // lexical reads and writes remain available. Never unlink a live lock.
        guard let embedLockDescriptor = Self.acquireEmbedLock(
            at: embedLockPath, timeout: embedLockTimeout, isCancelled: isCancelled
        ) else { return }
        defer { Self.releaseEmbedLock(embedLockDescriptor) }

        admissionCondition.lock()
        while reconciliationActive {
            admissionCondition.wait()
        }
        guard !isCancelled() else { admissionCondition.unlock(); return }
        reconciliationActive = true
        while activeSemanticSearches > 0 {
            admissionCondition.wait()
        }
        admissionCondition.unlock()

        defer {
            admissionCondition.lock()
            reconciliationActive = false
            admissionCondition.broadcast()
            admissionCondition.unlock()
        }
        queue.sync {
            guard !isCancelled() else { return }
            invalidateOnModelChangeLocked()
            admissionCondition.lock()
            hasReconciledModel = true
            admissionCondition.unlock()
            // Drop vectors whose backing rows are gone (reindex churns rowids).
            execLocked("DELETE FROM utterance_vectors WHERE rowid NOT IN (SELECT rowid FROM utterances)")
            execLocked("DELETE FROM dictation_entry_vectors WHERE rowid NOT IN (SELECT rowid FROM dictation_entries)")

            embedMissingLocked(table: "utterances", vectors: "utterance_vectors", isCancelled: isCancelled)
            embedMissingLocked(table: "dictation_entries", vectors: "dictation_entry_vectors", isCancelled: isCancelled)
            if !isCancelled() { pruneEmbeddingCacheLocked() }
        }
    }

    // MARK: - Cross-process embed lock

    /// Polls a non-blocking lock about every 100 ms until `timeout`. EINTR
    /// retries; any other error, or the deadline, closes the descriptor and
    /// returns nil so the caller defers the pass. Cancellation is cooperative.
    private static func acquireEmbedLock(at lockPath: URL, timeout: TimeInterval, isCancelled: () -> Bool) -> Int32? {
        let descriptor = open(lockPath.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, timeout) * 1_000_000_000)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let failure = errno
            if isCancelled() { close(descriptor); return nil }
            if failure == EINTR { continue }
            guard failure == EWOULDBLOCK, DispatchTime.now().uptimeNanoseconds < deadline else {
                close(descriptor)
                return nil
            }
            usleep(100_000)
        }
        _ = fchmod(descriptor, 0o600)
        return descriptor
    }

    private static func releaseEmbedLock(_ descriptor: Int32?) {
        guard let descriptor else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    // MARK: - Embedding cache

    static func cacheNamespace(for provider: EmbeddingProvider) -> String {
        var namespace = "\(provider.modelID)|\(provider.dimension)"
        if provider is NLEmbeddingProvider {
            // modelID is "nl.sentence.<language>.v1"; an OS update can ship a new
            // sentence-embedding revision under the same id.
            let parts = provider.modelID.split(separator: ".")
            if parts.count >= 3 {
                let language = NLLanguage(rawValue: String(parts[2]))
                namespace += "|rev\(NLEmbedding.currentSentenceEmbeddingRevision(for: language))"
            }
        }
        return namespace
    }

    private func cacheKey(for text: String) -> Data {
        var hasher = SHA256()
        hasher.update(data: cacheNamespace)
        hasher.update(data: Data([0]))
        hasher.update(data: Data(text.utf8))
        return Data(hasher.finalize())
    }

    private func nowSeconds() -> Int64 {
        Int64(now().timeIntervalSince1970)
    }

    /// Cached vectors (and when each was last used) for the given keys. Only
    /// blobs of the provider's exact size count as hits.
    private func lookupCachedVectorsLocked(_ keys: [Data]) -> [Data: (vec: Data, lastUsed: Int64)] {
        var hits: [Data: (vec: Data, lastUsed: Int64)] = [:]
        let expectedBytes = provider.dimension * MemoryLayout<Float>.stride
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT vec, last_used FROM embedding_cache WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return hits
        }
        defer { sqlite3_finalize(stmt) }
        for key in keys where hits[key] == nil {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            _ = key.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 1, raw.baseAddress, Int32(key.count), SQLITE_TRANSIENT)
            }
            guard sqlite3_step(stmt) == SQLITE_ROW,
                  let blobPtr = sqlite3_column_blob(stmt, 0) else { continue }
            let blobLen = Int(sqlite3_column_bytes(stmt, 0))
            guard expectedBytes > 0, blobLen == expectedBytes else { continue }
            hits[key] = (Data(bytes: blobPtr, count: blobLen), sqlite3_column_int64(stmt, 1))
        }
        return hits
    }

    private func pruneEmbeddingCacheLocked() {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM embedding_cache WHERE last_used < ?", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_int64(stmt, 1, nowSeconds() - Int64(cacheTTL))
            if sqlite3_step(stmt) != SQLITE_DONE {
                log("Vector store SQL operation failed")
            }
        }
        sqlite3_finalize(stmt)
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
            execLocked("DELETE FROM embedding_cache")
        }
        var upsert: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO embedding_meta (id, model_id, dimension) VALUES (0, ?, ?)", -1, &upsert, nil) == SQLITE_OK {
            sqlite3_bind_text(upsert, 1, (provider.modelID as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(upsert, 2, Int64(provider.dimension))
            sqlite3_step(upsert)
        }
        sqlite3_finalize(upsert)
    }

    private func embedMissingLocked(table: String, vectors: String, isCancelled: () -> Bool) {
        guard !isCancelled() else { return }
        // Lexical rowids are AUTOINCREMENT. Freeze the upper bound so imports
        // arriving during a pass are left for the next reconcile.
        var boundStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(rowid) FROM \(table)", -1, &boundStmt, nil) == SQLITE_OK else {
            sqlite3_finalize(boundStmt)
            return
        }
        let upperBound = sqlite3_step(boundStmt) == SQLITE_ROW ? sqlite3_column_int64(boundStmt, 0) : 0
        sqlite3_finalize(boundStmt)
        var lastRowID: Int64 = 0
        let selectSQL = """
            SELECT t.rowid, t.text FROM \(table) t
            LEFT JOIN \(vectors) v ON v.rowid = t.rowid
            WHERE v.rowid IS NULL AND t.rowid > ? AND t.rowid <= ?
            ORDER BY t.rowid LIMIT ?
            """
        let insertSQL = """
            INSERT OR REPLACE INTO \(vectors) (rowid, vec)
            SELECT ?, ? WHERE EXISTS (SELECT 1 FROM \(table) WHERE rowid = ?)
            """
        var inserted = 0
        var providerEmbedded = 0
        while lastRowID < upperBound, !isCancelled() {
            // Finalize the bounded read before provider calls or writes. Nothing
            // retains previous pages' strings or vectors; later reuse is on disk.
            var batch: [(rowid: Int64, text: String, key: Data)] = []
            var selectStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, selectSQL, -1, &selectStmt, nil) == SQLITE_OK else {
                sqlite3_finalize(selectStmt)
                break
            }
            sqlite3_bind_int64(selectStmt, 1, lastRowID)
            sqlite3_bind_int64(selectStmt, 2, upperBound)
            sqlite3_bind_int(selectStmt, 3, Int32(backfillBatchSize))
            while sqlite3_step(selectStmt) == SQLITE_ROW {
                let rowid = sqlite3_column_int64(selectStmt, 0)
                let text = sqlite3_column_text(selectStmt, 1).map { String(cString: $0) } ?? ""
                batch.append((rowid, text, cacheKey(for: text)))
            }
            sqlite3_finalize(selectStmt)
            guard let finalRow = batch.last else { break }
            // Advance even when every provider result is nil or every write fails.
            lastRowID = finalRow.rowid
            var embeddedThisBatch: [Data: Data] = [:]
            let cached = lookupCachedVectorsLocked(batch.map { $0.key })
            let timestamp = nowSeconds()
            let staleBefore = timestamp - Int64(cacheTouchInterval)

            // Vector computation is the slow part and happens before the
            // transaction, so lexical watcher updates can continue while a large
            // semantic backlog is processed. Cache hits and texts already
            // embedded earlier in this batch skip the provider entirely.
            var rows: [(rowid: Int64, blob: Data)] = []
            var newCacheRows: [(key: Data, blob: Data)] = []
            var touchedKeys: Set<Data> = []
            for item in batch {
                guard !isCancelled() else { return }
                if let hit = cached[item.key] {
                    rows.append((item.rowid, hit.vec))
                    if hit.lastUsed < staleBefore { touchedKeys.insert(item.key) }
                } else if let blob = embeddedThisBatch[item.key] {
                    rows.append((item.rowid, blob))
                } else if let vector = provider.embed(item.text) {
                    providerEmbedded += 1
                    let blob = VectorMath.blob(from: vector)
                    rows.append((item.rowid, blob))
                    embeddedThisBatch[item.key] = blob
                    // Never cache a vector of the wrong size; lookups would
                    // reject it anyway.
                    if blob.count == provider.dimension * MemoryLayout<Float>.stride {
                        newCacheRows.append((item.key, blob))
                    }
                }
            }
            guard !isCancelled() else { return }
            onBackfillBatch?(BackfillBatchMetrics(
                rowCount: batch.count, newVectorCount: embeddedThisBatch.count, cachedVectorCount: cached.count
            ))
            guard !rows.isEmpty else { continue }

            // Keep the database write lock short.
            guard sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK else { return }
            for (rowid, blob) in rows {
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else {
                    sqlite3_finalize(stmt)
                    continue
                }
                sqlite3_bind_int64(stmt, 1, rowid)
                _ = blob.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(blob.count), SQLITE_TRANSIENT)
                }
                sqlite3_bind_int64(stmt, 3, rowid)
                if sqlite3_step(stmt) == SQLITE_DONE { inserted += Int(sqlite3_changes(db)) }
                sqlite3_finalize(stmt)
            }
            for (key, blob) in newCacheRows {
                bindAndStepLocked(
                    "INSERT OR IGNORE INTO embedding_cache (key, vec, last_used) VALUES (?, ?, ?)",
                    key: key,
                    blob: blob,
                    timestamp: timestamp
                )
            }
            for key in touchedKeys {
                bindAndStepLocked(
                    "UPDATE embedding_cache SET last_used = ? WHERE key = ?",
                    key: key,
                    blob: nil,
                    timestamp: timestamp
                )
            }
            if sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
                return
            }
        }
        if inserted > 0 {
            // count_bucket is rows the provider had to embed; reused_bucket is
            // rows filled from embedding_cache. Buckets only, never keys.
            log("Embedded semantic rows (count_bucket=\(MCPLogPrivacy.countBucket(providerEmbedded)), reused_bucket=\(MCPLogPrivacy.countBucket(max(0, inserted - providerEmbedded))))")
        }
    }

    /// Runs one cache write. With a blob: (key, vec, last_used). Without one:
    /// (last_used, key).
    private func bindAndStepLocked(_ sql: String, key: Data, blob: Data?, timestamp: Int64) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return
        }
        defer { sqlite3_finalize(stmt) }
        if let blob {
            _ = key.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 1, raw.baseAddress, Int32(key.count), SQLITE_TRANSIENT)
            }
            _ = blob.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(blob.count), SQLITE_TRANSIENT)
            }
            sqlite3_bind_int64(stmt, 3, timestamp)
        } else {
            sqlite3_bind_int64(stmt, 1, timestamp)
            _ = key.withUnsafeBytes { raw in
                sqlite3_bind_blob(stmt, 2, raw.baseAddress, Int32(key.count), SQLITE_TRANSIENT)
            }
        }
        _ = sqlite3_step(stmt)
    }

    // MARK: - Semantic search

    private func withSemanticSearchAdmission<T>(_ body: () -> T) -> T? {
        admissionCondition.lock()
        guard provider.isAvailable,
              hasReconciledModel,
              !deferredStartupReconciliation,
              !reconciliationActive else {
            admissionCondition.unlock()
            return nil
        }
        activeSemanticSearches += 1
        admissionCondition.unlock()

        defer {
            admissionCondition.lock()
            activeSemanticSearches -= 1
            if activeSemanticSearches == 0 {
                admissionCondition.broadcast()
            }
            admissionCondition.unlock()
        }
        return body()
    }

    func semanticSearchUtterancesIfAvailable(
        query: String,
        speaker: String?,
        dateFrom: String?,
        dateTo: String?,
        maxMeetings: Int = 10,
        snippetsPerMeeting: Int = 3
    ) -> GroupedSearchResult? {
        withSemanticSearchAdmission {
            semanticSearchUtterances(
                query: query,
                speaker: speaker,
                dateFrom: dateFrom,
                dateTo: dateTo,
                maxMeetings: maxMeetings,
                snippetsPerMeeting: snippetsPerMeeting
            )
        }
    }

    /// Cosine-ranked meeting utterance search, grouped per meeting (same shape as
    /// the lexical path). Returns empty when the query can't be embedded.
    private func semanticSearchUtterances(
        query: String,
        speaker: String?,
        dateFrom: String?,
        dateTo: String?,
        maxMeetings: Int,
        snippetsPerMeeting: Int
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
                let title = TranscriptLoader.fallbackMeetingTitle(forFilename: filename)
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

    func semanticSearchDictationEntriesIfAvailable(
        query: String,
        dateFrom: String?,
        dateTo: String?,
        maxItems: Int = 10
    ) -> [ContextSearchGroup]? {
        withSemanticSearchAdmission {
            semanticSearchDictationEntries(
                query: query,
                dateFrom: dateFrom,
                dateTo: dateTo,
                maxItems: maxItems
            )
        }
    }

    /// Cosine-ranked dictation entry search, one snippet per entry (same shape as
    /// the lexical path). Returns empty when the query can't be embedded.
    private func semanticSearchDictationEntries(
        query: String,
        dateFrom: String?,
        dateTo: String?,
        maxItems: Int
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
    //
    // colText/dbErrorLocked are byte-identical to SQLiteHelpers.swift's
    // sqlColText/sqlDBError, so they delegate. execLocked keeps its own body:
    // its "Vector store SQL failed" log prefix (vs. the shared helper's
    // generic "SQL exec failed") is intentionally distinct so vector-store
    // failures are identifiable in logs, and the raw prepare/bind sequences
    // above (lines ~113-171, ~230-253, ~337-367) mix in loop/transaction
    // control flow that isn't a 1:1 mechanical match for the shared helpers,
    // so they're left as-is rather than risk a behavior change.

    private func execLocked(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            log("Vector store SQL operation failed")
        }
    }

    private func colText(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        sqlColText(stmt, col)
    }

    private func dbErrorLocked() -> String {
        sqlDBError(db)
    }
}
