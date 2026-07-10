// SpeakerNegativeExemplarStore.swift
// Per-profile "explicitly not this person" voice samples inside speakers.sqlite.
//
// When a user corrects a wrongly-suggested speaker, the rejected session embedding is recorded
// here against the profile it was wrongly matched to. `SpeakerNegativeExemplarPolicy` then uses
// these samples to veto that profile for future embeddings that resemble a rejected one — the
// mirror image of the positive fingerprint match. Rows hold only embeddings (no names, transcript
// text, or audio), matching the privacy posture of the speakers and match-outcome tables.

import Foundation
import SQLite3

@available(macOS 14.0, *)
extension SpeakerDatabase {

    /// Newest-N negative exemplars retained per profile. Corrections against a single confusable
    /// profile are bounded so the table cannot grow without limit and per-match scoring stays O(N);
    /// the most recent rejections are the most representative of the confusable voice.
    static let negativeExemplarRetentionPerProfile = 32

    private static let negativeExemplarDateFormatter = ISO8601DateFormatter()

    /// Create the negative-exemplar table. Idempotent; called from createTables().
    func createNegativeExemplarTablesImpl() {
        executeSQL("""
        CREATE TABLE IF NOT EXISTS speaker_negative_exemplars (
            id TEXT PRIMARY KEY,
            profile_id TEXT NOT NULL,
            embedding BLOB NOT NULL,
            created_at TEXT NOT NULL
        );
        """)
        executeSQL("CREATE INDEX IF NOT EXISTS idx_negative_exemplars_profile ON speaker_negative_exemplars(profile_id);")
    }

    /// Record one rejected embedding as a negative exemplar against the wrongly-matched profile.
    /// The embedding is L2-normalized to match how positive fingerprints are stored, so cosine
    /// comparisons at match time are consistent. No-ops on an empty embedding.
    public func recordNegativeExemplar(profileId: UUID, embedding: [Float]) {
        guard !embedding.isEmpty else { return }
        queue.sync { recordNegativeExemplarImpl(profileId: profileId, embedding: embedding) }
    }

    private func recordNegativeExemplarImpl(profileId: UUID, embedding: [Float]) {
        guard isDatabaseOpen else {
            AppLogger.speakers.error("recordNegativeExemplar skipped — database not open", [
                "profileId": profileId.uuidString
            ])
            return
        }

        let normalized = SpeakerVectorMath.l2Normalize(embedding)
        let now = Self.negativeExemplarDateFormatter.string(from: Date())

        let sql = """
        INSERT INTO speaker_negative_exemplars (id, profile_id, embedding, created_at)
        VALUES (?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            AppLogger.speakers.error("Failed to prepare recordNegativeExemplar", ["sqlite_error": dbErrorMessage()])
            return
        }
        let embeddingData = normalized.withUnsafeBufferPointer { Data(buffer: $0) }
        sqlite3_bind_text(statement, 1, (UUID().uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_blob(statement, 3, (embeddingData as NSData).bytes, Int32(embeddingData.count), SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 4, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
        if sqlite3_step(statement) != SQLITE_DONE {
            AppLogger.speakers.error("Failed to insert negative exemplar", [
                "sqlite_error": dbErrorMessage(),
                "profileId": profileId.uuidString
            ])
        }
        sqlite3_finalize(statement)

        pruneNegativeExemplarsImpl(profileId: profileId)
    }

    /// Keep only the newest `negativeExemplarRetentionPerProfile` rows for a profile.
    private func pruneNegativeExemplarsImpl(profileId: UUID) {
        let sql = """
        DELETE FROM speaker_negative_exemplars
        WHERE profile_id = ?
          AND rowid NOT IN (
              SELECT rowid FROM speaker_negative_exemplars
              WHERE profile_id = ?
              ORDER BY created_at DESC, rowid DESC
              LIMIT ?
          );
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            AppLogger.speakers.error("Failed to prepare pruneNegativeExemplars", ["sqlite_error": dbErrorMessage()])
            return
        }
        sqlite3_bind_text(statement, 1, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 3, Int32(Self.negativeExemplarRetentionPerProfile))
        if sqlite3_step(statement) != SQLITE_DONE {
            AppLogger.speakers.error("Failed to prune negative exemplars", ["sqlite_error": dbErrorMessage()])
        }
        sqlite3_finalize(statement)
    }

    /// Negative-exemplar embeddings for one profile, newest first.
    public func negativeExemplars(profileId: UUID) -> [[Float]] {
        queue.sync { negativeExemplarsImpl(profileId: profileId) }
    }

    func negativeExemplarsImpl(profileId: UUID) -> [[Float]] {
        guard isDatabaseOpen else { return [] }
        let sql = """
        SELECT embedding FROM speaker_negative_exemplars
        WHERE profile_id = ?
        ORDER BY created_at DESC, rowid DESC;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            AppLogger.speakers.error("Failed to prepare negativeExemplars query", ["sqlite_error": dbErrorMessage()])
            return []
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)

        var exemplars: [[Float]] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let embedding = Self.readEmbeddingBlob(statement, column: 0) {
                exemplars.append(embedding)
            }
        }
        return exemplars
    }

    /// All negative exemplars, grouped by profile id. Fetched once per recording so the matching
    /// loop can veto without a per-profile query. Empty when the feature has recorded nothing, which
    /// keeps matching byte-for-byte identical to the pre-feature behavior.
    public func negativeExemplarsByProfile() -> [UUID: [[Float]]] {
        queue.sync { allNegativeExemplarsImpl() }
    }

    func allNegativeExemplarsImpl() -> [UUID: [[Float]]] {
        guard isDatabaseOpen else { return [:] }
        let sql = """
        SELECT profile_id, embedding FROM speaker_negative_exemplars
        ORDER BY created_at DESC, rowid DESC;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            AppLogger.speakers.error("Failed to prepare allNegativeExemplars query", ["sqlite_error": dbErrorMessage()])
            return [:]
        }
        defer { sqlite3_finalize(statement) }

        var byProfile: [UUID: [[Float]]] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let profileIdStr = sqlite3_column_text(statement, 0).map(String.init(cString:)),
                  let profileId = UUID(uuidString: profileIdStr),
                  let embedding = Self.readEmbeddingBlob(statement, column: 1) else {
                continue
            }
            byProfile[profileId, default: []].append(embedding)
        }
        return byProfile
    }

    /// Drop all negative-exemplar rows for a profile that is being deleted or absorbed.
    /// Must be called on `queue`.
    func deleteNegativeExemplarsImpl(profileId: UUID) {
        guard isDatabaseOpen else { return }
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(
            db,
            "DELETE FROM speaker_negative_exemplars WHERE profile_id = ?;",
            -1,
            &statement,
            nil
        ) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) != SQLITE_DONE {
                AppLogger.speakers.error("Failed to delete negative exemplars", [
                    "sqlite_error": dbErrorMessage(),
                    "profileId": profileId.uuidString
                ])
            }
        } else {
            AppLogger.speakers.error("Failed to prepare delete negative exemplars", [
                "sqlite_error": dbErrorMessage(),
                "profileId": profileId.uuidString
            ])
        }
        sqlite3_finalize(statement)
    }

    private static func readEmbeddingBlob(_ statement: OpaquePointer?, column: Int32) -> [Float]? {
        guard let statement, let blobPtr = sqlite3_column_blob(statement, column) else { return nil }
        let blobSize = sqlite3_column_bytes(statement, column)
        guard blobSize > 0 else { return nil }
        let floatCount = Int(blobSize) / MemoryLayout<Float>.size
        return Array(UnsafeBufferPointer(
            start: blobPtr.assumingMemoryBound(to: Float.self),
            count: floatCount
        ))
    }
}
