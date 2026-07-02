// SpeakerMatchOutcomeStore.swift
// Append-only lifeline table inside speakers.sqlite: one row per auto-accept
// or review verdict, keyed by profile. Powers the local `speaker-stats`
// report, profile-health demotion, and the bucketed analytics events.
// Contains no names, embeddings, transcript text, or audio references.

import Foundation
import SQLite3

@available(macOS 14.0, *)
extension SpeakerDatabase {

    /// ISO8601DateFormatter is documented thread-safe, and all users below run
    /// on the database queue anyway — one shared instance avoids paying its
    /// construction cost on every insert/read.
    private static let matchOutcomeDateFormatter = ISO8601DateFormatter()

    /// Create the match-outcome table. Idempotent; called from createTables().
    func createMatchOutcomeTablesImpl() {
        let sql = """
        CREATE TABLE IF NOT EXISTS speaker_match_outcomes (
            id TEXT PRIMARY KEY,
            profile_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            similarity REAL,
            second_similarity REAL,
            call_count_at_match INTEGER,
            channel TEXT,
            transcript_id TEXT,
            recorded_at TEXT NOT NULL,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        );
        """
        executeSQL(sql)
        executeSQL("CREATE INDEX IF NOT EXISTS idx_match_outcomes_profile ON speaker_match_outcomes(profile_id);")
        executeSQL("CREATE INDEX IF NOT EXISTS idx_match_outcomes_transcript ON speaker_match_outcomes(transcript_id);")
        executeSQL("CREATE INDEX IF NOT EXISTS idx_match_outcomes_recorded ON speaker_match_outcomes(recorded_at);")
    }

    /// Append one outcome to the lifeline. Outcomes intentionally survive
    /// profile deletion/merges — they are history, not profile state.
    public func recordMatchOutcome(_ outcome: SpeakerMatchOutcome) {
        queue.sync { recordMatchOutcomeImpl(outcome) }
    }

    /// Append a batch of outcomes in one queue hop and one transaction —
    /// used by the pipeline (all auto-accepts of a meeting) and the naming
    /// coordinator (all verdicts of one review submit).
    public func recordMatchOutcomes(_ outcomes: [SpeakerMatchOutcome]) {
        guard !outcomes.isEmpty else { return }
        queue.sync {
            transaction {
                for outcome in outcomes {
                    recordMatchOutcomeImpl(outcome)
                }
            }
        }
    }

    private func recordMatchOutcomeImpl(_ outcome: SpeakerMatchOutcome) {
        guard isDatabaseOpen else {
            AppLogger.speakers.error("recordMatchOutcome skipped — database not open", [
                "profileId": outcome.profileId.uuidString,
                "kind": outcome.kind.rawValue
            ])
            return
        }

        let sql = """
        INSERT INTO speaker_match_outcomes
            (id, profile_id, kind, similarity, second_similarity, call_count_at_match, channel, transcript_id, recorded_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            AppLogger.speakers.error("Failed to prepare recordMatchOutcome", ["sqlite_error": dbErrorMessage()])
            return
        }
        defer { sqlite3_finalize(statement) }

        let recordedAt = Self.matchOutcomeDateFormatter.string(from: outcome.recordedAt)
        sqlite3_bind_text(statement, 1, (UUID().uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, (outcome.profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, (outcome.kind.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
        if let similarity = outcome.similarity {
            sqlite3_bind_double(statement, 4, similarity)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        if let second = outcome.secondSimilarity {
            sqlite3_bind_double(statement, 5, second)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        if let callCount = outcome.callCountAtMatch {
            sqlite3_bind_int(statement, 6, Int32(callCount))
        } else {
            sqlite3_bind_null(statement, 6)
        }
        if let channel = outcome.channel {
            sqlite3_bind_text(statement, 7, (channel as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, 7)
        }
        if let transcriptId = outcome.transcriptId {
            sqlite3_bind_text(statement, 8, (transcriptId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, 8)
        }
        sqlite3_bind_text(statement, 9, (recordedAt as NSString).utf8String, -1, SQLITE_TRANSIENT)

        if sqlite3_step(statement) != SQLITE_DONE {
            AppLogger.speakers.error("Failed to insert match outcome", [
                "sqlite_error": dbErrorMessage(),
                "profileId": outcome.profileId.uuidString,
                "kind": outcome.kind.rawValue
            ])
        }
    }

    /// Most-recent-first outcomes for one profile. Feeds
    /// `SpeakerProfileHealth.assess` at classification time.
    public func recentMatchOutcomes(profileId: UUID, limit: Int) -> [SpeakerMatchOutcome] {
        queue.sync {
            queryMatchOutcomesImpl(
                whereClause: "profile_id = ?",
                bindText: profileId.uuidString,
                limit: limit
            )
        }
    }

    /// All outcomes recorded for one saved transcript, most recent first.
    /// The app layer uses this after a save to emit bucketed analytics for
    /// silent auto-recognitions without a new Core→app callback seam.
    public func matchOutcomes(transcriptId: UUID) -> [SpeakerMatchOutcome] {
        queue.sync {
            queryMatchOutcomesImpl(
                whereClause: "transcript_id = ?",
                bindText: transcriptId.uuidString,
                limit: nil
            )
        }
    }

    /// How many times this profile has been silently auto-recognized. The app
    /// derives the graduation milestone by comparing this total against the
    /// rows belonging to the just-saved meeting (a single save can record more
    /// than one row for a profile).
    public func autoAcceptedOutcomeCount(profileId: UUID) -> Int {
        queue.sync {
            guard isDatabaseOpen else { return 0 }
            let sql = "SELECT COUNT(*) FROM speaker_match_outcomes WHERE profile_id = ? AND kind = ?;"
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                AppLogger.speakers.error("Failed to prepare autoAcceptedOutcomeCount", ["sqlite_error": dbErrorMessage()])
                return 0
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, (SpeakerMatchOutcomeKind.autoAccepted.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(statement, 0))
        }
    }

    private func queryMatchOutcomesImpl(
        whereClause: String,
        bindText: String,
        limit: Int?
    ) -> [SpeakerMatchOutcome] {
        guard isDatabaseOpen else { return [] }

        var sql = """
        SELECT profile_id, kind, similarity, second_similarity, call_count_at_match, channel, transcript_id, recorded_at
        FROM speaker_match_outcomes
        WHERE \(whereClause)
        ORDER BY recorded_at DESC, rowid DESC
        """
        if limit != nil {
            sql += " LIMIT ?"
        }
        sql += ";"

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            AppLogger.speakers.error("Failed to prepare match outcome query", ["sqlite_error": dbErrorMessage()])
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, (bindText as NSString).utf8String, -1, SQLITE_TRANSIENT)
        if let limit {
            sqlite3_bind_int(statement, 2, Int32(max(0, limit)))
        }

        var outcomes: [SpeakerMatchOutcome] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let profileIdStr = sqlite3_column_text(statement, 0).map(String.init(cString:)) ?? ""
            let kindStr = sqlite3_column_text(statement, 1).map(String.init(cString:)) ?? ""
            guard let profileId = UUID(uuidString: profileIdStr),
                  let kind = SpeakerMatchOutcomeKind(rawValue: kindStr) else {
                AppLogger.speakers.warning("Skipping corrupt match outcome row", ["raw_kind": kindStr])
                continue
            }
            let similarity = sqlite3_column_type(statement, 2) == SQLITE_NULL
                ? nil : sqlite3_column_double(statement, 2)
            let second = sqlite3_column_type(statement, 3) == SQLITE_NULL
                ? nil : sqlite3_column_double(statement, 3)
            let callCount = sqlite3_column_type(statement, 4) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int(statement, 4))
            let channel = sqlite3_column_text(statement, 5).map { String(cString: $0) }
            let transcriptId = sqlite3_column_text(statement, 6)
                .map { String(cString: $0) }
                .flatMap { UUID(uuidString: $0) }
            let recordedAtStr = sqlite3_column_text(statement, 7).map(String.init(cString:)) ?? ""

            outcomes.append(SpeakerMatchOutcome(
                profileId: profileId,
                kind: kind,
                similarity: similarity,
                secondSimilarity: second,
                callCountAtMatch: callCount,
                channel: channel,
                transcriptId: transcriptId,
                recordedAt: Self.matchOutcomeDateFormatter.date(from: recordedAtStr) ?? Date()
            ))
        }
        return outcomes
    }
}
