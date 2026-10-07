// SpeakerUnmergeRestore.swift
// How un-merge rebuilds a profile's voiceprint after restoring its snapshot.
//
// The merge event's snapshots are the exact pre-merge state, so they stay the
// base. Re-deriving from contribution rows would be wrong for a profile that
// predates provenance (June 2026): its rows cover only part of its history,
// and their mean would overwrite the real voiceprint and call count. The keeper
// may have learned from recordings after the merge, so those rows, and only
// those, are folded on top, weighted by the snapshot's call count.

import Foundation
import SQLite3

@available(macOS 14.0, *)
extension SpeakerDatabase {
    /// rowid of the merge's fuse marker. Provenance rows only ever get appended, so a
    /// row with a larger rowid was recorded after the merge.
    func mergeMarkerRowidImpl(mergeEventId: UUID) throws -> Int64 {
        let statement = try prepareStatement(
            "SELECT rowid FROM speaker_provenance WHERE merge_event_id = ? AND kind = ?;",
            operation: "prepare merge marker lookup"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (mergeEventId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, (SpeakerProvenanceKind.merge as NSString).utf8String, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteOperationError(operation: "find merge marker", code: sqlite3_errcode(db), detail: dbErrorMessage())
        }
        return sqlite3_column_int64(statement, 0)
    }

    /// Un-merge: keep the restored snapshot as the profile's base and add only the
    /// contributions recorded after the merge (rowid above the marker), weighted
    /// against the snapshot's call count. No post-merge rows leaves the snapshot exact.
    func foldPostMergeContributionsOrThrowImpl(into snapshot: ProfileSnapshot, afterRowid markerRowid: Int64) throws {
        let dim = snapshot.embedding.count
        guard dim > 0 else { return }
        let statement = try prepareStatement(
            """
            SELECT embedding FROM speaker_provenance
            WHERE profile_id = ? AND embedding IS NOT NULL AND kind != ? AND rowid > ?;
            """,
            operation: "prepare post-merge contribution lookup"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (snapshot.id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, (SpeakerProvenanceKind.merge as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 3, markerRowid)

        let base = Float(max(0, snapshot.callCount))
        var sum = snapshot.embedding.map { $0 * base }
        var added = 0
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let ptr = sqlite3_column_blob(statement, 0) else { continue }
            let floatCount = Int(sqlite3_column_bytes(statement, 0)) / MemoryLayout<Float>.size
            // A row from another embedding model can't be averaged with this voiceprint.
            guard floatCount == dim else { continue }
            let vector = UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: Float.self), count: floatCount)
            for i in 0..<dim { sum[i] += vector[i] }
            added += 1
        }
        guard added > 0 else { return }

        var norm: Float = 0
        for value in sum { norm += value * value }
        norm = norm.squareRoot()
        let normalized: [Float] = norm > 0 ? sum.map { $0 / norm } : sum

        let now = ISO8601DateFormatter().string(from: Date())
        let update = try prepareStatement(
            "UPDATE speakers SET embedding = ?, call_count = ?, last_seen = ? WHERE id = ?;",
            operation: "prepare post-merge contribution fold"
        )
        defer { sqlite3_finalize(update) }
        let embeddingData = normalized.withUnsafeBufferPointer { Data(buffer: $0) }
        sqlite3_bind_blob(update, 1, (embeddingData as NSData).bytes, Int32(embeddingData.count), SQLITE_TRANSIENT)
        sqlite3_bind_int(update, 2, Int32(max(0, snapshot.callCount) + added))
        sqlite3_bind_text(update, 3, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(update, 4, (snapshot.id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        try requireDone(update, operation: "step post-merge contribution fold", expectedChanges: 1)

        // Exemplars learned after the merge were built against the fused voice.
        let deleteExemplars = try prepareStatement(
            "DELETE FROM speaker_exemplars WHERE profile_id = ?;",
            operation: "prepare delete un-merged profile exemplars"
        )
        defer { sqlite3_finalize(deleteExemplars) }
        sqlite3_bind_text(deleteExemplars, 1, (snapshot.id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        try requireDone(deleteExemplars, operation: "step delete un-merged profile exemplars")
    }
}
