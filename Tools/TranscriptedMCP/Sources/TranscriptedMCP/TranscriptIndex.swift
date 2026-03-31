import Foundation
import SQLite3

final class TranscriptIndex: @unchecked Sendable {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.transcripted.mcp.index", qos: .utility)
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let indexPath: URL

    init(dataDir: URL) throws {
        self.indexPath = dataDir.appendingPathComponent("mcp_index.sqlite")
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

        // Set permissions to owner-only (0o600)
        chmod(indexPath.path, 0o600)

        exec("PRAGMA journal_mode=WAL")
        exec("PRAGMA busy_timeout=5000")
        exec("PRAGMA synchronous=NORMAL")

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
                    chmod(indexPath.path, 0o600)
                    exec("PRAGMA journal_mode=WAL")
                    exec("PRAGMA busy_timeout=5000")
                    exec("PRAGMA synchronous=NORMAL")
                }
            }
            sqlite3_finalize(stmt)
        }

        createTables()
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
    }

    // MARK: - Reconciliation

    func reconcile(dataDir: URL) throws {
        try queue.sync {
            let diskFiles = TranscriptLoader.enumerateSidecars(in: dataDir)
            let diskMap = Dictionary(uniqueKeysWithValues: diskFiles.map {
                ($0.url.deletingPathExtension().lastPathComponent, $0)
            })

            let indexed = try getIndexedModDates()

            // Index new or updated files
            for (filename, info) in diskMap {
                if let indexedMod = indexed[filename] {
                    if abs(info.modDate - indexedMod) > 0.001 {
                        try reindex(file: info.url, filename: filename)
                    }
                } else {
                    try indexOne(file: info.url, filename: filename, modDate: info.modDate)
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
            let filename = url.deletingPathExtension().lastPathComponent
            try reindex(file: url, filename: filename)
        }
    }

    private func getIndexedModDates() throws -> [String: TimeInterval] {
        var result: [String: TimeInterval] = [:]
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT filename, json_modified_at FROM meetings", -1, &stmt, nil) == SQLITE_OK else {
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

    private func indexOne(file url: URL, filename: String, modDate: TimeInterval) throws {
        guard let transcript = TranscriptLoader.load(url) else { return }
        let speakers = TranscriptLoader.speakerLookup(from: transcript)

        let dateOnly = String(transcript.recording.date.prefix(10))
        let wordCount = transcript.speakers.reduce(0) { $0 + $1.wordCount }

        exec("BEGIN EXCLUSIVE")

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
        log("Indexed: \(filename) (\(transcript.utterances.count) utterances)")
    }

    private func reindex(file url: URL, filename: String) throws {
        try removeFromIndex(filename: filename)
        let modDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate?.timeIntervalSince1970) ?? Date().timeIntervalSince1970
        try indexOne(file: url, filename: filename, modDate: modDate)
    }

    private func removeFromIndex(filename: String) throws {
        exec("BEGIN EXCLUSIVE")
        bindExec("DELETE FROM utterances WHERE filename = ?", bindings: [.text(filename)])
        bindExec("DELETE FROM meeting_speakers WHERE filename = ?", bindings: [.text(filename)])
        bindExec("DELETE FROM meetings WHERE filename = ?", bindings: [.text(filename)])
        exec("COMMIT")
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
                    duration: Int(sqlite3_column_int(stmt, 6))
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
                    meetingTitle: title, meetingDate: g.date, filename: filename, snippets: g.snippets
                )
            }

            return GroupedSearchResult(
                results: Array(results),
                totalMeetingsMatched: totalMeetings,
                truncated: totalMeetings > maxMeetings
            )
        }
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
                    wordCount: Int(sqlite3_column_int(stmt, 3)),
                    speakingSeconds: sqlite3_column_double(stmt, 4),
                    meetingDate: colText(stmt, 5),
                    meetingDurationSeconds: Int(sqlite3_column_int(stmt, 6)),
                    meetingSpeakerCount: Int(sqlite3_column_int(stmt, 7)),
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
                    durationSeconds: Int(sqlite3_column_int(stmt, 3)),
                    speakerCount: Int(sqlite3_column_int(stmt, 4)),
                    wordCount: Int(sqlite3_column_int(stmt, 5)),
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
                        wordCount: Int(sqlite3_column_int(spStmt, 3)),
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

        // Collect co-speakers across all meetings
        var coSpeakerCounts: [String: Int] = [:]
        for meeting in history.meetings {
            // Get all speakers in this meeting
            let meetingSpeakers = try queue.sync {
                var stmt: OpaquePointer?
                let sql = "SELECT speaker_name FROM meeting_speakers WHERE filename = ?"
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [String]() }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, (meeting.filename as NSString).utf8String, -1, SQLITE_TRANSIENT)
                var names: [String] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    names.append(colText(stmt, 0))
                }
                return names
            }
            for name in meetingSpeakers where name.lowercased() != history.matchedName.lowercased() && !name.hasPrefix("Speaker ") {
                coSpeakerCounts[name, default: 0] += 1
            }
        }

        let topCoSpeakers = coSpeakerCounts.sorted { $0.value > $1.value }.prefix(5).map(\.key)

        // Get representative quotes
        var quotes: [String] = []
        for meeting in history.meetings.prefix(5) {
            if !meeting.previewSnippet.isEmpty {
                quotes.append(meeting.previewSnippet)
            }
        }

        let recentMeetings = history.meetings.prefix(10).map { meeting in
            // Get other speakers in the meeting
            let others: [String] = queue.sync {
                var stmt: OpaquePointer?
                let sql = "SELECT speaker_name FROM meeting_speakers WHERE filename = ? AND speaker_name COLLATE NOCASE != ?"
                guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_text(stmt, 1, (meeting.filename as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, (history.matchedName as NSString).utf8String, -1, SQLITE_TRANSIENT)
                var names: [String] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    names.append(colText(stmt, 0))
                }
                return names
            }

            return PersonMeetingEntry(
                filename: meeting.filename,
                date: meeting.meetingDate,
                wordCount: meeting.wordCount,
                speakingMinutes: meeting.speakingSeconds / 60.0,
                otherSpeakers: others
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
            representativeQuotes: quotes
        )
    }

    func listRecentMeetings(count: Int) throws -> [MeetingSummary] {
        return try queue.sync {
            let limit = max(1, min(count, 50))

            var stmt: OpaquePointer?
            let sql = "SELECT filename, date, datetime, duration_seconds, speaker_count, word_count FROM meetings ORDER BY datetime DESC LIMIT ?"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw MCPIndexError.queryFailed(dbError())
            }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int(stmt, 1, Int32(limit))

            var meetings: [MeetingSummary] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                meetings.append(MeetingSummary(
                    filename: colText(stmt, 0),
                    date: colText(stmt, 1),
                    datetime: colText(stmt, 2),
                    durationSeconds: Int(sqlite3_column_int(stmt, 3)),
                    speakerCount: Int(sqlite3_column_int(stmt, 4)),
                    wordCount: Int(sqlite3_column_int(stmt, 5)),
                    speakers: []
                ))
            }

            // Batch-fetch speakers
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
                        wordCount: Int(sqlite3_column_int(spStmt, 3)),
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
            sqlite3_bind_int(stmt, index, Int32(i))
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
