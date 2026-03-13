// SpeakerDatabase.swift
// Persistent SQLite database for voice fingerprints.
// Stores 256-dim speaker embeddings and matches new voices against known speakers.
// Follows the same SQLite pattern as StatsDatabase.swift.

import Foundation
import SQLite3
import Accelerate

/// A persistent speaker profile with voice fingerprint
struct SpeakerProfile: Identifiable {
    let id: UUID
    var displayName: String?        // "Nate", "Travis", or nil if unnamed
    var nameSource: String?         // "user_manual", "qwen_inferred", nil
    var embedding: [Float]          // 256-dim average voice vector
    var firstSeen: Date
    var lastSeen: Date
    var callCount: Int
    var confidence: Double          // Improves with more data points
    var disputeCount: Int           // Times inference disagreed with DB name
}

/// Result of matching an embedding against the speaker database
struct SpeakerMatchResult {
    let profile: SpeakerProfile
    let similarity: Double          // Cosine similarity score (0.0–1.0)
}

@available(macOS 14.0, *)
final class SpeakerDatabase {

    static let shared = SpeakerDatabase()

    private var db: OpaquePointer?
    private var isDatabaseOpen = false
    private let dbPath: URL
    private let queue = DispatchQueue(label: "com.transcripted.speakerdb", qos: .utility)

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
            AppLogger.speakers.error("Failed to open database", ["path": dbPath.path])
            isDatabaseOpen = false
        } else {
            isDatabaseOpen = true
            // WAL mode for crash safety, busy timeout to avoid SQLITE_BUSY, NORMAL sync for performance
            sqlite3_exec(db, "PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA synchronous=NORMAL;", nil, nil, nil)
            AppLogger.speakers.info("Opened database", ["path": dbPath.path])
        }
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

    /// Query SQLite for existing column names in a table
    private func getColumnNames(table: String) -> Set<String> {
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

    private func executeSQL(_ sql: String) {
        var errorMessage: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            if let error = errorMessage {
                AppLogger.speakers.error("SQL error", ["detail": String(cString: error)])
                sqlite3_free(errorMessage)
            }
        }
    }

    /// Execute multiple writes atomically — if the app crashes mid-block, all changes are rolled back.
    private func transaction(_ block: () throws -> Void) rethrows {
        sqlite3_exec(db, "BEGIN EXCLUSIVE", nil, nil, nil)
        do {
            try block()
            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        } catch {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    /// Log and return the sqlite3_errmsg for the current database connection
    private func dbErrorMessage() -> String {
        if let db = db {
            return String(cString: sqlite3_errmsg(db))
        }
        return "database not open"
    }

    // MARK: - Speaker Matching

    /// Match an embedding against all stored speakers using cosine similarity.
    /// Returns the best match above threshold with similarity score, or nil for a new speaker.
    func matchSpeaker(embedding: [Float], threshold: Double = 0.6) -> SpeakerMatchResult? {
        return queue.sync {
            matchSpeakerImpl(embedding: embedding, threshold: threshold)
        }
    }

    private func matchSpeakerImpl(embedding: [Float], threshold: Double) -> SpeakerMatchResult? {
        let allSpeakers = allSpeakersImpl()
        guard !allSpeakers.isEmpty else { return nil }

        var bestMatch: SpeakerProfile?
        var bestSimilarity: Double = -1

        for speaker in allSpeakers {
            let similarity = cosineSimilarity(embedding, speaker.embedding)
            if similarity > bestSimilarity && similarity >= threshold {
                bestSimilarity = similarity
                bestMatch = speaker
            }
        }

        if let match = bestMatch {
            AppLogger.speakers.info("Matched speaker", ["name": match.displayName ?? match.id.uuidString, "similarity": String(format: "%.3f", bestSimilarity)])
            return SpeakerMatchResult(profile: match, similarity: bestSimilarity)
        }

        return nil
    }

    // MARK: - Speaker Management

    /// Add a new speaker or update an existing one's embedding.
    /// When updating, uses exponential moving average to refine the voice fingerprint.
    func addOrUpdateSpeaker(embedding: [Float], existingId: UUID? = nil) -> SpeakerProfile {
        return queue.sync {
            addOrUpdateSpeakerImpl(embedding: embedding, existingId: existingId)
        }
    }

    /// SQLITE_TRANSIENT tells SQLite to copy the blob data immediately, preventing dangling pointer issues
    private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func addOrUpdateSpeakerImpl(embedding: [Float], existingId: UUID?) -> SpeakerProfile {
        guard isDatabaseOpen else {
            AppLogger.speakers.error("addOrUpdateSpeaker skipped — database not open")
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
                }
            } else {
                AppLogger.speakers.error("Failed to prepare update speaker", ["sqlite_error": dbErrorMessage()])
            }
            sqlite3_finalize(statement)

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
                }
            } else {
                AppLogger.speakers.error("Failed to prepare insert speaker", ["sqlite_error": dbErrorMessage()])
            }
            sqlite3_finalize(statement)

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

    /// Set the display name for a speaker with provenance tracking
    /// - Parameters:
    ///   - id: Speaker profile UUID
    ///   - name: Display name to set
    ///   - source: Where the name came from ("user_manual", "qwen_inferred")
    func setDisplayName(id: UUID, name: String, source: String = "qwen_inferred") {
        queue.sync {
            setDisplayNameImpl(id: id, name: name, source: source)
        }
    }

    private func setDisplayNameImpl(id: UUID, name: String, source: String) {
        guard isDatabaseOpen else { return }
        let sql = "UPDATE speakers SET display_name = ?, name_source = ? WHERE id = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, (source as NSString).utf8String, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 3, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) != SQLITE_DONE {
                AppLogger.speakers.error("Failed to set display name", ["sqlite_error": dbErrorMessage(), "id": id.uuidString])
            }
        } else {
            AppLogger.speakers.error("Failed to prepare setDisplayName", ["sqlite_error": dbErrorMessage()])
        }
        sqlite3_finalize(statement)
    }

    /// Increment the dispute count for a speaker (inference disagreed with DB name)
    func incrementDisputeCount(id: UUID) {
        queue.sync { [self] in
            guard isDatabaseOpen else { return }
            let sql = "UPDATE speakers SET dispute_count = dispute_count + 1 WHERE id = ?;"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                if sqlite3_step(statement) != SQLITE_DONE {
                    AppLogger.speakers.error("Failed to increment dispute count", ["sqlite_error": dbErrorMessage()])
                }
            } else {
                AppLogger.speakers.error("Failed to prepare incrementDisputeCount", ["sqlite_error": dbErrorMessage()])
            }
            sqlite3_finalize(statement)
        }
    }

    /// Reset dispute count (after user manual rename or name confirmed)
    func resetDisputeCount(id: UUID) {
        queue.sync { [self] in
            guard isDatabaseOpen else { return }
            let sql = "UPDATE speakers SET dispute_count = 0 WHERE id = ?;"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (id.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                if sqlite3_step(statement) != SQLITE_DONE {
                    AppLogger.speakers.error("Failed to reset dispute count", ["sqlite_error": dbErrorMessage()])
                }
            } else {
                AppLogger.speakers.error("Failed to prepare resetDisputeCount", ["sqlite_error": dbErrorMessage()])
            }
            sqlite3_finalize(statement)
        }
    }

    /// Get all stored speakers
    func allSpeakers() -> [SpeakerProfile] {
        return queue.sync { allSpeakersImpl() }
    }

    private func allSpeakersImpl() -> [SpeakerProfile] {
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

                speakers.append(SpeakerProfile(
                    id: UUID(uuidString: idStr) ?? UUID(),
                    displayName: displayName,
                    nameSource: nameSource,
                    embedding: embedding,
                    firstSeen: isoFormatter.date(from: firstSeenStr) ?? Date(),
                    lastSeen: isoFormatter.date(from: lastSeenStr) ?? Date(),
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

    private func getSpeakerImpl(id: UUID) -> SpeakerProfile? {
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

    // MARK: - Profile Lookup by Name

    /// Find all profiles whose display name matches the query (using fuzzy name variant matching).
    /// Returns matching profiles sorted by call count descending (strongest profile first).
    func findProfilesByName(_ name: String) -> [SpeakerProfile] {
        return queue.sync {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }

            return allSpeakersImpl()
                .filter { profile in
                    guard let displayName = profile.displayName else { return false }
                    return SpeakerDatabase.areNameVariants(trimmed, displayName)
                }
                .sorted { $0.callCount > $1.callCount }
        }
    }

    // MARK: - Explicit Profile Merge

    /// Merge source profile into target profile.
    /// Blends embeddings weighted by call count, sums call counts, bumps confidence.
    /// Transfers name from source if target has none. Deletes source profile.
    func mergeProfiles(sourceId: UUID, into targetId: UUID) {
        queue.sync {
            mergeProfilesImpl(sourceId: sourceId, into: targetId)
        }
    }

    private func mergeProfilesImpl(sourceId: UUID, into targetId: UUID) {
        guard let source = getSpeakerImpl(id: sourceId),
              let target = getSpeakerImpl(id: targetId) else {
            AppLogger.speakers.warning("Merge failed — profile not found", [
                "sourceId": "\(sourceId)", "targetId": "\(targetId)"
            ])
            return
        }

        // Blend embeddings weighted by call count (stronger profile dominates)
        let totalCalls = Float(source.callCount + target.callCount)
        guard totalCalls > 0, source.embedding.count == target.embedding.count else { return }

        let sourceWeight = Float(source.callCount) / totalCalls
        let targetWeight = Float(target.callCount) / totalCalls
        let blended = zip(source.embedding, target.embedding).map { s, t in
            s * sourceWeight + t * targetWeight
        }
        let normalized = l2Normalize(blended)

        // Transfer name from source if target has none
        if target.displayName == nil, let name = source.displayName {
            setDisplayNameImpl(id: targetId, name: name, source: source.nameSource ?? "user_manual")
        }

        // Update target: blended embedding, summed call count, bumped confidence
        let isoFormatter = ISO8601DateFormatter()
        let now = isoFormatter.string(from: Date())
        let newCallCount = target.callCount + source.callCount
        let newConfidence = min(1.0, target.confidence + 0.15)

        // Wrap UPDATE + DELETE in a transaction so a crash between them can't orphan data
        transaction {
            let sql = """
            UPDATE speakers SET embedding = ?, last_seen = ?, call_count = ?, confidence = ?
            WHERE id = ?;
            """
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
                let embeddingData = normalized.withUnsafeBufferPointer { Data(buffer: $0) }
                sqlite3_bind_blob(statement, 1, (embeddingData as NSData).bytes, Int32(embeddingData.count), SQLITE_TRANSIENT)
                sqlite3_bind_text(statement, 2, (now as NSString).utf8String, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int(statement, 3, Int32(newCallCount))
                sqlite3_bind_double(statement, 4, newConfidence)
                sqlite3_bind_text(statement, 5, (targetId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                if sqlite3_step(statement) != SQLITE_DONE {
                    AppLogger.speakers.error("Failed to update target in merge", ["sqlite_error": dbErrorMessage(), "targetId": targetId.uuidString])
                }
            } else {
                AppLogger.speakers.error("Failed to prepare merge update", ["sqlite_error": dbErrorMessage()])
            }
            sqlite3_finalize(statement)

            // Delete source profile
            let deleteSql = "DELETE FROM speakers WHERE id = ?;"
            var deleteStmt: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteSql, -1, &deleteStmt, nil) == SQLITE_OK {
                sqlite3_bind_text(deleteStmt, 1, (sourceId.uuidString as NSString).utf8String, -1, SQLITE_TRANSIENT)
                if sqlite3_step(deleteStmt) != SQLITE_DONE {
                    AppLogger.speakers.error("Failed to delete source in merge", ["sqlite_error": dbErrorMessage(), "sourceId": sourceId.uuidString])
                }
            } else {
                AppLogger.speakers.error("Failed to prepare merge delete", ["sqlite_error": dbErrorMessage()])
            }
            sqlite3_finalize(deleteStmt)
        }

        AppLogger.speakers.info("Merged profiles", [
            "source": source.displayName ?? "\(sourceId)",
            "target": target.displayName ?? "\(targetId)",
            "newCallCount": "\(newCallCount)"
        ])
    }

    // MARK: - Duplicate Merging

    /// Scan all profiles for likely duplicates and merge them.
    /// Keeps the profile with more calls (better embedding). Transfers display name if the
    /// weaker profile has one and the stronger doesn't. Call after each recording.
    func mergeDuplicates(threshold: Double = 0.6) {
        queue.sync {
            mergeDuplicatesImpl(threshold: threshold)
        }
    }

    private func mergeDuplicatesImpl(threshold: Double) {
        let speakers = allSpeakersImpl()
        guard speakers.count > 1 else { return }

        var mergedIds: Set<UUID> = []
        var mergeCount = 0

        // Each mergeProfilesImpl call is individually transactional (UPDATE + DELETE).
        // No outer transaction — SQLite doesn't support nested BEGIN EXCLUSIVE.
        for i in 0..<speakers.count {
            guard !mergedIds.contains(speakers[i].id) else { continue }

            for j in (i + 1)..<speakers.count {
                guard !mergedIds.contains(speakers[j].id) else { continue }

                let similarity = cosineSimilarity(speakers[i].embedding, speakers[j].embedding)
                guard similarity >= threshold else { continue }

                // Determine which profile to keep (more calls = better data)
                let keeper: SpeakerProfile
                let absorbed: SpeakerProfile
                if speakers[i].callCount >= speakers[j].callCount {
                    keeper = speakers[i]
                    absorbed = speakers[j]
                } else {
                    keeper = speakers[j]
                    absorbed = speakers[i]
                }

                // Merge via mergeProfilesImpl (blends embeddings, transfers name, deletes source)
                mergeProfilesImpl(sourceId: absorbed.id, into: keeper.id)

                mergedIds.insert(absorbed.id)
                mergeCount += 1
                AppLogger.speakers.info("Merged duplicate speaker", ["absorbed": absorbed.displayName ?? "unnamed", "keeper": keeper.displayName ?? "unnamed", "similarity": String(format: "%.3f", similarity)])
            }
        }

        if mergeCount > 0 {
            AppLogger.speakers.info("Duplicate merge complete", ["merged": "\(mergeCount)", "remaining": "\(speakers.count - mergeCount)"])
        }
    }

    // MARK: - Same-Name Profile Merging

    /// Merge all profiles that share the same display name.
    /// After user naming, multiple profiles may end up with the same name (e.g., 4 profiles
    /// all named "Jenny Wen"). This merges them into a single profile — the one with the
    /// highest call count — using the existing weighted embedding blend from mergeProfilesImpl().
    func mergeProfilesByName() {
        queue.sync {
            mergeProfilesByNameImpl()
        }
    }

    private func mergeProfilesByNameImpl() {
        let speakers = allSpeakersImpl()

        // Group named profiles by lowercased display name
        var byName: [String: [SpeakerProfile]] = [:]
        for speaker in speakers {
            guard let name = speaker.displayName?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { continue }
            byName[name, default: []].append(speaker)
        }

        var mergeCount = 0
        for (name, profiles) in byName {
            guard profiles.count > 1 else { continue }

            // Keep the profile with the highest call count (best embedding data)
            let sorted = profiles.sorted { $0.callCount > $1.callCount }
            let keeper = sorted[0]

            for source in sorted.dropFirst() {
                mergeProfilesImpl(sourceId: source.id, into: keeper.id)
                mergeCount += 1
            }

            AppLogger.speakers.info("Merged same-name profiles", [
                "name": name,
                "merged": "\(sorted.count - 1)",
                "keeperId": "\(keeper.id)"
            ])
        }

        if mergeCount > 0 {
            AppLogger.speakers.info("Same-name merge complete", ["merged": "\(mergeCount)"])
        }
    }

    // MARK: - Weak Profile Pruning

    /// Remove unnamed, low-confidence, single-call profiles older than 1 hour.
    /// These are typically noise from AHC over-splitting one speaker into multiple clusters.
    /// Safe to call after each transcription — only prunes stale orphans, never recent profiles.
    func pruneWeakProfiles() {
        queue.sync {
            pruneWeakProfilesImpl()
        }
    }

    private func pruneWeakProfilesImpl() {
        guard isDatabaseOpen else { return }
        // Only prune profiles created more than 1 hour ago — don't prune profiles from
        // the current recording that are about to be named in the speaker naming flow.
        let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))

        let sql = """
        DELETE FROM speakers
        WHERE display_name IS NULL
          AND call_count <= 1
          AND confidence <= 0.5
          AND first_seen < ?;
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (cutoff as NSString).utf8String, -1, SQLITE_TRANSIENT)
            if sqlite3_step(statement) != SQLITE_DONE {
                AppLogger.speakers.error("Failed to prune weak profiles", ["sqlite_error": dbErrorMessage()])
            } else {
                let pruned = Int(sqlite3_changes(db))
                if pruned > 0 {
                    AppLogger.speakers.info("Pruned weak profiles", ["count": "\(pruned)"])
                }
            }
        } else {
            AppLogger.speakers.error("Failed to prepare pruneWeakProfiles", ["sqlite_error": dbErrorMessage()])
        }
        sqlite3_finalize(statement)
    }

    // MARK: - Name Variant Detection

    /// Common English name variants (informal → formal and vice versa)
    private static let nameVariants: [String: Set<String>] = [
        "mike": ["michael", "mike", "mikey"],
        "michael": ["michael", "mike", "mikey"],
        "nate": ["nate", "nathan", "nathaniel"],
        "nathan": ["nate", "nathan", "nathaniel"],
        "nathaniel": ["nate", "nathan", "nathaniel"],
        "dave": ["dave", "david"],
        "david": ["dave", "david"],
        "alex": ["alex", "alexander", "alexandra"],
        "alexander": ["alex", "alexander"],
        "alexandra": ["alex", "alexandra"],
        "dan": ["dan", "daniel", "danny"],
        "daniel": ["dan", "daniel", "danny"],
        "danny": ["dan", "daniel", "danny"],
        "matt": ["matt", "matthew"],
        "matthew": ["matt", "matthew"],
        "chris": ["chris", "christopher", "christine", "christina"],
        "christopher": ["chris", "christopher"],
        "christine": ["chris", "christine"],
        "christina": ["chris", "christina"],
        "nick": ["nick", "nicholas", "nic"],
        "nicholas": ["nick", "nicholas", "nic"],
        "rob": ["rob", "robert", "robbie", "bob", "bobby"],
        "robert": ["rob", "robert", "robbie", "bob", "bobby"],
        "bob": ["rob", "robert", "bob", "bobby"],
        "ed": ["ed", "edward", "eddie"],
        "edward": ["ed", "edward", "eddie"],
        "joe": ["joe", "joseph", "joey"],
        "joseph": ["joe", "joseph", "joey"],
        "tom": ["tom", "thomas", "tommy"],
        "thomas": ["tom", "thomas", "tommy"],
        "sam": ["sam", "samuel", "samantha"],
        "samuel": ["sam", "samuel"],
        "samantha": ["sam", "samantha"],
        "jen": ["jen", "jennifer", "jenny"],
        "jennifer": ["jen", "jennifer", "jenny"],
        "will": ["will", "william", "bill", "billy"],
        "william": ["will", "william", "bill", "billy"],
        "bill": ["will", "william", "bill", "billy"],
        "jim": ["jim", "james", "jimmy"],
        "james": ["jim", "james", "jimmy"],
        "tony": ["tony", "anthony"],
        "anthony": ["tony", "anthony"],
        "steve": ["steve", "steven", "stephen"],
        "steven": ["steve", "steven", "stephen"],
        "stephen": ["steve", "steven", "stephen"],
        "ben": ["ben", "benjamin", "benny"],
        "benjamin": ["ben", "benjamin", "benny"],
        "andy": ["andy", "andrew", "drew"],
        "andrew": ["andy", "andrew", "drew"],
        "drew": ["andy", "andrew", "drew"],
        "marques": ["marques", "marquez"],
        "marquez": ["marques", "marquez"],
    ]

    /// Check if two names are variants of each other (e.g., "Nate" and "Nathan")
    static func areNameVariants(_ name1: String, _ name2: String) -> Bool {
        let a = name1.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let b = name2.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

        // Exact match (case-insensitive)
        if a == b { return true }

        // Check variant table
        if let variants = nameVariants[a], variants.contains(b) { return true }
        if let variants = nameVariants[b], variants.contains(a) { return true }

        // Check if one contains the other (handles "Marques Brownlee" vs "Marques")
        if a.contains(b) || b.contains(a) { return true }

        return false
    }

    // MARK: - Math Utilities

    /// Cosine similarity between two vectors
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dotProduct: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        vDSP_dotpr(a, 1, a, 1, &normA, vDSP_Length(a.count))
        vDSP_dotpr(b, 1, b, 1, &normB, vDSP_Length(b.count))

        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 0 else { return 0 }

        return Double(dotProduct / denom)
    }

    /// L2 normalize a vector
    private func l2Normalize(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_dotpr(v, 1, v, 1, &norm, vDSP_Length(v.count))
        norm = sqrt(norm)
        guard norm > 0 else { return v }

        var result = [Float](repeating: 0, count: v.count)
        var divisor = norm
        vDSP_vsdiv(v, 1, &divisor, &result, 1, vDSP_Length(v.count))
        return result
    }
}
