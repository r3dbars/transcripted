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
    var embedding: [Float]          // 256-dim average voice vector
    var firstSeen: Date
    var lastSeen: Date
    var callCount: Int
    var confidence: Double          // Improves with more data points
}

@available(macOS 14.0, *)
final class SpeakerDatabase {

    static let shared = SpeakerDatabase()

    private var db: OpaquePointer?
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
            print("SpeakerDatabase: Failed to open database at \(dbPath.path)")
        } else {
            print("SpeakerDatabase: Opened at \(dbPath.path)")
        }
    }

    private func createTables() {
        let sql = """
        CREATE TABLE IF NOT EXISTS speakers (
            id TEXT PRIMARY KEY,
            display_name TEXT,
            embedding BLOB NOT NULL,
            first_seen TEXT NOT NULL,
            last_seen TEXT NOT NULL,
            call_count INTEGER NOT NULL DEFAULT 1,
            confidence REAL NOT NULL DEFAULT 0.5,
            created_at TEXT DEFAULT CURRENT_TIMESTAMP
        );
        """
        executeSQL(sql)
    }

    private func executeSQL(_ sql: String) {
        var errorMessage: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errorMessage) != SQLITE_OK {
            if let error = errorMessage {
                print("SpeakerDatabase SQL Error: \(String(cString: error))")
                sqlite3_free(errorMessage)
            }
        }
    }

    // MARK: - Speaker Matching

    /// Match an embedding against all stored speakers using cosine similarity.
    /// Returns the best match above threshold, or nil for a new speaker.
    func matchSpeaker(embedding: [Float], threshold: Double = 0.7) -> SpeakerProfile? {
        return queue.sync {
            matchSpeakerImpl(embedding: embedding, threshold: threshold)
        }
    }

    private func matchSpeakerImpl(embedding: [Float], threshold: Double) -> SpeakerProfile? {
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
            print("SpeakerDatabase: Matched speaker \(match.displayName ?? match.id.uuidString) (similarity: \(String(format: "%.3f", bestSimilarity)))")
        }

        return bestMatch
    }

    // MARK: - Speaker Management

    /// Add a new speaker or update an existing one's embedding.
    /// When updating, uses exponential moving average to refine the voice fingerprint.
    func addOrUpdateSpeaker(embedding: [Float], existingId: UUID? = nil) -> SpeakerProfile {
        return queue.sync {
            addOrUpdateSpeakerImpl(embedding: embedding, existingId: existingId)
        }
    }

    private func addOrUpdateSpeakerImpl(embedding: [Float], existingId: UUID?) -> SpeakerProfile {
        let isoFormatter = ISO8601DateFormatter()
        let now = isoFormatter.string(from: Date())

        if let existingId = existingId, let existing = getSpeakerImpl(id: existingId) {
            // Update: blend embedding with exponential moving average
            let alpha: Float = 0.3  // Weight for new embedding (0.3 = gradual adaptation)
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
                sqlite3_bind_blob(statement, 1, (embeddingData as NSData).bytes, Int32(embeddingData.count), nil)
                sqlite3_bind_text(statement, 2, (now as NSString).utf8String, -1, nil)
                sqlite3_bind_double(statement, 3, newConfidence)
                sqlite3_bind_text(statement, 4, (existingId.uuidString as NSString).utf8String, -1, nil)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)

            return SpeakerProfile(
                id: existingId,
                displayName: existing.displayName,
                embedding: normalized,
                firstSeen: existing.firstSeen,
                lastSeen: Date(),
                callCount: existing.callCount + 1,
                confidence: newConfidence
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
                sqlite3_bind_text(statement, 1, (newId.uuidString as NSString).utf8String, -1, nil)
                sqlite3_bind_blob(statement, 2, (embeddingData as NSData).bytes, Int32(embeddingData.count), nil)
                sqlite3_bind_text(statement, 3, (now as NSString).utf8String, -1, nil)
                sqlite3_bind_text(statement, 4, (now as NSString).utf8String, -1, nil)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)

            print("SpeakerDatabase: Created new speaker \(newId)")
            return SpeakerProfile(
                id: newId,
                displayName: nil,
                embedding: normalized,
                firstSeen: Date(),
                lastSeen: Date(),
                callCount: 1,
                confidence: 0.5
            )
        }
    }

    /// Set the display name for a speaker (user-assigned or Gemini-inferred)
    func setDisplayName(id: UUID, name: String) {
        queue.async { [weak self] in
            self?.setDisplayNameImpl(id: id, name: name)
        }
    }

    private func setDisplayNameImpl(id: UUID, name: String) {
        let sql = "UPDATE speakers SET display_name = ? WHERE id = ?;"
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, (name as NSString).utf8String, -1, nil)
            sqlite3_bind_text(statement, 2, (id.uuidString as NSString).utf8String, -1, nil)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    /// Get all stored speakers
    func allSpeakers() -> [SpeakerProfile] {
        return queue.sync { allSpeakersImpl() }
    }

    private func allSpeakersImpl() -> [SpeakerProfile] {
        var speakers: [SpeakerProfile] = []
        let sql = "SELECT id, display_name, embedding, first_seen, last_seen, call_count, confidence FROM speakers ORDER BY last_seen DESC;"
        var statement: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            let isoFormatter = ISO8601DateFormatter()

            while sqlite3_step(statement) == SQLITE_ROW {
                let idStr = String(cString: sqlite3_column_text(statement, 0))
                let displayName: String? = sqlite3_column_text(statement, 1).map { String(cString: $0) }

                // Read embedding BLOB
                let blobPtr = sqlite3_column_blob(statement, 2)
                let blobSize = sqlite3_column_bytes(statement, 2)
                var embedding: [Float] = []
                if let ptr = blobPtr, blobSize > 0 {
                    let floatCount = Int(blobSize) / MemoryLayout<Float>.size
                    embedding = Array(UnsafeBufferPointer(
                        start: ptr.assumingMemoryBound(to: Float.self),
                        count: floatCount
                    ))
                }

                let firstSeenStr = String(cString: sqlite3_column_text(statement, 3))
                let lastSeenStr = String(cString: sqlite3_column_text(statement, 4))
                let callCount = Int(sqlite3_column_int(statement, 5))
                let confidence = sqlite3_column_double(statement, 6)

                speakers.append(SpeakerProfile(
                    id: UUID(uuidString: idStr) ?? UUID(),
                    displayName: displayName,
                    embedding: embedding,
                    firstSeen: isoFormatter.date(from: firstSeenStr) ?? Date(),
                    lastSeen: isoFormatter.date(from: lastSeenStr) ?? Date(),
                    callCount: callCount,
                    confidence: confidence
                ))
            }
        }
        sqlite3_finalize(statement)
        return speakers
    }

    private func getSpeakerImpl(id: UUID) -> SpeakerProfile? {
        return allSpeakersImpl().first { $0.id == id }
    }

    /// Delete a speaker profile
    func deleteSpeaker(id: UUID) {
        queue.async { [weak self] in
            let sql = "DELETE FROM speakers WHERE id = ?;"
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(self?.db, sql, -1, &statement, nil) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, (id.uuidString as NSString).utf8String, -1, nil)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
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
