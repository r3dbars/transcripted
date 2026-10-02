import Foundation
import SQLite3
import TranscriptedCaptureKit

// Meeting read side: utterance search, speaker history, meeting lists, and
// person profiles. Split out of TranscriptIndex.swift; every query keeps its
// own queue.sync.

extension TranscriptIndex {
    // MARK: - Queries

    func searchUtterances(query: String, speaker: String?, dateFrom: String?, dateTo: String?, maxMeetings: Int = 10, snippetsPerMeeting: Int = 3, mode: SearchMode = .lexical) throws -> GroupedSearchResult {
        // Semantic / hybrid routing. Falls through to lexical when no vector store
        // is available, so these modes degrade gracefully rather than returning
        // nothing. The lexical branch below is unchanged.
        if mode != .lexical,
           let store = embeddingStore,
           let semantic = store.semanticSearchUtterancesIfAvailable(
                query: query, speaker: speaker, dateFrom: dateFrom, dateTo: dateTo,
                maxMeetings: maxMeetings, snippetsPerMeeting: snippetsPerMeeting
           ) {
            if mode == .semantic { return semantic }
            let lexical = try searchUtterances(
                query: query, speaker: speaker, dateFrom: dateFrom, dateTo: dateTo,
                maxMeetings: maxMeetings, snippetsPerMeeting: snippetsPerMeeting, mode: .lexical
            )
            return SemanticSearchFusion.fuseGrouped(
                lexical: lexical, semantic: semantic,
                maxMeetings: maxMeetings, snippetsPerMeeting: snippetsPerMeeting
            )
        }

        return try queue.sync {
            guard let ftsQuery = ftsQuery(from: query) else {
                return GroupedSearchResult(results: [], totalMeetingsMatched: 0, truncated: false)
            }

            var summaryGroups: [MeetingSearchGroup] = []
            var summaryFilenames: Set<String> = []

            if speaker == nil {
                var summarySQL = """
                    SELECT d.filename, d.title, d.attendees, d.decisions, d.action_items, d.open_questions,
                           m.date, m.datetime, m.duration_seconds,
                           bm25(meeting_summary_documents_fts, 8.0, 4.0, 6.0, 6.0, 6.0) AS score
                    FROM meeting_summary_documents_fts
                    JOIN meeting_summary_documents d ON d.rowid = meeting_summary_documents_fts.rowid
                    JOIN meetings m ON m.filename = d.filename
                    WHERE meeting_summary_documents_fts MATCH ?
                """
                var summaryBindings: [SQLBinding] = [.text(ftsQuery)]
                if let dateFrom = dateFrom {
                    summarySQL += " AND m.date >= ?"
                    summaryBindings.append(.text(dateFrom))
                }
                if let dateTo = dateTo {
                    summarySQL += " AND m.date <= ?"
                    summaryBindings.append(.text(dateTo))
                }
                summarySQL += " ORDER BY score LIMIT 200"

                var summaryStmt: OpaquePointer?
                guard sqlite3_prepare_v2(db, summarySQL, -1, &summaryStmt, nil) == SQLITE_OK else {
                    throw MCPIndexError.queryFailed(dbError())
                }
                defer { sqlite3_finalize(summaryStmt) }
                for (i, binding) in summaryBindings.enumerated() {
                    bind(stmt: summaryStmt, index: Int32(i + 1), value: binding)
                }

                while sqlite3_step(summaryStmt) == SQLITE_ROW {
                    let filename = colText(summaryStmt, 0)
                    summaryFilenames.insert(filename)
                    summaryGroups.append(MeetingSearchGroup(
                        meetingTitle: summarySearchTitle(summaryTitle: colText(summaryStmt, 1), filename: filename),
                        meetingDate: colText(summaryStmt, 6),
                        meetingDateTime: colText(summaryStmt, 7),
                        filename: filename,
                        snippets: summarySearchSnippets(
                            query: query,
                            title: colText(summaryStmt, 1),
                            attendees: colText(summaryStmt, 2),
                            decisions: colText(summaryStmt, 3),
                            actionItems: colText(summaryStmt, 4),
                            openQuestions: colText(summaryStmt, 5),
                            limit: snippetsPerMeeting
                        )
                    ))
                }
            }

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

            var rawSearchGroups = meetingOrder.compactMap { filename -> MeetingSearchGroup? in
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
            let rawGroupsByFilename = Dictionary(uniqueKeysWithValues: rawSearchGroups.map { ($0.filename, $0) })
            let mergedSummaryGroups = summaryGroups.map { summaryGroup -> MeetingSearchGroup in
                guard let rawGroup = rawGroupsByFilename[summaryGroup.filename] else { return summaryGroup }
                let cappedSnippets: [SearchSnippet]
                if snippetsPerMeeting > 1, !rawGroup.snippets.isEmpty {
                    let summarySlots = max(1, snippetsPerMeeting - 1)
                    var snippets = Array(summaryGroup.snippets.prefix(summarySlots))
                    snippets.append(contentsOf: rawGroup.snippets.prefix(snippetsPerMeeting - snippets.count))
                    cappedSnippets = snippets
                } else {
                    cappedSnippets = Array(summaryGroup.snippets.prefix(max(1, snippetsPerMeeting)))
                }
                return MeetingSearchGroup(
                    meetingTitle: summaryGroup.meetingTitle,
                    meetingDate: summaryGroup.meetingDate,
                    meetingDateTime: summaryGroup.meetingDateTime,
                    filename: summaryGroup.filename,
                    snippets: cappedSnippets
                )
            }
            rawSearchGroups.removeAll { summaryFilenames.contains($0.filename) }

            let combined = mergedSummaryGroups + rawSearchGroups
            let uniqueTotal = summaryFilenames.union(Set(meetingOrder)).count

            return GroupedSearchResult(
                results: Array(combined.prefix(maxMeetings)),
                totalMeetingsMatched: uniqueTotal,
                truncated: uniqueTotal > maxMeetings
            )
        }
    }

    private func summarySearchTitle(summaryTitle: String, filename: String) -> String {
        let trimmed = summaryTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return TranscriptLoader.fallbackMeetingTitle(forFilename: filename)
    }

    private func summarySearchSnippets(
        query: String,
        title: String,
        attendees: String,
        decisions: String,
        actionItems: String,
        openQuestions: String,
        limit: Int
    ) -> [SearchSnippet] {
        let fields: [(label: String, text: String)] = [
            ("Title", title),
            ("Decisions", decisions),
            ("Action Items", actionItems),
            ("Open Questions", openQuestions),
            ("Attendees", attendees)
        ]

        let queryTokens = query
            .components(separatedBy: .whitespacesAndNewlines)
            .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted).lowercased() }
            .filter { !$0.isEmpty }
        let orderedFields = fields.sorted { lhs, rhs in
            let lhsMatches = summaryField(lhs.text, matchesAny: queryTokens)
            let rhsMatches = summaryField(rhs.text, matchesAny: queryTokens)
            return lhsMatches == rhsMatches ? false : lhsMatches
        }

        let snippets = orderedFields.compactMap { field -> SearchSnippet? in
            let trimmed = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return SearchSnippet(
                speaker: "Summary",
                speakerId: nil,
                timestamp: field.label,
                text: "\(field.label): \(singleLineSummarySnippet(trimmed))"
            )
        }
        return Array(snippets.prefix(max(1, limit)))
    }

    private func summaryField(_ text: String, matchesAny queryTokens: [String]) -> Bool {
        guard !queryTokens.isEmpty else { return false }
        let normalized = text.lowercased()
        return queryTokens.contains { normalized.contains($0) }
    }

    private func singleLineSummarySnippet(_ text: String) -> String {
        let singleLine = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        return String(singleLine.prefix(320))
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
                       m.date, m.duration_seconds, m.speaker_count,
                       (SELECT text FROM utterances u
                        WHERE u.filename = ms.filename AND u.speaker_name = ms.speaker_name
                        ORDER BY u.utterance_start LIMIT 1) AS preview_snippet
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

                meetings.append(SpeakerMeeting(
                    filename: filename,
                    speakerName: speakerName,
                    persistentSpeakerId: colTextOptional(stmt, 2),
                    wordCount: Int(sqlite3_column_int64(stmt, 3)),
                    speakingSeconds: sqlite3_column_double(stmt, 4),
                    meetingDate: colText(stmt, 5),
                    meetingDurationSeconds: Int(sqlite3_column_int64(stmt, 6)),
                    meetingSpeakerCount: Int(sqlite3_column_int64(stmt, 7)),
                    previewSnippet: String(colText(stmt, 8).prefix(150))
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

    /// Internal, not `private`, only so listRecentContext in
    /// TranscriptIndex+Context.swift can reach it. Nothing outside this type
    /// should touch it.
    struct MeetingQueryRow {
        var summary: MeetingSummary
        let firstUtterance: String
    }

    /// Internal, not `private`, only so listRecentContext in
    /// TranscriptIndex+Context.swift can reach it. Nothing outside this type
    /// should touch it.
    func queryMeetings(
        count: Int,
        dateFrom: String?,
        dateTo: String?,
        includeFirstUtterance: Bool
    ) throws -> [MeetingQueryRow] {
        return try queue.sync {
            let limit = max(1, min(count, 50))

            var sql = """
                SELECT m.filename, m.date, m.datetime, m.duration_seconds, m.speaker_count, m.word_count
            """
            if includeFirstUtterance {
                sql += ", (SELECT text FROM utterances u WHERE u.filename = m.filename ORDER BY u.utterance_start LIMIT 1) AS first_utterance"
            }
            sql += " FROM meetings m"

            var bindings: [SQLBinding] = []
            var conditions: [String] = []

            if let dateFrom = dateFrom {
                conditions.append("m.date >= ?")
                bindings.append(.text(dateFrom))
            }
            if let dateTo = dateTo {
                conditions.append("m.date <= ?")
                bindings.append(.text(dateTo))
            }

            if !conditions.isEmpty {
                sql += " WHERE " + conditions.joined(separator: " AND ")
            }
            sql += " ORDER BY m.datetime DESC LIMIT ?"
            bindings.append(.int(limit))

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw MCPIndexError.queryFailed(dbError())
            }
            defer { sqlite3_finalize(stmt) }

            for (i, binding) in bindings.enumerated() {
                bind(stmt: stmt, index: Int32(i + 1), value: binding)
            }

            var meetings: [MeetingQueryRow] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                meetings.append(MeetingQueryRow(
                    summary: MeetingSummary(
                        filename: colText(stmt, 0),
                        date: colText(stmt, 1),
                        datetime: colText(stmt, 2),
                        durationSeconds: Int(sqlite3_column_int64(stmt, 3)),
                        speakerCount: Int(sqlite3_column_int64(stmt, 4)),
                        wordCount: Int(sqlite3_column_int64(stmt, 5)),
                        speakers: []
                    ),
                    firstUtterance: includeFirstUtterance ? colText(stmt, 6) : ""
                ))
            }

            // Batch-fetch speakers for all returned meetings
            if !meetings.isEmpty {
                let filenames = meetings.map { $0.summary.filename }
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
                    meetings[i].summary.speakers = speakersByMeeting[meetings[i].summary.filename] ?? []
                }
            }

            return meetings
        }
    }

    func listMeetings(count: Int, dateFrom: String? = nil, dateTo: String? = nil) throws -> [MeetingSummary] {
        try queryMeetings(
            count: count,
            dateFrom: dateFrom,
            dateTo: dateTo,
            includeFirstUtterance: false
        ).map(\.summary)
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
}
