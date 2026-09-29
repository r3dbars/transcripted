// SpeakerVoiceprintSourceSnapshot.swift
// A read-only, in-memory copy of the speaker database a voiceprint migration
// carries people out of.
//
// `SpeakerDatabase(path:)` is never used on the source: its init creates tables,
// runs schema and confirmation migrations, tightens file permissions, and moves
// a file it thinks is corrupt. Instead the file is opened with SQLITE_OPEN_READONLY
// and copied into memory with SQLite's backup API (one consistent read, WAL
// included), then closed before anything else happens. Nothing is written to the
// database file or its WAL.

import Foundation
import SQLite3

struct SpeakerVoiceprintSourceSnapshot: Sendable {
    /// A user-named person (`name_source == user_manual`) in the source database.
    struct Person: Sendable, Equatable {
        let id: UUID
        let displayName: String
        let firstSeen: Date
        let lastSeen: Date
        let callCount: Int
        let confidence: Double
        let disputeCount: Int
    }

    /// One explicit-confirmation ledger row, kept as the stored strings.
    struct Confirmation: Sendable, Equatable, Codable {
        let transcriptId: String
        let kind: String
        let confirmedAt: String
    }

    /// One lifeline outcome row, without the old model's similarity numbers
    /// (they mean nothing in the new model's space). The kinds are what
    /// `SpeakerProfileHealth` reads, so carrying them keeps a person who was on
    /// probation on probation.
    struct Outcome: Sendable, Equatable, Codable {
        let kind: String
        let callCountAtMatch: Int?
        let channel: String?
        let transcriptId: String?
        let recordedAt: String
    }

    struct ExemplarStats: Sendable, Equatable {
        let count: Int
        let sessions: Int
    }

    let people: [Person]
    let confirmations: [UUID: [Confirmation]]
    /// Most recent first, at most `SpeakerProfileHealth.recentOutcomeWindow` each.
    let recentOutcomes: [UUID: [Outcome]]
    let exemplarStats: [UUID: ExemplarStats]
    /// Active (not undone) merges: absorbed profile id to the keeper it went into.
    let mergeTargets: [UUID: UUID]

    /// The profile that now holds `id`, following merges that were not undone.
    func survivor(of id: UUID) -> UUID {
        var current = id
        var seen: Set<UUID> = [id]
        while let next = mergeTargets[current], seen.insert(next).inserted {
            current = next
        }
        return current
    }

    /// Every profile id whose survivor is `id` (including `id` itself).
    func absorbedIds(into id: UUID) -> [UUID] {
        var ids = [id]
        for source in mergeTargets.keys.sorted(by: { $0.uuidString < $1.uuidString })
        where source != id && survivor(of: source) == id {
            ids.append(source)
        }
        return ids
    }

    // MARK: - Loading

    enum LoadError: Error, Equatable {
        case missing
        case unreadable(code: Int32)
    }

    static func load(from url: URL) throws -> SpeakerVoiceprintSourceSnapshot {
        guard FileManager.default.fileExists(atPath: url.path) else { throw LoadError.missing }

        var memory: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &memory, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let memory else {
            sqlite3_close(memory)
            throw LoadError.unreadable(code: SQLITE_CANTOPEN)
        }
        defer { sqlite3_close(memory) }

        try copy(from: url, into: memory)
        return try read(memory)
    }

    /// Copy the whole file into `memory`, opening the file read-only.
    private static func copy(from url: URL, into memory: OpaquePointer) throws {
        var source: OpaquePointer?
        // A file: URI so `mode=ro` applies; the path is percent-encoded by URL.
        let uri = url.standardizedFileURL.absoluteString + "?mode=ro"
        let openResult = sqlite3_open_v2(uri, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil)
        defer { sqlite3_close(source) }
        guard openResult == SQLITE_OK, let source else {
            throw LoadError.unreadable(code: openResult)
        }
        sqlite3_busy_timeout(source, 5_000)

        guard let backup = sqlite3_backup_init(memory, "main", source, "main") else {
            throw LoadError.unreadable(code: sqlite3_errcode(memory))
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw LoadError.unreadable(code: stepResult == SQLITE_DONE ? finishResult : stepResult)
        }
    }

    private static func read(_ db: OpaquePointer) throws -> SpeakerVoiceprintSourceSnapshot {
        let iso = ISO8601DateFormatter()
        var people: [Person] = []
        try forEachRow(db, """
            SELECT id, display_name, first_seen, last_seen, call_count, confidence, dispute_count
            FROM speakers
            WHERE display_name IS NOT NULL AND TRIM(display_name) != '' AND name_source = ?
            ORDER BY last_seen DESC, id ASC;
            """, bind: [NameSource.userManual], required: true) { row in
            guard let id = UUID(uuidString: text(row, 0) ?? ""),
                  let name = text(row, 1) else { return }
            people.append(Person(
                id: id,
                displayName: name,
                firstSeen: text(row, 2).flatMap { iso.date(from: $0) } ?? Date(),
                lastSeen: text(row, 3).flatMap { iso.date(from: $0) } ?? Date(),
                callCount: Int(sqlite3_column_int(row, 4)),
                confidence: sqlite3_column_double(row, 5),
                disputeCount: Int(sqlite3_column_int(row, 6))
            ))
        }

        var confirmations: [UUID: [Confirmation]] = [:]
        try forEachRow(db, """
            SELECT profile_id, transcript_id, kind, confirmed_at
            FROM speaker_profile_confirmations
            ORDER BY rowid ASC;
            """) { row in
            guard let profileId = UUID(uuidString: text(row, 0) ?? ""),
                  let transcriptId = text(row, 1),
                  let kind = text(row, 2),
                  let confirmedAt = text(row, 3) else { return }
            confirmations[profileId, default: []].append(
                Confirmation(transcriptId: transcriptId, kind: kind, confirmedAt: confirmedAt)
            )
        }

        var outcomes: [UUID: [Outcome]] = [:]
        try forEachRow(db, """
            SELECT profile_id, kind, call_count_at_match, channel, transcript_id, recorded_at
            FROM speaker_match_outcomes
            ORDER BY recorded_at DESC, rowid DESC;
            """) { row in
            guard let profileId = UUID(uuidString: text(row, 0) ?? ""),
                  let kind = text(row, 1),
                  SpeakerMatchOutcomeKind(rawValue: kind) != nil,
                  let recordedAt = text(row, 5) else { return }
            guard outcomes[profileId, default: []].count < SpeakerProfileHealth.recentOutcomeWindow else { return }
            outcomes[profileId, default: []].append(Outcome(
                kind: kind,
                callCountAtMatch: sqlite3_column_type(row, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int(row, 2)),
                channel: text(row, 3),
                transcriptId: text(row, 4),
                recordedAt: recordedAt
            ))
        }

        var exemplarStats: [UUID: ExemplarStats] = [:]
        try forEachRow(db, """
            SELECT profile_id, COUNT(*), COALESCE(SUM(segment_count), 0)
            FROM speaker_exemplars
            GROUP BY profile_id;
            """) { row in
            guard let profileId = UUID(uuidString: text(row, 0) ?? "") else { return }
            exemplarStats[profileId] = ExemplarStats(
                count: Int(sqlite3_column_int(row, 1)),
                sessions: Int(sqlite3_column_int(row, 2))
            )
        }

        var mergeTargets: [UUID: UUID] = [:]
        try forEachRow(db, """
            SELECT source_id, target_id
            FROM speaker_merge_events
            WHERE undone_at IS NULL
            ORDER BY rowid ASC;
            """) { row in
            guard let source = UUID(uuidString: text(row, 0) ?? ""),
                  let target = UUID(uuidString: text(row, 1) ?? ""),
                  source != target else { return }
            mergeTargets[source] = target
        }

        return SpeakerVoiceprintSourceSnapshot(
            people: people,
            confirmations: confirmations,
            recentOutcomes: outcomes,
            exemplarStats: exemplarStats,
            mergeTargets: mergeTargets
        )
    }

    /// Run `sql` and call `body` per row. A table that doesn't exist yet (an old
    /// database) reads as empty unless `required`.
    private static func forEachRow(
        _ db: OpaquePointer,
        _ sql: String,
        bind values: [String] = [],
        required: Bool = false,
        _ body: (OpaquePointer) -> Void
    ) throws {
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(db, sql, -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepareResult == SQLITE_OK, let statement else {
            if required { throw LoadError.unreadable(code: prepareResult) }
            return
        }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), (value as NSString).utf8String, -1, transient)
        }
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return }
            guard step == SQLITE_ROW else { throw LoadError.unreadable(code: step) }
            body(statement)
        }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }
}
