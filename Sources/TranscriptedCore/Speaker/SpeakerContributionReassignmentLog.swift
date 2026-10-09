// SpeakerContributionReassignmentLog.swift
// The audit log of manual contribution moves (reassignContribution). Un-merge
// reads it to tell a move made after a merge from an older one, because a move
// changes profile_id in place and keeps the row's rowid (#2152).

import Foundation
import SQLite3

@available(macOS 14.0, *)
extension SpeakerDatabase {
    /// One row per manual move. `provenance_high_rowid` is the largest
    /// speaker_provenance rowid when the move happened, so a move at or above a
    /// merge's marker rowid happened after that merge. Idempotent.
    func createReassignmentLogTableImpl() {
        executeSQL("""
        CREATE TABLE IF NOT EXISTS speaker_contribution_reassignments (
            seq INTEGER PRIMARY KEY AUTOINCREMENT,
            contribution_id TEXT NOT NULL,
            from_profile_id TEXT NOT NULL,
            to_profile_id TEXT NOT NULL,
            provenance_high_rowid INTEGER NOT NULL,
            reassigned_at TEXT NOT NULL
        );
        """)
        executeSQL("CREATE INDEX IF NOT EXISTS idx_reassign_contribution ON speaker_contribution_reassignments(contribution_id);")
    }

    /// Logs a move. Call on `queue`, inside the reassign transaction, before the
    /// row's profile_id changes. Best-effort like the other audit writes.
    func logReassignmentImpl(_ contributionId: UUID, from fromProfileId: UUID, to toProfileId: UUID) {
        let sql = """
        INSERT INTO speaker_contribution_reassignments
            (contribution_id, from_profile_id, to_profile_id, provenance_high_rowid, reassigned_at)
        VALUES (?, ?, ?, (SELECT COALESCE(MAX(rowid), 0) FROM speaker_provenance), ?);
        """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            AppLogger.speakers.error("Failed to prepare reassignment log insert", ["sqlite_error": dbErrorMessage()])
            return
        }
        let now = ISO8601DateFormatter().string(from: Date())
        for (index, value) in [contributionId.uuidString, fromProfileId.uuidString, toProfileId.uuidString].enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
        }
        sqlite3_bind_text(statement, 4, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
        if sqlite3_step(statement) != SQLITE_DONE {
            AppLogger.speakers.error("Failed to log contribution reassignment", ["sqlite_error": dbErrorMessage()])
        }
    }
}
