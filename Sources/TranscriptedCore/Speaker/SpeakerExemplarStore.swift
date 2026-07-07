// SpeakerExemplarStore.swift
// Persistence for multi-exemplar voiceprints (see SpeakerExemplarPolicy).
//
// The `speakers` table keeps ONE blended-average embedding per person. This table stores a small,
// bounded set of additional representative embeddings ("exemplars") per person — the K most
// distinct-yet-confirmed session means — so the matcher can score a returning voice against its
// best-fitting capture condition (clean in-person vs compressed remote) instead of a single average
// that fits neither.
//
// Additive and backward-compatible: profiles built before this shipped simply have no exemplar rows,
// so `SpeakerProfile.exemplars` loads empty and matching falls back to the single average exactly.
// Exemplars are a rebuildable cache of gated centroids, never the source of truth for identity, so
// any structural edit that re-derives the average (merge / un-merge / reassign) safely clears them
// and lets them re-accumulate.

import Foundation
import SQLite3

@available(macOS 14.0, *)
extension SpeakerDatabase {

    // MARK: - Schema

    /// Create the exemplar table. Idempotent; called from createTables().
    func createExemplarTablesImpl() {
        let sql = """
        CREATE TABLE IF NOT EXISTS speaker_exemplars (
            id TEXT PRIMARY KEY,
            profile_id TEXT NOT NULL,
            embedding BLOB NOT NULL,
            segment_count INTEGER NOT NULL DEFAULT 1,
            updated_at TEXT NOT NULL,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        );
        """
        executeSQL(sql)
        executeSQL("CREATE INDEX IF NOT EXISTS idx_exemplars_profile ON speaker_exemplars(profile_id);")
    }

    // MARK: - Reads (called on the serialized queue)

    /// A single profile's exemplar embeddings, ordered oldest-first for determinism.
    func exemplarEmbeddingsImpl(forProfileId profileId: UUID) -> [[Float]] {
        exemplarsImpl(forProfileId: profileId).map { $0.embedding }
    }

    /// Batch-load every profile's exemplar embeddings in one query — used by `allSpeakers` so the
    /// hot pipeline snapshot doesn't issue one query per profile.
    func exemplarsByProfileImpl() -> [UUID: [[Float]]] {
        guard isDatabaseOpen else { return [:] }
        var result: [UUID: [[Float]]] = [:]
        let sql = "SELECT profile_id, embedding FROM speaker_exemplars ORDER BY profile_id, rowid;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idStr = sqlite3_column_text(statement, 0).map(String.init(cString:)),
                      let profileId = UUID(uuidString: idStr) else { continue }
                if let vector = readEmbeddingColumn(statement, index: 1) {
                    result[profileId, default: []].append(vector)
                }
            }
        } else {
            AppLogger.speakers.error("Failed to prepare exemplarsByProfile query", ["sqlite_error": dbErrorMessage()])
        }
        sqlite3_finalize(statement)
        return result
    }

    /// Full exemplars (with segment counts) for the write-path policy. Ordered oldest-first.
    private func exemplarsImpl(forProfileId profileId: UUID) -> [SpeakerExemplarPolicy.Exemplar] {
        guard isDatabaseOpen else { return [] }
        var rows: [SpeakerExemplarPolicy.Exemplar] = []
        let sql = "SELECT embedding, segment_count FROM speaker_exemplars WHERE profile_id = ? ORDER BY rowid;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let vector = readEmbeddingColumn(statement, index: 0) else { continue }
                let count = Int(sqlite3_column_int(statement, 1))
                rows.append(SpeakerExemplarPolicy.Exemplar(embedding: vector, segmentCount: max(1, count)))
            }
        }
        sqlite3_finalize(statement)
        return rows
    }

    private func readEmbeddingColumn(_ statement: OpaquePointer?, index: Int32) -> [Float]? {
        guard let statement, let blobPtr = sqlite3_column_blob(statement, index) else { return nil }
        let blobSize = sqlite3_column_bytes(statement, index)
        guard blobSize > 0 else { return nil }
        let floatCount = Int(blobSize) / MemoryLayout<Float>.size
        return Array(UnsafeBufferPointer(start: blobPtr.assumingMemoryBound(to: Float.self), count: floatCount))
    }

    // MARK: - Writes (called on the serialized queue)

    /// Fold a new confirmed session mean into the profile's exemplar set per `SpeakerExemplarPolicy`,
    /// persist the result, and return the resulting exemplar embeddings for the caller's in-memory
    /// profile. Best-effort: a failure here never fails the parent speaker write. Must be called on
    /// `queue`.
    ///
    /// `average` is the profile's post-blend `embedding` (an implicit always-present representative,
    /// so a mean already covered by the average is dropped rather than duplicated). The caller gates
    /// this on a positive write-back alpha, so ambiguous/frozen matches never touch exemplars.
    @discardableResult
    func updateExemplarsImpl(profileId: UUID, newMean: [Float], average: [Float]) -> [[Float]] {
        guard isDatabaseOpen, !newMean.isEmpty else {
            return exemplarEmbeddingsImpl(forProfileId: profileId)
        }
        let current = exemplarsImpl(forProfileId: profileId)
        let updated = SpeakerExemplarPolicy.updated(current: current, newMean: newMean, average: average)
        if updated == current { return current.map { $0.embedding } }

        persistExemplarsImpl(profileId: profileId, exemplars: updated)
        return updated.map { $0.embedding }
    }

    /// Replace all of a profile's exemplar rows with `exemplars`. Simple delete-then-insert keeps the
    /// stored set an exact image of the policy output without diff bookkeeping.
    private func persistExemplarsImpl(profileId: UUID, exemplars: [SpeakerExemplarPolicy.Exemplar]) {
        deleteExemplarsImpl(profileId: profileId)
        guard !exemplars.isEmpty else { return }
        let now = ISO8601DateFormatter().string(from: Date())
        let sql = """
        INSERT INTO speaker_exemplars (id, profile_id, embedding, segment_count, updated_at)
        VALUES (?, ?, ?, ?, ?);
        """
        for exemplar in exemplars {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                let embeddingData = exemplar.embedding.withUnsafeBufferPointer { Data(buffer: $0) }
                sqlite3_bind_text(statement, 1, (UUID().uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 2, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_blob(statement, 3, (embeddingData as NSData).bytes, Int32(embeddingData.count), SQLITE_TRANSIENT)
                sqlite3_bind_int(statement, 4, Int32(exemplar.segmentCount))
                sqlite3_bind_text(statement, 5, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
                if sqlite3_step(statement) != SQLITE_DONE {
                    AppLogger.speakers.error("Failed to insert exemplar", ["sqlite_error": dbErrorMessage(), "profileId": profileId.uuidString])
                }
            } else {
                AppLogger.speakers.error("Failed to prepare exemplar insert", ["sqlite_error": dbErrorMessage()])
            }
            sqlite3_finalize(statement)
        }
    }

    /// Drop all exemplar rows for a profile. Called when a profile is deleted or its average is
    /// structurally re-derived (merge / un-merge / reassign), so exemplars never outlive the identity
    /// they represented. Must be called on `queue`.
    func deleteExemplarsImpl(profileId: UUID) {
        guard isDatabaseOpen else { return }
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM speaker_exemplars WHERE profile_id = ?;", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) != SQLITE_DONE {
                AppLogger.speakers.error("Failed to delete exemplars", ["sqlite_error": dbErrorMessage(), "profileId": profileId.uuidString])
            }
        }
        sqlite3_finalize(statement)
    }
}
