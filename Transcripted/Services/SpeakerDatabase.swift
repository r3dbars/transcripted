// SpeakerDatabase.swift
// Persistent SQLite database for voice fingerprints.
// Stores 256-dim speaker embeddings and matches new voices against known speakers.
// Follows the same SQLite pattern as StatsDatabase.swift.

import Foundation
import SQLite3

@available(macOS 14.0, *)
final class SpeakerDatabase {

    static let shared = SpeakerDatabase()

    var db: OpaquePointer?
    var isDatabaseOpen = false
    let dbPath: URL
    let queue = DispatchQueue(label: "com.transcripted.speakerdb", qos: .utility)

    private init() {
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let transcriptedFolder = documentsPath.appendingPathComponent("Transcripted")
        try? FileManager.default.createDirectory(at: transcriptedFolder, withIntermediateDirectories: true)

        dbPath = transcriptedFolder.appendingPathComponent("speakers.sqlite")

        openDatabase()
        createTables()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Database Setup

    private func openDatabase() {
        if sqlite3_open(dbPath.path, &db) != SQLITE_OK {
            let sqliteError = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            AppLogger.speakers.error("Failed to open speaker database — all speaker operations will be skipped", ["path": dbPath.path, "sqlite_error": sqliteError])
            isDatabaseOpen = false
        } else {
            isDatabaseOpen = true
            // Restrict file permissions to owner-only (600) — speakers.sqlite contains voice fingerprints
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dbPath.path)
            // WAL mode for crash safety, busy timeout to avoid SQLITE_BUSY, NORMAL sync for performance
            let pragmas = [
                ("journal_mode=WAL", "WAL"),
                ("busy_timeout=5000", "busy_timeout"),
                ("synchronous=NORMAL", "synchronous")
            ]
            for (pragma, name) in pragmas {
                var errorMessage: UnsafeMutablePointer<CChar>?
                if sqlite3_exec(db, "PRAGMA \(pragma);", nil, nil, &errorMessage) != SQLITE_OK {
                    let detail = errorMessage.map { String(cString: $0) } ?? "unknown"
                    AppLogger.speakers.error("PRAGMA failed", ["pragma": name, "detail": detail])
                    sqlite3_free(errorMessage)
                }
            }

            // Corruption detection: run quick_check to verify database integrity
            if !verifyDatabaseIntegrity() {
                AppLogger.speakers.error("CRITICAL: Speaker database corrupt — backing up and recreating", ["path": dbPath.path])
                sqlite3_close(db)
                db = nil
                // Backup corrupt file with timestamp
                let backupName = "speakers_corrupt_\(DateFormattingHelper.formatFilename(Date())).sqlite"
                let backupPath = dbPath.deletingLastPathComponent().appendingPathComponent(backupName)
                try? FileManager.default.moveItem(at: dbPath, to: backupPath)
                // Recreate fresh database
                if sqlite3_open(dbPath.path, &db) == SQLITE_OK {
                    isDatabaseOpen = true
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dbPath.path)
                    for (pragma, _) in pragmas {
                        sqlite3_exec(db, "PRAGMA \(pragma);", nil, nil, nil)
                    }
                    AppLogger.speakers.info("Recreated fresh database after corruption recovery")
                } else {
                    isDatabaseOpen = false
                    AppLogger.speakers.error("Failed to recreate database after corruption recovery")
                }
            } else {
                AppLogger.speakers.info("Opened database", ["path": dbPath.path])
            }
        }
    }

    /// Verify database integrity using PRAGMA quick_check.
    /// Returns true if the database is healthy.
    private func verifyDatabaseIntegrity() -> Bool {
        guard let db = db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check;", -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqlite3_column_text(stmt, 0) {
                return String(cString: text) == "ok"
            }
        }
        return false
    }

    private func createTables() {
        let sql = """
        CREATE TABLE IF NOT EXISTS speakers (
            id TEXT PRIMARY KEY,
            display_name TEXT,
            name_source TEXT DEFAULT NULL,
            embedding BLOB NOT NULL,
            first_seen TEXT NOT NULL,
            last_seen TEXT NOT NULL,
            call_count INTEGER NOT NULL DEFAULT 1,
            confidence REAL NOT NULL DEFAULT 0.5,
            dispute_count INTEGER NOT NULL DEFAULT 0,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        );
        """
        executeSQL(sql)
        migrateSchema()
    }

    /// Add columns that may be missing from older databases.
    /// Uses column existence check to avoid false error logs from repeated ALTER TABLE.
    private func migrateSchema() {
        let existingColumns = getColumnNames(table: "speakers")
        if !existingColumns.contains("name_source") {
            executeSQL("ALTER TABLE speakers ADD COLUMN name_source TEXT DEFAULT NULL;")
        }
        if !existingColumns.contains("dispute_count") {
            executeSQL("ALTER TABLE speakers ADD COLUMN dispute_count INTEGER NOT NULL DEFAULT 0;")
        }
    }

    /// Query SQLite for existing column names in a table.
    /// Security: PRAGMA table_info does not support parameter binding, so the table name is
    /// validated against a compile-time allowlist before interpolation to prevent SQL injection.
    private func getColumnNames(table: String) -> Set<String> {
        // Allowlist of known table names — reject anything not in this set
        let allowedTables: Set<String> = ["speakers"]
        guard allowedTables.contains(table) else {
            AppLogger.speakers.error("getColumnNames called with unexpected table name — rejecting", ["table": table])
            return []
        }

        var columns: Set<String> = []
        var statement: OpaquePointer?
        let sql = "PRAGMA table_info(\(table));"
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            while sqlite3_step(statement) == SQLITE_ROW {
                if let namePtr = sqlite3_column_text(statement, 1) {
                    columns.insert(String(cString: namePtr))
                }
            }
        }
        sqlite3_finalize(statement)
        return columns
    }

    func executeSQL(_ sql: String) {
        var errorMessage: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            if let error = errorMessage {
                AppLogger.speakers.error("SQL error", ["detail": String(cString: error)])
                sqlite3_free(errorMessage)
            }
        }
    }

    /// Execute multiple writes atomically — if the app crashes mid-block, all changes are rolled back.
    func transaction(_ block: () throws -> Void) rethrows {
        if sqlite3_exec(db, "BEGIN EXCLUSIVE", nil, nil, nil) != SQLITE_OK {
            AppLogger.speakers.error("Transaction BEGIN EXCLUSIVE failed", ["sqlite_error": dbErrorMessage()])
        }
        do {
            try block()
            if sqlite3_exec(db, "COMMIT", nil, nil, nil) != SQLITE_OK {
                AppLogger.speakers.error("Transaction COMMIT failed", ["sqlite_error": dbErrorMessage()])
            }
        } catch {
            if sqlite3_exec(db, "ROLLBACK", nil, nil, nil) != SQLITE_OK {
                AppLogger.speakers.error("Transaction ROLLBACK failed", ["sqlite_error": dbErrorMessage()])
            }
            throw error
        }
    }

    /// Log and return the sqlite3_errmsg for the current database connection
    func dbErrorMessage() -> String {
        if let db = db {
            return String(cString: sqlite3_errmsg(db))
        }
        return "database not open"
    }

    // MARK: - Speaker Management

    /// SQLITE_TRANSIENT tells SQLite to copy the blob data immediately, preventing dangling pointer issues
    let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Add a new speaker or update an existing one's embedding.
    /// When updating, uses exponential moving average to refine the voice fingerprint.
    func addOrUpdateSpeaker(embedding: [Float], existingId: UUID? = nil) -> SpeakerProfile {
        return queue.sync {
            addOrUpdateSpeakerImpl(embedding: embedding, existingId: existingId)
        }
    }

    private func addOrUpdateSpeakerImpl(embedding: [Float], existingId: UUID?) -> SpeakerProfile {
        guard isDatabaseOpen else {
            AppLogger.speakers.error("CRITICAL: addOrUpdateSpeaker returning in-memory-only profile — database not open, speaker will NOT be persisted", ["existingId": existingId?.uuidString ?? "new"])
            return SpeakerProfile(id: existingId ?? UUID(), displayName: nil, nameSource: nil, embedding: embedding, firstSeen: Date(), lastSeen: Date(), callCount: 1, confidence: 0.5, disputeCount: 0)
        }

        let isoFormatter = ISO8601DateFormatter()
        let now = isoFormatter.string(from: Date())

        if let existingId = existingId, let existing = getSpeakerImpl(id: existingId) {
            // Update: blend embedding with exponential moving average
            let alpha: Float = 0.15  // Weight for new embedding (0.15 = slow adaptation, preserves identity)
            let blended = zip(existing.embedding, embedding).map { old, new in
                old * (1 - alpha) + new * alpha
            }
            let normalized = l2Normalize(blended)
            let newConfidence = min(1.0, existing.confidence + 0.1)

            var sqlSucceeded = false
            let sql = """
            UPDATE speakers SET embedding = ?, last_seen = ?, call_count = call_count + 1, confidence = ?
            WHERE id = ?;
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                let embeddingData = normalized.withUnsafeBufferPointer { Data(buffer: $0) }
                sqlite3_bind_blob(statement, 1, (embeddingData as NSData).bytes, Int32(embeddingData.count), SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 2, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(statement, 3, newConfidence)
                sqlite3_bind_text(statement, 4, (existingId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                if sqlite3_step(statement) != SQLITE_DONE {
                    AppLogger.speakers.error("Failed to update speaker embedding", ["sqlite_error": dbErrorMessage(), "id": existingId.uuidString])
                } else {
                    sqlSucceeded = true
                }
            } else {
                AppLogger.speakers.error("Failed to prepare update speaker", ["sqlite_error": dbErrorMessage()])
            }
            sqlite3_finalize(statement)

            if !sqlSucceeded {
                AppLogger.speakers.error("CRITICAL: speaker update was NOT persisted to database — returning stale profile", ["id": existingId.uuidString])
            }

            return SpeakerProfile(
                id: existingId,
                displayName: existing.displayName,
                nameSource: existing.nameSource,
                embedding: normalized,
                firstSeen: existing.firstSeen,
                lastSeen: Date(),
                callCount: existing.callCount + 1,
                confidence: newConfidence,
                disputeCount: existing.disputeCount
            )
        } else {
            // New speaker
            let newId = UUID()
            let normalized = l2Normalize(embedding)
            let embeddingData = normalized.withUnsafeBufferPointer { Data(buffer: $0) }

            var sqlSucceeded = false
            let sql = """
            INSERT INTO speakers (id, embedding, first_seen, last_seen, call_count, confidence)
            VALUES (?, ?, ?, ?, 1, 0.5);
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (newId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_blob(statement, 2, (embeddingData as NSData).bytes, Int32(embeddingData.count), SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 3, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 4, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
                if sqlite3_step(statement) != SQLITE_DONE {
                    AppLogger.speakers.error("Failed to insert new speaker", ["sqlite_error": dbErrorMessage(), "id": newId.uuidString])
                } else {
                    sqlSucceeded = true
                }
            } else {
                AppLogger.speakers.error("Failed to prepare insert speaker", ["sqlite_error": dbErrorMessage()])
            }
            sqlite3_finalize(statement)

            if !sqlSucceeded {
                AppLogger.speakers.error("CRITICAL: new speaker was NOT persisted to database — profile exists only in memory", ["id": newId.uuidString])
            }

            AppLogger.speakers.info("Created new speaker", ["id": "\(newId)"])
            return SpeakerProfile(
                id: newId,
                displayName: nil,
                nameSource: nil,
                embedding: normalized,
                firstSeen: Date(),
                lastSeen: Date(),
                callCount: 1,
                confidence: 0.5,
                disputeCount: 0
            )
        }
    }

    /// Get all stored speakers
    func allSpeakers() -> [SpeakerProfile] {
        return queue.sync { allSpeakersImpl() }
    }

    func allSpeakersImpl() -> [SpeakerProfile] {
        var speakers: [SpeakerProfile] = []
        let sql = "SELECT id, display_name, name_source, embedding, first_seen, last_seen, call_count, confidence, dispute_count FROM speakers ORDER BY last_seen DESC;"
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            let isoFormatter = ISO8601DateFormatter()

            while sqlite3_step(statement) == SQLITE_ROW {
                let idStr = String(cString: sqlite3_column_text(statement, 0))
                let displayName: String? = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                let nameSource: String? = sqlite3_column_text(statement, 2).map { String(cString: $0) }

                // Read embedding BLOB
                let blobPtr = sqlite3_column_blob(statement, 3)
                let blobSize = sqlite3_column_bytes(statement, 3)
                var embedding: [Float] = []
                if let ptr = blobPtr, blobSize > 0 {
                    let floatCount = Int(blobSize) / MemoryLayout<Float>.size
                    embedding = Array(UnsafeBufferPointer(
                        start: ptr.assumingMemoryBound(to: Float.self),
                        count: floatCount
                    ))
                }

                let firstSeenStr = String(cString: sqlite3_column_text(statement, 4))
                let lastSeenStr = String(cString: sqlite3_column_text(statement, 5))
                let callCount = Int(sqlite3_column_int(statement, 6))
                let confidence = sqlite3_column_double(statement, 7)
                let disputeCount = Int(sqlite3_column_int(statement, 8))

                let parsedId = UUID(uuidString: idStr)
                if parsedId == nil {
                    AppLogger.speakers.warning("Corrupt speaker UUID in database, using random UUID", ["raw_id": idStr])
                }
                let firstSeen = isoFormatter.date(from: firstSeenStr)
                if firstSeen == nil {
                    AppLogger.speakers.warning("Corrupt first_seen date in database, using current date", ["raw_date": firstSeenStr, "id": idStr])
                }
                let lastSeen = isoFormatter.date(from: lastSeenStr)
                if lastSeen == nil {
                    AppLogger.speakers.warning("Corrupt last_seen date in database, using current date", ["raw_date": lastSeenStr, "id": idStr])
                }

                speakers.append(SpeakerProfile(
                    id: parsedId ?? UUID(),
                    displayName: displayName,
                    nameSource: nameSource,
                    embedding: embedding,
                    firstSeen: firstSeen ?? Date(),
                    lastSeen: lastSeen ?? Date(),
                    callCount: callCount,
                    confidence: confidence,
                    disputeCount: disputeCount
                ))
            }
        } else {
            AppLogger.speakers.error("Failed to prepare allSpeakers query", ["sqlite_error": dbErrorMessage()])
        }
        sqlite3_finalize(statement)
        return speakers
    }

    /// Get a single speaker by ID
    func getSpeaker(id: UUID) -> SpeakerProfile? {
        return queue.sync { getSpeakerImpl(id: id) }
    }

    func getSpeakerImpl(id: UUID) -> SpeakerProfile? {
        guard isDatabaseOpen else { return nil }

        let sql = "SELECT id, display_name, name_source, embedding, first_seen, last_seen, call_count, confidence, dispute_count FROM speakers WHERE id = ?;"
        var statement: OpaquePointer?
        var profile: SpeakerProfile?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)

            if sqlite3_step(statement) == SQLITE_ROW {
                let isoFormatter = ISO8601DateFormatter()
                let idStr = String(cString: sqlite3_column_text(statement, 0))
                let displayName: String? = sqlite3_column_text(statement, 1).map { String(cString: $0) }
                let nameSource: String? = sqlite3_column_text(statement, 2).map { String(cString: $0) }

                let blobPtr = sqlite3_column_blob(statement, 3)
                let blobSize = sqlite3_column_bytes(statement, 3)
                var embedding: [Float] = []
                if let ptr = blobPtr, blobSize > 0 {
                    let floatCount = Int(blobSize) / MemoryLayout<Float>.size
                    embedding = Array(UnsafeBufferPointer(
                        start: ptr.assumingMemoryBound(to: Float.self),
                        count: floatCount
                    ))
                }

                let firstSeenStr = String(cString: sqlite3_column_text(statement, 4))
                let lastSeenStr = String(cString: sqlite3_column_text(statement, 5))
                let callCount = Int(sqlite3_column_int(statement, 6))
                let confidence = sqlite3_column_double(statement, 7)
                let disputeCount = Int(sqlite3_column_int(statement, 8))

                profile = SpeakerProfile(
                    id: UUID(uuidString: idStr) ?? id,
                    displayName: displayName,
                    nameSource: nameSource,
                    embedding: embedding,
                    firstSeen: isoFormatter.date(from: firstSeenStr) ?? Date(),
                    lastSeen: isoFormatter.date(from: lastSeenStr) ?? Date(),
                    callCount: callCount,
                    confidence: confidence,
                    disputeCount: disputeCount
                )
            }
        } else {
            AppLogger.speakers.error("Failed to prepare getSpeaker query", ["sqlite_error": dbErrorMessage(), "id": id.uuidString])
        }
        sqlite3_finalize(statement)
        return profile
    }

    /// Delete a speaker profile
    func deleteSpeaker(id: UUID) {
        queue.sync { [self] in
            guard isDatabaseOpen else { return }
            let sql = "DELETE FROM speakers WHERE id = ?;"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                if sqlite3_step(statement) != SQLITE_DONE {
                    AppLogger.speakers.error("Failed to delete speaker", ["sqlite_error": dbErrorMessage(), "id": id.uuidString])
                }
            } else {
                AppLogger.speakers.error("Failed to prepare deleteSpeaker", ["sqlite_error": dbErrorMessage()])
            }
            sqlite3_finalize(statement)
        }
    }
}
