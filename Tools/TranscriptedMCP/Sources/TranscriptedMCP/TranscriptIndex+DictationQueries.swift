import Foundation
import SQLite3
import TranscriptedCaptureKit

// Dictation read side: day lists, entry search, and the recent-entries feed.
// Split out of TranscriptIndex.swift; every query keeps its own queue.sync.

extension TranscriptIndex {
    func listDictationDays(count: Int, dateFrom: String? = nil, dateTo: String? = nil) throws -> [DictationDaySummary] {
        return try queue.sync {
            let limit = max(1, min(count, 50))

            var sql = "SELECT filename, date, datetime, entry_count, word_count FROM dictation_days"
            var bindings: [SQLBinding] = []
            var conditions: [String] = []

            if let dateFrom = dateFrom {
                conditions.append("date >= ?")
                bindings.append(.text(dateFrom))
            }
            if let dateTo = dateTo {
                conditions.append("date <= ?")
                bindings.append(.text(dateTo))
            }

            if !conditions.isEmpty {
                sql += " WHERE " + conditions.joined(separator: " AND ")
            }
            sql += " ORDER BY datetime DESC LIMIT ?"
            bindings.append(.int(limit))

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw MCPIndexError.queryFailed(dbError())
            }
            defer { sqlite3_finalize(stmt) }

            for (i, binding) in bindings.enumerated() {
                bind(stmt: stmt, index: Int32(i + 1), value: binding)
            }

            // Collect raw day rows before fetching per-entry details.
            struct RawDayRow {
                let filename: String
                let date: String
                let datetime: String
                let entryCount: Int
                let wordCount: Int
            }
            var rawDays: [RawDayRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                rawDays.append(RawDayRow(
                    filename: colText(stmt, 0),
                    date: colText(stmt, 1),
                    datetime: colText(stmt, 2),
                    entryCount: Int(sqlite3_column_int64(stmt, 3)),
                    wordCount: Int(sqlite3_column_int64(stmt, 4))
                ))
            }

            guard !rawDays.isEmpty else { return [] }

            let filenames = rawDays.map(\.filename)
            let placeholders = filenames.map { _ in "?" }.joined(separator: ", ")
            let detailsSQL = """
                SELECT filename, title, source_app_name
                FROM dictation_entries
                WHERE filename IN (\(placeholders))
                ORDER BY created_at DESC
            """

            var titlesByDay: [String: [String]] = [:]
            var appsByDay: [String: Set<String>] = [:]

            var detailStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, detailsSQL, -1, &detailStmt, nil) == SQLITE_OK {
                defer { sqlite3_finalize(detailStmt) }
                for (i, filename) in filenames.enumerated() {
                    sqlite3_bind_text(detailStmt, Int32(i + 1), (filename as NSString).utf8String, -1, SQLITE_TRANSIENT)
                }
                while sqlite3_step(detailStmt) == SQLITE_ROW {
                    let filename = colText(detailStmt, 0)
                    let title = colText(detailStmt, 1)
                    let sourceApp = colText(detailStmt, 2)
                    if !titlesByDay[filename, default: []].contains(title) {
                        titlesByDay[filename, default: []].append(title)
                    }
                    if !sourceApp.isEmpty {
                        appsByDay[filename, default: []].insert(sourceApp)
                    }
                }
            }

            return rawDays.map { row in
                DictationDaySummary(
                    filename: row.filename,
                    date: row.date,
                    datetime: row.datetime,
                    entryCount: row.entryCount,
                    wordCount: row.wordCount,
                    sourceApps: Array(appsByDay[row.filename, default: []]).sorted(),
                    titles: titlesByDay[row.filename] ?? []
                )
            }
        }
    }

    func searchDictationEntries(query: String, dateFrom: String?, dateTo: String?, maxItems: Int = 10, mode: SearchMode = .lexical) throws -> [ContextSearchGroup] {
        if mode != .lexical,
           let store = embeddingStore,
           let semantic = store.semanticSearchDictationEntriesIfAvailable(
                query: query, dateFrom: dateFrom, dateTo: dateTo, maxItems: maxItems
           ) {
            if mode == .semantic { return semantic }
            let lexical = try searchDictationEntries(
                query: query, dateFrom: dateFrom, dateTo: dateTo, maxItems: maxItems, mode: .lexical
            )
            return SemanticSearchFusion.fuseContextGroups(
                lexical: lexical, semantic: semantic, maxItems: maxItems
            )
        }

        return try queue.sync {
            let tokens = query.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            let ftsQuery = tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }.joined(separator: " ")

            var sql = """
                SELECT e.filename, e.entry_id, e.title, e.created_at, e.text, e.source_app_name, e.delivery, d.date
                FROM dictation_entries_fts
                JOIN dictation_entries e ON e.rowid = dictation_entries_fts.rowid
                JOIN dictation_days d ON d.filename = e.filename
                WHERE dictation_entries_fts MATCH ?
            """
            var bindings: [SQLBinding] = [.text(ftsQuery)]

            if let dateFrom = dateFrom {
                sql += " AND d.date >= ?"
                bindings.append(.text(dateFrom))
            }
            if let dateTo = dateTo {
                sql += " AND d.date <= ?"
                bindings.append(.text(dateTo))
            }

            sql += " ORDER BY rank LIMIT 200"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw MCPIndexError.queryFailed(dbError())
            }
            defer { sqlite3_finalize(stmt) }

            for (i, binding) in bindings.enumerated() {
                bind(stmt: stmt, index: Int32(i + 1), value: binding)
            }

            var results: [ContextSearchGroup] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append(ContextSearchGroup(
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
                ))
            }

            return Array(results.prefix(maxItems))
        }
    }

    func listRecentDictationEntries(count: Int, dateFrom: String? = nil, dateTo: String? = nil) throws -> [RecentContextItem] {
        return try queue.sync {
            let limit = max(1, min(count, 50))
            var sql = """
                SELECT e.filename, e.entry_id, e.title, e.created_at, e.text, e.word_count, e.source_app_name, e.delivery, d.date
                FROM dictation_entries e
                JOIN dictation_days d ON d.filename = e.filename
            """
            var bindings: [SQLBinding] = []
            var conditions: [String] = []

            if let dateFrom = dateFrom {
                conditions.append("d.date >= ?")
                bindings.append(.text(dateFrom))
            }
            if let dateTo = dateTo {
                conditions.append("d.date <= ?")
                bindings.append(.text(dateTo))
            }

            if !conditions.isEmpty {
                sql += " WHERE " + conditions.joined(separator: " AND ")
            }
            sql += " ORDER BY e.created_at DESC LIMIT ?"
            bindings.append(.int(limit))

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw MCPIndexError.queryFailed(dbError())
            }
            defer { sqlite3_finalize(stmt) }

            for (i, binding) in bindings.enumerated() {
                bind(stmt: stmt, index: Int32(i + 1), value: binding)
            }

            var items: [RecentContextItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                items.append(RecentContextItem(
                    kind: .dictation,
                    title: colText(stmt, 2),
                    filename: colText(stmt, 0),
                    entryId: colText(stmt, 1),
                    date: colText(stmt, 8),
                    datetime: colText(stmt, 3),
                    preview: String(colText(stmt, 4).prefix(220)),
                    wordCount: Int(sqlite3_column_int64(stmt, 5)),
                    speakers: nil,
                    sourceAppName: colText(stmt, 6),
                    delivery: colText(stmt, 7)
                ))
            }

            return items
        }
    }
}
