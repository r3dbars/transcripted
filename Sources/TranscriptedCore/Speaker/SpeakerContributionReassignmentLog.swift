// SpeakerContributionReassignmentLog.swift
// The audit log of manual contribution moves (reassignContribution). Un-merge
// reads it to tell a move made after a merge from an older one, because a move
// changes profile_id in place and keeps the row's rowid (#2152).

import Foundation
import SQLite3

@available(macOS 14.0, *)
extension SpeakerDatabase {
    /// One row per manual move. `merge_events_high` is the largest
    /// speaker_merge_events rowid when the move happened. Merge events are never
    /// deleted (un-merge only sets undone_at), so their rowids never repeat: a
    /// move with merge_events_high >= a merge's event rowid happened after that
    /// merge. (Provenance rowids can repeat once un-merge deletes a marker.) Idempotent.
    func createReassignmentLogTableImpl() {
        executeSQL("""
        CREATE TABLE IF NOT EXISTS speaker_contribution_reassignments (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            contribution_id TEXT NOT NULL,
            from_profile_id TEXT NOT NULL,
            to_profile_id TEXT NOT NULL,
            merge_events_high INTEGER NOT NULL,
            reassigned_at TEXT NOT NULL
        );
        """)
        executeSQL("CREATE INDEX IF NOT EXISTS idx_reassign_contribution ON speaker_contribution_reassignments(contribution_id);")
    }

    /// Logs a move. Call on `queue`, inside the reassign transaction, before the
    /// row's profile_id changes. Throws so a failed log rolls the move back:
    /// an unlogged move would be invisible to a later un-merge.
    func logReassignmentOrThrowImpl(_ contributionId: UUID, from fromProfileId: UUID, to toProfileId: UUID) throws {
        let sql = """
        INSERT INTO speaker_contribution_reassignments
            (contribution_id, from_profile_id, to_profile_id, merge_events_high, reassigned_at)
        VALUES (?, ?, ?, (SELECT COALESCE(MAX(rowid), 0) FROM speaker_merge_events), ?);
        """
        let statement = try prepareStatement(sql, operation: "prepare reassignment log insert")
        defer { sqlite3_finalize(statement) }
        let now = ISO8601DateFormatter().string(from: Date())
        for (index, value) in [contributionId.uuidString, fromProfileId.uuidString, toProfileId.uuidString].enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
        }
        sqlite3_bind_text(statement, 4, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
        try requireDone(statement, operation: "step reassignment log insert", expectedChanges: 1)
    }

    /// After an un-merge: drop moves older than every merge still undoable. They
    /// are pre-merge for all of them, so no later un-merge can need them.
    func trimReassignmentLogImpl() throws {
        let statement = try prepareStatement(
            """
            DELETE FROM speaker_contribution_reassignments WHERE merge_events_high < COALESCE(
                (SELECT MIN(rowid) FROM speaker_merge_events WHERE undone_at IS NULL), 9223372036854775807);
            """,
            operation: "prepare reassignment log trim"
        )
        defer { sqlite3_finalize(statement) }
        try requireDone(statement, operation: "step reassignment log trim")
    }
}
