// SpeakerVoiceprintMigrationLedger.swift
// The target side of a voiceprint migration: the ledger table that makes it
// idempotent and resumable, and the one-transaction write that brings a person
// into the new model's database.
//
// Each person is written in a single `performMutationBatch`: profile row (same
// UUID), name and counts, rebuilt exemplars, confirmations, recent lifeline
// kinds, and the ledger row. A cancel or crash between people leaves every
// finished person complete and the rest untouched; the next run skips anyone
// already in the ledger.

import Foundation
import SQLite3

/// What happened to one person in a voiceprint migration.
public enum SpeakerVoiceprintMigrationStatus: String, Sendable, Codable, CaseIterable {
    /// Voiceprint rebuilt from their audio, which agrees with itself. Name,
    /// counts and confirmations carried, so silent naming works as before.
    case carried
    /// Voiceprint rebuilt, name and counts carried, but their audio disagreed
    /// with itself under the new model (or was one clip, so it couldn't be
    /// checked). Their confirmations wait in the ledger, so the new model won't
    /// silently name them; the first time the user confirms them, the next run
    /// restores the confirmations.
    case held
    /// No usable audio left: no profile could be built. Listed so the host can
    /// ask for one confirmation instead of the person silently disappearing.
    case needsConfirmation = "needs_confirmation"
    /// The new model's database already had a profile with this UUID, and it
    /// was left untouched.
    case alreadyPresent = "already_present"
}

/// One ledger row, for hosts that list who still needs a confirmation.
public struct SpeakerVoiceprintMigrationLedgerEntry: Sendable, Equatable {
    public let profileId: UUID
    public let displayName: String
    public let status: SpeakerVoiceprintMigrationStatus
    public let embedderIdentifier: String
    public let sessions: Int
    public let speechSeconds: Double
    public let selfSimilarity: Double?
    /// When a held person's confirmations were restored after a new confirmation.
    public let releasedAt: Date?
}

/// Everything the source knew about a person that isn't a vector, kept in the
/// ledger for held and needs-confirmation people.
struct SpeakerVoiceprintHeldRecord: Codable, Equatable {
    var firstSeen: Date
    var lastSeen: Date
    var callCount: Int
    var confidence: Double
    var disputeCount: Int
    var confirmations: [SpeakerVoiceprintSourceSnapshot.Confirmation]
    var outcomes: [SpeakerVoiceprintSourceSnapshot.Outcome]
}

/// One person, ready to write.
struct SpeakerVoiceprintMigrationWrite {
    let person: SpeakerVoiceprintSourceSnapshot.Person
    let status: SpeakerVoiceprintMigrationStatus
    let embedderIdentifier: String
    /// The new voiceprint; nil only for `.needsConfirmation`.
    let centroid: [Float]?
    /// Session means to fold into exemplars (oldest first); empty when held.
    let exemplarMeans: [[Float]]
    let confirmations: [SpeakerVoiceprintSourceSnapshot.Confirmation]
    let outcomes: [SpeakerVoiceprintSourceSnapshot.Outcome]
    let sessions: Int
    let speechSeconds: Double
    let selfSimilarity: Double?
}

@available(macOS 14.0, *)
extension SpeakerDatabase {

    static let voiceprintMigrationTable = "speaker_voiceprint_migrations"

    // MARK: - Schema

    func ensureVoiceprintMigrationLedger() throws {
        try queue.sync {
            guard isDatabaseOpen else { throw voiceprintLedgerError("create voiceprint migration ledger", SQLITE_MISUSE) }
            try execVoiceprintLedgerSQL("""
            CREATE TABLE IF NOT EXISTS \(Self.voiceprintMigrationTable) (
                profile_id TEXT PRIMARY KEY,
                display_name TEXT NOT NULL,
                status TEXT NOT NULL,
                embedder_id TEXT NOT NULL,
                sessions INTEGER NOT NULL DEFAULT 0,
                speech_seconds REAL NOT NULL DEFAULT 0,
                self_similarity REAL,
                held_record TEXT,
                recorded_at TEXT NOT NULL,
                released_at TEXT
            );
            """, operation: "create voiceprint migration ledger")
        }
    }

    // MARK: - Reads

    /// Every person a voiceprint migration has handled in this database.
    public func voiceprintMigrationLedger() -> [SpeakerVoiceprintMigrationLedgerEntry] {
        queue.sync {
            guard isDatabaseOpen else { return [] }
            var statement: OpaquePointer?
            let sql = """
            SELECT profile_id, display_name, status, embedder_id, sessions, speech_seconds,
                   self_similarity, released_at
            FROM \(Self.voiceprintMigrationTable)
            ORDER BY rowid ASC;
            """
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
                sqlite3_finalize(statement)
                return []
            }
            defer { sqlite3_finalize(statement) }
            let iso = ISO8601DateFormatter()
            var entries: [SpeakerVoiceprintMigrationLedgerEntry] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                guard let id = sqlite3_column_text(statement, 0).flatMap({ UUID(uuidString: String(cString: $0)) }),
                      let status = sqlite3_column_text(statement, 2)
                        .flatMap({ SpeakerVoiceprintMigrationStatus(rawValue: String(cString: $0)) }) else { continue }
                entries.append(SpeakerVoiceprintMigrationLedgerEntry(
                    profileId: id,
                    displayName: sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? "",
                    status: status,
                    embedderIdentifier: sqlite3_column_text(statement, 3).map { String(cString: $0) } ?? "",
                    sessions: Int(sqlite3_column_int(statement, 4)),
                    speechSeconds: sqlite3_column_double(statement, 5),
                    selfSimilarity: sqlite3_column_type(statement, 6) == SQLITE_NULL
                        ? nil : sqlite3_column_double(statement, 6),
                    releasedAt: sqlite3_column_text(statement, 7).flatMap { iso.date(from: String(cString: $0)) }
                ))
            }
            return entries
        }
    }

    // MARK: - Writes

    /// Write one person in one transaction. Returns the status that ended up in
    /// the ledger: the planned one, `.alreadyPresent` when this UUID already has a
    /// profile here, or the existing ledger status when the person was done
    /// before (nothing is changed then).
    @discardableResult
    func writeVoiceprintMigrationPerson(_ write: SpeakerVoiceprintMigrationWrite) throws -> SpeakerVoiceprintMigrationStatus {
        var finalStatus = write.status
        try performMutationBatch {
            if let existing = try voiceprintLedgerStatusImpl(profileId: write.person.id) {
                finalStatus = existing
                return
            }
            let person = write.person
            var status = write.status
            if getSpeakerImpl(id: person.id) != nil {
                status = .alreadyPresent
            }

            let heldRecord: SpeakerVoiceprintHeldRecord?
            switch status {
            case .carried, .held:
                guard let centroid = write.centroid, !centroid.isEmpty else {
                    throw voiceprintLedgerError("write migrated voiceprint", SQLITE_MISUSE)
                }
                let inserted = addOrUpdateSpeaker(embedding: centroid, existingId: person.id)
                guard inserted.id == person.id else {
                    throw voiceprintLedgerError("insert migrated profile", SQLITE_CONSTRAINT)
                }
                restoreProfile(SpeakerProfile(
                    id: person.id,
                    displayName: person.displayName,
                    nameSource: NameSource.userManual,
                    embedding: SpeakerVectorMath.l2Normalize(centroid),
                    firstSeen: person.firstSeen,
                    lastSeen: person.lastSeen,
                    callCount: person.callCount,
                    confidence: person.confidence,
                    disputeCount: person.disputeCount
                ))
                for mean in write.exemplarMeans where mean.count == centroid.count {
                    updateExemplarsImpl(
                        profileId: person.id,
                        newMean: mean,
                        average: SpeakerVectorMath.l2Normalize(centroid)
                    )
                }
                if status == .carried {
                    try insertVoiceprintConfirmationsImpl(profileId: person.id, write.confirmations)
                }
                try insertVoiceprintOutcomesImpl(profileId: person.id, write.outcomes)
                heldRecord = status == .held ? Self.heldRecord(for: write) : nil
            case .needsConfirmation:
                heldRecord = Self.heldRecord(for: write)
            case .alreadyPresent:
                heldRecord = nil
            }
            try insertVoiceprintLedgerRowImpl(write, status: status, heldRecord: heldRecord)
            finalStatus = status
        }
        return finalStatus
    }

    /// Give held people their confirmations back once the user has confirmed
    /// them at least once under the new model (a confirmation row now exists for
    /// their profile, or for the profile they were merged into). Returns the ids
    /// released. Held people whose profile was deleted stay held.
    func releaseHeldVoiceprintConfirmations() throws -> [UUID] {
        var released: [UUID] = []
        try performMutationBatch {
            for (profileId, record) in try heldVoiceprintRecordsImpl() {
                var holder = profileId
                var seen: Set<UUID> = [profileId]
                while let next = mergeSurvivorId(of: holder), seen.insert(next).inserted {
                    holder = next
                }
                guard getSpeakerImpl(id: holder) != nil,
                      try voiceprintConfirmationCountImpl(profileId: holder) > 0 else { continue }
                try insertVoiceprintConfirmationsImpl(profileId: holder, record.confirmations)
                try markVoiceprintReleasedImpl(profileId: profileId)
                released.append(profileId)
            }
        }
        return released
    }

    // MARK: - Implementation (on `queue`, inside a mutation batch)

    private static func heldRecord(for write: SpeakerVoiceprintMigrationWrite) -> SpeakerVoiceprintHeldRecord {
        SpeakerVoiceprintHeldRecord(
            firstSeen: write.person.firstSeen,
            lastSeen: write.person.lastSeen,
            callCount: write.person.callCount,
            confidence: write.person.confidence,
            disputeCount: write.person.disputeCount,
            confirmations: write.confirmations,
            outcomes: write.outcomes
        )
    }

    private func voiceprintLedgerStatusImpl(profileId: UUID) throws -> SpeakerVoiceprintMigrationStatus? {
        let statement = try prepareStatement(
            "SELECT status FROM \(Self.voiceprintMigrationTable) WHERE profile_id = ? LIMIT 1;",
            operation: "read voiceprint migration ledger"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        let step = sqlite3_step(statement)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW else { throw voiceprintLedgerError("read voiceprint migration ledger", step) }
        return sqlite3_column_text(statement, 0)
            .flatMap { SpeakerVoiceprintMigrationStatus(rawValue: String(cString: $0)) }
    }

    private func heldVoiceprintRecordsImpl() throws -> [(UUID, SpeakerVoiceprintHeldRecord)] {
        let statement = try prepareStatement(
            "SELECT profile_id, held_record FROM \(Self.voiceprintMigrationTable) WHERE status = ? ORDER BY rowid ASC;",
            operation: "read held voiceprint migrations"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(
            statement, 1,
            (SpeakerVoiceprintMigrationStatus.held.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var records: [(UUID, SpeakerVoiceprintHeldRecord)] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return records }
            guard step == SQLITE_ROW else { throw voiceprintLedgerError("read held voiceprint migrations", step) }
            guard let id = sqlite3_column_text(statement, 0).flatMap({ UUID(uuidString: String(cString: $0)) }),
                  let json = sqlite3_column_text(statement, 1).map({ String(cString: $0) }),
                  let record = try? decoder.decode(SpeakerVoiceprintHeldRecord.self, from: Data(json.utf8)) else {
                continue
            }
            records.append((id, record))
        }
    }

    private func voiceprintConfirmationCountImpl(profileId: UUID) throws -> Int {
        let statement = try prepareStatement(
            "SELECT COUNT(*) FROM speaker_profile_confirmations WHERE profile_id = ?;",
            operation: "count confirmations for held voiceprint"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw voiceprintLedgerError("count confirmations for held voiceprint", sqlite3_errcode(db))
        }
        return Int(sqlite3_column_int(statement, 0))
    }

    private func insertVoiceprintConfirmationsImpl(
        profileId: UUID,
        _ confirmations: [SpeakerVoiceprintSourceSnapshot.Confirmation]
    ) throws {
        guard !confirmations.isEmpty else { return }
        let statement = try prepareStatement("""
        INSERT OR IGNORE INTO speaker_profile_confirmations
            (id, profile_id, transcript_id, kind, confirmed_at)
        VALUES (?, ?, ?, ?, ?);
        """, operation: "carry speaker confirmations")
        defer { sqlite3_finalize(statement) }
        for confirmation in confirmations {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, (UUID().uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, (confirmation.transcriptId as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 4, (confirmation.kind as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 5, (confirmation.confirmedAt as NSString).utf8String, -1, SQLITE_TRANSIENT)
            try requireDone(statement, operation: "carry speaker confirmation")
        }
    }

    private func insertVoiceprintOutcomesImpl(
        profileId: UUID,
        _ outcomes: [SpeakerVoiceprintSourceSnapshot.Outcome]
    ) throws {
        guard !outcomes.isEmpty else { return }
        let statement = try prepareStatement("""
        INSERT INTO speaker_match_outcomes
            (id, profile_id, kind, similarity, second_similarity, call_count_at_match, channel, transcript_id, recorded_at)
        VALUES (?, ?, ?, NULL, NULL, ?, ?, ?, ?);
        """, operation: "carry speaker lifeline")
        defer { sqlite3_finalize(statement) }
        // Oldest first, so rowid order matches time order like live writes.
        for outcome in outcomes.reversed() {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, (UUID().uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, (outcome.kind as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if let callCount = outcome.callCountAtMatch {
                sqlite3_bind_int(statement, 4, Int32(clamping: callCount))
            } else {
                sqlite3_bind_null(statement, 4)
            }
            bindOptionalText(statement, 5, outcome.channel)
            bindOptionalText(statement, 6, outcome.transcriptId)
            sqlite3_bind_text(statement, 7, (outcome.recordedAt as NSString).utf8String, -1, SQLITE_TRANSIENT)
            try requireDone(statement, operation: "carry speaker lifeline row")
        }
    }

    private func insertVoiceprintLedgerRowImpl(
        _ write: SpeakerVoiceprintMigrationWrite,
        status: SpeakerVoiceprintMigrationStatus,
        heldRecord: SpeakerVoiceprintHeldRecord?
    ) throws {
        let statement = try prepareStatement("""
        INSERT INTO \(Self.voiceprintMigrationTable)
            (profile_id, display_name, status, embedder_id, sessions, speech_seconds,
             self_similarity, held_record, recorded_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?);
        """, operation: "write voiceprint migration ledger")
        defer { sqlite3_finalize(statement) }
        var heldJSON: String?
        if let heldRecord {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.sortedKeys]
            heldJSON = String(decoding: try encoder.encode(heldRecord), as: UTF8.self)
        }
        sqlite3_bind_text(statement, 1, (write.person.id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, (write.person.displayName as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, (status.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 4, (write.embedderIdentifier as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 5, Int32(clamping: write.sessions))
        sqlite3_bind_double(statement, 6, write.speechSeconds)
        if let selfSimilarity = write.selfSimilarity, selfSimilarity.isFinite {
            sqlite3_bind_double(statement, 7, selfSimilarity)
        } else {
            sqlite3_bind_null(statement, 7)
        }
        bindOptionalText(statement, 8, heldJSON)
        let now = ISO8601DateFormatter().string(from: Date())
        sqlite3_bind_text(statement, 9, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
        try requireDone(statement, operation: "write voiceprint migration ledger", expectedChanges: 1)
    }

    private func markVoiceprintReleasedImpl(profileId: UUID) throws {
        let statement = try prepareStatement("""
        UPDATE \(Self.voiceprintMigrationTable)
        SET status = ?, released_at = ?, held_record = NULL
        WHERE profile_id = ?;
        """, operation: "release held voiceprint")
        defer { sqlite3_finalize(statement) }
        let now = ISO8601DateFormatter().string(from: Date())
        sqlite3_bind_text(
            statement, 1,
            (SpeakerVoiceprintMigrationStatus.carried.rawValue as NSString).utf8String, -1, SQLITE_TRANSIENT
        )
        sqlite3_bind_text(statement, 2, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, (profileId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
        try requireDone(statement, operation: "release held voiceprint", expectedChanges: 1)
    }

    private func bindOptionalText(_ statement: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func execVoiceprintLedgerSQL(_ sql: String, operation: String) throws {
        let result = sqlite3_exec(db, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw voiceprintLedgerError(operation, result) }
    }

    private func voiceprintLedgerError(_ operation: String, _ code: Int32) -> SQLiteOperationError {
        SQLiteOperationError(operation: operation, code: code, detail: dbErrorMessage())
    }
}
