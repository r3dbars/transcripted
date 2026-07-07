// SpeakerProfileProvenance.swift
// Provenance + reversible-merge safety net for the speaker database.
//
// A wrong speaker merge used to be permanently lossy: mergeProfilesImpl L2-blends
// the source embedding into the target and DELETEs the source row, so the original
// embeddings were unrecoverable and there was no record of which clips built a
// profile or what a merge fused.
//
// This file adds two audit tables and the un-merge / reassignment paths on top of
// them, entirely on the concrete `SpeakerDatabase` so the `SpeakerStore` protocol
// (the matching/merge surface other work edits) stays untouched:
//
//   speaker_provenance   — one row per contribution that built a profile (the mean
//                          embedding a recording added) plus a marker row per fuse.
//   speaker_merge_events — full pre-merge snapshots of BOTH source and target for
//                          every merge, so an un-merge reconstructs two distinct
//                          profiles exactly from the retained embeddings rather than
//                          trying to arithmetically invert the (non-invertible) blend.
//
// Un-merge is restricted to the most-recent non-undone merge for a target (LIFO):
// restoring a target to an older snapshot would silently drop merges layered on top
// of it, so we refuse instead of corrupting identity a second time.

import Foundation
import SQLite3

/// User-facing record of a merge that can be undone.
public struct SpeakerMergeRecord: Identifiable, Sendable {
    public let id: UUID
    public let sourceId: UUID
    public let targetId: UUID
    public let sourceName: String?
    public let targetName: String?
    public let kind: String          // SpeakerMergeKind.rawValue
    public let mergedAt: Date
    public let isUndone: Bool

    public init(
        id: UUID,
        sourceId: UUID,
        targetId: UUID,
        sourceName: String?,
        targetName: String?,
        kind: String,
        mergedAt: Date,
        isUndone: Bool
    ) {
        self.id = id
        self.sourceId = sourceId
        self.targetId = targetId
        self.sourceName = sourceName
        self.targetName = targetName
        self.kind = kind
        self.mergedAt = mergedAt
        self.isUndone = isUndone
    }
}

/// Audit record of a single contribution (clip/recording mean embedding, or a merge
/// fusion marker) that built a profile.
public struct SpeakerContribution: Identifiable, Sendable {
    public let id: UUID
    public let profileId: UUID
    public let kind: String          // SpeakerProvenanceKind.rawValue
    public let sourceProfileId: UUID? // set for `merge` fusion markers
    public let recordedAt: Date
    public let hasEmbedding: Bool

    public init(
        id: UUID,
        profileId: UUID,
        kind: String,
        sourceProfileId: UUID?,
        recordedAt: Date,
        hasEmbedding: Bool
    ) {
        self.id = id
        self.profileId = profileId
        self.kind = kind
        self.sourceProfileId = sourceProfileId
        self.recordedAt = recordedAt
        self.hasEmbedding = hasEmbedding
    }
}

/// Where a provenance row came from.
public enum SpeakerProvenanceKind {
    public static let seed = "seed"                 // first embedding that created the profile
    public static let contribution = "contribution" // a later recording's mean embedding
    public static let merge = "merge"               // marker: an absorbed profile fused in here
}

/// What kind of merge produced a merge event.
public enum SpeakerMergeKind {
    public static let explicit = "explicit"   // user/coordinator merged two profiles
    public static let duplicate = "duplicate" // auto duplicate-merge after a recording
    public static let byName = "by_name"      // same-display-name fuse
}

@available(macOS 14.0, *)
extension SpeakerDatabase {

    // MARK: - Schema

    /// Create the provenance + merge-event tables. Idempotent; called from createTables().
    func createProvenanceTablesImpl() {
        let provenance = """
        CREATE TABLE IF NOT EXISTS speaker_provenance (
            id TEXT PRIMARY KEY,
            profile_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            embedding BLOB,
            source_profile_id TEXT,
            merge_event_id TEXT,
            recorded_at TEXT NOT NULL,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        );
        """
        executeSQL(provenance)
        executeSQL("CREATE INDEX IF NOT EXISTS idx_provenance_profile ON speaker_provenance(profile_id);")
        executeSQL("CREATE INDEX IF NOT EXISTS idx_provenance_event ON speaker_provenance(merge_event_id);")

        let mergeEvents = """
        CREATE TABLE IF NOT EXISTS speaker_merge_events (
            id TEXT PRIMARY KEY,
            target_id TEXT NOT NULL,
            source_id TEXT NOT NULL,
            kind TEXT NOT NULL,
            source_snapshot TEXT NOT NULL,
            target_snapshot TEXT NOT NULL,
            moved_provenance_ids TEXT,
            merged_at TEXT NOT NULL,
            undone_at TEXT,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        );
        """
        executeSQL(mergeEvents)
        executeSQL("CREATE INDEX IF NOT EXISTS idx_merge_target ON speaker_merge_events(target_id);")
    }

    // MARK: - Recording (called on the serialized queue)

    /// Record one contribution embedding that built a profile. Best-effort audit —
    /// never blocks or fails the speaker write. Must be called on `queue`.
    func recordContributionImpl(profileId: UUID, embedding: [Float], kind: String) {
        guard isDatabaseOpen, !embedding.isEmpty else { return }
        let sql = """
        INSERT INTO speaker_provenance (id, profile_id, kind, embedding, source_profile_id, merge_event_id, recorded_at)
        VALUES (?, ?, ?, ?, NULL, NULL, ?);
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            let embeddingData = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
            let now = ISO8601DateFormatter().string(from: Date())
            sqlite3_bind_text(statement, 1, (UUID().uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, (kind as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_blob(statement, 4, (embeddingData as NSData).bytes, Int32(embeddingData.count), SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 5, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) != SQLITE_DONE {
                AppLogger.speakers.error("Failed to record speaker provenance", ["sqlite_error": dbErrorMessage(), "profileId": profileId.uuidString])
            }
        } else {
            AppLogger.speakers.error("Failed to prepare provenance insert", ["sqlite_error": dbErrorMessage()])
        }
        sqlite3_finalize(statement)
    }

    /// Snapshot both profiles, re-point the source's provenance onto the target, and
    /// drop a merge marker — all on the open connection so the caller can run it inside
    /// the same transaction as the embedding blend + source delete. Must be called on
    /// `queue`, inside a transaction. Returns the new merge-event id (nil on failure).
    @discardableResult
    func recordMergeEventImpl(source: SpeakerProfile, target: SpeakerProfile, kind: String) -> UUID? {
        guard isDatabaseOpen else { return nil }
        guard let sourceSnapshot = Self.encodeProfileSnapshot(source),
              let targetSnapshot = Self.encodeProfileSnapshot(target) else {
            AppLogger.speakers.error("Failed to encode merge snapshot — skipping provenance", ["sourceId": source.id.uuidString])
            return nil
        }

        let eventId = UUID()
        let movedIds = provenanceIdsImpl(forProfileId: source.id)
        let movedIdsJSON = (try? JSONEncoder().encode(movedIds.map { $0.uuidString }))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let now = ISO8601DateFormatter().string(from: Date())

        let insertEvent = """
        INSERT INTO speaker_merge_events
            (id, target_id, source_id, kind, source_snapshot, target_snapshot, moved_provenance_ids, merged_at, undone_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL);
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, insertEvent, -1, &statement, nil) == SQLITE_OK else {
            AppLogger.speakers.error("Failed to prepare merge-event insert", ["sqlite_error": dbErrorMessage()])
            sqlite3_finalize(statement)
            return nil
        }
        sqlite3_bind_text(statement, 1, (eventId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, (target.id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, (source.id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 4, (kind as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 5, (sourceSnapshot as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 6, (targetSnapshot as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 7, (movedIdsJSON as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 8, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
        if sqlite3_step(statement) != SQLITE_DONE {
            AppLogger.speakers.error("Failed to insert merge event", ["sqlite_error": dbErrorMessage()])
            sqlite3_finalize(statement)
            return nil
        }
        sqlite3_finalize(statement)

        // Re-point the absorbed profile's provenance onto the keeper.
        execBind(
            "UPDATE speaker_provenance SET profile_id = ? WHERE profile_id = ?;",
            [target.id.uuidString, source.id.uuidString],
            label: "re-point provenance"
        )

        // Marker row so the keeper's history shows what fused in.
        let marker = """
        INSERT INTO speaker_provenance (id, profile_id, kind, embedding, source_profile_id, merge_event_id, recorded_at)
        VALUES (?, ?, ?, NULL, ?, ?, ?);
        """
        var markerStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, marker, -1, &markerStmt, nil) == SQLITE_OK {
            sqlite3_bind_text(markerStmt, 1, (UUID().uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(markerStmt, 2, (target.id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(markerStmt, 3, (SpeakerProvenanceKind.merge as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(markerStmt, 4, (source.id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(markerStmt, 5, (eventId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(markerStmt, 6, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(markerStmt) != SQLITE_DONE {
                AppLogger.speakers.error("Failed to insert merge marker", ["sqlite_error": dbErrorMessage()])
            }
        }
        sqlite3_finalize(markerStmt)

        return eventId
    }

    // MARK: - Public queries

    /// Recent merges that can still be undone, newest first.
    public func recentUndoableMerges(limit: Int = 25) -> [SpeakerMergeRecord] {
        queue.sync { recentUndoableMergesImpl(limit: limit) }
    }

    /// The most recent still-undoable merge whose keeper is `targetId`, if any.
    /// Targeted indexed lookup — not capped by any recent-list limit.
    public func undoableMerge(forTargetId targetId: UUID) -> SpeakerMergeRecord? {
        queue.sync { undoableMergeImpl(forTargetId: targetId) }
    }

    /// Audit trail of contributions that built a profile, newest first.
    public func contributions(forProfileId profileId: UUID) -> [SpeakerContribution] {
        queue.sync { contributionsImpl(forProfileId: profileId) }
    }

    /// Undo the most recent still-undoable merge whose keeper is `targetId`.
    /// Returns true if a merge was reversed.
    @discardableResult
    public func unmergeMostRecent(forTargetId targetId: UUID) -> Bool {
        queue.sync {
            guard let record = undoableMergeImpl(forTargetId: targetId) else { return false }
            return unmergeImpl(mergeId: record.id)
        }
    }

    /// Undo a specific merge by event id. Refuses (returns false) if a newer non-undone
    /// merge targets the same keeper, since restoring the older snapshot would drop it.
    @discardableResult
    public func unmerge(mergeId: UUID) -> Bool {
        queue.sync { unmergeImpl(mergeId: mergeId) }
    }

    /// Move a single contribution to another profile and re-derive both profiles'
    /// embeddings from their remaining contribution embeddings (mean → L2 normalize).
    /// Embedding/call-count re-derivation is best-effort: it only applies to profiles
    /// that have stored contribution embeddings (i.e. built after provenance shipped).
    @discardableResult
    public func reassignContribution(id contributionId: UUID, toProfileId: UUID) -> Bool {
        queue.sync { reassignContributionImpl(id: contributionId, toProfileId: toProfileId) }
    }

    // MARK: - Impl

    private func recentUndoableMergesImpl(limit: Int) -> [SpeakerMergeRecord] {
        guard isDatabaseOpen else { return [] }
        var records: [SpeakerMergeRecord] = []
        // Order by rowid (monotonic insertion order) — merged_at only has second
        // precision, so two merges in the same second would order non-deterministically.
        let sql = """
        SELECT id, target_id, source_id, kind, source_snapshot, target_snapshot, merged_at
        FROM speaker_merge_events
        WHERE undone_at IS NULL
        ORDER BY rowid DESC
        LIMIT ?;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(max(0, limit)))
            let isoFormatter = ISO8601DateFormatter()
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idStr = sqlite3_column_text(statement, 0).map(String.init(cString:)),
                      let id = UUID(uuidString: idStr),
                      let targetStr = sqlite3_column_text(statement, 1).map(String.init(cString:)),
                      let targetId = UUID(uuidString: targetStr),
                      let sourceStr = sqlite3_column_text(statement, 2).map(String.init(cString:)),
                      let sourceId = UUID(uuidString: sourceStr) else { continue }
                let kind = sqlite3_column_text(statement, 3).map(String.init(cString:)) ?? SpeakerMergeKind.explicit
                let sourceSnapshot = sqlite3_column_text(statement, 4).map(String.init(cString:))
                let targetSnapshot = sqlite3_column_text(statement, 5).map(String.init(cString:))
                let mergedAtStr = sqlite3_column_text(statement, 6).map(String.init(cString:)) ?? ""
                records.append(SpeakerMergeRecord(
                    id: id,
                    sourceId: sourceId,
                    targetId: targetId,
                    sourceName: sourceSnapshot.flatMap { Self.decodeProfileSnapshot($0)?.displayName },
                    targetName: targetSnapshot.flatMap { Self.decodeProfileSnapshot($0)?.displayName },
                    kind: kind,
                    mergedAt: isoFormatter.date(from: mergedAtStr) ?? Date.distantPast,
                    isUndone: false
                ))
            }
        } else {
            AppLogger.speakers.error("Failed to prepare recentUndoableMerges", ["sqlite_error": dbErrorMessage()])
        }
        sqlite3_finalize(statement)
        return records
    }

    private func undoableMergeImpl(forTargetId targetId: UUID) -> SpeakerMergeRecord? {
        guard isDatabaseOpen else { return nil }
        let sql = """
        SELECT id, source_id, kind, source_snapshot, target_snapshot, merged_at
        FROM speaker_merge_events
        WHERE target_id = ? AND undone_at IS NULL
        ORDER BY rowid DESC
        LIMIT 1;
        """
        var statement: OpaquePointer?
        var record: SpeakerMergeRecord?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (targetId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) == SQLITE_ROW,
               let idStr = sqlite3_column_text(statement, 0).map(String.init(cString:)),
               let id = UUID(uuidString: idStr),
               let sourceStr = sqlite3_column_text(statement, 1).map(String.init(cString:)),
               let sourceId = UUID(uuidString: sourceStr) {
                let kind = sqlite3_column_text(statement, 2).map(String.init(cString:)) ?? SpeakerMergeKind.explicit
                let sourceSnapshot = sqlite3_column_text(statement, 3).map(String.init(cString:))
                let targetSnapshot = sqlite3_column_text(statement, 4).map(String.init(cString:))
                let mergedAtStr = sqlite3_column_text(statement, 5).map(String.init(cString:)) ?? ""
                record = SpeakerMergeRecord(
                    id: id,
                    sourceId: sourceId,
                    targetId: targetId,
                    sourceName: sourceSnapshot.flatMap { Self.decodeProfileSnapshot($0)?.displayName },
                    targetName: targetSnapshot.flatMap { Self.decodeProfileSnapshot($0)?.displayName },
                    kind: kind,
                    mergedAt: ISO8601DateFormatter().date(from: mergedAtStr) ?? Date.distantPast,
                    isUndone: false
                )
            }
        }
        sqlite3_finalize(statement)
        return record
    }

    private func contributionsImpl(forProfileId profileId: UUID) -> [SpeakerContribution] {
        guard isDatabaseOpen else { return [] }
        var rows: [SpeakerContribution] = []
        let sql = """
        SELECT id, profile_id, kind, source_profile_id, recorded_at, (embedding IS NOT NULL)
        FROM speaker_provenance WHERE profile_id = ? ORDER BY recorded_at DESC;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            let isoFormatter = ISO8601DateFormatter()
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let idStr = sqlite3_column_text(statement, 0).map(String.init(cString:)),
                      let id = UUID(uuidString: idStr) else { continue }
                let kind = sqlite3_column_text(statement, 2).map(String.init(cString:)) ?? SpeakerProvenanceKind.contribution
                let sourceId = sqlite3_column_text(statement, 3).map(String.init(cString:)).flatMap { UUID(uuidString: $0) }
                let recordedAtStr = sqlite3_column_text(statement, 4).map(String.init(cString:)) ?? ""
                let hasEmbedding = sqlite3_column_int(statement, 5) != 0
                rows.append(SpeakerContribution(
                    id: id,
                    profileId: profileId,
                    kind: kind,
                    sourceProfileId: sourceId,
                    recordedAt: isoFormatter.date(from: recordedAtStr) ?? Date.distantPast,
                    hasEmbedding: hasEmbedding
                ))
            }
        }
        sqlite3_finalize(statement)
        return rows
    }

    private func unmergeImpl(mergeId: UUID) -> Bool {
        guard isDatabaseOpen else { return false }
        guard let event = loadMergeEventImpl(id: mergeId), event.undoneAt == nil else {
            AppLogger.speakers.warning("Un-merge skipped — event missing or already undone", ["mergeId": mergeId.uuidString])
            return false
        }
        guard let sourceSnapshot = Self.decodeProfileSnapshot(event.sourceSnapshot),
              let targetSnapshot = Self.decodeProfileSnapshot(event.targetSnapshot) else {
            AppLogger.speakers.error("Un-merge failed — snapshot decode error", ["mergeId": mergeId.uuidString])
            return false
        }

        // LIFO safety: a newer non-undone merge into the same keeper means restoring the
        // older target snapshot would silently drop the newer fuse. Refuse instead.
        if hasNewerUndoneMergeImpl(targetId: event.targetId, afterRowid: event.rowid) {
            AppLogger.speakers.warning("Un-merge refused — a newer merge targets the same profile; undo it first", [
                "mergeId": mergeId.uuidString, "targetId": event.targetId.uuidString
            ])
            return false
        }

        var ok = true
        transaction {
            // Re-create the absorbed profile and restore the keeper to its pre-merge state.
            ok = reinsertProfileSnapshotImpl(sourceSnapshot) && ok
            ok = reinsertProfileSnapshotImpl(targetSnapshot) && ok

            // Move the absorbed profile's provenance rows back.
            if !event.movedProvenanceIds.isEmpty {
                let placeholders = Array(repeating: "?", count: event.movedProvenanceIds.count).joined(separator: ",")
                let sql = "UPDATE speaker_provenance SET profile_id = ? WHERE id IN (\(placeholders));"
                var stmt: OpaquePointer?
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, (event.sourceId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    for (offset, pid) in event.movedProvenanceIds.enumerated() {
                        sqlite3_bind_text(stmt, Int32(offset + 2), (pid.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                    }
                    if sqlite3_step(stmt) != SQLITE_DONE {
                        AppLogger.speakers.error("Un-merge failed to restore provenance", ["sqlite_error": dbErrorMessage()])
                        ok = false
                    }
                }
                sqlite3_finalize(stmt)
            }

            // Drop the fuse marker so it doesn't linger on the keeper's audit trail.
            execBind("DELETE FROM speaker_provenance WHERE merge_event_id = ? AND kind = ?;",
                     [mergeId.uuidString, SpeakerProvenanceKind.merge], label: "delete merge marker")

            // Re-derive both profiles from their (now disjoint) contribution embeddings.
            // The snapshots above are exact pre-merge state, but the keeper may have
            // gained recordings after the merge — re-deriving from contributions keeps
            // that post-merge learning instead of silently discarding it. No-op (keeps
            // the snapshot) for legacy profiles that have no stored contribution rows.
            ok = rederiveProfileFromContributionsImpl(event.sourceId) && ok
            ok = rederiveProfileFromContributionsImpl(event.targetId) && ok

            let now = ISO8601DateFormatter().string(from: Date())
            execBind("UPDATE speaker_merge_events SET undone_at = ? WHERE id = ?;",
                     [now, mergeId.uuidString], label: "mark event undone")
        }

        if ok {
            AppLogger.speakers.info("Un-merged profiles", [
                "restoredSource": event.sourceId.uuidString,
                "restoredTarget": event.targetId.uuidString
            ])
        }
        return ok
    }

    private func reassignContributionImpl(id contributionId: UUID, toProfileId: UUID) -> Bool {
        guard isDatabaseOpen else { return false }
        guard let fromProfileId = contributionProfileIdImpl(contributionId) else {
            AppLogger.speakers.warning("Reassign skipped — contribution not found", ["contributionId": contributionId.uuidString])
            return false
        }
        guard fromProfileId != toProfileId else { return true }
        guard getSpeakerImpl(id: toProfileId) != nil else {
            AppLogger.speakers.warning("Reassign skipped — destination profile missing", ["toProfileId": toProfileId.uuidString])
            return false
        }

        var ok = true
        transaction {
            execBind("UPDATE speaker_provenance SET profile_id = ? WHERE id = ?;",
                     [toProfileId.uuidString, contributionId.uuidString], label: "reassign contribution")
            ok = rederiveProfileFromContributionsImpl(fromProfileId) && ok
            ok = rederiveProfileFromContributionsImpl(toProfileId) && ok
        }
        return ok
    }

    /// Recompute a profile's embedding and call count from its stored contribution
    /// embeddings. No-op (returns true) for profiles without stored embeddings.
    private func rederiveProfileFromContributionsImpl(_ profileId: UUID) -> Bool {
        let embeddings = contributionEmbeddingsImpl(forProfileId: profileId)
        guard !embeddings.isEmpty else { return true }
        guard getSpeakerImpl(id: profileId) != nil else { return true }

        let dim = embeddings[0].count
        guard dim > 0, embeddings.allSatisfy({ $0.count == dim }) else { return true }

        var mean = [Float](repeating: 0, count: dim)
        for vector in embeddings {
            for i in 0..<dim { mean[i] += vector[i] }
        }
        let count = Float(embeddings.count)
        for i in 0..<dim { mean[i] /= count }

        // L2-normalize in place (kept self-contained so this method has no cross-file
        // type-inference dependency — the release WMO build choked resolving the shared
        // l2Normalize helper from here).
        var norm: Float = 0
        for value in mean { norm += value * value }
        norm = norm.squareRoot()
        let normalized: [Float] = norm > 0 ? mean.map { $0 / norm } : mean

        let now = ISO8601DateFormatter().string(from: Date())
        let sql = "UPDATE speakers SET embedding = ?, call_count = ?, last_seen = ? WHERE id = ?;"
        var statement: OpaquePointer?
        var ok = false
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            let embeddingData = normalized.withUnsafeBufferPointer { buffer in
                Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Float>.stride)
            }
            sqlite3_bind_blob(statement, 1, (embeddingData as NSData).bytes, Int32(embeddingData.count), SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 2, Int32(embeddings.count))
            sqlite3_bind_text(statement, 3, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            ok = sqlite3_step(statement) == SQLITE_DONE
            if !ok {
                AppLogger.speakers.error("Failed to re-derive profile from contributions", ["sqlite_error": dbErrorMessage(), "profileId": profileId.uuidString])
            }
        }
        sqlite3_finalize(statement)
        // The average was just rebuilt from a changed contribution set (un-merge / reassign), so any
        // cached multi-exemplar voiceprints no longer represent this identity — drop them and let
        // them re-accumulate from future confident matches.
        if ok {
            deleteExemplarsImpl(profileId: profileId)
        }
        return ok
    }

    // MARK: - Small SQLite helpers

    private struct MergeEventRow {
        let id: UUID
        let rowid: Int64
        let targetId: UUID
        let sourceId: UUID
        let sourceSnapshot: String
        let targetSnapshot: String
        let movedProvenanceIds: [UUID]
        let mergedAt: String
        let undoneAt: String?
    }

    private func loadMergeEventImpl(id: UUID) -> MergeEventRow? {
        let sql = """
        SELECT rowid, target_id, source_id, source_snapshot, target_snapshot, moved_provenance_ids, merged_at, undone_at
        FROM speaker_merge_events WHERE id = ?;
        """
        var statement: OpaquePointer?
        var row: MergeEventRow?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) == SQLITE_ROW {
                let rowid = sqlite3_column_int64(statement, 0)
                let targetId = sqlite3_column_text(statement, 1).map(String.init(cString:)).flatMap { UUID(uuidString: $0) }
                let sourceId = sqlite3_column_text(statement, 2).map(String.init(cString:)).flatMap { UUID(uuidString: $0) }
                let sourceSnapshot = sqlite3_column_text(statement, 3).map(String.init(cString:)) ?? ""
                let targetSnapshot = sqlite3_column_text(statement, 4).map(String.init(cString:)) ?? ""
                let movedJSON = sqlite3_column_text(statement, 5).map(String.init(cString:)) ?? "[]"
                let mergedAt = sqlite3_column_text(statement, 6).map(String.init(cString:)) ?? ""
                let undoneAt = sqlite3_column_text(statement, 7).map(String.init(cString:))
                let movedIds = (movedJSON.data(using: .utf8)
                    .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? [])
                    .compactMap { UUID(uuidString: $0) }
                if let targetId, let sourceId {
                    row = MergeEventRow(
                        id: id, rowid: rowid, targetId: targetId, sourceId: sourceId,
                        sourceSnapshot: sourceSnapshot, targetSnapshot: targetSnapshot,
                        movedProvenanceIds: movedIds, mergedAt: mergedAt, undoneAt: undoneAt
                    )
                }
            }
        }
        sqlite3_finalize(statement)
        return row
    }

    /// LIFO safety check for un-merge: true if either (a) a newer non-undone merge
    /// still targets `targetId` (restoring the older snapshot would drop it), or
    /// (b) `targetId` was itself later absorbed as the *source* of a newer
    /// non-undone merge (its contributions were already re-pointed onward, so
    /// resurrecting it here would leave a stale, orphaned profile row — the
    /// merge that consumed it must be undone first).
    private func hasNewerUndoneMergeImpl(targetId: UUID, afterRowid rowid: Int64) -> Bool {
        let sql = """
        SELECT COUNT(*) FROM speaker_merge_events
        WHERE undone_at IS NULL AND rowid > ?
          AND (target_id = ? OR source_id = ?);
        """
        var statement: OpaquePointer?
        var count: Int32 = 0
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_int64(statement, 1, rowid)
            sqlite3_bind_text(statement, 2, (targetId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, (targetId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) == SQLITE_ROW {
                count = sqlite3_column_int(statement, 0)
            }
        }
        sqlite3_finalize(statement)
        return count > 0
    }

    private func provenanceIdsImpl(forProfileId profileId: UUID) -> [UUID] {
        var ids: [UUID] = []
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT id FROM speaker_provenance WHERE profile_id = ?;", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            while sqlite3_step(statement) == SQLITE_ROW {
                if let str = sqlite3_column_text(statement, 0).map(String.init(cString:)), let id = UUID(uuidString: str) {
                    ids.append(id)
                }
            }
        }
        sqlite3_finalize(statement)
        return ids
    }

    private func contributionProfileIdImpl(_ contributionId: UUID) -> UUID? {
        var statement: OpaquePointer?
        var result: UUID?
        if sqlite3_prepare_v2(db, "SELECT profile_id FROM speaker_provenance WHERE id = ?;", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (contributionId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) == SQLITE_ROW {
                result = sqlite3_column_text(statement, 0).map(String.init(cString:)).flatMap { UUID(uuidString: $0) }
            }
        }
        sqlite3_finalize(statement)
        return result
    }

    private func contributionEmbeddingsImpl(forProfileId profileId: UUID) -> [[Float]] {
        var embeddings: [[Float]] = []
        let sql = """
        SELECT embedding FROM speaker_provenance
        WHERE profile_id = ? AND embedding IS NOT NULL AND kind != ?;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, (SpeakerProvenanceKind.merge as NSString).utf8String, -1, SQLITE_TRANSIENT)
            while sqlite3_step(statement) == SQLITE_ROW {
                let blobPtr = sqlite3_column_blob(statement, 0)
                let blobSize = sqlite3_column_bytes(statement, 0)
                if let ptr = blobPtr, blobSize > 0 {
                    let floatCount = Int(blobSize) / MemoryLayout<Float>.size
                    embeddings.append(Array(UnsafeBufferPointer(start: ptr.assumingMemoryBound(to: Float.self), count: floatCount)))
                }
            }
        }
        sqlite3_finalize(statement)
        return embeddings
    }

    /// INSERT OR REPLACE a profile from a decoded snapshot. Used by un-merge to both
    /// resurrect a deleted source row and restore the keeper's pre-merge state.
    private func reinsertProfileSnapshotImpl(_ snapshot: ProfileSnapshot) -> Bool {
        let sql = """
        INSERT OR REPLACE INTO speakers
            (id, display_name, name_source, embedding, first_seen, last_seen, call_count, confidence, dispute_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        var statement: OpaquePointer?
        var ok = false
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            let embeddingData = snapshot.embedding.withUnsafeBufferPointer { Data(buffer: $0) }
            sqlite3_bind_text(statement, 1, (snapshot.id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if let name = snapshot.displayName as NSString? {
                sqlite3_bind_text(statement, 2, name.utf8String, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 2)
            }
            if let source = snapshot.nameSource as NSString? {
                sqlite3_bind_text(statement, 3, source.utf8String, -1, SQLITE_TRANSIENT)
            } else {
                sqlite3_bind_null(statement, 3)
            }
            sqlite3_bind_blob(statement, 4, (embeddingData as NSData).bytes, Int32(embeddingData.count), SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 5, (snapshot.firstSeen as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 6, (snapshot.lastSeen as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(statement, 7, Int32(snapshot.callCount))
            sqlite3_bind_double(statement, 8, snapshot.confidence)
            sqlite3_bind_int(statement, 9, Int32(snapshot.disputeCount))
            ok = sqlite3_step(statement) == SQLITE_DONE
            if !ok {
                AppLogger.speakers.error("Failed to reinsert profile snapshot", ["sqlite_error": dbErrorMessage(), "id": snapshot.id.uuidString])
            }
        }
        sqlite3_finalize(statement)
        return ok
    }

    /// Prepare/bind/step a write with text params. Best-effort; logs on failure.
    private func execBind(_ sql: String, _ params: [String], label: String) {
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            for (offset, value) in params.enumerated() {
                sqlite3_bind_text(statement, Int32(offset + 1), (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
            }
            if sqlite3_step(statement) != SQLITE_DONE {
                AppLogger.speakers.error("SQL write failed", ["label": label, "sqlite_error": dbErrorMessage()])
            }
        } else {
            AppLogger.speakers.error("SQL prepare failed", ["label": label, "sqlite_error": dbErrorMessage()])
        }
        sqlite3_finalize(statement)
    }

    // MARK: - Snapshot coding

    struct ProfileSnapshot: Codable {
        let id: UUID
        let displayName: String?
        let nameSource: String?
        let embedding: [Float]
        let firstSeen: String
        let lastSeen: String
        let callCount: Int
        let confidence: Double
        let disputeCount: Int
    }

    static func encodeProfileSnapshot(_ profile: SpeakerProfile) -> String? {
        let isoFormatter = ISO8601DateFormatter()
        let snapshot = ProfileSnapshot(
            id: profile.id,
            displayName: profile.displayName,
            nameSource: profile.nameSource,
            embedding: profile.embedding,
            firstSeen: isoFormatter.string(from: profile.firstSeen),
            lastSeen: isoFormatter.string(from: profile.lastSeen),
            callCount: profile.callCount,
            confidence: profile.confidence,
            disputeCount: profile.disputeCount
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeProfileSnapshot(_ json: String) -> ProfileSnapshot? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ProfileSnapshot.self, from: data)
    }
}
