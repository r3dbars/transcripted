import Foundation
import SQLite3

// MARK: - Writing day files
//
// Indexing and queries for `Writing_<date>.md` day files, kept out of
// TranscriptIndex.swift (already a hotspot). The shape mirrors the dictation
// day code there: `writing_days` + `writing_entries` + FTS5 (tables in
// TranscriptIndex+Schema.swift). Writing search is lexical in every mode;
// EmbeddingStore only vectors utterances and dictation entries, so a semantic
// or hybrid request still returns FTS matches for writing.
//
// Everything here runs on `queue` against `db`, the same serial queue and
// connection the rest of TranscriptIndex uses; statements go through the shared
// helpers in SQLiteHelpers.swift.

extension TranscriptIndex {
    /// Index one writing day file. Called from `indexOne` inside `reconcile`'s
    /// `queue.sync`, so it must not re-enter `queue`. Returns false when the
    /// file couldn't be parsed, so nothing was written.
    func indexWritingDay(file url: URL, filename: String, modDate: TimeInterval) throws -> Bool {
        guard let day = TranscriptLoader.loadWritingDay(url) else { return false }

        let latestEntryDate = day.entries.last?.createdAt ?? "\(day.date)T00:00:00+0000"

        try sqlExecOrThrow(db: db, sql: "BEGIN EXCLUSIVE")
        var committed = false
        defer { if !committed { exec("ROLLBACK") } }
        try deleteIndexedRows(filename: filename)

        try sqlBindExec(
            db: db,
            sql: "INSERT OR REPLACE INTO writing_days (filename, date, datetime, markdown_filename, entry_count, word_count, accepted_word_count, json_modified_at) VALUES (?,?,?,?,?,?,?,?)",
            bindings: [
                .text(filename),
                .text(day.date),
                .text(latestEntryDate),
                .text(day.markdownFilename),
                .int(day.entryCount),
                .int(day.wordCount),
                .int(day.acceptedWordCount),
                .double(modDate)
            ]
        )

        try sqlBindExecRows(
            db: db,
            sql: "INSERT INTO writing_entries (filename, entry_id, title, created_at, source_app_name, source_app_bundle_id, word_count, character_count, accepted_word_count, text) VALUES (?,?,?,?,?,?,?,?,?,?)",
            rows: day.entries.map { entry -> [SQLBinding] in
                [
                    .text(filename),
                    .text(entry.id),
                    .text(entry.title),
                    .text(entry.createdAt),
                    .text(entry.sourceAppName),
                    entry.sourceAppBundleId.map { .text($0) } ?? .null,
                    .int(entry.wordCount),
                    .int(entry.characterCount),
                    .int(entry.acceptedWordCount),
                    .text(entry.text)
                ]
            }
        )

        try sqlExecOrThrow(db: db, sql: "COMMIT")
        committed = true
        log("Indexed writing day (entry_count_bucket=\(MCPLogPrivacy.countBucket(day.entries.count)))")
        return true
    }

    func listWritingDays(count: Int, dateFrom: String? = nil, dateTo: String? = nil) throws -> [WritingDaySummary] {
        try queue.sync {
            let limit = max(1, min(count, 50))

            var sql = "SELECT filename, date, datetime, entry_count, word_count, accepted_word_count FROM writing_days"
            var bindings: [SQLBinding] = []
            var conditions: [String] = []

            if let dateFrom {
                conditions.append("date >= ?")
                bindings.append(.text(dateFrom))
            }
            if let dateTo {
                conditions.append("date <= ?")
                bindings.append(.text(dateTo))
            }
            if !conditions.isEmpty {
                sql += " WHERE " + conditions.joined(separator: " AND ")
            }
            sql += " ORDER BY datetime DESC LIMIT ?"
            bindings.append(.int(limit))

            struct RawDayRow {
                let filename: String
                let date: String
                let datetime: String
                let entryCount: Int
                let wordCount: Int
                let acceptedWordCount: Int
            }
            var rawDays: [RawDayRow] = []
            try withStatement(sql, bindings: bindings) { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    rawDays.append(RawDayRow(
                        filename: sqlColText(stmt, 0),
                        date: sqlColText(stmt, 1),
                        datetime: sqlColText(stmt, 2),
                        entryCount: Int(sqlite3_column_int64(stmt, 3)),
                        wordCount: Int(sqlite3_column_int64(stmt, 4)),
                        acceptedWordCount: Int(sqlite3_column_int64(stmt, 5))
                    ))
                }
            }

            guard !rawDays.isEmpty else { return [] }

            let filenames = rawDays.map(\.filename)
            let placeholders = filenames.map { _ in "?" }.joined(separator: ", ")
            var titlesByDay: [String: [String]] = [:]
            var appsByDay: [String: Set<String>] = [:]
            try withStatement(
                """
                SELECT filename, title, source_app_name
                FROM writing_entries
                WHERE filename IN (\(placeholders))
                ORDER BY created_at DESC
                """,
                bindings: filenames.map { .text($0) }
            ) { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let filename = sqlColText(stmt, 0)
                    let title = sqlColText(stmt, 1)
                    let sourceApp = sqlColText(stmt, 2)
                    if !titlesByDay[filename, default: []].contains(title) {
                        titlesByDay[filename, default: []].append(title)
                    }
                    if !sourceApp.isEmpty {
                        appsByDay[filename, default: []].insert(sourceApp)
                    }
                }
            }

            return rawDays.map { row in
                WritingDaySummary(
                    filename: row.filename,
                    date: row.date,
                    datetime: row.datetime,
                    entryCount: row.entryCount,
                    wordCount: row.wordCount,
                    acceptedWordCount: row.acceptedWordCount,
                    sourceApps: Array(appsByDay[row.filename, default: []]).sorted(),
                    titles: titlesByDay[row.filename] ?? []
                )
            }
        }
    }

    func searchWritingEntries(query: String, dateFrom: String?, dateTo: String?, maxItems: Int = 10) throws -> [ContextSearchGroup] {
        try queue.sync {
            let tokens = query.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard !tokens.isEmpty else { return [] }
            let ftsQuery = tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }.joined(separator: " ")

            var sql = """
                SELECT e.filename, e.entry_id, e.title, e.created_at, e.text, e.source_app_name, d.date
                FROM writing_entries_fts
                JOIN writing_entries e ON e.rowid = writing_entries_fts.rowid
                JOIN writing_days d ON d.filename = e.filename
                WHERE writing_entries_fts MATCH ?
            """
            var bindings: [SQLBinding] = [.text(ftsQuery)]
            if let dateFrom {
                sql += " AND d.date >= ?"
                bindings.append(.text(dateFrom))
            }
            if let dateTo {
                sql += " AND d.date <= ?"
                bindings.append(.text(dateTo))
            }
            sql += " ORDER BY rank LIMIT ?"
            bindings.append(.int(max(1, min(maxItems, 200))))

            var results: [ContextSearchGroup] = []
            try withStatement(sql, bindings: bindings) { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    results.append(ContextSearchGroup(
                        kind: .writing,
                        title: sqlColText(stmt, 2),
                        filename: sqlColText(stmt, 0),
                        entryId: sqlColText(stmt, 1),
                        date: sqlColText(stmt, 6),
                        datetime: sqlColText(stmt, 3),
                        snippets: [
                            ContextSearchSnippet(
                                text: sqlColText(stmt, 4),
                                speaker: nil,
                                speakerId: nil,
                                timestamp: nil,
                                sourceAppName: sqlColText(stmt, 5),
                                delivery: nil
                            )
                        ]
                    ))
                }
            }
            return results
        }
    }

    func listRecentWritingEntries(count: Int, dateFrom: String? = nil, dateTo: String? = nil) throws -> [RecentContextItem] {
        try queue.sync {
            var sql = """
                SELECT e.filename, e.entry_id, e.title, e.created_at, e.text, e.word_count, e.source_app_name, d.date
                FROM writing_entries e
                JOIN writing_days d ON d.filename = e.filename
            """
            var bindings: [SQLBinding] = []
            var conditions: [String] = []
            if let dateFrom {
                conditions.append("d.date >= ?")
                bindings.append(.text(dateFrom))
            }
            if let dateTo {
                conditions.append("d.date <= ?")
                bindings.append(.text(dateTo))
            }
            if !conditions.isEmpty {
                sql += " WHERE " + conditions.joined(separator: " AND ")
            }
            sql += " ORDER BY e.created_at DESC LIMIT ?"
            bindings.append(.int(max(1, min(count, 50))))

            var items: [RecentContextItem] = []
            try withStatement(sql, bindings: bindings) { stmt in
                while sqlite3_step(stmt) == SQLITE_ROW {
                    items.append(RecentContextItem(
                        kind: .writing,
                        title: sqlColText(stmt, 2),
                        filename: sqlColText(stmt, 0),
                        entryId: sqlColText(stmt, 1),
                        date: sqlColText(stmt, 7),
                        datetime: sqlColText(stmt, 3),
                        preview: String(sqlColText(stmt, 4).prefix(220)),
                        wordCount: Int(sqlite3_column_int64(stmt, 5)),
                        speakers: nil,
                        sourceAppName: sqlColText(stmt, 6),
                        delivery: nil
                    ))
                }
            }
            return items
        }
    }

    /// Prepare, bind, run `body`, finalize. Must run inside `queue.sync`.
    private func withStatement(
        _ sql: String,
        bindings: [SQLBinding],
        body: (OpaquePointer?) throws -> Void
    ) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MCPIndexError.queryFailed(sqlDBError(db))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, binding) in bindings.enumerated() {
            sqlBind(stmt: stmt, index: Int32(i + 1), value: binding)
        }
        try body(stmt)
    }
}
