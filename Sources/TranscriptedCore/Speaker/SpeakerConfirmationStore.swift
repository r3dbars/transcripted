// SpeakerConfirmationStore.swift
// Canonical proof that a user explicitly confirmed a speaker identity in a
// distinct saved meeting. Passive matches and silent auto-accepts never write
// this ledger, so repeated appearances cannot self-graduate into auto-naming.

import Foundation
import SQLite3

public enum SpeakerUserConfirmationKind: String, Sendable {
    case named
    case confirmed
    case corrected
    case merged

    public init?(reviewAction: SpeakerNameUpdate.NamingAction) {
        switch reviewAction {
        case .named: self = .named
        case .confirmed: self = .confirmed
        case .corrected: self = .corrected
        case .merged: self = .merged
        case .collapsedToMe, .discardedFromDatabase: return nil
        }
    }
}

public struct SpeakerUserConfirmation: Sendable {
    public let profileId: UUID
    public let transcriptId: UUID
    public let kind: SpeakerUserConfirmationKind
    public let confirmedAt: Date

    public init(
        profileId: UUID,
        transcriptId: UUID,
        kind: SpeakerUserConfirmationKind,
        confirmedAt: Date = Date()
    ) {
        self.profileId = profileId
        self.transcriptId = transcriptId
        self.kind = kind
        self.confirmedAt = confirmedAt
    }
}

@available(macOS 14.0, *)
extension SpeakerDatabase {
    private struct ConfirmationRow {
        let id: String
        let transcriptId: String
        let kind: String
        let confirmedAt: String
    }

    private struct ConfirmationMoveRow {
        let confirmation: ConfirmationRow
        let sourceProfileId: String
        let targetProfileId: String
        let targetHadRow: Bool
    }

    private struct ActiveConfirmationMerge {
        let id: UUID
        let sourceProfileId: UUID
        let targetProfileId: UUID
    }

    private static let confirmationDateFormatter = ISO8601DateFormatter()
    private static let legacyConfirmationMigrationKey = "legacy-positive-outcomes-v2"

    // MARK: - Schema and conservative migration

    func createConfirmationTablesImpl() {
        executeSQL("""
        CREATE TABLE IF NOT EXISTS speaker_profile_confirmations (
            id TEXT PRIMARY KEY,
            profile_id TEXT NOT NULL,
            transcript_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            confirmed_at TEXT NOT NULL,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(profile_id, transcript_id)
        );
        """)
        executeSQL("CREATE INDEX IF NOT EXISTS idx_speaker_confirmations_profile ON speaker_profile_confirmations(profile_id);")
        executeSQL("CREATE INDEX IF NOT EXISTS idx_speaker_confirmations_transcript ON speaker_profile_confirmations(transcript_id);")

        executeSQL("""
        CREATE TABLE IF NOT EXISTS speaker_confirmation_moves (
            merge_event_id TEXT NOT NULL,
            confirmation_id TEXT NOT NULL,
            source_profile_id TEXT NOT NULL,
            target_profile_id TEXT NOT NULL,
            transcript_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            confirmed_at TEXT NOT NULL,
            target_had_row INTEGER NOT NULL,
            PRIMARY KEY(merge_event_id, confirmation_id)
        );
        """)
        executeSQL("CREATE INDEX IF NOT EXISTS idx_speaker_confirmation_moves_event ON speaker_confirmation_moves(merge_event_id);")

        executeSQL("""
        CREATE TABLE IF NOT EXISTS speaker_confirmation_migrations (
            key TEXT PRIMARY KEY,
            completed_at TEXT NOT NULL
        );
        """)

        do {
            try throwingTransaction {
                try migrateLegacyPositiveOutcomesImpl()
            }
        } catch {
            AppLogger.speakers.error("Failed to migrate legacy speaker confirmations", [
                "error": error.localizedDescription,
            ])
        }
    }

    /// Older installs already have privacy-safe review outcomes. Recover only
    /// explicit positive user verdicts, then replay every still-active merge so
    /// absorbed profiles contribute to the live keeper and can be reconstructed
    /// by a later unmerge. Corrections are intentionally excluded: legacy
    /// correction outcomes point at the rejected suggestion, not the corrected-to
    /// person. Auto-accepted rows and call_count are never treated as user proof.
    private func migrateLegacyPositiveOutcomesImpl() throws {
        let marker = try prepareStatement(
            "SELECT 1 FROM speaker_confirmation_migrations WHERE key = ? LIMIT 1;",
            operation: "prepare speaker confirmation migration lookup"
        )
        defer { sqlite3_finalize(marker) }
        sqlite3_bind_text(
            marker,
            1,
            (Self.legacyConfirmationMigrationKey as NSString).utf8String,
            -1,
            SQLITE_TRANSIENT
        )
        let markerResult = sqlite3_step(marker)
        if markerResult == SQLITE_ROW { return }
        guard markerResult == SQLITE_DONE else {
            throw SQLiteOperationError(
                operation: "step speaker confirmation migration lookup",
                code: markerResult,
                detail: dbErrorMessage()
            )
        }

        let insert = try prepareStatement("""
        INSERT OR IGNORE INTO speaker_profile_confirmations
            (id, profile_id, transcript_id, kind, confirmed_at)
        SELECT 'legacy-outcome-' || o.id, o.profile_id, o.transcript_id, o.kind, o.recorded_at
        FROM speaker_match_outcomes o
        WHERE o.transcript_id IS NOT NULL
          AND o.transcript_id != ''
          AND o.kind IN ('named', 'confirmed', 'merged')
        ORDER BY o.rowid ASC;
        """, operation: "prepare legacy speaker confirmation migration")
        defer { sqlite3_finalize(insert) }
        try requireDone(insert, operation: "step legacy speaker confirmation migration")

        for merge in try activeConfirmationMergesImpl() {
            try moveConfirmationsForMergeImpl(
                mergeEventId: merge.id,
                sourceProfileId: merge.sourceProfileId,
                targetProfileId: merge.targetProfileId
            )
        }

        // Outcomes for profiles deleted outside a recorded merge have no safe
        // surviving owner. Keep them out of the canonical maturity count.
        let prune = try prepareStatement("""
        DELETE FROM speaker_profile_confirmations
        WHERE NOT EXISTS (
            SELECT 1 FROM speakers WHERE speakers.id = speaker_profile_confirmations.profile_id
        );
        """, operation: "prepare orphan legacy confirmation cleanup")
        defer { sqlite3_finalize(prune) }
        try requireDone(prune, operation: "step orphan legacy confirmation cleanup")

        let completion = try prepareStatement(
            "INSERT INTO speaker_confirmation_migrations (key, completed_at) VALUES (?, ?);",
            operation: "prepare speaker confirmation migration marker"
        )
        defer { sqlite3_finalize(completion) }
        let now = Self.confirmationDateFormatter.string(from: Date())
        sqlite3_bind_text(
            completion,
            1,
            (Self.legacyConfirmationMigrationKey as NSString).utf8String,
            -1,
            SQLITE_TRANSIENT
        )
        sqlite3_bind_text(completion, 2, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
        try requireDone(
            completion,
            operation: "step speaker confirmation migration marker",
            expectedChanges: 1
        )
    }

    private func activeConfirmationMergesImpl() throws -> [ActiveConfirmationMerge] {
        let statement = try prepareStatement("""
        SELECT id, source_id, target_id
        FROM speaker_merge_events
        WHERE undone_at IS NULL
        ORDER BY rowid ASC;
        """, operation: "prepare active merge lookup for confirmation migration")
        defer { sqlite3_finalize(statement) }

        var merges: [ActiveConfirmationMerge] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return merges }
            guard result == SQLITE_ROW else {
                throw SQLiteOperationError(
                    operation: "step active merge lookup for confirmation migration",
                    code: result,
                    detail: dbErrorMessage()
                )
            }
            guard let idText = sqlite3_column_text(statement, 0).map(String.init(cString:)),
                  let id = UUID(uuidString: idText),
                  let sourceText = sqlite3_column_text(statement, 1).map(String.init(cString:)),
                  let sourceId = UUID(uuidString: sourceText),
                  let targetText = sqlite3_column_text(statement, 2).map(String.init(cString:)),
                  let targetId = UUID(uuidString: targetText) else {
                throw SQLiteOperationError(
                    operation: "decode active merge for confirmation migration",
                    code: SQLITE_CORRUPT,
                    detail: "merge event contains an invalid UUID"
                )
            }
            merges.append(ActiveConfirmationMerge(
                id: id,
                sourceProfileId: sourceId,
                targetProfileId: targetId
            ))
        }
    }

    // MARK: - Explicit confirmation writes

    public func recordUserConfirmations(_ confirmations: [SpeakerUserConfirmation]) throws {
        guard !confirmations.isEmpty else { return }
        if isExecutingOnQueue {
            try recordUserConfirmationsImpl(confirmations)
            return
        }
        try queue.sync {
            try throwingTransaction {
                try recordUserConfirmationsImpl(confirmations)
            }
        }
    }

    private func recordUserConfirmationsImpl(_ confirmations: [SpeakerUserConfirmation]) throws {
        guard isDatabaseOpen else {
            throw SQLiteOperationError(
                operation: "record speaker confirmations",
                code: SQLITE_MISUSE,
                detail: "database not open"
            )
        }

        let sql = """
        INSERT OR IGNORE INTO speaker_profile_confirmations
            (id, profile_id, transcript_id, kind, confirmed_at)
        VALUES (?, ?, ?, ?, ?);
        """
        let statement = try prepareStatement(sql, operation: "prepare speaker confirmation insert")
        defer { sqlite3_finalize(statement) }

        for confirmation in confirmations {
            guard getSpeakerImpl(id: confirmation.profileId) != nil else {
                throw SQLiteOperationError(
                    operation: "record speaker confirmation",
                    code: SQLITE_NOTFOUND,
                    detail: "profile \(confirmation.profileId.uuidString) does not exist"
                )
            }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            let confirmedAt = Self.confirmationDateFormatter.string(from: confirmation.confirmedAt)
            sqlite3_bind_text(statement, 1, (UUID().uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, (confirmation.profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, (confirmation.transcriptId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, (confirmation.kind.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 5, (confirmedAt as NSString).utf8String, -1, SQLITE_TRANSIENT)
            try requireDone(statement, operation: "step speaker confirmation insert")
        }
    }

    func deleteConfirmationsImpl(profileId: UUID) {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(
            db,
            "DELETE FROM speaker_profile_confirmations WHERE profile_id = ?;",
            -1,
            &statement,
            nil
        )
        guard result == SQLITE_OK else {
            sqlite3_finalize(statement)
            recordMutationFailure(operation: "prepare delete speaker confirmations", code: result)
            return
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        let step = sqlite3_step(statement)
        if step != SQLITE_DONE {
            recordMutationFailure(operation: "delete speaker confirmations", code: step)
        }
    }

    // MARK: - Merge and unmerge set semantics

    /// Move the absorbed profile's confirmation set onto the keeper. Duplicate
    /// profile/meeting pairs collapse to one row, while the move journal keeps
    /// enough information to reconstruct both sets during an unmerge.
    func moveConfirmationsForMergeImpl(
        mergeEventId: UUID,
        sourceProfileId: UUID,
        targetProfileId: UUID
    ) throws {
        let rows = try confirmationRowsImpl(profileId: sourceProfileId)
        for row in rows {
            let targetHadRow = try confirmationExistsImpl(
                profileId: targetProfileId,
                transcriptId: row.transcriptId
            )

            let journal = try prepareStatement("""
            INSERT INTO speaker_confirmation_moves
                (merge_event_id, confirmation_id, source_profile_id, target_profile_id,
                 transcript_id, kind, confirmed_at, target_had_row)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?);
            """, operation: "prepare speaker confirmation move journal")
            defer { sqlite3_finalize(journal) }
            sqlite3_bind_text(journal, 1, (mergeEventId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(journal, 2, (row.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(journal, 3, (sourceProfileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(journal, 4, (targetProfileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(journal, 5, (row.transcriptId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(journal, 6, (row.kind as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(journal, 7, (row.confirmedAt as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(journal, 8, targetHadRow ? 1 : 0)
            try requireDone(journal, operation: "step speaker confirmation move journal", expectedChanges: 1)

            if targetHadRow {
                let delete = try prepareStatement(
                    "DELETE FROM speaker_profile_confirmations WHERE id = ?;",
                    operation: "prepare duplicate speaker confirmation delete"
                )
                defer { sqlite3_finalize(delete) }
                sqlite3_bind_text(delete, 1, (row.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
                try requireDone(delete, operation: "step duplicate speaker confirmation delete", expectedChanges: 1)
            } else {
                let move = try prepareStatement(
                    "UPDATE speaker_profile_confirmations SET profile_id = ? WHERE id = ? AND profile_id = ?;",
                    operation: "prepare speaker confirmation move"
                )
                defer { sqlite3_finalize(move) }
                sqlite3_bind_text(move, 1, (targetProfileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(move, 2, (row.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(move, 3, (sourceProfileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                try requireDone(move, operation: "step speaker confirmation move", expectedChanges: 1)
            }
        }
    }

    func restoreConfirmationsForUnmergeImpl(mergeEventId: UUID) throws {
        let rows = try confirmationMoveRowsImpl(mergeEventId: mergeEventId)
        for row in rows {
            if row.targetHadRow {
                let insert = try prepareStatement("""
                INSERT OR IGNORE INTO speaker_profile_confirmations
                    (id, profile_id, transcript_id, kind, confirmed_at)
                VALUES (?, ?, ?, ?, ?);
                """, operation: "prepare restore duplicate speaker confirmation")
                defer { sqlite3_finalize(insert) }
                sqlite3_bind_text(insert, 1, (row.confirmation.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(insert, 2, (row.sourceProfileId as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(insert, 3, (row.confirmation.transcriptId as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(insert, 4, (row.confirmation.kind as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(insert, 5, (row.confirmation.confirmedAt as NSString).utf8String, -1, SQLITE_TRANSIENT)
                try requireDone(insert, operation: "step restore duplicate speaker confirmation")
            } else {
                let move = try prepareStatement(
                    "UPDATE speaker_profile_confirmations SET profile_id = ? WHERE id = ? AND profile_id = ?;",
                    operation: "prepare restore speaker confirmation move"
                )
                defer { sqlite3_finalize(move) }
                sqlite3_bind_text(move, 1, (row.sourceProfileId as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(move, 2, (row.confirmation.id as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(move, 3, (row.targetProfileId as NSString).utf8String, -1, SQLITE_TRANSIENT)
                try requireDone(move, operation: "step restore speaker confirmation move", expectedChanges: 1)
            }
        }
    }

    private func confirmationRowsImpl(profileId: UUID) throws -> [ConfirmationRow] {
        let statement = try prepareStatement("""
        SELECT id, transcript_id, kind, confirmed_at
        FROM speaker_profile_confirmations
        WHERE profile_id = ?
        ORDER BY rowid ASC;
        """, operation: "prepare speaker confirmation lookup")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)

        var rows: [ConfirmationRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else {
                throw SQLiteOperationError(
                    operation: "step speaker confirmation lookup",
                    code: result,
                    detail: dbErrorMessage()
                )
            }
            rows.append(ConfirmationRow(
                id: sqlite3_column_text(statement, 0).map(String.init(cString:)) ?? "",
                transcriptId: sqlite3_column_text(statement, 1).map(String.init(cString:)) ?? "",
                kind: sqlite3_column_text(statement, 2).map(String.init(cString:)) ?? "",
                confirmedAt: sqlite3_column_text(statement, 3).map(String.init(cString:)) ?? ""
            ))
        }
    }

    private func confirmationExistsImpl(profileId: UUID, transcriptId: String) throws -> Bool {
        let statement = try prepareStatement("""
        SELECT 1 FROM speaker_profile_confirmations
        WHERE profile_id = ? AND transcript_id = ?
        LIMIT 1;
        """, operation: "prepare speaker confirmation existence lookup")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, (transcriptId as NSString).utf8String, -1, SQLITE_TRANSIENT)
        let result = sqlite3_step(statement)
        if result == SQLITE_ROW { return true }
        if result == SQLITE_DONE { return false }
        throw SQLiteOperationError(
            operation: "step speaker confirmation existence lookup",
            code: result,
            detail: dbErrorMessage()
        )
    }

    private func confirmationMoveRowsImpl(mergeEventId: UUID) throws -> [ConfirmationMoveRow] {
        let statement = try prepareStatement("""
        SELECT confirmation_id, source_profile_id, target_profile_id,
               transcript_id, kind, confirmed_at, target_had_row
        FROM speaker_confirmation_moves
        WHERE merge_event_id = ?
        ORDER BY rowid ASC;
        """, operation: "prepare speaker confirmation move lookup")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (mergeEventId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)

        var rows: [ConfirmationMoveRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else {
                throw SQLiteOperationError(
                    operation: "step speaker confirmation move lookup",
                    code: result,
                    detail: dbErrorMessage()
                )
            }
            let confirmation = ConfirmationRow(
                id: sqlite3_column_text(statement, 0).map(String.init(cString:)) ?? "",
                transcriptId: sqlite3_column_text(statement, 3).map(String.init(cString:)) ?? "",
                kind: sqlite3_column_text(statement, 4).map(String.init(cString:)) ?? "",
                confirmedAt: sqlite3_column_text(statement, 5).map(String.init(cString:)) ?? ""
            )
            rows.append(ConfirmationMoveRow(
                confirmation: confirmation,
                sourceProfileId: sqlite3_column_text(statement, 1).map(String.init(cString:)) ?? "",
                targetProfileId: sqlite3_column_text(statement, 2).map(String.init(cString:)) ?? "",
                targetHadRow: sqlite3_column_int(statement, 6) != 0
            ))
        }
    }
}
