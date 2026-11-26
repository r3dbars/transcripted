// SpeakerProvenanceCleanup.swift
// Provenance, merge-event, confirmation-move, and reassignment-log cleanup for
// profile deletion, weak-profile pruning, and rejected-session rollback.

import Foundation
import SQLite3

@available(macOS 14.0, *)
extension SpeakerDatabase {

    /// Erase provenance, confirmation move history, and reassignment log rows referencing
    /// any of `ids`, and scrub matching `speaker_merge_events` rows in place (clearing
    /// snapshots and marking them non-undoable without deleting the row so monotonic
    /// `rowid`s never repeat for `speaker_contribution_reassignments`). Called inside an
    /// explicit `deleteSpeaker` or `pruneWeakProfiles` (never inside `mergeProfilesImpl`,
    /// which preserves merge history so surviving speakers can un-merge).
    ///
    /// Must be called on `queue`.
    func deleteProvenanceAndMergeHistoryImpl(forProfileIds ids: [UUID]) {
        guard isDatabaseOpen, !ids.isEmpty else { return }
        let idStrings = ids.map(\.uuidString)
        let placeholders = Array(repeating: "?", count: idStrings.count).joined(separator: ",")

        // Only scrub merge events whose target is being deleted, or already-undone events
        // naming a deleted source. A live merge event whose source is in `ids` always has
        // its target in `ids` too on a consistent DB; restricting `source_id` to already-undone
        // events ensures that even a resurrected absorbed UUID can never wipe a surviving
        // keeper's live undo-merge history.
        //
        // Delete dependent confirmation moves and provenance merge markers BEFORE setting
        // `undone_at` on the scrubbed events so the `undone_at IS NOT NULL` filter matches
        // the exact same event set.
        let deleteConfirmationMovesSQL = """
        DELETE FROM speaker_confirmation_moves
        WHERE merge_event_id IN (
            SELECT id FROM speaker_merge_events
            WHERE target_id IN (\(placeholders))
               OR (source_id IN (\(placeholders)) AND undone_at IS NOT NULL)
        )
           OR target_profile_id IN (\(placeholders));
        """
        executeBoundStatement(
            sql: deleteConfirmationMovesSQL,
            values: idStrings + idStrings + idStrings,
            operation: "delete speaker confirmation moves"
        )

        let deleteProvenanceSQL = """
        DELETE FROM speaker_provenance
        WHERE profile_id IN (\(placeholders))
           OR merge_event_id IN (
               SELECT id FROM speaker_merge_events
               WHERE target_id IN (\(placeholders))
                  OR (source_id IN (\(placeholders)) AND undone_at IS NOT NULL)
           );
        """
        executeBoundStatement(
            sql: deleteProvenanceSQL,
            values: idStrings + idStrings + idStrings,
            operation: "delete speaker provenance"
        )

        // Scrub merge-event snapshots in place instead of DELETE so SQLite never reuses
        // `speaker_merge_events.rowid` values referenced by `speaker_contribution_reassignments`.
        let now = ISO8601DateFormatter().string(from: Date())
        let scrubMergeEventsSQL = """
        UPDATE speaker_merge_events
        SET source_snapshot = '',
            target_snapshot = '',
            moved_provenance_ids = '[]',
            undone_at = COALESCE(undone_at, ?)
        WHERE target_id IN (\(placeholders))
           OR (source_id IN (\(placeholders)) AND undone_at IS NOT NULL);
        """
        executeBoundStatement(
            sql: scrubMergeEventsSQL,
            values: [now] + idStrings + idStrings,
            operation: "scrub speaker merge events"
        )

        let deleteReassignmentsSQL = """
        DELETE FROM speaker_contribution_reassignments
        WHERE from_profile_id IN (\(placeholders)) OR to_profile_id IN (\(placeholders));
        """
        executeBoundStatement(
            sql: deleteReassignmentsSQL,
            values: idStrings + idStrings,
            operation: "delete speaker contribution reassignments"
        )
    }

    /// Delete one rejected session's contribution row from `speaker_provenance`.
    /// When `embedding` is provided, matches the newest contribution row with that
    /// exact embedding BLOB first so a later valid meeting on the same profile is
    /// untouched. Falls back to the newest `contribution` row when `fallbackToLatest`
    /// is true (e.g. single-match revert or callers without the session embedding).
    /// Never removes `seed` or `merge` rows. Must be called on `queue`.
    func deleteRejectedContributionImpl(
        profileId: UUID,
        embedding: [Float]?,
        fallbackToLatest: Bool
    ) {
        guard isDatabaseOpen else { return }

        if let embedding, !embedding.isEmpty {
            let sql = """
            DELETE FROM speaker_provenance
            WHERE rowid = (
                SELECT rowid FROM speaker_provenance
                WHERE profile_id = ? AND kind = ? AND embedding = ?
                ORDER BY rowid DESC
                LIMIT 1
            );
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                let embeddingData = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
                sqlite3_bind_text(statement, 1, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 2, (SpeakerProvenanceKind.contribution as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_blob(statement, 3, (embeddingData as NSData).bytes, Int32(embeddingData.count), SQLITE_TRANSIENT)
                let step = sqlite3_step(statement)
                let removed = sqlite3_changes(db)
                sqlite3_finalize(statement)
                if step != SQLITE_DONE {
                    AppLogger.speakers.error("Failed to delete rejected speaker provenance row", ["sqlite_error": dbErrorMessage(), "profileId": profileId.uuidString])
                    recordMutationFailure(operation: "delete rejected speaker provenance", code: step)
                    return
                }
                if removed > 0 { return }
                AppLogger.speakers.warning(
                    "Rejected speaker provenance embedding matched no contribution row",
                    ["profileId": profileId.uuidString, "fallbackToLatest": "\(fallbackToLatest)"]
                )
            } else {
                sqlite3_finalize(statement)
                recordMutationFailure(operation: "prepare delete rejected speaker provenance", code: sqlite3_errcode(db))
                return
            }
        }

        if fallbackToLatest {
            deleteLatestContributionsImpl(profileId: profileId, limit: 1)
        }
    }

    /// Delete the newest `limit` `contribution` rows for `profileId` from
    /// `speaker_provenance` (never deleting `seed` or `merge` rows). Used when
    /// rolling a profile back to an earlier snapshot with a lower `callCount`.
    /// Must be called on `queue`.
    func deleteLatestContributionsImpl(profileId: UUID, limit: Int) {
        guard isDatabaseOpen, limit > 0 else { return }
        let sql = """
        DELETE FROM speaker_provenance
        WHERE rowid IN (
            SELECT rowid FROM speaker_provenance
            WHERE profile_id = ? AND kind = ?
            ORDER BY rowid DESC
            LIMIT ?
        );
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, (SpeakerProvenanceKind.contribution as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 3, Int32(limit))
            if sqlite3_step(statement) != SQLITE_DONE {
                AppLogger.speakers.error("Failed to delete latest speaker provenance rows", ["sqlite_error": dbErrorMessage(), "profileId": profileId.uuidString])
                recordMutationFailure(operation: "delete latest speaker provenance", code: sqlite3_errcode(db))
            }
        } else {
            recordMutationFailure(operation: "prepare delete latest speaker provenance", code: sqlite3_errcode(db))
        }
        sqlite3_finalize(statement)
    }

    private func executeBoundStatement(sql: String, values: [String], operation: String) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            AppLogger.speakers.error("Failed to prepare \(operation)", ["sqlite_error": dbErrorMessage()])
            recordMutationFailure(operation: "prepare \(operation)", code: sqlite3_errcode(db))
            sqlite3_finalize(statement)
            return
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(offset + 1), (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
        }
        if sqlite3_step(statement) != SQLITE_DONE {
            AppLogger.speakers.error("Failed to \(operation)", ["sqlite_error": dbErrorMessage()])
            recordMutationFailure(operation: operation, code: sqlite3_errcode(db))
        }
    }
}
