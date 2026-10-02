import Foundation
import Darwin
import SQLite3
import TranscriptedCaptureKit

final class TranscriptIndex: @unchecked Sendable {
    /// `private(set)` rather than `private`, and `queue` internal, only so the
    /// cross-file writing extension (TranscriptIndex+Writing.swift) can run its
    /// statements on this connection under the same serial queue. Nothing
    /// outside this type should touch either.
    private(set) var db: OpaquePointer?
    let queue = DispatchQueue(label: "com.transcripted.mcp.index", qos: .utility)
    /// Internal, not `private`, only so the TranscriptIndex+*.swift extensions
    /// can reach it (`private` is file-scoped). Nothing outside this type should
    /// touch it.
    let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let indexPath: URL
    private let reconcileLockPath: URL

    /// Optional semantic-search sidecar. Nil when no embedding provider was
    /// supplied or the provider is unavailable on this host; in that case every
    /// search transparently runs lexical-only. Additive: it manages its own
    /// vector tables on a separate connection to the same database file.
    private(set) var embeddingStore: EmbeddingStore?

    init(indexDir: URL, embeddingProvider: EmbeddingProvider? = nil) throws {
        self.indexPath = indexDir.appendingPathComponent("mcp_index.sqlite")
        self.reconcileLockPath = indexDir.appendingPathComponent("mcp_index.reconcile.lock", isDirectory: false)
        let setupLockPath = indexDir.appendingPathComponent("mcp_index.setup.lock", isDirectory: false)
        try queue.sync {
            try Self.withExclusiveLock(at: setupLockPath) {
                try self.openAndSetup()
            }
        }
        if let provider = embeddingProvider, provider.isAvailable {
            self.embeddingStore = try EmbeddingStore(dbPath: indexPath, provider: provider)
        }
    }

    deinit {
        queue.sync {
            if let db = db { sqlite3_close(db) }
        }
    }

    // MARK: - Setup

    /// Serializes a window across MCP client processes sharing one index. Setup
    /// uses it so two cold starts cannot remove the database underneath each
    /// other; reconcile uses a separate lock (see `reconcile`).
    private static func withExclusiveLock(
        at lockPath: URL,
        operation: () throws -> Void
    ) throws {
        let descriptor = open(lockPath.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw MCPIndexError.databaseOpenFailed("Could not open the index lock")
        }
        defer {
            _ = flock(descriptor, LOCK_UN)
            close(descriptor)
        }

        while flock(descriptor, LOCK_EX) != 0 {
            guard errno == EINTR else {
                throw MCPIndexError.databaseOpenFailed("Could not acquire the index lock")
            }
        }
        _ = chmod(lockPath.path, 0o600)
        try operation()
    }

    private func openAndSetup() throws {
        if sqlite3_open(indexPath.path, &db) != SQLITE_OK {
            throw MCPIndexError.databaseOpenFailed(dbError())
        }
        configureDatabase()

        // Integrity check
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                let result = String(cString: sqlite3_column_text(stmt, 0))
                if result != "ok" {
                    sqlite3_finalize(stmt)
                    sqlite3_close(db)
                    db = nil
                    try? FileManager.default.removeItem(at: indexPath)
                    log("Index corrupt, rebuilding")
                    if sqlite3_open(indexPath.path, &db) != SQLITE_OK {
                        throw MCPIndexError.databaseOpenFailed(dbError())
                    }
                    configureDatabase()
                }
            }
            sqlite3_finalize(stmt)
        }

        try applySchemaVersionGate()
        createTables()
        // Only ever raise it. An older helper still running from before an
        // update must not roll the version back, or the next newer helper to
        // open would rebuild again.
        if storedUserVersion() < Self.schemaVersion {
            exec("PRAGMA user_version=\(Self.schemaVersion)")
        }
    }

    /// Bump when the derived index shape changes so existing on-disk indexes are
    /// rebuilt from disk on next open. v2 added `meeting_summary_items`; v3 added
    /// the meeting-summary FTS document used by general search; v4 adds action
    /// item `status` and `due` metadata; v5 makes that metadata searchable; v6
    /// adds the writing day tables and stops indexing `Writing_` files found in
    /// a shared folder as meetings.
    private static let schemaVersion: Int32 = 6

    /// An already-indexed meeting whose transcript mtime is unchanged is skipped
    /// by `reconcile`, so a schema addition (new table/column) would never
    /// populate for it. When the stored `user_version` is older than the current
    /// schema, empty the index so the next reconcile rebuilds every derived
    /// table from disk. (Old/unversioned indexes report 0, indistinguishable
    /// from a fresh DB — emptying an empty fresh DB is a harmless no-op.)
    ///
    /// It drops the tables in place, in one transaction, rather than deleting
    /// the file: every agent runs its own server on this index, and after an
    /// update some are still the old version. Deleting the database under
    /// their open connections left them failing every query with "disk I/O
    /// error" until they were restarted.
    private func applySchemaVersionGate() throws {
        guard storedUserVersion() < Self.schemaVersion else { return }
        log("Index schema older than v\(Self.schemaVersion), rebuilding from disk")
        try execOrThrow("BEGIN IMMEDIATE")
        do {
            // Virtual tables first: dropping one drops its shadow tables,
            // which must never be dropped on their own.
            for name in schemaObjectNames(virtualTablesOnly: true) {
                try execOrThrow("DROP TABLE IF EXISTS \(Self.quotedIdentifier(name))")
            }
            for name in schemaObjectNames(virtualTablesOnly: false) {
                try execOrThrow("DROP TABLE IF EXISTS \(Self.quotedIdentifier(name))")
            }
            try execOrThrow("COMMIT")
        } catch {
            exec("ROLLBACK")
            throw error
        }
    }

    /// The index's own tables (triggers and indexes go with them).
    private func schemaObjectNames(virtualTablesOnly: Bool) -> [String] {
        let filter = virtualTablesOnly ? " AND sql LIKE 'CREATE VIRTUAL TABLE%'" : ""
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'\(filter)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var names: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            names.append(colText(stmt, 0))
        }
        return names
    }

    private static func quotedIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private func storedUserVersion() -> Int32 {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? sqlite3_column_int(stmt, 0) : 0
    }

    /// Apply owner-only file permissions and WAL pragmas to an already-opened database handle.
    /// Mirrors SpeakerDatabase.configureOpenDatabase() — called on initial open and after
    /// corruption-recovery re-open so setup logic stays in one place.
    private func configureDatabase() {
        chmod(indexPath.path, 0o600)
        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA busy_timeout=5000")
        exec("PRAGMA synchronous=NORMAL")
    }

    // MARK: - Reconciliation

    func reconcile(
        meetingsDir: URL,
        dictationsDir: URL,
        updateEmbeddings: Bool = true
    ) throws {
        try reconcile(
            meetingDirs: [meetingsDir],
            dictationDirs: [dictationsDir],
            updateEmbeddings: updateEmbeddings
        )
    }

    func reconcile(
        meetingDirs: [URL],
        dictationDirs: [URL],
        writingDirs: [URL] = [],
        updateEmbeddings: Bool = true
    ) throws {
        // Every MCP client (a desktop chat app, an IDE agent, ...) launches its own
        // server against the same index. Without this lock two processes reconcile
        // the same files at once: both see a file as new, both insert it, and the
        // loser fails with "UNIQUE constraint failed: meeting_summary_documents.filename",
        // which used to abort its whole pass. Holding the lock, the second process
        // re-reads the indexed mtimes after the first commits and skips that work.
        // The lock is taken before `queue`, not inside it: waiting on another
        // process's pass must not block this server's own read tools, which share
        // `queue` and can read the WAL database while the other process writes.
        var failedFileCount = 0
        var firstFailure: Error?
        try Self.withExclusiveLock(at: reconcileLockPath) {
            try queue.sync {
                var seenPaths: Set<String> = []
                var diskMap: [String: ContextArtifactFile] = [:]

                // A file's kind comes from the file (prefix / capture_type), not
                // from which directory list found it, so the flat shared-folder
                // fallback (all three lists are the same folder) stays correct.
                for directory in meetingDirs + dictationDirs + writingDirs {
                    let directoryPath = directory.standardizedFileURL.path
                    guard !seenPaths.contains(directoryPath) else { continue }
                    seenPaths.insert(directoryPath)

                    for file in TranscriptLoader.enumerateArtifacts(in: directory) {
                        let filename = file.url.deletingPathExtension().lastPathComponent
                        if diskMap[filename] == nil {
                            diskMap[filename] = file
                        }
                    }
                }

                let indexed = try getIndexedModDates()

                // Index new or updated files. A file that fails to index doesn't stop
                // the rest; the first failure is rethrown once the pass finishes.
                for (filename, info) in diskMap {
                    do {
                        if let indexedMod = indexed[filename] {
                            if abs(info.modDate - indexedMod) > 0.001 {
                                try reindex(file: info.url, filename: filename, kind: info.kind)
                            }
                        } else {
                            try indexOne(file: info.url, filename: filename, modDate: info.modDate, kind: info.kind)
                        }
                    } catch {
                        failedFileCount += 1
                        if firstFailure == nil { firstFailure = error }
                    }
                }

                // Remove stale entries
                for filename in indexed.keys where diskMap[filename] == nil {
                    do {
                        try removeFromIndex(filename: filename)
                    } catch {
                        failedFileCount += 1
                        if firstFailure == nil { firstFailure = error }
                    }
                }
            }
        }

        // Best-effort: embed any newly indexed rows. Never fails the reconcile —
        // lexical search must keep working even if embedding hits a snag. Runs
        // even when some files failed, so the files that did index still get
        // vectors instead of waiting for the bad file to be fixed.
        if updateEmbeddings {
            reconcileEmbeddings()
        }

        if let firstFailure {
            log("Reconcile skipped files that failed to index (count_bucket=\(MCPLogPrivacy.countBucket(failedFileCount)))")
            throw MCPReconcileFileFailures(failedFileCount: failedFileCount, firstFailure: firstFailure)
        }
    }

    func reconcileEmbeddings() {
        embeddingStore?.reconcileEmbeddings()
    }

    private func getIndexedModDates() throws -> [String: TimeInterval] {
        var result: [String: TimeInterval] = [:]
        var stmt: OpaquePointer?
        let sql = """
            SELECT filename, json_modified_at FROM meetings
            UNION ALL
            SELECT filename, json_modified_at FROM dictation_days
            UNION ALL
            SELECT filename, json_modified_at FROM writing_days
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MCPIndexError.queryFailed(dbError())
        }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let filename = String(cString: sqlite3_column_text(stmt, 0))
            let modDate = sqlite3_column_double(stmt, 1)
            result[filename] = modDate
        }
        return result
    }

    /// Returns false when the file couldn't be parsed, so nothing was written.
    @discardableResult
    private func indexOne(file url: URL, filename: String, modDate: TimeInterval, kind: ContextArtifactKind) throws -> Bool {
        switch kind {
        case .meeting:
            return try indexMeeting(file: url, filename: filename, modDate: modDate)
        case .dictationDay:
            return try indexDictationDay(file: url, filename: filename, modDate: modDate)
        case .writingDay:
            return try indexWritingDay(file: url, filename: filename, modDate: modDate)
        }
    }

    private func indexMeeting(file url: URL, filename: String, modDate: TimeInterval) throws -> Bool {
        guard let transcript = TranscriptLoader.loadMeeting(url) else { return false }
        let speakers = TranscriptLoader.speakerLookup(from: transcript)

        let dateOnly = String(transcript.recording.date.prefix(10))
        let wordCount = transcript.speakers.reduce(0) { $0 + $1.wordCount }

        try execOrThrow("BEGIN EXCLUSIVE")
        var committed = false
        defer { if !committed { exec("ROLLBACK") } }
        // Clear rows an earlier interrupted pass may have left for this file, so
        // indexing it is idempotent and the plain INSERTs below can't collide.
        try deleteIndexedRows(filename: filename)

        try bindExec(
            "INSERT OR REPLACE INTO meetings (filename, date, datetime, duration_seconds, speaker_count, word_count, json_modified_at) VALUES (?,?,?,?,?,?,?)",
            bindings: [
                .text(filename), .text(dateOnly), .text(transcript.recording.date),
                .int(transcript.recording.durationSeconds), .int(transcript.speakers.count),
                .int(wordCount), .double(modDate)
            ]
        )

        try bindExecRows(
            "INSERT OR REPLACE INTO meeting_speakers (filename, speaker_name, persistent_speaker_id, word_count, speaking_seconds) VALUES (?,?,?,?,?)",
            rows: transcript.speakers.map { speaker -> [SQLBinding] in
                [
                    .text(filename), .text(speaker.name),
                    speaker.persistentSpeakerId.map { .text($0) } ?? .null,
                    .int(speaker.wordCount), .double(speaker.speakingSeconds)
                ]
            }
        )

        try bindExecRows(
            "INSERT INTO utterances (filename, speaker_name, utterance_start, utterance_end, text) VALUES (?,?,?,?,?)",
            rows: transcript.utterances.map { utterance -> [SQLBinding] in
                let speakerName = speakers[utterance.speakerId]?.name ?? "Unknown"
                return [
                    .text(filename), .text(speakerName),
                    .double(utterance.start), .double(utterance.end), .text(utterance.text)
                ]
            }
        )

        if let summary = TranscriptLoader.loadMeetingSummary(forTranscript: url) {
            try insertSummaryItems(summary, filename: filename)
            try insertSummarySearchDocument(summary, filename: filename)
        }

        try execOrThrow("COMMIT")
        committed = true
        log("Indexed meeting (utterance_count_bucket=\(MCPLogPrivacy.countBucket(transcript.utterances.count)))")
        return true
    }

    /// Parse the meeting's structured summary (inline transcript summary, then a
    /// generated sidecar) and write one row per Decision / Action Item / Open
    /// Question. Called inside the meeting index transaction. A meeting with no
    /// summary inserts nothing.
    private func insertSummaryItems(_ summary: ParsedMeetingSummary, filename: String) throws {
        try bindExecRows(
            "INSERT INTO meeting_summary_items (filename, kind, position, owner, text) VALUES (?,?,?,?,?)",
            rows: summary.decisions.enumerated().map { position, text -> [SQLBinding] in
                [.text(filename), .text(SummaryItemKind.decision), .int(position), .null, .text(text)]
            }
        )
        try bindExecRows(
            "INSERT INTO meeting_summary_items (filename, kind, position, owner, text, status, due) VALUES (?,?,?,?,?,?,?)",
            rows: summary.actionItems.enumerated().map { position, item -> [SQLBinding] in
                [
                    .text(filename), .text(SummaryItemKind.actionItem), .int(position),
                    item.owner.map { .text($0) } ?? .null, .text(item.text),
                    item.status.map { .text($0) } ?? .null,
                    item.due.map { .text($0) } ?? .null
                ]
            }
        )
        try bindExecRows(
            "INSERT INTO meeting_summary_items (filename, kind, position, owner, text) VALUES (?,?,?,?,?)",
            rows: summary.openQuestions.enumerated().map { position, text -> [SQLBinding] in
                [.text(filename), .text(SummaryItemKind.openQuestion), .int(position), .null, .text(text)]
            }
        )
    }

    private func insertSummarySearchDocument(_ summary: ParsedMeetingSummary, filename: String) throws {
        try bindExec(
            """
            INSERT INTO meeting_summary_documents
                (filename, title, attendees, decisions, action_items, open_questions)
            VALUES (?,?,?,?,?,?)
            """,
            bindings: [
                .text(filename),
                .text(summary.title ?? ""),
                .text(summary.attendees.joined(separator: "\n")),
                .text(summary.decisions.joined(separator: "\n")),
                .text(summary.actionItems.map(\.text).joined(separator: "\n")),
                .text(summary.openQuestions.joined(separator: "\n"))
            ]
        )
    }

    private func indexDictationDay(file url: URL, filename: String, modDate: TimeInterval) throws -> Bool {
        guard let day = TranscriptLoader.loadDictationDay(url) else { return false }

        let latestEntryDate = day.entries.last?.createdAt ?? "\(day.date)T00:00:00+0000"

        try execOrThrow("BEGIN EXCLUSIVE")
        var committed = false
        defer { if !committed { exec("ROLLBACK") } }
        try deleteIndexedRows(filename: filename)

        try bindExec(
            "INSERT OR REPLACE INTO dictation_days (filename, date, datetime, markdown_filename, entry_count, word_count, json_modified_at) VALUES (?,?,?,?,?,?,?)",
            bindings: [
                .text(filename),
                .text(day.date),
                .text(latestEntryDate),
                .text(day.markdownFilename),
                .int(day.entryCount),
                .int(day.wordCount),
                .double(modDate)
            ]
        )

        try bindExecRows(
            "INSERT INTO dictation_entries (filename, entry_id, title, created_at, source_app_name, source_app_bundle_id, delivery, word_count, character_count, text) VALUES (?,?,?,?,?,?,?,?,?,?)",
            rows: day.entries.map { entry -> [SQLBinding] in
                [
                    .text(filename),
                    .text(entry.id),
                    .text(entry.title),
                    .text(entry.createdAt),
                    .text(entry.sourceAppName),
                    entry.sourceAppBundleId.map { .text($0) } ?? .null,
                    .text(entry.delivery),
                    .int(entry.wordCount),
                    .int(entry.characterCount),
                    .text(entry.text)
                ]
            }
        )

        try execOrThrow("COMMIT")
        committed = true
        log("Indexed dictation day (entry_count_bucket=\(MCPLogPrivacy.countBucket(day.entries.count)))")
        return true
    }

    /// `indexOne` clears the file's old rows inside its own transaction, so a
    /// failed reindex rolls back to the old rows instead of dropping the file
    /// from the index. Only a file that no longer parses is removed.
    private func reindex(file url: URL, filename: String, kind: ContextArtifactKind) throws {
        let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate?.timeIntervalSince1970) ?? Date().timeIntervalSince1970
        let indexed = try indexOne(file: url, filename: filename, modDate: modDate, kind: kind)
        if !indexed {
            try removeFromIndex(filename: filename)
        }
    }

    private func removeFromIndex(filename: String) throws {
        try execOrThrow("BEGIN EXCLUSIVE")
        var committed = false
        defer { if !committed { exec("ROLLBACK") } }
        try deleteIndexedRows(filename: filename)
        try execOrThrow("COMMIT")
        committed = true
    }

    /// Deletes every derived row for one file. Must run inside a transaction.
    /// Internal (not `private`) so TranscriptIndex+Writing.swift's indexer
    /// clears rows the same way the meeting and dictation indexers do.
    func deleteIndexedRows(filename: String) throws {
        try bindExec("DELETE FROM utterances WHERE filename = ?", bindings: [.text(filename)])
        try bindExec("DELETE FROM meeting_summary_items WHERE filename = ?", bindings: [.text(filename)])
        try bindExec("DELETE FROM meeting_summary_documents WHERE filename = ?", bindings: [.text(filename)])
        try bindExec("DELETE FROM meeting_speakers WHERE filename = ?", bindings: [.text(filename)])
        try bindExec("DELETE FROM meetings WHERE filename = ?", bindings: [.text(filename)])
        try bindExec("DELETE FROM dictation_entries WHERE filename = ?", bindings: [.text(filename)])
        try bindExec("DELETE FROM dictation_days WHERE filename = ?", bindings: [.text(filename)])
        try bindExec("DELETE FROM writing_entries WHERE filename = ?", bindings: [.text(filename)])
        try bindExec("DELETE FROM writing_days WHERE filename = ?", bindings: [.text(filename)])
    }

    /// Internal, not `private`, only so the TranscriptIndex+*.swift extensions
    /// can reach it (`private` is file-scoped). Nothing outside this type should
    /// touch it.
    func ftsQuery(from query: String?) -> String? {
        guard let query, !query.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let tokens = query.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        return tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }.joined(separator: " ")
    }

    // MARK: - SQLite Helpers
    //
    // Thin wrappers over the shared free functions in SQLiteHelpers.swift,
    // bound to this instance's `db` handle. Kept as instance methods so every
    // existing call site in this file (bind(...), bindExec(...), etc.) is
    // unchanged.

    /// Internal, not `private`, only so the TranscriptIndex+*.swift extensions
    /// can reach it (`private` is file-scoped). Nothing outside this type should
    /// touch it.
    func bind(stmt: OpaquePointer?, index: Int32, value: SQLBinding) {
        sqlBind(stmt: stmt, index: index, value: value)
    }

    private func bindExec(_ sql: String, bindings: [SQLBinding]) throws {
        try sqlBindExec(db: db, sql: sql, bindings: bindings)
    }

    private func bindExecRows(_ sql: String, rows: [[SQLBinding]]) throws {
        try sqlBindExecRows(db: db, sql: sql, rows: rows)
    }

    /// Not `private` — TranscriptIndex+Schema.swift's createTables() extension
    /// calls this cross-file, and `private` is file-scoped in Swift.
    func exec(_ sql: String) {
        sqlExec(db: db, sql: sql)
    }

    private func execOrThrow(_ sql: String) throws {
        try sqlExecOrThrow(db: db, sql: sql)
    }

    /// Internal, not `private`, only so the TranscriptIndex+*.swift extensions
    /// can reach it (`private` is file-scoped). Nothing outside this type should
    /// touch it.
    func colText(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        sqlColText(stmt, col)
    }

    /// Internal, not `private`, only so the TranscriptIndex+*.swift extensions
    /// can reach it (`private` is file-scoped). Nothing outside this type should
    /// touch it.
    func colTextOptional(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        sqlColTextOptional(stmt, col)
    }

    /// Internal, not `private`, only so the TranscriptIndex+*.swift extensions
    /// can reach it (`private` is file-scoped). Nothing outside this type should
    /// touch it.
    func dbError() -> String {
        sqlDBError(db)
    }
}

/// Keeps the stdio attach path bounded by making the lexical index available
/// first. Semantic vectors are additive and can finish after the client has
/// connected without changing any read-only tool contract.
enum MCPStartupIndexing {
    static func prepareForAttach(
        index: TranscriptIndex,
        meetingDirs: [URL],
        dictationDirs: [URL],
        writingDirs: [URL] = []
    ) throws {
        index.embeddingStore?.deferSemanticSearchUntilReconciled()
        do {
            try index.reconcile(
                meetingDirs: meetingDirs,
                dictationDirs: dictationDirs,
                writingDirs: writingDirs,
                updateEmbeddings: false
            )
        } catch is MCPReconcileFileFailures {
            // Some files failed but the rest are indexed and the index is usable.
            // reconcile already logged the count; the watcher retries on change.
            // Pre-pass errors (lock, database) still stop startup.
        }
    }

    static func completeAfterAttach(index: TranscriptIndex) {
        defer { index.embeddingStore?.finishDeferredStartupReconciliation() }
        index.reconcileEmbeddings()
    }
}
