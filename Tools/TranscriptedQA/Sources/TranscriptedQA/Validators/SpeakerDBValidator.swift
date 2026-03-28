import Foundation

struct SpeakerDBValidator {
    let dbPath: String

    func validate() -> [ValidationResult] {
        var results: [ValidationResult] = []
        let target = "speakers.sqlite"

        // File exists
        guard FileManager.default.fileExists(atPath: dbPath) else {
            return [.warn("database/speakers-exists", target: target, detail: "speakers.sqlite not found")]
        }

        // Open DB
        guard let db = try? SQLiteReader(path: dbPath) else {
            return [.fail("database/speakers-open", target: target, detail: "Cannot open speakers.sqlite")]
        }

        // Integrity check
        if let result = try? db.pragma("integrity_check"), result == "ok" {
            results.append(.pass("database/speakers-integrity", target: target))
        } else {
            results.append(.fail("database/speakers-integrity", target: target, detail: "PRAGMA integrity_check failed"))
        }

        // WAL mode
        if let mode = try? db.pragma("journal_mode"), mode == "wal" {
            results.append(.pass("database/speakers-wal-mode", target: target))
        } else {
            results.append(.warn("database/speakers-wal-mode", target: target, detail: "Not in WAL mode"))
        }

        // Schema check
        if let columns = try? db.tableColumns("speakers") {
            let expectedColumns = ["id", "display_name", "name_source", "embedding",
                                   "first_seen", "last_seen", "call_count", "confidence",
                                   "dispute_count", "created_at"]
            let actualNames = columns.map { $0.name }
            let missing = expectedColumns.filter { !actualNames.contains($0) }
            if missing.isEmpty {
                results.append(.pass("database/speakers-schema", target: target))
            } else {
                results.append(.fail("database/speakers-schema", target: target, detail: "Missing columns: \(missing.joined(separator: ", "))"))
            }
        } else {
            results.append(.fail("database/speakers-schema", target: target, detail: "Cannot read table schema"))
        }

        // Embedding size (256 float32 = 1024 bytes)
        if let rows = try? db.query("SELECT id, LENGTH(embedding) as emb_len FROM speakers WHERE embedding IS NOT NULL") {
            var allCorrect = true
            for row in rows {
                if let len = row["emb_len"] as? Int64, len != 1024 {
                    let id = row["id"] as? String ?? "?"
                    results.append(.fail("database/speakers-embedding-size", target: target, detail: "Speaker \(id) has \(len)-byte embedding (expected 1024)"))
                    allCorrect = false
                }
            }
            if allCorrect && !rows.isEmpty {
                results.append(.pass("database/speakers-embedding-size", target: target))
            }
        }

        // No NULL embeddings
        if let rows = try? db.query("SELECT COUNT(*) as cnt FROM speakers WHERE embedding IS NULL"),
           let cnt = rows.first?["cnt"] as? Int64 {
            if cnt == 0 {
                results.append(.pass("database/speakers-no-null-embeddings", target: target))
            } else {
                results.append(.fail("database/speakers-no-null-embeddings", target: target, detail: "\(cnt) speakers with NULL embedding"))
            }
        }

        // Valid UUIDs
        if let rows = try? db.query("SELECT id FROM speakers") {
            let invalidIds = rows.compactMap { row -> String? in
                guard let id = row["id"] as? String else { return nil }
                return UUID(uuidString: id) == nil ? id : nil
            }
            if invalidIds.isEmpty {
                results.append(.pass("database/speakers-valid-uuids", target: target))
            } else {
                results.append(.fail("database/speakers-valid-uuids", target: target, detail: "Invalid UUIDs: \(invalidIds.prefix(3).joined(separator: ", "))"))
            }
        }

        // Confidence range [0, 1]
        if let rows = try? db.query("SELECT id, confidence FROM speakers") {
            let outOfRange = rows.filter { row in
                guard let conf = row["confidence"] as? Double else { return true }
                return conf < 0.0 || conf > 1.0
            }
            if outOfRange.isEmpty {
                results.append(.pass("database/speakers-confidence-range", target: target))
            } else {
                results.append(.fail("database/speakers-confidence-range", target: target, detail: "\(outOfRange.count) speakers with out-of-range confidence"))
            }
        }

        // Call count positive
        if let rows = try? db.query("SELECT id, call_count FROM speakers") {
            let invalid = rows.filter { row in
                guard let cnt = row["call_count"] as? Int64 else { return true }
                return cnt < 1
            }
            if invalid.isEmpty {
                results.append(.pass("database/speakers-callcount-positive", target: target))
            } else {
                results.append(.fail("database/speakers-callcount-positive", target: target, detail: "\(invalid.count) speakers with call_count < 1"))
            }
        }

        // Name source values
        if let rows = try? db.query("SELECT id, name_source FROM speakers WHERE name_source IS NOT NULL") {
            let validSources = ["user_manual", "qwen_inferred", "test"]
            let invalid = rows.filter { row in
                guard let source = row["name_source"] as? String else { return false }
                return !validSources.contains(source)
            }
            if invalid.isEmpty {
                results.append(.pass("database/speakers-name-source", target: target))
            } else {
                results.append(.fail("database/speakers-name-source", target: target, detail: "\(invalid.count) speakers with invalid name_source"))
            }
        }

        // File permissions
        if let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath),
           let perms = attrs[.posixPermissions] as? Int {
            if perms & 0o077 == 0 { // Owner-only
                results.append(.pass("database/speakers-permissions", target: target))
            } else {
                results.append(.warn("database/speakers-permissions", target: target, detail: "Permissions \(String(perms, radix: 8)) — expected 0600"))
            }
        }

        return results
    }
}
