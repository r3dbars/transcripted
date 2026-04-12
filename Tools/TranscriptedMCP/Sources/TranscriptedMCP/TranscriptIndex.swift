import Foundation
import SQLite3

final class TranscriptIndex: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.transcripted.mcp.index", qos: .utility)
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let indexPath: URL

    init(indexDir: URL) throws {
        self.indexPath = indexDir.appendingPathComponent("mcp_index.sqlite")
        try queue.sync { try self.openAndSetup() }
    }

    deinit {
        queue.sync {
            if let db = db { sqlite3_close(db) }
        }
    }

    // MARK: - Setup

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

        createTables()
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

    private func createTables() {
        exec("""
            CREATE TABLE IF NOT EXISTS meetings (
                filename TEXT PRIMARY KEY,
                date TEXT NOT NULL,
                datetime TEXT NOT NULL,
                duration_seconds INTEGER NOT NULL,
                speaker_count INTEGER NOT NULL,
                word_count INTEGER NOT NULL,
                json_modified_at REAL NOT NULL
            )
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS meeting_speakers (
                filename TEXT NOT NULL,
                speaker_name TEXT NOT NULL,
                persistent_speaker_id TEXT,
                word_count INTEGER NOT NULL DEFAULT 0,
                speaking_seconds REAL NOT NULL DEFAULT 0,
                PRIMARY KEY (filename, speaker_name)
            )
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS utterances (
                rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                filename TEXT NOT NULL,
                speaker_name TEXT NOT NULL,
                utterance_start REAL NOT NULL,
                utterance_end REAL NOT NULL,
                text TEXT NOT NULL
            )
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS dictation_days (
                filename TEXT PRIMARY KEY,
                date TEXT NOT NULL,
                datetime TEXT NOT NULL,
                markdown_filename TEXT NOT NULL,
                entry_count INTEGER NOT NULL,
                word_count INTEGER NOT NULL,
                json_modified_at REAL NOT NULL
            )
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS dictation_entries (
                rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                filename TEXT NOT NULL,
                entry_id TEXT NOT NULL,
                title TEXT NOT NULL,
                created_at TEXT NOT NULL,
                source_app_name TEXT NOT NULL,
                source_app_bundle_id TEXT,
                delivery TEXT NOT NULL,
                word_count INTEGER NOT NULL,
                character_count INTEGER NOT NULL,
                text TEXT NOT NULL
            )
        """)

        exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS dictation_entries_fts USING fts5(
                text, title, source_app_name,
                content='dictation_entries', content_rowid='rowid',
                tokenize='porter unicode61'
            )
        """)

        exec("""
            CREATE TRIGGER IF NOT EXISTS dictation_entries_ai AFTER INSERT ON dictation_entries BEGIN
                INSERT INTO dictation_entries_fts(rowid, text, title, source_app_name)
                VALUES (new.rowid, new.text, new.title, new.source_app_name);
            END
        """)

        exec("""
            CREATE TRIGGER IF NOT EXISTS dictation_entries_ad AFTER DELETE ON dictation_entries BEGIN
                INSERT INTO dictation_entries_fts(dictation_entries_fts, rowid, text, title, source_app_name)
                VALUES ('delete', old.rowid, old.text, old.title, old.source_app_name);
            END
        """)

        exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS utterances_fts USING fts5(
                text, speaker_name,
                content='utterances', content_rowid='rowid',
                tokenize='porter unicode61'
            )
        """)

        exec("""
            CREATE TRIGGER IF NOT EXISTS utterances_ai AFTER INSERT ON utterances BEGIN
                INSERT INTO utterances_fts(rowid, text, speaker_name)
                VALUES (new.rowid, new.text, new.speaker_name);
            END
        """)

        exec("""
            CREATE TRIGGER IF NOT EXISTS utterances_ad AFTER DELETE ON utterances BEGIN
                INSERT INTO utterances_fts(utterances_fts, rowid, text, speaker_name)
                VALUES ('delete', old.rowid, old.text, old.speaker_name);
            END
        """)

        exec("CREATE INDEX IF NOT EXISTS idx_meetings_date ON meetings(date)")
        exec("CREATE INDEX IF NOT EXISTS idx_meeting_speakers_name ON meeting_speakers(speaker_name COLLATE NOCASE)")
        exec("CREATE INDEX IF NOT EXISTS idx_meeting_speakers_persistent_id ON meeting_speakers(persistent_speaker_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_utterances_filename ON utterances(filename)")
        exec("CREATE INDEX IF NOT EXISTS idx_dictation_days_date ON dictation_days(date)")
        exec("CREATE INDEX IF NOT EXISTS idx_dictation_entries_filename ON dictation_entries(filename)")
        exec("CREATE INDEX IF NOT EXISTS idx_dictation_entries_created_at ON dictation_entries(created_at)")
    }

    // MARK: - Reconciliation

    func reconcile(meetingsDir: URL, dictationsDir: URL) throws {
        try queue.sync {
            let diskFiles: [ContextArtifactFile]
            if meetingsDir.standardizedFileURL == dictationsDir.standardizedFileURL {
                diskFiles = TranscriptLoader.enumerateArtifacts(in: meetingsDir)
            } else {
                diskFiles = TranscriptLoader.enumerateArtifacts(in: meetingsDir)
                    + TranscriptLoader.enumerateArtifacts(in: dictationsDir)
            }
            let diskMap = Dictionary(uniqueKeysWithValues: diskFiles.map {
                ($0.url.deletingPathExtension().lastPathComponent, $0)
            })

            let indexed = try getIndexedModDates()

            // Index new or updated files
            for (filename, info) in diskMap {
                if let indexedMod = indexed[filename] {
                    if abs(info.modDate - indexedMod) > 0.001 {
                        try reindex(file: info.url, filename: filename, kind: info.kind)
                    }
                } else {
                    try indexOne(file: info.url, filename: filename, modDate: info.modDate, kind: info.kind)
                }
            }

            // Remove stale entries
            for filename in indexed.keys where diskMap[filename] == nil {
                try removeFromIndex(filename: filename)
            }
        }
    }

    func indexSingleFile(_ url: URL) throws {
        try queue.sync {
            guard let kind = TranscriptLoader.artifactKind(for: url) else { return }
            let filename = url.deletingPathExtension().lastPathComponent
            try reindex(file: url, filename: filename, kind: kind)
        }
    }

    private func getIndexedModDates() throws -> [String: TimeInterval] {
        var result: [String: TimeInterval] = [:]
        var stmt: OpaquePointer?
        let sql = """
            SELECT filename, json_modified_at FROM meetings
            UNION ALL
            SELECT filename, json_modified_at FROM dictation_days
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

    private func indexOne(file url: URL, filename: String, modDate: TimeInterval, kind: ContextArtifactKind) throws {
        switch kind {
        case .meeting:
            try indexMeeting(file: url, filename: filename, modDate: modDate)
        case .dictationDay:
            try indexDictationDay(file: url, filename: filename, modDate: modDate)
        }
    }

    private func indexMeeting(file url: URL, filename: String, modDate: TimeInterval) throws {
        guard let transcript = TranscriptLoader.loadMeeting(url) else { return }
        let speakers = TranscriptLoader.speakerLookup(from: transcript)

        let dateOnly = String(transcript.recording.date.prefix(10))
        let wordCount = transcript.speakers.reduce(0) { $0 + $1.wordCount }

        exec("BEGIN EXCLUSIVE")
        var committed = false
        defer { if !committed { exec("ROLLBACK") } }

        bindExec(
            "INSERT OR REPLACE INTO meetings (filename, date, datetime, duration_seconds, speaker_count, word_count, json_modified_at) VALUES (?,?,?,?,?,?,?)",
            bindings: [
                .text(filename), .text(dateOnly), .text(transcript.recording.date),
                .int(transcript.recording.durationSeconds), .int(transcript.speakers.count),
                .int(wordCount), .double(modDate)
            ]
        )

        for speaker in transcript.speakers {
            bindExec(
                "INSERT OR REPLACE INTO meeting_speakers (filename, speaker_name, persistent_speaker_id, word_count, speaking_seconds) VALUES (?,?,?,?,?)",
                bindings: [
                    .text(filename), .text(speaker.name),
                    speaker.persistentSpeakerId.map { .text($0) } ?? .null,
                    .int(speaker.wordCount), .double(speaker.speakingSeconds)
                ]
            )
        }

        for utterance in transcript.utterances {
            let speakerName = speakers[utterance.speakerId]?.name ?? "Unknown"
            bindExec(
                "INSERT INTO utterances (filename, speaker_name, utterance_start, utterance_end, text) VALUES (?,?,?,?,?)",
                bindings: [
                    .text(filename), .text(speakerName),
                    .double(utterance.start), .double(utterance.end), .text(utterance.text)
                ]
            )
        }

        exec("COMMIT")
        committed = true
        log("Indexed: \(filename) (\(transcript.utterances.count) utterances)")
    }

    private func indexDictationDay(file url: URL, filename: String, modDate: TimeInterval) throws {
        guard let day = TranscriptLoader.loadDictationDay(url) else { return }

        let latestEntryDate = day.entries.last?.createdAt ?? "\(day.date)T00:00:00+0000"

        exec("BEGIN EXCLUSIVE")
        var committed = false
        defer { if !committed { exec("ROLLBACK") } }

        bindExec(
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

        for entry in day.entries {
            bindExec(
                "INSERT INTO dictation_entries (filename, entry_id, title, created_at, source_app_name, source_app_bundle_id, delivery, word_count, character_count, text) VALUES (?,?,?,?,?,?,?,?,?,?)",
                bindings: [
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
            )
        }

        exec("COMMIT")
        committed = true
        log("Indexed dictation day: \(filename) (\(day.entries.count) entries)")
    }

    private func reindex(file url: URL, filename: String, kind: ContextArtifactKind) throws {
        try removeFromIndex(filename: filename)
        let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate?.timeIntervalSince1970) ?? Date().timeIntervalSince1970
        try indexOne(file: url, filename: filename, modDate: modDate, kind: kind)
    }

    private func removeFromIndex(filename: String) throws {
        exec("BEGIN EXCLUSIVE")
        var committed = false
        defer { if !committed { exec("ROLLBACK") } }
        bindExec("DELETE FROM utterances WHERE filename = ?", bindings: [.text(filename)])
        bindExec("DELETE FROM meeting_speakers WHERE filename = ?", bindings: [.text(filename)])
        bindExec("DELETE FROM meetings WHERE filename = ?", bindings: [.text(filename)])
        bindExec("DELETE FROM dictation_entries WHERE filename = ?", bindings: [.text(filename)])
        bindExec("DELETE FROM dictation_days WHERE filename = ?", bindings: [.text(filename)])
        exec("COMMIT")
        committed = true
    }

    // MARK: - Queries

    func searchUtterances(query: String, speaker: String?, dateFrom: String?, dateTo: String?, maxMeetings: Int = 10, snippetsPerMeeting: Int = 3) throws -> GroupedSearchResult {
        return try queue.sync {
            let tokens = query.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            let ftsQuery = tokens.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }.joined(separator: " ")

            var sql = """
                SELECT u.filename, u.speaker_name, u.utterance_start, u.text,
                       m.date, m.datetime, m.duration_seconds
                FROM utterances_fts
                JOIN utterances u ON u.rowid = utterances_fts.rowid
                JOIN meetings m ON m.filename = u.filename
                WHERE utterances_fts MATCH ?
            """
            var bindings: [SQLBinding] = [.text(ftsQuery)]

            if let speaker = speaker {
                let names = NameVariants.expandName(speaker)
                // Match exact names OR substring (e.g., "Jenny" matches "Jenny Wen")
                let exactPlaceholders = names.map { _ in "u.speaker_name COLLATE NOCASE = ?" }
                let likePlaceholders = names.map { _ in "u.speaker_name COLLATE NOCASE LIKE ?" }
                let allConditions = (exactPlaceholders + likePlaceholders).joined(separator: " OR ")
                sql += " AND (\(allConditions))"
                bindings.append(contentsOf: names.map { .text($0) })
                bindings.append(contentsOf: names.map { .text("%\($0)%") })
            }

            if let dateFrom = dateFrom {
                sql += " AND m.date >= ?"
                bindings.append(.text(dateFrom))
            }
            if let dateTo = dateTo {
                sql += " AND m.date <= ?"
                bindings.append(.text(dateTo))
            }

            sql += " ORDER BY rank LIMIT 200"

            var rawResults: [(filename: String, speaker: String, start: Double, text: String, date: String, datetime: String, duration: Int)] = []

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw MCPIndexError.queryFailed(dbError())
            }
            defer { sqlite3_finalize(stmt) }

            for (i, binding) in bindings.enumerated() {
                bind(stmt: stmt, index: Int32(i + 1), value: binding)
            }

            while sqlite3_step(stmt) == SQLITE_ROW {
                rawResults.append((
                    filename: colText(stmt, 0),
                    speaker: colText(stmt, 1),
                    start: sqlite3_column_double(stmt, 2),
                    text: colText(stmt, 3),
                    date: colText(stmt, 4),
                    datetime: colText(stmt, 5),
                    duration: Int(sqlite3_column_int64(stmt, 6))
                ))
            }

            // Group by meeting, take top snippets per meeting
            var grouped: [String: (date: String, datetime: String, snippets: [SearchSnippet])] = [:]
            var meetingOrder: [String] = []

            for r in rawResults {
                if grouped[r.filename] == nil {
                    meetingOrder.append(r.filename)
                    grouped[r.filename] = (date: r.date, datetime: r.datetime, snippets: [])
                }
                if (grouped[r.filename]?.snippets.count ?? 0) < snippetsPerMeeting {
                    let mins = Int(r.start) / 60
                    let secs = Int(r.start) % 60
                    let timestamp = String(format: "%d:%02d", mins, secs)
                    grouped[r.filename]?.snippets.append(SearchSnippet(
                        speaker: r.speaker, speakerId: nil, timestamp: timestamp, text: r.text
                    ))
                }
            }

            let totalMeetings = meetingOrder.count
            let results = meetingOrder.prefix(maxMeetings).compactMap { filename -> MeetingSearchGroup? in
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
                totalMeetingsMatched: totalMeetings,
                truncated: totalMeetings > maxMeetings
            )
        }
    }

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

    func searchDictationEntries(query: String, dateFrom: String?, dateTo: String?, maxItems: Int = 10) throws -> [ContextSearchGroup] {
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

    func searchContext(query: String, speaker: String?, kind: ContextKind, dateFrom: String?, dateTo: String?, maxItems: Int = 10) throws -> ContextSearchResult {
        var combined: [ContextSearchGroup] = []

        if kind != .dictation {
            let meetings = try searchUtterances(
                query: query,
                speaker: speaker,
                dateFrom: dateFrom,
                dateTo: dateTo,
                maxMeetings: maxItems,
                snippetsPerMeeting: 3
            )
            combined.append(contentsOf: meetings.results.map {
                ContextSearchGroup(
                    kind: .meeting,
                    title: $0.meetingTitle,
                    filename: $0.filename,
                    entryId: nil,
                    date: $0.meetingDate,
                    datetime: $0.meetingDateTime,
                    snippets: $0.snippets.map {
                        ContextSearchSnippet(
                            text: $0.text,
                            speaker: $0.speaker,
                            speakerId: $0.speakerId,
                            timestamp: $0.timestamp,
                            sourceAppName: nil,
                            delivery: nil
                        )
                    }
                )
            })
        }

        if kind != .meeting, speaker == nil {
            combined.append(contentsOf: try searchDictationEntries(
                query: query,
                dateFrom: dateFrom,
                dateTo: dateTo,
                maxItems: maxItems
            ))
        }

        combined.sort { $0.datetime > $1.datetime }
        let total = combined.count

        return ContextSearchResult(
            results: Array(combined.prefix(maxItems)),
            totalItemsMatched: total,
            truncated: total > maxItems
        )
    }

    func listRecentContext(kind: ContextKind, count: Int, dateFrom: String? = nil, dateTo: String? = nil) throws -> RecentContextResult {
        var items: [RecentContextItem] = []

        if kind != .dictation {
            let meetings = try listMeetings(count: count, dateFrom: dateFrom, dateTo: dateTo)
            items.append(contentsOf: meetings.map {
                RecentContextItem(
                    kind: .meeting,
                    title: $0.title ?? $0.filename,
                    filename: $0.filename,
                    entryId: nil,
                    date: $0.date,
                    datetime: $0.datetime,
                    preview: $0.speakers.map(\.name).joined(separator: ", "),
                    wordCount: $0.wordCount,
                    speakers: $0.speakers.map(\.name),
                    sourceAppName: nil,
                    delivery: nil
                )
            })
        }

        if kind != .meeting {
            items.append(contentsOf: try listRecentDictationEntries(count: count, dateFrom: dateFrom, dateTo: dateTo))
        }

        items.sort { $0.datetime > $1.datetime }
        return RecentContextResult(items: Array(items.prefix(max(1, min(count, 50)))))
    }

    func getSpeakerHistory(speaker: String) throws -> SpeakerHistoryResult {
        return try queue.sync {
            var matchCondition: String
            var matchBindings: [SQLBinding]

            if UUID(uuidString: speaker) != nil {
                matchCondition = "ms.persistent_speaker_id = ?"
                matchBindings = [.text(speaker)]
            } else {
                let names = NameVariants.expandName(speaker)
                let exactConditions = names.map { _ in "ms.speaker_name COLLATE NOCASE = ?" }
                let likeConditions = names.map { _ in "ms.speaker_name COLLATE NOCASE LIKE ?" }
                matchCondition = "(" + (exactConditions + likeConditions).joined(separator: " OR ") + ")"
                matchBindings = names.map { .text($0) } + names.map { .text("%\($0)%") }
            }

            let sql = """
                SELECT ms.filename, ms.speaker_name, ms.persistent_speaker_id,
                       ms.word_count, ms.speaking_seconds,
                       m.date, m.duration_seconds, m.speaker_count
                FROM meeting_speakers ms
                JOIN meetings m ON m.filename = ms.filename
                WHERE \(matchCondition)
                ORDER BY m.date DESC
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw MCPIndexError.queryFailed(dbError())
            }
            defer { sqlite3_finalize(stmt) }

            for (i, binding) in matchBindings.enumerated() {
                bind(stmt: stmt, index: Int32(i + 1), value: binding)
            }

            var meetings: [SpeakerMeeting] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let filename = colText(stmt, 0)
                let speakerName = colText(stmt, 1)
                let previewSnippet = (try? getFirstUtterance(filename: filename, speaker: speakerName)) ?? ""

                meetings.append(SpeakerMeeting(
                    filename: filename,
                    speakerName: speakerName,
                    persistentSpeakerId: colTextOptional(stmt, 2),
                    wordCount: Int(sqlite3_column_int64(stmt, 3)),
                    speakingSeconds: sqlite3_column_double(stmt, 4),
                    meetingDate: colText(stmt, 5),
                    meetingDurationSeconds: Int(sqlite3_column_int64(stmt, 6)),
                    meetingSpeakerCount: Int(sqlite3_column_int64(stmt, 7)),
                    previewSnippet: String(previewSnippet.prefix(150))
                ))
            }

            return SpeakerHistoryResult(
                queriedName: speaker,
                matchedName: meetings.first?.speakerName ?? speaker,
                persistentSpeakerId: meetings.compactMap(\.persistentSpeakerId).first,
                meetingCount: meetings.count,
                totalWordCount: meetings.reduce(0) { $0 + $1.wordCount },
                totalSpeakingSeconds: meetings.reduce(0.0) { $0 + $1.speakingSeconds },
                meetings: meetings
            )
        }
    }

    // MARK: - List Meetings (with date filter)

    func listMeetings(count: Int, dateFrom: String? = nil, dateTo: String? = nil) throws -> [MeetingSummary] {
        return try queue.sync {
            let limit = max(1, min(count, 50))

            var sql = "SELECT filename, date, datetime, duration_seconds, speaker_count, word_count FROM meetings"
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

            var meetings: [MeetingSummary] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                meetings.append(MeetingSummary(
                    filename: colText(stmt, 0),
                    date: colText(stmt, 1),
                    datetime: colText(stmt, 2),
                    durationSeconds: Int(sqlite3_column_int64(stmt, 3)),
                    speakerCount: Int(sqlite3_column_int64(stmt, 4)),
                    wordCount: Int(sqlite3_column_int64(stmt, 5)),
                    speakers: []
                ))
            }

            // Batch-fetch speakers for all returned meetings
            if !meetings.isEmpty {
                let filenames = meetings.map(\.filename)
                let placeholders = filenames.map { _ in "?" }.joined(separator: ", ")
                let speakerSql = "SELECT filename, speaker_name, persistent_speaker_id, word_count, speaking_seconds FROM meeting_speakers WHERE filename IN (\(placeholders))"

                var spStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, speakerSql, -1, &spStmt, nil) == SQLITE_OK else {
                    return meetings
                }
                defer { sqlite3_finalize(spStmt) }

                for (i, f) in filenames.enumerated() {
                    sqlite3_bind_text(spStmt, Int32(i + 1), (f as NSString).utf8String, -1, SQLITE_TRANSIENT)
                }

                var speakersByMeeting: [String: [MeetingSpeaker]] = [:]
                while sqlite3_step(spStmt) == SQLITE_ROW {
                    let filename = colText(spStmt, 0)
                    speakersByMeeting[filename, default: []].append(MeetingSpeaker(
                        name: colText(spStmt, 1),
                        persistentSpeakerId: colTextOptional(spStmt, 2),
                        wordCount: Int(sqlite3_column_int64(spStmt, 3)),
                        speakingSeconds: sqlite3_column_double(spStmt, 4)
                    ))
                }

                for i in meetings.indices {
                    meetings[i].speakers = speakersByMeeting[meetings[i].filename] ?? []
                }
            }

            return meetings
        }
    }

    // MARK: - Person Profile (who_is)

    func getPersonProfile(speaker: String) throws -> PersonProfile {
        let history = try getSpeakerHistory(speaker: speaker)

        // Batch-fetch all co-speakers for all meetings in one query
        let allFilenames = history.meetings.map(\.filename)
        var coSpeakersByMeeting: [String: [String]] = [:]

        if !allFilenames.isEmpty {
            queue.sync {
                let placeholders = allFilenames.map { _ in "?" }.joined(separator: ", ")
                let sql = "SELECT filename, speaker_name FROM meeting_speakers WHERE filename IN (\(placeholders)) AND speaker_name COLLATE NOCASE != ? AND speaker_name NOT LIKE 'Speaker %'"
                var stmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
                defer { sqlite3_finalize(stmt) }
                for (i, f) in allFilenames.enumerated() {
                    sqlite3_bind_text(stmt, Int32(i + 1), (f as NSString).utf8String, -1, SQLITE_TRANSIENT)
                }
                sqlite3_bind_text(stmt, Int32(allFilenames.count + 1), (history.matchedName as NSString).utf8String, -1, SQLITE_TRANSIENT)
                while sqlite3_step(stmt) == SQLITE_ROW {
                    coSpeakersByMeeting[colText(stmt, 0), default: []].append(colText(stmt, 1))
                }
            }
        }

        // Tally co-speaker frequency across all meetings
        var coSpeakerCounts: [String: Int] = [:]
        for meeting in history.meetings {
            for name in coSpeakersByMeeting[meeting.filename] ?? [] {
                coSpeakerCounts[name, default: 0] += 1
            }
        }

        let topCoSpeakers = coSpeakerCounts.sorted { $0.value > $1.value }.prefix(5).map(\.key)

        let quotes = history.meetings.prefix(5).compactMap { $0.previewSnippet.isEmpty ? nil : $0.previewSnippet }

        let recentMeetings = history.meetings.prefix(10).map { meeting in
            PersonMeetingEntry(
                filename: meeting.filename,
                date: meeting.meetingDate,
                wordCount: meeting.wordCount,
                speakingMinutes: meeting.speakingSeconds / 60.0,
                otherSpeakers: coSpeakersByMeeting[meeting.filename] ?? []
            )
        }

        return PersonProfile(
            name: history.matchedName,
            persistentSpeakerId: history.persistentSpeakerId,
            meetingCount: history.meetingCount,
            totalWordCount: history.totalWordCount,
            totalSpeakingMinutes: history.totalSpeakingSeconds / 60.0,
            firstSeen: history.meetings.last?.meetingDate ?? "",
            lastSeen: history.meetings.first?.meetingDate ?? "",
            frequentCoSpeakers: Array(topCoSpeakers),
            recentMeetings: Array(recentMeetings),
            representativeQuotes: Array(quotes)
        )
    }

    /// Convenience wrapper — returns the N most recent meetings with no date filter.
    func listRecentMeetings(count: Int) throws -> [MeetingSummary] {
        try listMeetings(count: count)
    }

    private func getFirstUtterance(filename: String, speaker: String) throws -> String {
        var stmt: OpaquePointer?
        let sql = "SELECT text FROM utterances WHERE filename = ? AND speaker_name = ? ORDER BY utterance_start LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return "" }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (filename as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, (speaker as NSString).utf8String, -1, SQLITE_TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return colText(stmt, 0)
        }
        return ""
    }

    // MARK: - SQLite Helpers

    private enum SQLBinding {
        case text(String)
        case int(Int)
        case double(Double)
        case null
    }

    private func bind(stmt: OpaquePointer?, index: Int32, value: SQLBinding) {
        switch value {
        case .text(let s):
            sqlite3_bind_text(stmt, index, (s as NSString).utf8String, -1, SQLITE_TRANSIENT)
        case .int(let i):
            sqlite3_bind_int64(stmt, index, Int64(i))
        case .double(let d):
            sqlite3_bind_double(stmt, index, d)
        case .null:
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindExec(_ sql: String, bindings: [SQLBinding]) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log("SQL prepare failed: \(dbError()) for: \(sql)")
            return
        }
        defer { sqlite3_finalize(stmt) }
        for (i, binding) in bindings.enumerated() {
            bind(stmt: stmt, index: Int32(i + 1), value: binding)
        }
        if sqlite3_step(stmt) != SQLITE_DONE {
            log("SQL exec failed: \(dbError()) for: \(sql)")
        }
    }

    private func exec(_ sql: String) {
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            log("SQL exec failed: \(dbError()) for: \(sql)")
        }
    }

    private func colText(_ stmt: OpaquePointer?, _ col: Int32) -> String {
        guard let ptr = sqlite3_column_text(stmt, col) else { return "" }
        return String(cString: ptr)
    }

    private func colTextOptional(_ stmt: OpaquePointer?, _ col: Int32) -> String? {
        guard sqlite3_column_type(stmt, col) != SQLITE_NULL,
              let ptr = sqlite3_column_text(stmt, col) else { return nil }
        return String(cString: ptr)
    }

    private func dbError() -> String {
        if let db = db {
            return String(cString: sqlite3_errmsg(db))
        }
        return "database not open"
    }
}
