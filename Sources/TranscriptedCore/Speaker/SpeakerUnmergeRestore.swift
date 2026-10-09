// SpeakerUnmergeRestore.swift
// How un-merge rebuilds a profile's voiceprint after restoring its snapshot.
//
// The merge event's snapshots are the exact pre-merge state, so they stay the
// base. Re-deriving from contribution rows would be wrong for a profile that
// predates provenance (June 2026): its rows cover only part of its history,
// and their mean would overwrite the real voiceprint and call count. The keeper
// may have learned from recordings after the merge, so those rows, and only
// those, are folded on top, weighted by the snapshot's call count.
//
// A contribution can also change owner after the merge without getting a new
// rowid (reassignContribution updates profile_id in place), so rowid alone misses
// it. Moves are logged in speaker_contribution_reassignments; un-merge compares a
// pre-merge row's owner at merge time with its owner now and adds it to, or takes
// it out of, the restored snapshot. Moves made before that log existed are not
// recorded and keep the old snapshot-only behavior.

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
    func foldPostMergeContributionsOrThrowImpl(
        into snapshot: ProfileSnapshot,
        afterRowid markerRowid: Int64,
        adding extraRows: [[Float]] = [],
        removing removedRows: [[Float]] = []
    ) throws {
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
        // Pre-merge rows moved onto this profile after the merge.
        for vector in extraRows where vector.count == dim {
            for i in 0..<dim { sum[i] += vector[i] }
            added += 1
        }
        // Pre-merge rows the snapshot still counts but the user moved away.
        var removed = 0
        for vector in removedRows where vector.count == dim {
            for i in 0..<dim { sum[i] -= vector[i] }
            removed += 1
        }
        guard added > 0 || removed > 0 else { return }

        var norm: Float = 0
        for value in sum { norm += value * value }
        norm = norm.squareRoot()
        // Nothing left to average (every recording moved away): keep the snapshot's voice.
        let normalized: [Float] = norm > 1e-6 ? sum.map { $0 / norm } : snapshot.embedding
        let newCallCount = max(0, max(0, snapshot.callCount) + added - removed)

        let now = ISO8601DateFormatter().string(from: Date())
        let update = try prepareStatement(
            "UPDATE speakers SET embedding = ?, call_count = ?, last_seen = ? WHERE id = ?;",
            operation: "prepare post-merge contribution fold"
        )
        defer { sqlite3_finalize(update) }
        let embeddingData = normalized.withUnsafeBufferPointer { Data(buffer: $0) }
        sqlite3_bind_blob(update, 1, (embeddingData as NSData).bytes, Int32(embeddingData.count), SQLITE_TRANSIENT)
        sqlite3_bind_int(update, 2, Int32(newCallCount))
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

    struct PostMergeReassignment {
        let contributionId: UUID
        let firstFromProfileId: UUID
    }

    /// Contributions moved by hand at or after `markerRowid` (that is, after the
    /// merge), each with the owner it had before its first such move.
    func postMergeReassignmentsImpl(atOrAfterRowid markerRowid: Int64) throws -> [PostMergeReassignment] {
        let statement = try prepareStatement(
            """
            SELECT contribution_id, from_profile_id FROM speaker_contribution_reassignments
            WHERE provenance_high_rowid >= ? ORDER BY seq ASC;
            """,
            operation: "prepare post-merge reassignment lookup"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, markerRowid)
        var seen = Set<UUID>()
        var result: [PostMergeReassignment] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else {
                throw SQLiteOperationError(operation: "step post-merge reassignment lookup", code: step, detail: dbErrorMessage())
            }
            guard let contribution = sqlite3_column_text(statement, 0).map(String.init(cString:)).flatMap(UUID.init(uuidString:)),
                  let from = sqlite3_column_text(statement, 1).map(String.init(cString:)).flatMap(UUID.init(uuidString:)),
                  seen.insert(contribution).inserted else { continue }
            result.append(PostMergeReassignment(contributionId: contribution, firstFromProfileId: from))
        }
    }

    /// For pre-merge rows (rowid below the marker) moved after the merge, the
    /// embeddings to add to and take out of each restored snapshot. Call after the
    /// absorbed profile's rows are moved back, so "now" is the post-un-merge owner.
    func ownershipChangesImpl(
        _ reassigned: [PostMergeReassignment],
        movedIds: Set<UUID>,
        sourceId: UUID,
        targetId: UUID,
        beforeRowid markerRowid: Int64
    ) throws -> (added: [UUID: [[Float]]], removed: [UUID: [[Float]]]) {
        var added: [UUID: [[Float]]] = [:]
        var removed: [UUID: [[Float]]] = [:]
        guard !reassigned.isEmpty else { return (added, removed) }
        let statement = try prepareStatement(
            """
            SELECT profile_id, embedding FROM speaker_provenance
            WHERE id = ? AND rowid < ? AND embedding IS NOT NULL AND kind != ?;
            """,
            operation: "prepare reassigned contribution lookup"
        )
        defer { sqlite3_finalize(statement) }
        let restored: Set<UUID> = [sourceId, targetId]
        for move in reassigned {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, (move.contributionId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(statement, 2, markerRowid)
            sqlite3_bind_text(statement, 3, (SpeakerProvenanceKind.merge as NSString).utf8String, -1, SQLITE_TRANSIENT)
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { continue }  // post-merge row or no embedding: rowid fold covers it
            guard step == SQLITE_ROW else {
                throw SQLiteOperationError(operation: "step reassigned contribution lookup", code: step, detail: dbErrorMessage())
            }
            guard let now = sqlite3_column_text(statement, 0).map(String.init(cString:)).flatMap(UUID.init(uuidString:)),
                  let ptr = sqlite3_column_blob(statement, 1) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 1)) / MemoryLayout<Float>.size
            let vector = Array(UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: Float.self), count: count))
            // The absorbed profile's rows were re-pointed at the keeper by the merge
            // itself; their owner in the source snapshot is the absorbed profile.
            let before = movedIds.contains(move.contributionId) ? sourceId : move.firstFromProfileId
            guard before != now else { continue }
            if restored.contains(before) { removed[before, default: []].append(vector) }
            if restored.contains(now) { added[now, default: []].append(vector) }
        }
        return (added, removed)
    }
}
