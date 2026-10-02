import Foundation
import SQLite3
import TranscriptedCaptureKit

// Structured summary queries and the cross-meeting rollups built on them
// (list_action_items, list_decisions, digest). Split out of
// TranscriptIndex.swift; every query keeps its own queue.sync.

extension TranscriptIndex {
    // MARK: - Structured summary queries

    /// Stable `kind` discriminator values for `meeting_summary_items`.
    enum SummaryItemKind {
        static let decision = "decision"
        static let actionItem = "action_item"
        static let openQuestion = "open_question"
    }

    /// One indexed structured-summary row joined to its meeting's date metadata.
    /// This is the foundation the cross-meeting tools (e.g.
    /// `list_action_items`) build on.
    struct IndexedSummaryItem {
        let filename: String
        let kind: String
        let position: Int
        let owner: String?
        let text: String
        let meetingDate: String
        let meetingDateTime: String
    }

    /// Roll up structured summary items across meetings, newest meeting first.
    /// `kind` and `owner` are optional filters; `owner == ""` selects unassigned
    /// (NULL-owner) items, which is meaningful only for action items.
    func listSummaryItems(
        kind: String? = nil,
        owner: String? = nil,
        dateFrom: String? = nil,
        dateTo: String? = nil,
        limit: Int = 200
    ) throws -> [IndexedSummaryItem] {
        return try queue.sync {
            let cappedLimit = max(1, min(limit, 1000))
            var sql = """
                SELECT s.filename, s.kind, s.position, s.owner, s.text, m.date, m.datetime
                FROM meeting_summary_items s
                JOIN meetings m ON m.filename = s.filename
            """
            var bindings: [SQLBinding] = []
            var conditions: [String] = []

            if let kind = kind {
                conditions.append("s.kind = ?")
                bindings.append(.text(kind))
            }
            if let owner = owner {
                if owner.isEmpty {
                    conditions.append("s.owner IS NULL")
                } else {
                    conditions.append("s.owner COLLATE NOCASE = ?")
                    bindings.append(.text(owner))
                }
            }
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
            sql += " ORDER BY m.datetime DESC, s.filename, s.kind, s.position LIMIT ?"
            bindings.append(.int(cappedLimit))

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw MCPIndexError.queryFailed(dbError())
            }
            defer { sqlite3_finalize(stmt) }
            for (i, binding) in bindings.enumerated() {
                bind(stmt: stmt, index: Int32(i + 1), value: binding)
            }

            var items: [IndexedSummaryItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                items.append(IndexedSummaryItem(
                    filename: colText(stmt, 0),
                    kind: colText(stmt, 1),
                    position: Int(sqlite3_column_int64(stmt, 2)),
                    owner: colTextOptional(stmt, 3),
                    text: colText(stmt, 4),
                    meetingDate: colText(stmt, 5),
                    meetingDateTime: colText(stmt, 6)
                ))
            }
            return items
        }
    }

    // MARK: - Summary-fact rollups (cross-meeting tools)

    func listActionItems(
        owner: String?,
        query: String?,
        status: ActionItemStatusFilter,
        dateFrom: String?,
        dateTo: String?,
        maxItems: Int = 50
    ) throws -> ActionItemsResult {
        try queue.sync {
            let limit = max(1, min(maxItems, 200))
            var sql = """
                SELECT s.filename, s.text, s.owner, s.status, s.due, m.date, m.datetime
                FROM meeting_summary_items s
                JOIN meetings m ON m.filename = s.filename
                WHERE s.kind = ?
            """
            var bindings: [SQLBinding] = [.text(SummaryItemKind.actionItem)]

            if let owner, !owner.trimmingCharacters(in: .whitespaces).isEmpty {
                let (clause, ownerBindings) = ownerMatchClause(owner, column: "s.owner")
                sql += " AND \(clause)"
                bindings.append(contentsOf: ownerBindings)
            }

            switch status {
            case .open:
                sql += " AND (s.status IS NULL OR s.status = '' OR lower(s.status) NOT IN ('done', 'complete', 'completed', 'resolved', 'closed', 'cancelled', 'canceled'))"
            case .all:
                break
            case .done:
                sql += " AND lower(s.status) IN ('done', 'complete', 'completed', 'resolved', 'closed', 'cancelled', 'canceled')"
            }

            if let dateFrom { sql += " AND m.date >= ?"; bindings.append(.text(dateFrom)) }
            if let dateTo { sql += " AND m.date <= ?"; bindings.append(.text(dateTo)) }

            if let fts = ftsQuery(from: query) {
                sql += " AND s.rowid IN (SELECT rowid FROM meeting_summary_items_fts WHERE meeting_summary_items_fts MATCH ?)"
                bindings.append(.text(fts))
            }

            sql += " ORDER BY m.datetime DESC, s.position ASC LIMIT ?"
            bindings.append(.int(limit + 1))

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw MCPIndexError.queryFailed(dbError())
            }
            defer { sqlite3_finalize(stmt) }
            for (i, binding) in bindings.enumerated() { bind(stmt: stmt, index: Int32(i + 1), value: binding) }

            var rows: [ActionItemRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let filename = colText(stmt, 0)
                rows.append(ActionItemRecord(
                    filename: filename,
                    meetingTitle: filename,
                    date: colText(stmt, 5),
                    datetime: colText(stmt, 6),
                    text: colText(stmt, 1),
                    owner: colTextOptional(stmt, 2),
                    status: colTextOptional(stmt, 3),
                    due: colTextOptional(stmt, 4)
                ))
            }

            let truncated = rows.count > limit
            let items = Array(rows.prefix(limit))
            return ActionItemsResult(
                owner: owner,
                status: status.rawValue,
                count: items.count,
                truncated: truncated,
                items: items
            )
        }
    }

    func listDecisions(
        query: String?,
        dateFrom: String?,
        dateTo: String?,
        maxItems: Int = 50
    ) throws -> DecisionsResult {
        try queue.sync {
            let limit = max(1, min(maxItems, 200))
            var sql = """
                SELECT s.filename, s.text, m.date, m.datetime
                FROM meeting_summary_items s
                JOIN meetings m ON m.filename = s.filename
                WHERE s.kind = ?
            """
            var bindings: [SQLBinding] = [.text(SummaryItemKind.decision)]

            if let dateFrom { sql += " AND m.date >= ?"; bindings.append(.text(dateFrom)) }
            if let dateTo { sql += " AND m.date <= ?"; bindings.append(.text(dateTo)) }

            if let fts = ftsQuery(from: query) {
                sql += " AND s.rowid IN (SELECT rowid FROM meeting_summary_items_fts WHERE meeting_summary_items_fts MATCH ?)"
                bindings.append(.text(fts))
            }

            sql += " ORDER BY m.datetime DESC, s.position ASC LIMIT ?"
            bindings.append(.int(limit + 1))

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw MCPIndexError.queryFailed(dbError())
            }
            defer { sqlite3_finalize(stmt) }
            for (i, binding) in bindings.enumerated() { bind(stmt: stmt, index: Int32(i + 1), value: binding) }

            var rows: [DecisionRecord] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let filename = colText(stmt, 0)
                rows.append(DecisionRecord(
                    filename: filename,
                    meetingTitle: filename,
                    date: colText(stmt, 2),
                    datetime: colText(stmt, 3),
                    text: colText(stmt, 1)
                ))
            }

            let truncated = rows.count > limit
            let decisions = Array(rows.prefix(limit))
            return DecisionsResult(count: decisions.count, truncated: truncated, decisions: decisions)
        }
    }

    /// Cross-meeting digest for a date window: every meeting in range that has any
    /// summary facts, with its decisions, action items, and open questions, plus
    /// rolled-up counts.
    func digest(dateFrom: String?, dateTo: String?, maxMeetings: Int = 50) throws -> DigestResult {
        try queue.sync {
            let limit = max(1, min(maxMeetings, 100))

            var meetingSQL = """
                SELECT m.filename, m.date, m.datetime
                FROM meetings m
                WHERE EXISTS (
                    SELECT 1 FROM meeting_summary_items s WHERE s.filename = m.filename
                )
            """
            var bindings: [SQLBinding] = []
            if let dateFrom { meetingSQL += " AND m.date >= ?"; bindings.append(.text(dateFrom)) }
            if let dateTo { meetingSQL += " AND m.date <= ?"; bindings.append(.text(dateTo)) }
            meetingSQL += " ORDER BY m.datetime DESC LIMIT ?"
            bindings.append(.int(limit))

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, meetingSQL, -1, &stmt, nil) == SQLITE_OK else {
                throw MCPIndexError.queryFailed(dbError())
            }
            defer { sqlite3_finalize(stmt) }
            for (i, binding) in bindings.enumerated() { bind(stmt: stmt, index: Int32(i + 1), value: binding) }

            struct WindowMeeting { let filename: String; let date: String; let datetime: String }
            var windowMeetings: [WindowMeeting] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                windowMeetings.append(WindowMeeting(
                    filename: colText(stmt, 0), date: colText(stmt, 1), datetime: colText(stmt, 2)
                ))
            }

            guard !windowMeetings.isEmpty else {
                return DigestResult(
                    dateRange: digestRangeLabel(dateFrom: dateFrom, dateTo: dateTo),
                    meetingCount: 0, actionItemCount: 0, openActionItemCount: 0,
                    decisionCount: 0, openQuestionCount: 0, meetings: []
                )
            }

            let filenames = windowMeetings.map(\.filename)
            let decisionsByMeeting = try fetchTextSummaryItems(kind: SummaryItemKind.decision, filenames: filenames)
            let questionsByMeeting = try fetchTextSummaryItems(kind: SummaryItemKind.openQuestion, filenames: filenames)
            let actionsByMeeting = try fetchActionSummaryItems(filenames: filenames)

            var digestMeetings: [DigestMeeting] = []
            var totalActions = 0, totalOpenActions = 0, totalDecisions = 0, totalQuestions = 0

            for meeting in windowMeetings {
                let decisions = decisionsByMeeting[meeting.filename] ?? []
                let questions = questionsByMeeting[meeting.filename] ?? []
                let actions = actionsByMeeting[meeting.filename] ?? []
                guard !decisions.isEmpty || !questions.isEmpty || !actions.isEmpty else { continue }

                totalDecisions += decisions.count
                totalQuestions += questions.count
                totalActions += actions.count
                totalOpenActions += actions.filter { Self.isOpenStatus($0.status) }.count

                digestMeetings.append(DigestMeeting(
                    filename: meeting.filename,
                    title: meeting.filename,
                    date: meeting.date,
                    datetime: meeting.datetime,
                    decisions: decisions,
                    actionItems: actions,
                    openQuestions: questions
                ))
            }

            return DigestResult(
                dateRange: digestRangeLabel(dateFrom: dateFrom, dateTo: dateTo),
                meetingCount: digestMeetings.count,
                actionItemCount: totalActions,
                openActionItemCount: totalOpenActions,
                decisionCount: totalDecisions,
                openQuestionCount: totalQuestions,
                meetings: digestMeetings
            )
        }
    }

    // MARK: - Summary-fact helpers (run inside queue.sync)

    private func fetchTextSummaryItems(kind: String, filenames: [String]) throws -> [String: [String]] {
        let placeholders = filenames.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            SELECT filename, text FROM meeting_summary_items
            WHERE kind = ? AND filename IN (\(placeholders))
            ORDER BY filename, position ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MCPIndexError.queryFailed(dbError())
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (kind as NSString).utf8String, -1, SQLITE_TRANSIENT)
        for (i, f) in filenames.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 2), (f as NSString).utf8String, -1, SQLITE_TRANSIENT)
        }
        var result: [String: [String]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            result[colText(stmt, 0), default: []].append(colText(stmt, 1))
        }
        return result
    }

    private func fetchActionSummaryItems(filenames: [String]) throws -> [String: [DigestActionItem]] {
        let placeholders = filenames.map { _ in "?" }.joined(separator: ", ")
        let sql = """
            SELECT filename, text, owner, status, due FROM meeting_summary_items
            WHERE kind = ? AND filename IN (\(placeholders))
            ORDER BY filename, position ASC
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw MCPIndexError.queryFailed(dbError())
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (SummaryItemKind.actionItem as NSString).utf8String, -1, SQLITE_TRANSIENT)
        for (i, f) in filenames.enumerated() {
            sqlite3_bind_text(stmt, Int32(i + 2), (f as NSString).utf8String, -1, SQLITE_TRANSIENT)
        }
        var result: [String: [DigestActionItem]] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            result[colText(stmt, 0), default: []].append(DigestActionItem(
                text: colText(stmt, 1),
                owner: colTextOptional(stmt, 2),
                status: colTextOptional(stmt, 3),
                due: colTextOptional(stmt, 4)
            ))
        }
        return result
    }

    private func ownerMatchClause(_ owner: String, column: String) -> (String, [SQLBinding]) {
        let names = NameVariants.expandName(owner)
        let exact = names.map { _ in "\(column) COLLATE NOCASE = ?" }
        let like = names.map { _ in "\(column) COLLATE NOCASE LIKE ?" }
        let clause = "(" + (exact + like).joined(separator: " OR ") + ")"
        let bindings = names.map { SQLBinding.text($0) } + names.map { SQLBinding.text("%\($0)%") }
        return (clause, bindings)
    }

    /// Swift predicate for in-memory rollup counting. Current saved summaries do
    /// not carry status, so nil means open.
    static func isOpenStatus(_ status: String?) -> Bool {
        guard let status = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !status.isEmpty else {
            return true
        }
        return !["done", "complete", "completed", "resolved", "closed", "cancelled", "canceled"].contains(status)
    }

    private func digestRangeLabel(dateFrom: String?, dateTo: String?) -> String {
        switch (dateFrom, dateTo) {
        case let (from?, to?): return from == to ? from : "\(from) to \(to)"
        case let (from?, nil): return "since \(from)"
        case let (nil, to?): return "through \(to)"
        case (nil, nil): return "all time"
        }
    }
}
